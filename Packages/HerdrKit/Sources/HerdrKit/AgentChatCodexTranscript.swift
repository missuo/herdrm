import Foundation

/// A Codex rollout (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`) as a chat.
///
/// Rollouts interleave model items (`response_item`) with UI events (`event_msg`).
/// The person's prompts come from the events (`user_message`, or the newer
/// `item_completed` with a `UserMessage` item): the model-facing user messages also
/// carry harness context (environment, instructions) that nobody typed. Replies come
/// from assistant `message` items; tool calls from `function_call`,
/// `custom_tool_call` and `local_shell_call`, paired to their outputs by `call_id`.
/// Reasoning stays out of view. Best effort: the format is Codex's own and changes.
public struct AgentChatCodexTranscript: AgentChatTranscriptParsing {
    public private(set) var items: [AgentChatItem] = []

    private var pending = Data()
    private var skipFirstLine: Bool
    private var toolSlots: [String: Int] = [:]
    private var seenUserIDs = Set<String>()
    private var lineNumber = 0

    public init(startsMidFile: Bool = false) {
        skipFirstLine = startsMidFile
    }

    @discardableResult
    public mutating func ingest(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        pending.append(data)
        var changed = false
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            lineNumber += 1
            if skipFirstLine {
                skipFirstLine = false
            } else if consume(pending[start..<newline]) {
                changed = true
            }
            start = pending.index(after: newline)
        }
        pending.removeSubrange(pending.startIndex..<start)
        return changed
    }

    private mutating func consume(_ line: Data) -> Bool {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line),
              let record = object as? [String: Any],
              let payload = record["payload"] as? [String: Any] else { return false }
        let timestamp = AgentChatText.date(record["timestamp"])
        let lineID = "l\(lineNumber)"
        switch (record["type"] as? String, payload["type"] as? String) {
        case ("event_msg", "user_message"):
            guard let message = payload["message"] as? String else { return false }
            return appendUser(id: payload["id"] as? String ?? lineID, text: message,
                              attachments: (payload["images"] as? [Any])?.count ?? 0, timestamp: timestamp)
        case ("event_msg", "item_completed"):
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage" else { return false }
            let parts = item["content"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n\n")
            let images = parts.filter { ($0["type"] as? String)?.contains("image") == true }.count
            return appendUser(id: item["id"] as? String ?? lineID, text: text, attachments: images, timestamp: timestamp)
        case ("event_msg", "turn_aborted"):
            items.append(AgentChatItem(id: lineID, content: .notice(String(localized: "Interrupted")), timestamp: timestamp))
            return true
        case ("event_msg", "context_compacted"), ("compacted", _):
            items.append(AgentChatItem(id: lineID, content: .notice(String(localized: "Conversation compacted")), timestamp: timestamp))
            return true
        case ("response_item", "message"):
            guard payload["role"] as? String == "assistant" else { return false }
            let parts = payload["content"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
                .joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            items.append(AgentChatItem(id: payload["id"] as? String ?? lineID, content: .assistant(text), timestamp: timestamp))
            return true
        case ("response_item", "function_call"):
            let name = payload["name"] as? String ?? "tool"
            let arguments = payload["arguments"] as? String ?? ""
            return appendTool(callID: payload["call_id"] as? String ?? lineID, name: name,
                              call: Self.functionCall(name: name, arguments: arguments), timestamp: timestamp)
        case ("response_item", "custom_tool_call"):
            let name = payload["name"] as? String ?? "tool"
            let input = payload["input"] as? String ?? ""
            return appendTool(callID: payload["call_id"] as? String ?? lineID, name: name,
                              call: (summary: Self.customSummary(name: name, input: input), input: AgentChatText.clipped(input)),
                              timestamp: timestamp)
        case ("response_item", "local_shell_call"):
            let action = payload["action"] as? [String: Any]
            let command = Self.commandText(action?["command"]) ?? ""
            return appendTool(callID: payload["call_id"] as? String ?? lineID, name: "shell",
                              call: (summary: AgentChatText.firstLine(command), input: command), timestamp: timestamp)
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"),
             ("response_item", "local_shell_call_output"):
            guard let callID = payload["call_id"] as? String,
                  let slot = toolSlots[callID], var call = items[slot].toolCall else { return false }
            let (text, failed) = Self.output(payload["output"])
            call.result = text.map { AgentChatText.clipped($0) }
            call.state = failed ? .failed : .succeeded
            items[slot].content = .tool(call)
            return true
        default:
            return false
        }
    }

    private mutating func appendUser(id: String, text: String, attachments: Int, timestamp: Date?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachments > 0, seenUserIDs.insert(id).inserted else { return false }
        // Some Codex versions log one prompt as both a `user_message` and a
        // `UserMessage` item; the second copy follows before any reply.
        if case .user(let previous, _)? = items.last?.content, previous == trimmed { return false }
        items.append(AgentChatItem(id: id, content: .user(trimmed, attachments: attachments), timestamp: timestamp))
        return true
    }

    private mutating func appendTool(callID: String, name: String, call: (summary: String?, input: String?),
                                     timestamp: Date?) -> Bool {
        guard toolSlots[callID] == nil else { return false }
        toolSlots[callID] = items.count
        items.append(AgentChatItem(
            id: callID,
            content: .tool(AgentChatToolCall(id: callID, name: name, summary: call.summary, input: call.input)),
            timestamp: timestamp
        ))
        return true
    }

    static func commandText(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let parts = value as? [String] else { return nil }
        // ["bash", "-lc", "<script>"] is how Codex runs most commands.
        if parts.count == 3, ["bash", "zsh", "sh"].contains(parts[0]), parts[1].hasPrefix("-") { return parts[2] }
        return parts.joined(separator: " ")
    }

    static func functionCall(name: String, arguments: String) -> (summary: String?, input: String?) {
        let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        if let object {
            for key in ["cmd", "command"] {
                if let command = commandText(object[key]) {
                    return (AgentChatText.firstLine(command), AgentChatText.clipped(command))
                }
            }
            let summary = ClaudeTranscriptIndex.toolSummary(name: name, input: object).map { AgentChatText.firstLine($0) }
            return (summary, AgentChatText.json(object).map { AgentChatText.clipped($0) })
        }
        return (arguments.isEmpty ? nil : AgentChatText.firstLine(arguments), arguments.isEmpty ? nil : AgentChatText.clipped(arguments))
    }

    /// apply_patch inputs name their files on `*** Update File:` lines.
    static func customSummary(name: String, input: String) -> String? {
        let lines = input.split(whereSeparator: \.isNewline).map(String.init)
        let files = lines.compactMap { line -> String? in
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
            return nil
        }
        if !files.isEmpty { return files.joined(separator: ", ") }
        return lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map { AgentChatText.firstLine($0) }
    }

    /// Output text, and whether it reports failure (`success: false` or a non-zero exit).
    static func output(_ value: Any?) -> (String?, Bool) {
        if let string = value as? String {
            if let object = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] {
                return output(object)
            }
            return (string, false)
        }
        if let parts = value as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (text.isEmpty ? nil : text, false)
        }
        if let object = value as? [String: Any] {
            let text = (object["output"] as? String) ?? (object["content"] as? String) ?? AgentChatText.json(object)
            let exit = ((object["metadata"] as? [String: Any])?["exit_code"] as? Int) ?? (object["exit_code"] as? Int)
            let failed = object["success"] as? Bool == false || (exit.map { $0 != 0 } ?? false)
            return (text, failed)
        }
        return (nil, false)
    }
}
