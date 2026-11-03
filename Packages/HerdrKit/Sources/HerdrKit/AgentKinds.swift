import Foundation

/// Agent kinds herdr ships manifests for (plus OMP, which starts through its
/// lifecycle extension), with their display names, most used first.
public enum AgentKinds {
    public static let known: [(kind: String, label: String)] = [
        ("claude", "Claude"),
        ("codex", "Codex"),
        ("droid", "Droid"),
        ("agy", "Antigravity"),
        ("cursor", "Cursor"),
        ("gemini", "Gemini"),
        ("grok", "Grok"),
        ("kimi", "Kimi"),
        ("opencode", "OpenCode"),
        ("copilot", "Copilot"),
        ("devin", "Devin"),
        ("cline", "Cline"),
        ("kiro", "Kiro"),
        ("amp", "Amp"),
        ("hermes", "Hermes"),
        ("kilo", "Kilo"),
        ("qodercli", "Qoder"),
        ("qwen", "Qwen Code"),
        ("letta", "Letta"),
        ("maki", "Maki"),
        ("muse", "Muse"),
        ("pi", "Pi"),
        ("omp", "Oh My Pi"),
    ]
}
