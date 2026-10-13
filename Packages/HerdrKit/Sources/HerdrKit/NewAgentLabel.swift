import Foundation

/// The tab label New Agent gives a fresh agent: its space's name, so the
/// sidebar shows the project ("cotabby") rather than the kind ("claude"). A
/// tab label the user can read wins over herdr's generated names in
/// `AgentInfo.title`, and tab labels take any text, unlike `agent.rename`.
public enum NewAgentLabel {
    /// `taken` holds the titles of the device's agents. A second agent in the
    /// same space is numbered ("cotabby 2"). Without a space name the label is
    /// the kind, which `AgentInfo.title` treats as generic, as before.
    public static func make(spaceLabel: String?, kind: String, taken: Set<String>) -> String {
        let base = spaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty else { return kind }
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
