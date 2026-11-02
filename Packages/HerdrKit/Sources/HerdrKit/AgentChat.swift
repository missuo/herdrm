import Foundation

/// The coding agents whose conversation Herdrm can show as a chat, and whose
/// choice prompts it can answer. Everything else falls back to the terminal.
public enum AgentChatKind: String, Sendable, Equatable, CaseIterable {
    case claude
    case codex

    /// herdr's agent kind (`AgentInfo.agent`), e.g. "claude", "claude-code", "codex".
    public init?(agentKind: String?) {
        switch agentKind?.lowercased() {
        case "claude", "claude-code": self = .claude
        case "codex": self = .codex
        default: return nil
        }
    }

    /// The session id herdr reports for the pane (`agent_session`), when it is
    /// this agent's own id. herdr fills it from the official integrations only.
    public func sessionID(from ref: AgentSessionRef?) -> String? {
        guard let ref, ref.kind == "id", !ref.value.isEmpty else { return nil }
        switch self {
        case .claude: return ref.source == "herdr:claude" && ref.agent == "claude" ? ref.value : nil
        case .codex: return ref.source == "herdr:codex" && ref.agent == "codex" ? ref.value : nil
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// One tool call as the chat shows it: a name, a one-line summary, and the
/// input and result behind a disclosure.
public struct AgentChatToolCall: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// No result yet: running, or waiting on the user's permission.
        case pending
        case succeeded
        case failed
        /// The user declined it at a permission prompt.
        case rejected
    }

    /// Questions Claude asked with AskUserQuestion, and the plan it proposed
    /// with ExitPlanMode. Shown as their own cards rather than raw input.
    public enum Special: Sendable, Equatable {
        case questions([AgentChatQuestion])
        case plan(String)
    }

    public let id: String
    public let name: String
    public let summary: String?
    public let input: String?
    public var result: String?
    public var state: State
    public let special: Special?
    /// AskUserQuestion answers keyed by question text, once answered.
    public var answers: [String: String]

    public init(id: String, name: String, summary: String? = nil, input: String? = nil,
                result: String? = nil, state: State = .pending, special: Special? = nil,
                answers: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.input = input
        self.result = result
        self.state = state
        self.special = special
        self.answers = answers
    }
}

public struct AgentChatQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let detail: String?
        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public let question: String
    public let header: String?
    public let multiSelect: Bool
    public let options: [Option]
    public init(question: String, header: String? = nil, multiSelect: Bool = false, options: [Option] = []) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }
}

/// One row of the chat.
public struct AgentChatItem: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        /// Something the person sent: a prompt, a slash command, a `!` shell line.
        case user(String, attachments: Int)
        case assistant(String)
        case tool(AgentChatToolCall)
        /// Harness events worth a line: compaction, an interrupt, command output.
        case notice(String)
    }

    public let id: String
    public var content: Content
    public let timestamp: Date?

    public init(id: String, content: Content, timestamp: Date? = nil) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
    }

    public var toolCall: AgentChatToolCall? {
        if case .tool(let call) = content { return call }
        return nil
    }
}

/// A transcript parser fed with bytes in any chunking, as they arrive.
public protocol AgentChatTranscriptParsing: Sendable {
    /// Appends transcript bytes. Returns true when `items` changed.
    mutating func ingest(_ data: Data) -> Bool
    var items: [AgentChatItem] { get }
}

extension AgentChatTranscriptParsing {
    /// The newest tool call still without a result, if nothing was said after it.
    /// While the agent is blocked this is what it is asking permission for.
    public var pendingToolCall: AgentChatToolCall? {
        for item in items.reversed() {
            switch item.content {
            case .tool(let call): if call.state == .pending { return call }
            case .assistant, .user: return nil
            case .notice: continue
            }
        }
        return nil
    }
}

enum AgentChatText {
    static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let isoParserNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ raw: Any?) -> Date? {
        guard let raw = raw as? String else { return nil }
        return isoParser.date(from: raw) ?? isoParserNoFraction.date(from: raw)
    }

    /// Long tool output is cut for the phone; the terminal still has all of it.
    static func clipped(_ text: String, limit: Int = 4_000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    static func firstLine(_ text: String, limit: Int = 200) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    static func tagged(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
