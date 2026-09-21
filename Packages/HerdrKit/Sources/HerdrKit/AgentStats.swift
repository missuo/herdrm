import Foundation

/// One extra sidebar line under an agent row, derived from the pane `tokens`
/// that Herdr plugins publish. Mirrors the four rows the Herdr TUI shows when
/// grazr and herdr-agent-quota are installed:
///
///     senad@example.com            ← account   (`grazr`)
///     Fable 5.1 (1M context)       ← model     (`claude_model`, else `quota_model`)
///     context 47% · cache 99.8%    ← context   (`claude_ctx`, else `quota_context` + `quota_cache`)
///     5h 7% 3h21m · 7d 2% 6d18h    ← usage     (`claude_usage`, else `quota_5h_*` + `quota_week_*`)
///
/// grazr's own keys win because they carry the richer text; the `quota_*`
/// keys are the fallback on hosts that only run herdr-agent-quota. Blank
/// values are skipped and a missing kind simply renders no line.
public struct AgentStatsLine: Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case account, model, context, usage
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func lines(from tokens: [String: String]) -> [AgentStatsLine] {
        func value(_ key: String) -> String? {
            guard let raw = tokens[key] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{200b}", with: "")
            return trimmed.isEmpty ? nil : trimmed
        }
        func first(_ keys: [String]) -> String? {
            keys.lazy.compactMap(value).first
        }
        func joined(_ parts: [String?]) -> String? {
            let present = parts.compactMap { $0 }
            return present.isEmpty ? nil : present.joined(separator: " · ")
        }

        // herdr-agent-quota publishes exactly one of the four severity
        // variants per window; whichever is set is the current reading.
        let quota5h = first(["quota_5h_normal", "quota_5h_warning", "quota_5h_danger", "quota_5h_unknown"])
        let quotaWeek = first(["quota_week_normal", "quota_week_warning", "quota_week_danger", "quota_week_unknown"])

        let texts: [(Kind, String?)] = [
            (.account, value("grazr")),
            (.model, value("claude_model") ?? value("quota_model")),
            (.context, value("claude_ctx") ?? joined([value("quota_context"), value("quota_cache")])),
            (.usage, value("claude_usage") ?? joined([quota5h, quotaWeek])),
        ]
        return texts.compactMap { kind, text in text.map { AgentStatsLine(kind: kind, text: $0) } }
    }
}
