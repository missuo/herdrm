import Foundation
import Darwin
import XCTest
@testable import HerdrKit

final class ClaudeHistoryProviderTests: XCTestCase {
    private let sessionID = "0b4f6c1e-1111-4222-8333-944455556666"
    private var configDirectory: URL!
    private var transcript: URL!

    override func setUpWithError() throws {
        configDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hhist-\(UUID().uuidString.prefix(8))")
        let project = configDirectory.appendingPathComponent("projects/-tmp-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        transcript = project.appendingPathComponent("\(sessionID).jsonl")
        // The reader is a child process; it finds the transcript through this.
        setenv("CLAUDE_CONFIG_DIR", configDirectory.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CLAUDE_CONFIG_DIR")
        try? FileManager.default.removeItem(at: configDirectory)
    }

    private func prompt(_ uuid: String, parent: String?, _ text: String) -> String {
        record(["type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "origin": ["kind": "human"],
                "message": ["role": "user", "content": text]])
    }

    private func reply(_ uuid: String, parent: String, id: String, _ text: String) -> String {
        record(["type": "assistant", "uuid": uuid, "parentUuid": parent,
                "message": ["id": id, "role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    private func record(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func provider(store: ClaudeTranscriptStore = .init()) -> ClaudeHistoryProvider {
        let device = Device(name: "fixture", kind: .local, socketPath: "/tmp/none.sock")
        return ClaudeHistoryProvider(store: store, device: device, service: HerdrService(device: device, autoStartLocalServer: false))
    }

    func testReadsTheTranscriptAndFollowsAppendedRecords() async throws {
        try (prompt("u1", parent: nil, "first") + reply("a1", parent: "u1", id: "m1", "one")).write(to: transcript, atomically: true, encoding: .utf8)
        let store = ClaudeTranscriptStore()
        let provider = provider(store: store)
        let latest = try await provider.read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init())
        XCTAssertEqual(latest.availability, "ready")
        XCTAssertEqual(latest.binding?.sessionID, sessionID)
        XCTAssertEqual(latest.messages.map(\.id), ["u1", "a-m1"])
        let cursor = try XCTUnwrap(latest.changesCursor)

        try append(prompt("u2", parent: "a1", "second"))
        var upserts: [String] = []
        for _ in 0..<40 where upserts.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            upserts = try await provider.read(target: "w:p", expectedSessionID: sessionID, window: .changes(cursor: cursor), limits: .init()).upserts.map(\.id)
        }
        XCTAssertEqual(upserts, ["u2"])
        await store.stopAll()
    }

    func testMissingTranscriptIsReportedNotThrown() async throws {
        let page = try await provider().read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init())
        XCTAssertEqual(page.availability, "source_missing")
    }

    /// An alias, wrapper or account switcher sets `CLAUDE_CONFIG_DIR` on the `claude`
    /// process alone, so HerdrM's own environment never has it.
    func testFindsTheTranscriptInAConfigDirectorySetOnlyOnTheAgentProcess() async throws {
        try prompt("u1", parent: nil, "first").write(to: transcript, atomically: true, encoding: .utf8)
        unsetenv("CLAUDE_CONFIG_DIR")
        // macOS hides the environment of its own binaries from `ps`, so the stand-in
        // agent is a re-signed copy of sleep, the way `claude` is a third-party binary.
        let sleep = configDirectory.appendingPathComponent("agent")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleep)
        let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-s", "-", "-f", sleep.path])
        sign.waitUntilExit()
        let agent = Process()
        agent.executableURL = sleep
        agent.arguments = ["30"]
        agent.environment = ["CLAUDE_CONFIG_DIR": configDirectory.path]
        try agent.run()
        defer { agent.terminate() }

        let store = ClaudeTranscriptStore()
        let page = try await provider(store: store).read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init())
        XCTAssertEqual(page.availability, "ready")
        XCTAssertEqual(page.messages.map(\.id), ["u1"])
        await store.stopAll()
    }

    /// sshd runs the command in the login shell; zsh aborts it on the first glob that
    /// matches nothing, before the next directory is tried.
    func testRemoteCommandRunsUnderShWhateverTheLoginShell() throws {
        let home = configDirectory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/-tmp-other"), withIntermediateDirectories: true)
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-c", ClaudeTranscriptReader.remoteCommand(sessionID: sessionID)]
        zsh.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        zsh.standardError = FileHandle.nullDevice
        try zsh.run()
        zsh.waitUntilExit()
        XCTAssertEqual(zsh.terminationStatus, ClaudeTranscriptReader.missingStatus)
    }

    func testUnsupportedDevicesAndSessionIDsNeverStartAReader() async throws {
        let store = ClaudeTranscriptStore()
        let tailcat = Device(name: "tc", kind: .tailcat)
        let snapshot = try await store.snapshot(device: tailcat, sessionID: sessionID)
        guard case .unavailable("unsupported_device") = snapshot else { return XCTFail("\(snapshot)") }
        let local = Device(name: "l", kind: .local)
        let injected = try await store.snapshot(device: local, sessionID: "x'; rm -rf ~; '")
        guard case .unavailable("no_binding") = injected else { return XCTFail("\(injected)") }
    }

    func testJumpSearchesThePaneAndScrollsItsViewportOnly() async throws {
        let text = prompt("u1", parent: nil, "continue") + reply("a1", parent: "u1", id: "m1", "ok")
            + prompt("u2", parent: "a1", "continue") + reply("a2", parent: "u2", id: "m2", "ok again")
        try text.write(to: transcript, atomically: true, encoding: .utf8)
        // Row 30 is Claude quoting the prompt mid-line; rows 10 and 50 are the prompts.
        let socket = try PaneFixtureSocket(matches: [(10, 2), (30, 12), (50, 2)], maxOffset: 200, viewportRows: 40)
        defer { socket.stop() }
        let store = ClaudeTranscriptStore()
        let device = Device(name: "fixture", kind: .local, socketPath: socket.path)
        let service = HerdrService(device: device, autoStartLocalServer: false)
        _ = try await service.connect()
        let provider = ClaudeHistoryProvider(store: store, device: device, service: service)
        let page = try await provider.read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init())
        let second = try XCTUnwrap(page.messages.first { $0.id == "u2" })
        let result = try await provider.jump(target: "w:p", expectedSessionID: sessionID,
                                             expectedGeneration: try XCTUnwrap(page.binding?.generation),
                                             messageID: "u2", messageRevision: second.messageRevision)
        await service.disconnect()
        await store.stopAll()
        XCTAssertEqual(result.sourceRow, 50)
        XCTAssertEqual(result.offsetFromBottom, 151, "row 50 lands one line below the viewport top")
        let methods = socket.requests.compactMap { $0["method"] as? String }
        XCTAssertEqual(methods, ["ping", "pane.copy_motion", "pane.copy_search", "pane.get", "pane.copy_motion", "pane.scroll"])
        let search = try XCTUnwrap(socket.requests.first { $0["method"] as? String == "pane.copy_search" }?["params"] as? [String: Any])
        XCTAssertEqual(search["query"] as? String, "continue")
        XCTAssertEqual(search["content_revision"] as? Int, 42)
        XCTAssertTrue(methods.allSatisfy { !["pane.send_input", "pane.send_text", "pane.send_keys", "agent.prompt"].contains($0) })
    }

    /// Ten prompts, each answered with `replyLines` lines; the terminal shows each reply
    /// in `shownLines` rows (Claude collapses tool output, so it can be fewer).
    private func fullscreenJump(to target: Int, replyLines: Int = 40, shownLines: Int? = nil, drop: Int? = nil,
                                prompts: [String]? = nil) async throws -> (Result<ConversationJumpResult, Error>, FullscreenClaude) {
        let texts = prompts ?? (0..<10).map { "question number \($0)" }
        var transcriptText = "", parent: String?, history: [String] = []
        for (n, prompt) in texts.enumerated() {
            let reply = (0..<replyLines).map { "answer \(n) line \($0)" }.joined(separator: "\n")
            transcriptText += self.prompt("u\(n)", parent: parent, prompt)
                + self.reply("a\(n)", parent: "u\(n)", id: "m\(n)", reply)
            parent = "a\(n)"
            if n != drop { history.append("❯ \(prompt)") }
            history += (0..<(shownLines ?? replyLines)).map { "  answer \(n) line \($0)" } + [""]
        }
        try transcriptText.write(to: transcript, atomically: true, encoding: .utf8)
        let claude = FullscreenClaude(history: history)
        // Fullscreen Claude: herdr has no scrollback (max offset 0) and nothing on screen matches.
        let socket = try PaneFixtureSocket(matches: [], maxOffset: 0, viewportRows: 45)
        defer { socket.stop() }
        let store = ClaudeTranscriptStore()
        let device = Device(name: "fixture", kind: .local, socketPath: socket.path)
        let service = HerdrService(device: device, autoStartLocalServer: false)
        _ = try await service.connect()
        let provider = ClaudeHistoryProvider(
            store: store, device: device, service: service,
            appTerminal: AppTerminal(press: { claude.press($0) }, screen: { claude.screen() }),
            pageSettle: .milliseconds(40)
        )
        let page = try await provider.read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init(limit: 200))
        let message = try XCTUnwrap(page.messages.first { $0.id == "u\(target)" })
        let outcome: Result<ConversationJumpResult, Error>
        do {
            outcome = .success(try await provider.jump(target: "w:p", expectedSessionID: sessionID,
                                                       expectedGeneration: try XCTUnwrap(page.binding?.generation),
                                                       messageID: message.id, messageRevision: message.messageRevision))
        } catch { outcome = .failure(error) }
        await service.disconnect()
        await store.stopAll()
        return (outcome, claude)
    }

    func testFullscreenJumpSkipsAheadThenFindsThePrompt() async throws {
        let (outcome, claude) = try await fullscreenJump(to: 2)
        let result = try outcome.get()
        XCTAssertTrue(result.scrolledApp)
        XCTAssertTrue(claude.visibleHistory.contains("❯ question number 2"))
        XCTAssertFalse(claude.keys.contains(.pageDown), "aimed short, so no need to come back down")
        XCTAssertLessThan(claude.settledReads, claude.keys.count + 30, "a burst is read once, not per key")
    }

    func testFullscreenJumpSearchesBackDownAfterOvershooting() async throws {
        // The transcript says 40 lines per reply but the terminal shows 5: the burst overshoots.
        let (outcome, claude) = try await fullscreenJump(to: 20, shownLines: 5,
                                                         prompts: (0..<30).map { "question number \($0)" })
        _ = try outcome.get()
        XCTAssertTrue(claude.visibleHistory.contains("❯ question number 20"))
        XCTAssertTrue(claude.keys.contains(.pageDown))
    }

    func testFullscreenJumpReturnsToTheBottomWhenThePromptIsNotThere() async throws {
        let (outcome, claude) = try await fullscreenJump(to: 4, replyLines: 10, drop: 4)
        XCTAssertThrowsError(try outcome.get()) { XCTAssertEqual($0 as? ConversationJumpNotice, .notFound) }
        XCTAssertEqual(claude.keys.last, .toBottom)
        XCTAssertEqual(claude.offset, 0)
    }

    func testFullscreenJumpOnlyFindsTheNewestOfRepeatedPrompts() async throws {
        let (outcome, claude) = try await fullscreenJump(to: 0, prompts: ["continue", "other", "continue"])
        XCTAssertThrowsError(try outcome.get()) { XCTAssertEqual($0 as? ConversationJumpNotice, .notFound) }
        XCTAssertTrue(claude.keys.isEmpty, "an older repeat cannot be told apart, so nothing is typed")
    }

    func testScrollShiftMeasuresHowFarAPageMoved() {
        let old = (0..<30).map { "row \($0)" }.joined(separator: "\n")
        let new = (0..<30).map { $0 < 12 ? "older \($0)" : "row \($0 - 12)" }.joined(separator: "\n")
        XCTAssertEqual(ClaudeHistoryProvider.scrollShift(from: old, to: new), 12)
    }

    func testRowSelectionAccountsForScrolledOutAndQuotedPrompts() throws {
        let target = ClaudeTranscriptIndex.JumpTarget(key: "continue", occurrence: 2, occurrences: 3)
        // Only the two newest prompts are still in the scrollback.
        XCTAssertEqual(try ClaudeHistoryProvider.row(for: target, in: [.init(row: 5, col: 2), .init(row: 9, col: 2)]), 9)
        let oldest = ClaudeTranscriptIndex.JumpTarget(key: "continue", occurrence: 0, occurrences: 3)
        XCTAssertThrowsError(try ClaudeHistoryProvider.row(for: oldest, in: [.init(row: 5, col: 2), .init(row: 9, col: 2)])) {
            XCTAssertEqual($0 as? ConversationJumpNotice, .notFound)
        }
        let single = ClaudeTranscriptIndex.JumpTarget(key: "yes", occurrence: 0, occurrences: 1)
        XCTAssertThrowsError(try ClaudeHistoryProvider.row(for: single, in: [.init(row: 1, col: 2), .init(row: 7, col: 2)])) {
            XCTAssertEqual($0 as? ConversationJumpNotice, .ambiguous, "an older session's prompt in the scrollback")
        }
        XCTAssertThrowsError(try ClaudeHistoryProvider.row(for: single, in: [.init(row: 1, col: 20)])) {
            XCTAssertEqual($0 as? ConversationJumpNotice, .notFound)
        }
    }

    func testPromptRowFindsThePromptAtTheLeftEdgeOnly() {
        let screen = "● Claude said: ❯ first\n\n❯ first question here\n  quoting first"
        XCTAssertEqual(ClaudeHistoryProvider.promptRow(of: "first", in: screen), 2)
        XCTAssertNil(ClaudeHistoryProvider.promptRow(of: "missing", in: screen))
    }

    func testOffsetClampsToTheScrollback() {
        let metrics = PaneScrollMetrics(offsetFromBottom: 0, maxOffsetFromBottom: 100, viewportRows: 40)
        XCTAssertEqual(ClaudeHistoryProvider.offset(showing: 0, metrics: metrics), 100)
        XCTAssertEqual(ClaudeHistoryProvider.offset(showing: 61, metrics: metrics), 40)
        XCTAssertEqual(ClaudeHistoryProvider.offset(showing: 139, metrics: metrics), 0)
    }
}

/// Claude's fullscreen renderer as the jump sees it: 30 history rows above 15 rows of
/// prompt and status, PageUp/PageDown move 20 rows, ⌃End returns to the bottom, and the
/// spinner on the last row changes on every read.
final class FullscreenClaude: @unchecked Sendable {
    private let lock = NSLock()
    private let history: [String]
    private let rows = 30, page = 20
    private var scrolled = 0
    private var pressed: [AppScrollKey] = []
    private var reads = 0
    init(history: [String]) { self.history = history }
    var keys: [AppScrollKey] { lock.lock(); defer { lock.unlock() }; return pressed }
    var offset: Int { lock.lock(); defer { lock.unlock() }; return scrolled }
    var settledReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var visibleHistory: [String] { lock.lock(); defer { lock.unlock() }; return window() }
    func press(_ key: AppScrollKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pressed.append(key)
        let top = max(0, history.count - rows)
        switch key {
        case .pageUp: scrolled = min(top, scrolled + page)
        case .pageDown: scrolled = max(0, scrolled - page)
        case .toBottom: scrolled = 0
        }
        return true
    }
    func screen() -> String {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        let status = (0..<14).map { "  status \($0)" } + ["✻ Working… \(reads)"]
        return (window() + status).joined(separator: "\n")
    }
    private func window() -> [String] {
        let end = history.count - scrolled
        let shown = Array(history[max(0, end - rows)..<end])
        return Array(repeating: "", count: rows - shown.count) + shown
    }
}

/// Synthetic private socket only; never opens the user's daemon.
private final class PaneFixtureSocket: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []
    private let listener: Int32
    private var stopped = false
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(matches: [(row: Int, col: Int)], maxOffset: Int, viewportRows: Int) throws {
        path = "/tmp/hhist-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HerdrError.connectionFailed("fixture socket") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0, listen(listener, 8) == 0 else { close(listener); throw HerdrError.connectionFailed("fixture bind") }
        let listening = listener
        let ranges = matches.map { ["start": ["row": $0.row, "col": $0.col], "end": ["row": $0.row, "col": $0.col + 8]] }
        Thread.detachNewThread { [weak self] in
            while true {
                let connection = accept(listening, nil, nil)
                guard connection >= 0 else { return }
                defer { close(connection) }
                var noSignal: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                guard let data = try? SocketRPC.readLine(fd: connection, timeoutSeconds: 2),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let self else { continue }
                self.lock.lock(); self.recorded.append(request); self.lock.unlock()
                let params = request["params"] as? [String: Any] ?? [:]
                let result: [String: Any]
                switch request["method"] as? String ?? "" {
                case "ping":
                    result = ["type": "pong", "version": "fixture", "protocol": 17]
                case "pane.copy_motion":
                    result = ["type": "pane_copy_motion", "pane_id": "w:p", "cursor": ["row": 0, "col": 0], "content_revision": 42]
                case "pane.copy_search":
                    result = ["type": "pane_copy_search", "pane_id": "w:p", "content_revision": 42, "matches": ranges, "total": ranges.count]
                case "pane.get":
                    result = ["type": "pane_info", "pane": ["scroll": ["offset_from_bottom": 0, "max_offset_from_bottom": maxOffset, "viewport_rows": viewportRows]]]
                case "pane.scroll":
                    let offset = params["offset_from_bottom"] as? Int ?? 0
                    result = ["type": "pane_info", "pane": ["scroll": ["offset_from_bottom": offset, "max_offset_from_bottom": maxOffset, "viewport_rows": viewportRows]]]
                default:
                    result = ["type": "unknown"]
                }
                guard var reply = try? JSONSerialization.data(withJSONObject: ["id": request["id"] ?? "fixture", "ok": true, "result": result]) else { continue }
                reply.append(10)
                reply.withUnsafeBytes { bytes in _ = write(connection, bytes.baseAddress!, bytes.count) }
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true
        shutdown(listener, SHUT_RDWR); close(listener); unlink(path)
    }
    deinit { stop() }
}
