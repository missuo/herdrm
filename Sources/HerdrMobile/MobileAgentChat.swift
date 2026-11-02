import Foundation
import HerdrKit
import SwiftUI

/// A transport that can run a short command on the device (SSH). The chat reads
/// the agent's transcript this way; without one it still answers choices and
/// sends prompts, both of which are herdr RPCs.
protocol MobileCommandRunning: AnyObject {
    func runCommand(_ command: String, timeout: Duration) async throws -> (stdout: Data, status: Int32)
}

/// Drives one agent's Chat tab: polls the transcript tail over SSH while the tab
/// is visible, reads the pane's screen while herdr reports the agent blocked,
/// and answers the choice the agent waits on with the keys its TUI expects.
///
/// Only official herdr methods are used: `pane.read` (visible text),
/// `pane.send_input` (one key per request) and `agent.prompt`.
@MainActor
final class MobileAgentChatModel: ObservableObject {
    enum Availability: Equatable {
        case loading
        case ready
        /// herdr reports no session id for this pane (no official integration).
        case noSession
        /// The agent is not one the chat can read.
        case unsupportedAgent
        /// The transport has no shell (tailcat).
        case noShell
        /// No transcript file for this session on the device.
        case missing
        case failed(String)
    }

    enum Answering: Equatable {
        /// Keys are going out for this option (0 = submit, -1 = cancel).
        case sending(Int)
        /// Sent; waiting for the prompt to go away.
        case waiting(fingerprint: String, since: Date)
    }

    @Published private(set) var items: [AgentChatItem] = []
    @Published private(set) var availability: Availability = .loading
    @Published private(set) var choice: AgentPendingChoice?
    @Published private(set) var answering: Answering?
    @Published var notice: String?
    /// Prompts sent from the composer that the transcript has not shown yet.
    @Published private(set) var outgoing: [String] = []
    @Published private(set) var status: AgentStatus

    let kind: AgentChatKind?
    let paneID: String
    private let transport: MobileTransport
    private let sessionID: String?
    private var parser: (any AgentChatTranscriptParsing)?
    private var path: String?
    private var offset: Int?
    private var missingUntil: Date?
    private var loop: Task<Void, Never>?
    private var wake = false
    /// The agent left `blocked` after the last answer went out.
    private var leftBlockedSinceAnswer = false

    static let pollInterval: Duration = .milliseconds(1500)
    static let firstReadBytes = 3 * 1_048_576
    static let laterReadBytes = 1_048_576
    /// How long an answer may go unacknowledged before the card comes back.
    static let answerTimeout: TimeInterval = 8

    init(transport: MobileTransport, agent: AgentInfo) {
        self.transport = transport
        paneID = agent.paneID
        kind = AgentChatKind(agentKind: agent.agentKindRaw)
        sessionID = kind?.sessionID(from: agent.agentSession)
        status = agent.status
        if kind == nil {
            availability = .unsupportedAgent
        } else if !(transport is MobileCommandRunning) {
            availability = .noShell
        } else if sessionID == nil {
            availability = .noSession
        }
    }

    var pendingToolCall: AgentChatToolCall? { parser?.pendingToolCall }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollTranscript()
                await self.pollScreen()
                await self.sleepUntilNextPoll()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// herdr's status for the pane changed (from the session's event pump).
    func update(status: AgentStatus) {
        guard status != self.status else { return }
        if self.status == .blocked { leftBlockedSinceAnswer = true }
        self.status = status
        pollSoon()
    }

    func pollSoon() { wake = true }

    private func sleepUntilNextPoll() async {
        let deadline = ContinuousClock.now + Self.pollInterval
        while !Task.isCancelled, !wake, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        wake = false
    }

    // MARK: - Transcript

    private func pollTranscript() async {
        guard let kind, let sessionID, let runner = transport as? MobileCommandRunning else { return }
        if let missingUntil, missingUntil > Date() { return }
        for _ in 0..<8 {
            let first = parser == nil
            guard let command = AgentChatRemoteSource.command(
                agent: kind, sessionID: sessionID, knownPath: path, offset: offset,
                maxBytes: first ? Self.firstReadBytes : Self.laterReadBytes
            ) else {
                availability = .noSession
                return
            }
            let output: (stdout: Data, status: Int32)
            do {
                output = try await runner.runCommand(command, timeout: .seconds(20))
            } catch {
                if items.isEmpty { availability = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
                return
            }
            guard !Task.isCancelled else { return }
            if output.status == AgentChatRemoteSource.missingStatus {
                missingUntil = Date().addingTimeInterval(10)
                if items.isEmpty { availability = .missing }
                return
            }
            guard let chunk = AgentChatRemoteSource.parse(output.stdout) else {
                if items.isEmpty { availability = .failed(String(localized: "The device returned an unreadable transcript.")) }
                return
            }
            if first || chunk.start != offset || chunk.path != path {
                parser = Self.makeParser(kind, startsMidFile: chunk.start > 0)
            }
            path = chunk.path
            offset = chunk.end
            if parser?.ingest(chunk.body) == true, let parsed = parser?.items {
                items = parsed
                reconcileOutgoing()
            }
            availability = .ready
            guard chunk.hasMore, !chunk.body.isEmpty else { return }
        }
    }

    private static func makeParser(_ kind: AgentChatKind, startsMidFile: Bool) -> any AgentChatTranscriptParsing {
        switch kind {
        case .claude: return AgentChatClaudeTranscript(startsMidFile: startsMidFile)
        case .codex: return AgentChatCodexTranscript(startsMidFile: startsMidFile)
        }
    }

    private func reconcileOutgoing() {
        guard !outgoing.isEmpty else { return }
        let recent = items.suffix(20).compactMap { item -> String? in
            if case .user(let text, _) = item.content { return text }
            return nil
        }
        outgoing.removeAll { sent in recent.contains(sent) }
    }

    // MARK: - Pending choice

    /// The screen is read only while the agent may be waiting on a choice: herdr
    /// says blocked, or a tool call is still open while the agent is not working.
    private var mayBeWaiting: Bool {
        status == .blocked || (pendingToolCall != nil && status != .working)
    }

    private func pollScreen() async {
        guard kind != nil else { return }
        if case .sending = answering { return }
        guard mayBeWaiting else {
            choice = nil
            settleAnswer(current: nil)
            return
        }
        let current = await readChoice()
        settleAnswer(current: current)
        choice = current
    }

    private func readChoice() async -> AgentPendingChoice? {
        do {
            let result = try await transport.request(
                method: "pane.read",
                params: .object([
                    "pane_id": .string(paneID),
                    "source": .string("visible"),
                    "format": .string("text"),
                ])
            )
            return result["read"]?["text"]?.stringValue.flatMap(AgentChoicePrompt.parse)
        } catch {
            return nil
        }
    }

    /// An answer is done once its prompt is gone, replaced, or herdr has seen the
    /// agent leave `blocked` (a re-shown plan prompt looks the same as the old one).
    private func settleAnswer(current: AgentPendingChoice?) {
        guard case .waiting(let fingerprint, let since) = answering else { return }
        if current?.fingerprint != fingerprint || leftBlockedSinceAnswer {
            answering = nil
        } else if Date().timeIntervalSince(since) > Self.answerTimeout {
            answering = nil
            notice = String(localized: "The agent didn't respond to that answer. Check the Terminal tab.")
        }
    }

    /// Picks `option`; for options that take words, types `text` into it and submits.
    func choose(_ option: AgentPendingChoice.Option, text: String? = nil) {
        guard let kind, answering == nil else { return }
        answering = .sending(option.number)
        notice = nil
        Task {
            guard let fresh = await verifiedChoice() else { return }
            guard let target = fresh.options.first(where: { $0.number == option.number }) else {
                answering = nil
                return
            }
            let ok = await send(AgentChoiceKeys.select(target, in: fresh, agent: kind))
            var typed = false
            if ok, let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, target.acceptsText {
                try? await Task.sleep(for: .milliseconds(350))
                typed = await sendText(text)
                try? await Task.sleep(for: .milliseconds(200))
                typed = await send(["enter"]) && typed
            }
            guard ok, text == nil || typed else {
                answering = nil
                notice = String(localized: "Couldn't send the answer. Check the connection and try again.")
                return
            }
            if fresh.isMultiSelect, target.isChecked != nil {
                // A toggle: the question stays; show the new checkbox state.
                answering = nil
                choice = await readChoice() ?? fresh
                return
            }
            leftBlockedSinceAnswer = false
            answering = .waiting(fingerprint: fresh.fingerprint, since: Date())
            pollSoon()
        }
    }

    /// Multi-select: confirms the ticked options.
    func submit() {
        guard let kind, answering == nil else { return }
        answering = .sending(0)
        Task {
            guard let fresh = await verifiedChoice() else { return }
            guard await send(AgentChoiceKeys.submit(fresh, agent: kind)) else {
                answering = nil
                notice = String(localized: "Couldn't send the answer. Check the connection and try again.")
                return
            }
            leftBlockedSinceAnswer = false
            answering = .waiting(fingerprint: fresh.fingerprint, since: Date())
            pollSoon()
        }
    }

    /// Esc: dismisses the prompt (Claude treats it as "No").
    func cancelChoice() {
        guard answering == nil else { return }
        answering = .sending(-1)
        Task {
            guard let fresh = await verifiedChoice() else { return }
            _ = await send(AgentChoiceKeys.cancel)
            leftBlockedSinceAnswer = false
            answering = .waiting(fingerprint: fresh.fingerprint, since: Date())
            pollSoon()
        }
    }

    /// Re-reads the screen right before typing: a digit sent after the prompt
    /// closed would land in the agent's input box as text.
    private func verifiedChoice() async -> AgentPendingChoice? {
        let shown = choice
        let fresh = await readChoice()
        guard let fresh, let shown, fresh.fingerprint == shown.fingerprint else {
            choice = fresh
            answering = nil
            notice = String(localized: "The question changed. Check the options again.")
            return nil
        }
        return fresh
    }

    /// One key per request: Claude Code ignores two digits that arrive in one read.
    private func send(_ keys: [String]) async -> Bool {
        for (index, key) in keys.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(90)) }
            do {
                _ = try await transport.request(
                    method: "pane.send_input",
                    params: .object(["pane_id": .string(paneID), "keys": .array([.string(key)])])
                )
            } catch {
                return false
            }
        }
        return true
    }

    private func sendText(_ text: String) async -> Bool {
        do {
            _ = try await transport.request(
                method: "pane.send_input",
                params: .object(["pane_id": .string(paneID), "text": .string(text)])
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Composer

    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        outgoing.append(trimmed)
        Task {
            do {
                _ = try await transport.request(
                    method: "agent.prompt",
                    params: .object(["target": .string(paneID), "text": .string(trimmed)])
                )
                pollSoon()
            } catch {
                outgoing.removeAll { $0 == trimmed }
                notice = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "Couldn't send the message.")
            }
        }
    }

    /// Interrupts the agent's current turn, as Esc does in its terminal.
    func interrupt() {
        Task { _ = await send(["esc"]) }
    }
}
