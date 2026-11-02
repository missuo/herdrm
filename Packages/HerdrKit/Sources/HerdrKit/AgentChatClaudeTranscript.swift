import Foundation

/// A Claude Code transcript (`<config>/projects/<project>/<session>.jsonl`) as a chat:
/// prompts, replies, and every tool call paired with its result.
///
/// `ClaudeTranscriptIndex` serves the Mac's history drawer and leaves tool results
/// out; the phone's chat needs them (a call's outcome, AskUserQuestion answers,
/// rejected permissions), so this reads the same records with that in view.
///
/// Like the index it shows only the active branch: the chain from the newest record
/// back through `parentUuid`, so prompts abandoned by a rewind drop out. A record
/// whose parent was never read ends the walk without error, which lets the reader
/// start part-way into a long file (`startsMidFile`) and still show its tail.
public struct AgentChatClaudeTranscript: AgentChatTranscriptParsing {
    public private(set) var items: [AgentChatItem] = []

    private var pending = Data()
    private var skipFirstLine: Bool
    private var nodes: [String: String?] = [:]
    private var continuations: [String: String] = [:]
    private var leaf: String?
    private var records: [String: Record] = [:]

    /// `startsMidFile`: the first bytes are the tail of a line cut by a byte offset.
    public init(startsMidFile: Bool = false) {
        skipFirstLine = startsMidFile
    }

    private enum Block: Sendable {
        case text(String)
        case toolUse(id: String, name: String, input: [String: AnySendable])
    }

    private struct ToolResult: Sendable {
        let id: String
        let text: String?
        let isError: Bool
        let rejected: Bool
    }

    private enum Content: Sendable {
        case prompt(String, attachments: Int)
        case assistant([Block])
        case toolResults([ToolResult], answers: [String: String])
        case notice(String)
    }

    private struct Record: Sendable {
        let timestamp: Date?
        let content: Content
    }

    // MARK: - Ingest

    @discardableResult
    public mutating func ingest(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        pending.append(data)
        var changed = false
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            if skipFirstLine {
                skipFirstLine = false
            } else if consume(pending[start..<newline]) {
                changed = true
            }
            start = pending.index(after: newline)
        }
        pending.removeSubrange(pending.startIndex..<start)
        guard changed else { return false }
        let rebuilt = build()
        guard rebuilt != items else { return false }
        items = rebuilt
        return true
    }

    private mutating func consume(_ line: Data) -> Bool {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line),
              let record = object as? [String: Any],
              let uuid = record["uuid"] as? String else { return false }
        if record["isSidechain"] as? Bool == true { return false }
        let parent = record["parentUuid"] as? String
        if parent == nil, let previous = leaf, previous != uuid { continuations[uuid] = previous }
        nodes[uuid] = .some(parent)
        leaf = uuid
        if let content = Self.content(of: record) {
            records[uuid] = Record(timestamp: AgentChatText.date(record["timestamp"]), content: content)
        }
        return true
    }

    private static func content(of record: [String: Any]) -> Content? {
        guard let type = record["type"] as? String,
              let message = record["message"] as? [String: Any] else { return nil }
        switch type {
        case "assistant":
            guard let items = message["content"] as? [[String: Any]] else { return nil }
            let blocks = items.compactMap(assistantBlock)
            return blocks.isEmpty ? nil : .assistant(blocks)
        case "user":
            if record["isMeta"] as? Bool == true { return nil }
            if let items = message["content"] as? [[String: Any]],
               items.contains(where: { $0["type"] as? String == "tool_result" }) {
                return toolResults(items, record: record)
            }
            return userContent(record: record, message: message)
        default:
            return nil
        }
    }

    private static func assistantBlock(_ item: [String: Any]) -> Block? {
        switch item["type"] as? String {
        case "text":
            guard let text = item["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .text(text)
        case "tool_use", "server_tool_use":
            guard let id = item["id"] as? String else { return nil }
            let input = (item["input"] as? [String: Any] ?? [:]).mapValues(AnySendable.init)
            return .toolUse(id: id, name: item["name"] as? String ?? "Tool", input: input)
        default:
            return nil
        }
    }

    static let rejectionMarkers = [
        "The user doesn't want to proceed with this tool use",
        "The user doesn't want to take this action",
        "[Request interrupted by user for tool use]",
    ]

    private static func toolResults(_ items: [[String: Any]], record: [String: Any]) -> Content {
        let results = items.compactMap { item -> ToolResult? in
            guard item["type"] as? String == "tool_result", let id = item["tool_use_id"] as? String else { return nil }
            let text = resultText(item["content"])
            let rejected = rejectionMarkers.contains { text?.contains($0) == true }
            return ToolResult(id: id, text: text, isError: item["is_error"] as? Bool == true, rejected: rejected)
        }
        var answers: [String: String] = [:]
        if let result = record["toolUseResult"] as? [String: Any],
           let raw = result["answers"] as? [String: Any] {
            for (question, answer) in raw {
                if let answer = answer as? String { answers[question] = answer }
                else if let list = answer as? [String] { answers[question] = list.joined(separator: ", ") }
            }
        }
        return .toolResults(results, answers: answers)
    }

    private static func resultText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part -> String? in
            switch part["type"] as? String {
            case "text": return part["text"] as? String
            case "image": return "[Image]"
            default: return nil
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func userContent(record: [String: Any], message: [String: Any]) -> Content? {
        var text = ""
        var attachments = 0
        if let string = message["content"] as? String {
            text = string
        } else if let items = message["content"] as? [[String: Any]] {
            var parts: [String] = []
            for item in items {
                switch item["type"] as? String {
                case "text": if let value = item["text"] as? String { parts.append(value) }
                case "image", "document": attachments += 1
                default: break
                }
            }
            text = parts.joined(separator: "\n\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if record["isCompactSummary"] as? Bool == true {
            return .notice(String(localized: "Conversation compacted"))
        }
        if trimmed.hasPrefix("[Request interrupted") { return .notice(String(localized: "Interrupted")) }
        for tag in ["bash-stdout", "bash-stderr", "local-command-stdout", "local-command-stderr"]
        where trimmed.hasPrefix("<\(tag)>") {
            return nil
        }
        if let name = AgentChatText.tagged("command-name", in: trimmed) {
            let args = AgentChatText.tagged("command-args", in: trimmed) ?? ""
            return .prompt(args.isEmpty ? name : "\(name) \(args)", attachments: attachments)
        }
        if let command = AgentChatText.tagged("bash-input", in: trimmed) {
            return .prompt("! \(command)", attachments: attachments)
        }
        // Harness envelopes (reminders, caveats, task and teammate notifications)
        // are not something the person typed.
        if trimmed.hasPrefix("<") { return nil }
        let originKind = (record["origin"] as? [String: Any])?["kind"] as? String
        if let originKind, originKind != "human" { return nil }
        guard !trimmed.isEmpty || attachments > 0 else { return nil }
        return .prompt(trimmed, attachments: attachments)
    }

    // MARK: - Build

    private func build() -> [AgentChatItem] {
        var chain: [String] = []
        var visited = Set<String>()
        var cursor = leaf
        while let id = cursor, visited.insert(id).inserted {
            guard let parent = nodes[id] else { break }
            chain.append(id)
            cursor = parent ?? continuations[id]
        }

        var built: [AgentChatItem] = []
        var toolSlots: [String: Int] = [:]
        for id in chain.reversed() {
            guard let record = records[id] else { continue }
            switch record.content {
            case .prompt(let text, let attachments):
                built.append(AgentChatItem(id: id, content: .user(text, attachments: attachments), timestamp: record.timestamp))
            case .notice(let text):
                built.append(AgentChatItem(id: id, content: .notice(text), timestamp: record.timestamp))
            case .assistant(let blocks):
                for (index, block) in blocks.enumerated() {
                    switch block {
                    case .text(let text):
                        built.append(AgentChatItem(id: "\(id)#\(index)", content: .assistant(text), timestamp: record.timestamp))
                    case .toolUse(let toolID, let name, let input):
                        guard toolSlots[toolID] == nil else { continue }
                        toolSlots[toolID] = built.count
                        built.append(AgentChatItem(id: toolID, content: .tool(Self.toolCall(id: toolID, name: name, input: input)),
                                                   timestamp: record.timestamp))
                    }
                }
            case .toolResults(let results, let answers):
                for result in results {
                    guard let slot = toolSlots[result.id], var call = built[slot].toolCall else { continue }
                    call.result = result.text.map { AgentChatText.clipped($0) }
                    call.state = result.rejected ? .rejected : result.isError ? .failed : .succeeded
                    if !answers.isEmpty { call.answers = answers }
                    built[slot].content = .tool(call)
                }
            }
        }
        return built
    }

    static func toolCall(id: String, name: String, input: [String: AnySendable]) -> AgentChatToolCall {
        let raw = input.mapValues(\.value)
        var special: AgentChatToolCall.Special?
        switch name {
        case "AskUserQuestion":
            let questions = (raw["questions"] as? [[String: Any]] ?? []).compactMap { entry -> AgentChatQuestion? in
                guard let question = entry["question"] as? String else { return nil }
                let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentChatQuestion.Option? in
                    guard let label = option["label"] as? String else { return nil }
                    return AgentChatQuestion.Option(label: label, detail: option["description"] as? String)
                }
                return AgentChatQuestion(question: question, header: entry["header"] as? String,
                                         multiSelect: entry["multiSelect"] as? Bool ?? false, options: options)
            }
            if !questions.isEmpty { special = .questions(questions) }
        case "ExitPlanMode":
            if let plan = raw["plan"] as? String, !plan.isEmpty { special = .plan(plan) }
        default:
            break
        }
        let summary = ClaudeTranscriptIndex.toolSummary(name: name, input: raw).map { AgentChatText.firstLine($0) }
        return AgentChatToolCall(id: id, name: name, summary: summary, input: detail(name: name, input: raw), special: special)
    }

    /// The call's input as a person reads it: the command, the edit as -/+ lines,
    /// the written file, or the raw JSON for anything else.
    static func detail(name: String, input: [String: Any]) -> String? {
        if let command = input["command"] as? String { return AgentChatText.clipped(command) }
        if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            let minus = old.split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
            let plus = new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
            return AgentChatText.clipped((minus + plus).joined(separator: "\n"))
        }
        if let content = input["content"] as? String { return AgentChatText.clipped(content) }
        guard !input.isEmpty else { return nil }
        return AgentChatText.json(input).map { AgentChatText.clipped($0) }
    }
}

/// JSON values carried across the Sendable boundary. JSONSerialization only ever
/// produces immutable Foundation property-list types.
struct AnySendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}
