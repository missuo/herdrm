import Foundation

/// Reads an agent's transcript on the device with one short shell command per
/// poll, from a byte offset, so a phone polling every second or two only moves
/// what is new. Used where there is a shell but no long-lived reader (iOS over SSH).
///
/// The command finds the file (Claude: `<config>/projects/*/<id>.jsonl` under
/// `$CLAUDE_CONFIG_DIR`, `~/.claude`, then any `CLAUDE_CONFIG_DIR` the user's
/// processes were started with; Codex: `rollout-*<id>.jsonl` under
/// `$CODEX_HOME/sessions` or `~/.codex/sessions`), prints
/// `herdrm-chat <size> <start> <path>` and then the bytes from `start`, at most
/// `maxBytes`. Exits 44 when no transcript exists.
public enum AgentChatRemoteSource {
    public static let headerPrefix = "herdrm-chat "
    public static let missingStatus: Int32 = 44

    public struct Chunk: Sendable, Equatable {
        /// The file's size when read.
        public let size: Int
        /// Offset of `body`'s first byte in the file.
        public let start: Int
        public let path: String
        public let body: Data
        /// More bytes follow `body`; read again without waiting.
        public var hasMore: Bool { start + body.count < size }
        public var end: Int { start + body.count }
    }

    /// Session ids are UUID-like; anything else never reaches a shell.
    public static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The script. `offset` nil reads the last `maxBytes` of the file (first load);
    /// an offset past the end (the file was replaced) reads from the start.
    /// `knownPath` skips the search when the file is still there.
    public static func script(agent: AgentChatKind, sessionID: String, knownPath: String?,
                              offset: Int?, maxBytes: Int) -> String? {
        guard isValidSessionID(sessionID) else { return nil }
        let find: String
        switch agent {
        case .claude:
            find = """
            look() {
              for d in "$@"; do
                for x in "$d"/projects/*/"$id".jsonl; do
                  if [ -f "$x" ]; then f=$x; return 0; fi
                done
              done
              return 1
            }
            look "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude" || {
              IFS='
            '
              look $(
                if [ -r /proc/self/environ ]; then
                  for e in /proc/[0-9]*/environ; do tr '\\0' '\\n' 2>/dev/null < "$e"; done
                else
                  ps -E -ww -o command= -U "$(id -u)" 2>/dev/null | tr ' ' '\\n'
                fi | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | sort -u
              )
              unset IFS
            }
            """
        case .codex:
            find = """
            for d in "${CODEX_HOME:-$HOME/.codex}" "$HOME/.codex"; do
              [ -d "$d/sessions" ] || continue
              x=$(find "$d/sessions" -type f -name "rollout-*$id.jsonl" 2>/dev/null | head -n 1)
              if [ -n "$x" ]; then f=$x; break; fi
            done
            """
        }
        let start: String
        if let offset {
            start = "start=\(max(0, offset)); [ \"$start\" -gt \"$size\" ] && start=0"
        } else {
            start = "start=$((size > max ? size - max : 0))"
        }
        return """
        id=\(ShellQuoting.quoted(sessionID))
        max=\(max(1, maxBytes))
        f=\(ShellQuoting.quoted(knownPath ?? ""))
        if [ -z "$f" ] || [ ! -f "$f" ]; then
        f=
        \(find)
        fi
        [ -n "$f" ] || exit \(missingStatus)
        size=$(wc -c < "$f" | tr -d ' ')
        \(start)
        printf '\(headerPrefix)%s %s %s\\n' "$size" "$start" "$f"
        tail -c +$((start + 1)) -- "$f" | head -c "$max"
        """
    }

    /// The script for sshd's exec, which runs it through the login shell; zsh
    /// would stop at the first glob that matches nothing.
    public static func command(agent: AgentChatKind, sessionID: String, knownPath: String?,
                               offset: Int?, maxBytes: Int) -> String? {
        script(agent: agent, sessionID: sessionID, knownPath: knownPath, offset: offset, maxBytes: maxBytes)
            .map { "exec /bin/sh -c \(ShellQuoting.quoted($0))" }
    }

    /// Splits the command's output into header and body; nil when there is no header.
    public static func parse(_ output: Data) -> Chunk? {
        guard let newline = output.firstIndex(of: 0x0A) else { return nil }
        let header = String(decoding: output[output.startIndex..<newline], as: UTF8.self)
        guard header.hasPrefix(headerPrefix) else { return nil }
        let fields = header.dropFirst(headerPrefix.count).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let size = Int(fields[0]), let start = Int(fields[1]), !fields[2].isEmpty else { return nil }
        return Chunk(size: size, start: start, path: String(fields[2]), body: Data(output[output.index(after: newline)...]))
    }
}
