import Foundation
import HerdrKit

extension AppModel {
    func projectManagedAgentIdentities(device: Device, snapshot: SessionSnapshot) -> ManagedAgentProjection {
        guard device.isLocal, !device.isNamedSession else {
            return ManagedAgentProjection(agents: snapshot.agents, kindsByPane: [:], boundIntents: [])
        }
        do {
            return try managedIdentities.synchronize(agents: snapshot.agents, panes: snapshot.panes ?? [], tabs: snapshot.tabs ?? [])
        } catch {
            actionError = String(localized: "Could not save agent identity.") + " " + error.localizedDescription
            return ManagedAgentProjection(agents: snapshot.agents, kindsByPane: [:], boundIntents: [])
        }
    }

    func rememberManagedAgent(device: Device, paneID: String, requestedName: String, kind: String,
                              onCommitted: (() -> Void)? = nil) throws {
        guard device.isLocal, !device.isNamedSession else { return }
        let state = session(device.id)
        guard let pane = state.allPanes.first(where: { $0.paneID == paneID }) else {
            throw HerdrError.malformedResponse("New agent pane is missing from the snapshot.")
        }
        let tab = state.tabs.first { $0.tabID == pane.tabID }
        try managedIdentities.remember(ManagedAgentIntent(
            tabLabel: tab?.customLabel ?? tab?.label, cwd: pane.cwd,
            name: requestedName, kind: kind, paneID: pane.paneID, tabID: pane.tabID,
            terminalID: pane.terminalID, workspaceID: pane.workspaceID
        ), onCommitted: onCommitted)
    }

    func managedAgentRemoval(device: Device, paneIDs: Set<String>) -> ManagedAgentRemoval {
        let state = session(device.id)
        return ManagedAgentRemoval(paneIDs: paneIDs, agents: state.agents, panes: state.allPanes)
    }

    func forgetManagedAgents(device: Device, removal: ManagedAgentRemoval) throws {
        guard device.isLocal, !device.isNamedSession else { return }
        try managedIdentities.remove(removal)
    }
}
