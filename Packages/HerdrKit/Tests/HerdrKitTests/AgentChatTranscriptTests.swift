import XCTest
@testable import HerdrKit

/// Synthetic transcripts in the shape Claude Code and Codex write them; no real data.
final class AgentChatTranscriptTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func claudeUser(_ uuid: String, parent: String?, _ text: String) -> String {
        line(["type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "isSidechain": false,
              "timestamp": "2026-01-02T03:04:05.000Z", "message": ["role": "user", "content": text]])
    }

    private func claudeAssistant(_ uuid: String, parent: String, id: String, _ content: [[String: Any]]) -> String {
        line(["type": "assistant", "uuid": uuid, "parentUuid": parent, "isSidechain": false,
              "timestamp": "2026-01-02T03:04:06.000Z",
              "message": ["id": id, "role": "assistant", "content": content]])
    }

    private func claudeResult(_ uuid: String, parent: String, toolID: String, _ text: String,
                              isError: Bool = false, extra: [String: Any] = [:]) -> String {
        var record: [String: Any] = ["type": "user", "uuid": uuid, "parentUuid": parent, "isSidechain": false,
                                     "message": ["role": "user", "content": [[
                                         "type": "tool_result", "tool_use_id": toolID, "content": text, "is_error": isError,
                                     ]]]]
        record.merge(extra) { _, new in new }
        return line(record)
    }

    private func feed<P: AgentChatTranscriptParsing>(_ parser: inout P, _ lines: [String]) {
        parser.ingest(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - Claude

    func testClaudePromptReplyAndToolCallWithResult() {
        var chat = AgentChatClaudeTranscript()
        feed(&chat, [
            claudeUser("u1", parent: nil, "List the files in test1"),
            claudeAssistant("a1", parent: "u1", id: "m1", [["type": "thinking", "thinking": "hidden"]]),
            claudeAssistant("a2", parent: "a1", id: "m1", [["type": "text", "text": "Sure, listing them."]]),
            claudeAssistant("a3", parent: "a2", id: "m1", [["type": "tool_use", "id": "t1", "name": "Bash",
                                                            "input": ["command": "ls test1", "description": "List"]]]),
            claudeResult("r1", parent: "a3", toolID: "t1", "a.txt\nb.txt"),
            claudeAssistant("a4", parent: "r1", id: "m2", [["type": "text", "text": "Two files."]]),
        ])
        XCTAssertEqual(chat.items.count, 4)
        XCTAssertEqual(chat.items[0].content, .user("List the files in test1", attachments: 0))
        XCTAssertEqual(chat.items[1].content, .assistant("Sure, listing them."))
        let call = try! XCTUnwrap(chat.items[2].toolCall)
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.summary, "ls test1")
        XCTAssertEqual(call.input, "ls test1")
        XCTAssertEqual(call.result, "a.txt\nb.txt")
        XCTAssertEqual(call.state, .succeeded)
        XCTAssertEqual(chat.items[3].content, .assistant("Two files."))
        XCTAssertNil(chat.pendingToolCall)
        XCTAssertNotNil(chat.items[0].timestamp)
    }

    func testClaudePendingToolCallIsWhatTheAgentWaitsOn() {
        var chat = AgentChatClaudeTranscript()
        feed(&chat, [
            claudeUser("u1", parent: nil, "Delete the build folder"),
            claudeAssistant("a1", parent: "u1", id: "m1", [["type": "tool_use", "id": "t1", "name": "Bash",
                                                            "input": ["command": "rm -rf build"]]]),
        ])
        XCTAssertEqual(chat.pendingToolCall?.id, "t1")
        XCTAssertEqual(chat.pendingToolCall?.state, .pending)
    }

    func testClaudeRejectedAndFailedToolCalls() {
        var chat = AgentChatClaudeTranscript()
        feed(&chat, [
            claudeUser("u1", parent: nil, "Go"),
            claudeAssistant("a1", parent: "u1", id: "m1", [
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "rm -rf build"]],
            ]),
            claudeResult("r1", parent: "a1", toolID: "t1",
                         "The user doesn't want to proceed with this tool use. The tool use was rejected.", isError: true),
            claudeAssistant("a2", parent: "r1", id: "m2", [
                ["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "/tmp/test2"]],
            ]),
            claudeResult("r2", parent: "a2", toolID: "t2", "File does not exist.", isError: true),
        ])
        XCTAssertEqual(chat.items.compactMap(\.toolCall).map(\.state), [.rejected, .failed])
        XCTAssertEqual(chat.items.compactMap(\.toolCall).last?.summary, "/tmp/test2")
    }

    func testClaudeAskUserQuestionCarriesOptionsAndAnswers() throws {
        var chat = AgentChatClaudeTranscript()
        let question = "Where should test1 keep its cache?"
        feed(&chat, [
            claudeUser("u1", parent: nil, "Add a cache"),
            claudeAssistant("a1", parent: "u1", id: "m1", [[
                "type": "tool_use", "id": "t1", "name": "AskUserQuestion",
                "input": ["questions": [[
                    "question": question, "header": "Storage", "multiSelect": false,
                    "options": [["label": "On disk", "description": "Survives restarts"],
                                ["label": "In memory", "description": "Fastest"]],
                ]]],
            ]]),
        ])
        var call = try XCTUnwrap(chat.pendingToolCall)
        guard case .questions(let questions)? = call.special else { return XCTFail("no questions") }
        XCTAssertEqual(questions.first?.question, question)
        XCTAssertEqual(questions.first?.header, "Storage")
        XCTAssertEqual(questions.first?.options.map(\.label), ["On disk", "In memory"])
        XCTAssertEqual(questions.first?.options.first?.detail, "Survives restarts")

        feed(&chat, [claudeResult("r1", parent: "a1", toolID: "t1", "User has answered your questions",
                                  extra: ["toolUseResult": ["answers": [question: "In memory"]]])])
        call = try XCTUnwrap(chat.items.last?.toolCall)
        XCTAssertEqual(call.answers, [question: "In memory"])
        XCTAssertEqual(call.state, .succeeded)
    }

    func testClaudeExitPlanModeCarriesThePlan() throws {
        var chat = AgentChatClaudeTranscript()
        feed(&chat, [
            claudeUser("u1", parent: nil, "Plan it"),
            claudeAssistant("a1", parent: "u1", id: "m1", [[
                "type": "tool_use", "id": "t1", "name": "ExitPlanMode", "input": ["plan": "# Plan\n1. Add test1"],
            ]]),
        ])
        XCTAssertEqual(try XCTUnwrap(chat.pendingToolCall).special, .plan("# Plan\n1. Add test1"))
    }

    func testClaudeHidesHarnessRecordsAndShowsCommands() {
        var chat = AgentChatClaudeTranscript()
        feed(&chat, [
            claudeUser("u1", parent: nil, "<command-name>/compact</command-name><command-args></command-args>"),
            claudeUser("u2", parent: "u1", "<system-reminder>internal</system-reminder>"),
            claudeUser("u3", parent: "u2", "<bash-input>git status</bash-input>"),
            claudeUser("u4", parent: "u3", "<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>"),
            line(["type": "user", "uuid": "u5", "parentUuid": "u4", "isMeta": true,
                  "message": ["role": "user", "content": "meta"]]),
            claudeUser("u6", parent: "u5", "[Request interrupted by user]"),
            line(["type": "assistant", "uuid": "s1", "parentUuid": "u6", "isSidechain": true,
                  "message": ["id": "sm", "content": [["type": "text", "text": "subagent"]]]]),
        ])
        XCTAssertEqual(chat.items.map(\.content), [
            .user("/compact", attachments: 0),
            .user("! git status", attachments: 0),
            .notice("Interrupted"),
        ])
    }

    func testClaudeFollowsTheActiveBranchAfterARewind() {
        var chat = AgentChatClaudeTranscript()
        feed(&chat, [
            claudeUser("u1", parent: nil, "First"),
            claudeAssistant("a1", parent: "u1", id: "m1", [["type": "text", "text": "Reply one"]]),
            claudeUser("u2", parent: "a1", "Abandoned prompt"),
            claudeAssistant("a2", parent: "u2", id: "m2", [["type": "text", "text": "Abandoned reply"]]),
            // Rewound to a1, then a new prompt.
            claudeUser("u3", parent: "a1", "Second try"),
        ])
        XCTAssertEqual(chat.items.map(\.content), [
            .user("First", attachments: 0), .assistant("Reply one"), .user("Second try", attachments: 0),
        ])
    }

    func testClaudeStartsMidFileAndAcceptsSplitChunks() {
        var chat = AgentChatClaudeTranscript(startsMidFile: true)
        let text = "tail of a cut line\"}\n" + [
            claudeUser("u9", parent: "u8-not-read", "Late prompt"),
            claudeAssistant("a9", parent: "u9", id: "m9", [["type": "text", "text": "Late reply"]]),
        ].joined(separator: "\n") + "\n"
        let bytes = Data(text.utf8)
        let middle = bytes.count / 2
        XCTAssertFalse(chat.ingest(bytes.prefix(middle)) && chat.items.count == 2)
        chat.ingest(bytes.suffix(from: middle))
        XCTAssertEqual(chat.items.map(\.content), [.user("Late prompt", attachments: 0), .assistant("Late reply")])
    }

    func testClaudeEditShowsDiffLines() {
        let call = AgentChatClaudeTranscript.toolCall(
            id: "t1", name: "Edit",
            input: ["file_path": AnySendable("/tmp/test1.swift"), "old_string": AnySendable("let a = 1"),
                    "new_string": AnySendable("let a = 2")]
        )
        XCTAssertEqual(call.summary, "/tmp/test1.swift")
        XCTAssertEqual(call.input, "- let a = 1\n+ let a = 2")
    }

    // MARK: - Codex

    private func codex(_ type: String, _ payload: [String: Any]) -> String {
        line(["timestamp": "2026-01-02T03:04:05.000Z", "type": type, "payload": payload])
    }

    func testCodexPromptsRepliesAndToolCalls() {
        var chat = AgentChatCodexTranscript()
        feed(&chat, [
            codex("session_meta", ["id": "s1", "cwd": "/tmp/test1"]),
            codex("response_item", ["type": "message", "role": "user",
                                    "content": [["type": "input_text", "text": "<environment_context>…</environment_context>"]]]),
            codex("event_msg", ["type": "item_completed",
                                "item": ["type": "UserMessage", "id": "p1", "content": [["type": "text", "text": "Run the tests"]]]]),
            codex("response_item", ["type": "reasoning", "summary": []]),
            codex("response_item", ["type": "message", "role": "assistant", "id": "m1",
                                    "content": [["type": "output_text", "text": "Running them now."]]]),
            codex("response_item", ["type": "function_call", "name": "exec_command", "call_id": "c1",
                                    "arguments": #"{"cmd":["bash","-lc","swift test"],"workdir":"/tmp/test1"}"#]),
            codex("response_item", ["type": "function_call_output", "call_id": "c1",
                                    "output": #"{"output":"All tests passed","metadata":{"exit_code":0}}"#]),
            codex("response_item", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2",
                                    "input": "*** Begin Patch\n*** Update File: Sources/test2.swift\n@@\n-a\n+b\n*** End Patch"]),
            codex("response_item", ["type": "custom_tool_call_output", "call_id": "c2",
                                    "output": #"{"output":"error: patch failed","metadata":{"exit_code":1}}"#]),
            codex("event_msg", ["type": "turn_aborted"]),
        ])
        XCTAssertEqual(chat.items.count, 5)
        XCTAssertEqual(chat.items[0].content, .user("Run the tests", attachments: 0))
        XCTAssertEqual(chat.items[1].content, .assistant("Running them now."))
        let exec = try! XCTUnwrap(chat.items[2].toolCall)
        XCTAssertEqual(exec.summary, "swift test")
        XCTAssertEqual(exec.result, "All tests passed")
        XCTAssertEqual(exec.state, .succeeded)
        let patch = try! XCTUnwrap(chat.items[3].toolCall)
        XCTAssertEqual(patch.summary, "Sources/test2.swift")
        XCTAssertEqual(patch.state, .failed)
        XCTAssertEqual(chat.items[4].content, .notice("Interrupted"))
    }

    func testCodexLegacyUserMessageEventAndDuplicateCopies() {
        var chat = AgentChatCodexTranscript()
        feed(&chat, [
            codex("event_msg", ["type": "user_message", "message": "Fix test1"]),
            codex("event_msg", ["type": "item_completed",
                                "item": ["type": "UserMessage", "id": "p1", "content": [["type": "text", "text": "Fix test1"]]]]),
        ])
        XCTAssertEqual(chat.items.map(\.content), [.user("Fix test1", attachments: 0)])
    }

    func testCodexPendingCallWithoutOutput() {
        var chat = AgentChatCodexTranscript()
        feed(&chat, [
            codex("response_item", ["type": "function_call", "name": "shell", "call_id": "c1",
                                    "arguments": #"{"command":["rm","-rf","build"]}"#]),
        ])
        XCTAssertEqual(chat.pendingToolCall?.summary, "rm -rf build")
    }

    // MARK: - Kinds and remote reads

    func testAgentKindsAndSessionRefs() {
        XCTAssertEqual(AgentChatKind(agentKind: "claude"), .claude)
        XCTAssertEqual(AgentChatKind(agentKind: "Codex"), .codex)
        XCTAssertNil(AgentChatKind(agentKind: "pi"))
        XCTAssertNil(AgentChatKind(agentKind: nil))
        let claudeRef = AgentSessionRef(source: "herdr:claude", agent: "claude", kind: "id", value: "abc-1")
        XCTAssertEqual(AgentChatKind.claude.sessionID(from: claudeRef), "abc-1")
        XCTAssertNil(AgentChatKind.codex.sessionID(from: claudeRef))
        let codexRef = AgentSessionRef(source: "herdr:codex", agent: "codex", kind: "id", value: "def-2")
        XCTAssertEqual(AgentChatKind.codex.sessionID(from: codexRef), "def-2")
        XCTAssertNil(AgentChatKind.claude.sessionID(from: nil))
    }

    func testRemoteSourceRejectsUnsafeSessionIDs() {
        XCTAssertNil(AgentChatRemoteSource.command(agent: .claude, sessionID: "a; rm -rf ~", knownPath: nil, offset: nil, maxBytes: 10))
        XCTAssertNil(AgentChatRemoteSource.command(agent: .codex, sessionID: "", knownPath: nil, offset: 0, maxBytes: 10))
        XCTAssertNotNil(AgentChatRemoteSource.command(agent: .codex, sessionID: "01a1-x_2", knownPath: nil, offset: 0, maxBytes: 10))
    }

    func testRemoteSourceParsesHeaderWithSpacesInPath() throws {
        let output = Data("herdrm-chat 120 100 /Users/test1/My Projects/s.jsonl\n{\"a\":1}\n".utf8)
        let chunk = try XCTUnwrap(AgentChatRemoteSource.parse(output))
        XCTAssertEqual(chunk.size, 120)
        XCTAssertEqual(chunk.start, 100)
        XCTAssertEqual(chunk.path, "/Users/test1/My Projects/s.jsonl")
        XCTAssertEqual(chunk.body, Data("{\"a\":1}\n".utf8))
        XCTAssertEqual(chunk.end, 108)
        XCTAssertTrue(chunk.hasMore)
        XCTAssertNil(AgentChatRemoteSource.parse(Data("garbage\n".utf8)))
    }

    /// Runs the real script in /bin/sh against a temporary config dir.
    func testRemoteScriptReadsTailAndOffsets() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("herdrm-chat-\(UUID().uuidString)")
        let project = home.appendingPathComponent(".claude/projects/-tmp-test1")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = project.appendingPathComponent("sess-1.jsonl")
        try Data("0123456789".utf8).write(to: file)

        func run(offset: Int?, max: Int, knownPath: String? = nil) throws -> (Int32, AgentChatRemoteSource.Chunk?) {
            let script = try XCTUnwrap(AgentChatRemoteSource.script(agent: .claude, sessionID: "sess-1",
                                                                    knownPath: knownPath, offset: offset, maxBytes: max))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, AgentChatRemoteSource.parse(data))
        }

        let tail = try XCTUnwrap(run(offset: nil, max: 4).1)
        XCTAssertEqual(tail.start, 6)
        XCTAssertEqual(tail.body, Data("6789".utf8))
        XCTAssertTrue(tail.path.hasSuffix("/projects/-tmp-test1/sess-1.jsonl"))

        let middle = try XCTUnwrap(run(offset: 2, max: 3, knownPath: tail.path).1)
        XCTAssertEqual(middle.body, Data("234".utf8))
        XCTAssertTrue(middle.hasMore)

        let replaced = try XCTUnwrap(run(offset: 50, max: 100).1)
        XCTAssertEqual(replaced.start, 0, "an offset past the end starts over")

        XCTAssertEqual(try run(offset: 0, max: 10, knownPath: nil).0, 0)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try run(offset: 0, max: 10).0, AgentChatRemoteSource.missingStatus)
    }
}
