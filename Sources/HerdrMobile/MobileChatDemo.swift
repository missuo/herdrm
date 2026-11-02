#if DEBUG
import Foundation
import HerdrKit
import HerdrSSH
import SwiftUI

/// Debug-only: the Chat tab against a scripted fake device, with fake data
/// (test1, test2, …), for screenshots and for exercising the poll → parse →
/// answer loop without a Mac. Launch with `-HerdrmChatDemo`.
struct MobileChatDemoView: View {
    @State private var transport: DemoChatTransport
    @State private var agent = DemoChatTransport.agent(status: .blocked)
    @StateObject private var chat: MobileAgentChatModel
    /// `-HerdrmChatDemoAutoplay`: answers each choice through the chat model
    /// itself (re-read, keys, wait for the prompt to clear), a few seconds after it shows.
    private let autoplay = ProcessInfo.processInfo.arguments.contains("-HerdrmChatDemoAutoplay")

    init() {
        let transport = DemoChatTransport()
        _transport = State(initialValue: transport)
        _chat = StateObject(wrappedValue: MobileAgentChatModel(
            transport: transport, agent: DemoChatTransport.agent(status: .blocked)
        ))
    }

    var body: some View {
        NavigationStack {
            MobileAgentDetailView(transport: transport, agent: agent, title: "test1",
                                  terminalAvailable: false, chat: chat)
        }
        .task {
            var shownSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                let status = transport.status
                if status != agent.status { agent = DemoChatTransport.agent(status: status) }
                guard autoplay, let choice = chat.choice, chat.answering == nil else { shownSince = nil; continue }
                let since = shownSince ?? Date()
                shownSince = since
                if Date().timeIntervalSince(since) > 4, let first = choice.options.first {
                    chat.choose(first)
                    shownSince = nil
                }
            }
        }
    }
}

/// Plays a short Claude Code session: a permission prompt, then a question,
/// then a reply, advancing as the chat sends the keys a real TUI would get.
final class DemoChatTransport: MobileTransport, MobileCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var transcript = Data()
    private var screen = ""
    private var step = 0
    private var currentStatus: AgentStatus = .blocked

    var status: AgentStatus {
        lock.lock(); defer { lock.unlock() }
        return currentStatus
    }

    static func agent(status: AgentStatus) -> AgentInfo {
        let json = """
        {"agent":"claude","agent_status":"\(status.rawValue)","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1",
         "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"demo-session"}}
        """
        return try! JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
    }

    init() {
        append([
            Self.user("u1", nil, "Add an on-disk cache to test1 and run the tests."),
            Self.assistant("a1", "u1", [["type": "text", "text": "I'll look at the current loader first, then add a **disk cache** behind `CacheStore`."]]),
            Self.assistant("a2", "a1", [["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "Sources/test1/Loader.swift"]]]),
            Self.result("r1", "a2", "t1", "struct Loader {\n    func load() async throws -> Data\n}"),
            Self.assistant("a3", "r1", [["type": "tool_use", "id": "t2", "name": "Edit", "input": [
                "file_path": "Sources/test1/Loader.swift", "old_string": "let cache = MemoryCache()", "new_string": "let cache = DiskCache(directory: .caches)",
            ]]]),
            Self.result("r2", "a3", "t2", "The file has been updated."),
            Self.assistant("a4", "r2", [["type": "tool_use", "id": "t3", "name": "Bash", "input": [
                "command": "swift test --filter CacheTests", "description": "Run the cache tests",
            ]]]),
        ])
        screen = Self.permissionScreen
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        try await Task.sleep(for: .milliseconds(120))
        switch method {
        case "pane.read":
            lock.lock(); defer { lock.unlock() }
            return .object(["read": .object(["text": .string(screen)])])
        case "pane.send_input":
            if case .array(let keys)? = params["keys"], let key = keys.first?.stringValue { advance(key: key) }
            return .object([:])
        case "agent.prompt":
            if let text = params["text"]?.stringValue {
                append([Self.user("p\(UUID().uuidString)", lastUUID, text)])
            }
            return .object([:])
        default:
            return .object([:])
        }
    }

    func runCommand(_ command: String, timeout: Duration) async throws -> (stdout: Data, status: Int32) {
        try await Task.sleep(for: .milliseconds(150))
        lock.lock(); defer { lock.unlock() }
        var start = 0
        if let range = command.range(of: #"start=(\d+)"#, options: .regularExpression) {
            start = Int(command[range].dropFirst(6)) ?? 0
        }
        if start > transcript.count { start = 0 }
        var output = Data("\(AgentChatRemoteSource.headerPrefix)\(transcript.count) \(start) /demo/demo-session.jsonl\n".utf8)
        output.append(transcript.suffix(from: start))
        return (output, 0)
    }

    func events(kinds _: [String], statusPaneIDs _: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    func openTerminal(command _: String, columns _: Int, rows _: Int) async throws -> SSHPTYChannel {
        throw MobileTransportError.tailcatTerminalUnsupported
    }

    func close() async {}

    // MARK: - Script

    private var lastUUID: String?

    private func advance(key: String) {
        lock.lock()
        let current = step
        lock.unlock()
        switch (current, key) {
        case (0, "1"):
            set(screen: "", status: .working, step: 1)
            Task {
                try? await Task.sleep(for: .seconds(2))
                append([
                    Self.result("r3", "a4", "t3", "Test Suite 'CacheTests' passed.\nExecuted 6 tests, with 0 failures"),
                    Self.assistant("a5", "r3", [["type": "text", "text": "All 6 cache tests pass. One decision before I wire it in:"]]),
                    Self.assistant("a6", "a5", [["type": "tool_use", "id": "t4", "name": "AskUserQuestion", "input": ["questions": [[
                        "question": "How long should cached files live?", "header": "Expiry", "multiSelect": false,
                        "options": [["label": "1 day (Recommended)", "description": "Fresh data, small disk use."],
                                    ["label": "1 week", "description": "Fewer downloads."]],
                    ]]]]]),
                ])
                set(screen: Self.questionScreen, status: .blocked, step: 2)
            }
        case (0, "esc"), (0, "4"):
            set(screen: "", status: .idle, step: 9)
            append([Self.result("r3", "a4", "t3", "The user doesn't want to proceed with this tool use.")])
        case (2, "1"), (2, "2"):
            let answer = key == "1" ? "1 day (Recommended)" : "1 week"
            set(screen: "", status: .working, step: 3)
            Task {
                try? await Task.sleep(for: .seconds(1))
                append([
                    Self.result("r4", "a6", "t4", "User has answered your questions",
                                answers: ["How long should cached files live?": answer]),
                    Self.assistant("a7", "r4", [["type": "text", "text": "Done. Cached files now expire after **\(answer)**.\n\n- `DiskCache` prunes on launch\n- `CacheTests` covers expiry\n\n```swift\nlet cache = DiskCache(directory: .caches, maxAge: .days(1))\n```"]]),
                ])
                set(screen: "", status: .done, step: 4)
            }
        default:
            break
        }
    }

    private func set(screen: String, status: AgentStatus, step: Int) {
        lock.lock()
        self.screen = screen
        currentStatus = status
        self.step = step
        lock.unlock()
    }

    private func append(_ lines: [String]) {
        lock.lock()
        for line in lines {
            transcript.append(Data((line + "\n").utf8))
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                lastUUID = object["uuid"] as? String
            }
        }
        lock.unlock()
    }

    private static func encode(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func user(_ uuid: String, _ parent: String?, _ text: String) -> String {
        encode(["type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": "2026-01-02T03:04:05.000Z",
                "message": ["role": "user", "content": text]])
    }

    private static func assistant(_ uuid: String, _ parent: String, _ content: [[String: Any]]) -> String {
        encode(["type": "assistant", "uuid": uuid, "parentUuid": parent, "timestamp": "2026-01-02T03:04:06.000Z",
                "message": ["id": "m-\(uuid)", "role": "assistant", "content": content]])
    }

    private static func result(_ uuid: String, _ parent: String, _ tool: String, _ text: String,
                               answers: [String: String]? = nil) -> String {
        var object: [String: Any] = ["type": "user", "uuid": uuid, "parentUuid": parent,
                                     "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": tool, "content": text]]]]
        if let answers { object["toolUseResult"] = ["answers": answers] }
        return encode(object)
    }

    private static let rule = String(repeating: "─", count: 50)
    private static let dashes = String(repeating: "╌", count: 50)

    private static var permissionScreen: String {
        """
        \(rule)
         Bash command

         Run the cache tests
        \(dashes)
         swift test --filter CacheTests
        \(dashes)

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for swift test commands in /Users/test1/test2
           3. Yes, and switch to auto mode
           4. No

         Esc to cancel · Tab to amend
        """
    }

    private static var questionScreen: String {
        """
        \(rule)
         ☐ Expiry

        How long should cached files live?

        ❯ 1. 1 day (Recommended)
             Fresh data, small disk use.
          2. 1 week
             Fewer downloads.
          3. Type something.
        \(rule)
          4. Chat about this

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
    }
}
#endif
