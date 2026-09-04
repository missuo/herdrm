import Foundation

/// Maps a sidebar drop onto herdr's `tab.move` `insert_index`.
///
/// `orderedIDs` is one workspace's tabs in snapshot / `tab.list` display
/// order — not `number`. Herdr applies `insert_index` before removing the
/// source tab (`tab.moved` returns that workspace's updated ordered list).
/// Returns `nil` when the drop would not change order (same row, already
/// adjacent, unknown ids).
public enum TabReorder: Sendable {
    /// Groups by workspace list order and keeps snapshot array order inside
    /// each workspace. `number` is a TUI slot, not a sort key.
    public static func ordered(_ tabs: [TabInfo], workspaces: [WorkspaceInfo]) -> [TabInfo] {
        let known = Set(workspaces.map(\.workspaceID))
        var buckets: [String: [TabInfo]] = [:]
        buckets.reserveCapacity(workspaces.count)
        var unknown: [TabInfo] = []
        unknown.reserveCapacity(4)
        for tab in tabs {
            if known.contains(tab.workspaceID) {
                buckets[tab.workspaceID, default: []].append(tab)
            } else {
                unknown.append(tab)
            }
        }
        var result: [TabInfo] = []
        result.reserveCapacity(tabs.count)
        for workspace in workspaces {
            result.append(contentsOf: buckets[workspace.workspaceID] ?? [])
        }
        result.append(contentsOf: unknown)
        return result
    }

    public static func insertIndex(
        moving: String,
        onto: String,
        placeAfter: Bool,
        orderedIDs: [String]
    ) -> UInt? {
        guard let plan = WorkspaceReorder.plan(
            moving: moving,
            onto: onto,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return nil }

        // herdr's `move_tab` reads `insert_index` against the list as it is
        // BEFORE the move — "insert before the tab currently at this index" —
        // and subtracts one itself when the source sits earlier. Indexing the
        // list with the moving tab already removed double-compensated, landing
        // every forward drag one slot short.
        if let before = plan.beforeWorkspaceID {
            let index = orderedIDs.firstIndex(of: before) ?? orderedIDs.count
            return UInt(index)
        }
        return UInt(orderedIDs.count)
    }
}
