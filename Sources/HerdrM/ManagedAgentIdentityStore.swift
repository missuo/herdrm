import Foundation
import HerdrKit

/// Persistence is separate from runtime observations. This store never starts an agent.
@MainActor
final class ManagedAgentIdentityStore {
    private let registry: ManagedAgentRegistry
    private(set) var intents: [ManagedAgentIntent] = []

    init(registry: ManagedAgentRegistry) { self.registry = registry }

    func synchronize(agents: [AgentInfo], panes: [PaneInfo], tabs: [TabInfo]) throws -> ManagedAgentProjection {
        intents = try registry.load()
        var savedNames = Set(intents.map(\.name))
        for agent in agents {
            guard let name = agent.name, let kind = agent.agentKindRaw,
                  !savedNames.contains(name),
                  let pane = panes.first(where: { $0.paneID == agent.paneID }) else { continue }
            let tab = tabs.first { $0.tabID == pane.tabID }
            try registry.upsert(ManagedAgentIntent(
                tabLabel: tab?.customLabel ?? tab?.label, cwd: pane.cwd,
                name: name, kind: kind, paneID: pane.paneID, tabID: pane.tabID,
                terminalID: pane.terminalID, workspaceID: pane.workspaceID
            ))
            savedNames.insert(name)
        }
        intents = try registry.load()
        let projection = ManagedAgentProjection.resolve(agents: agents, panes: panes, tabs: tabs, intents: intents)
        for intent in projection.boundIntents where !intents.contains(intent) {
            try registry.upsert(intent)
        }
        intents = try registry.load()
        return projection
    }

    func remember(_ intent: ManagedAgentIntent, onCommitted: (() -> Void)? = nil) throws {
        try registry.upsert(intent, onCommitted: onCommitted)
        intents = try registry.load()
    }

    func remove(_ removal: ManagedAgentRemoval) throws {
        try registry.remove(paneIDs: removal.paneIDs, names: removal.names, terminalIDs: removal.terminalIDs)
        intents = try registry.load()
    }
}
