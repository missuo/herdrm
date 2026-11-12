import Foundation

/// The Spaces list as herdr's sidebar draws it: a repository's linked
/// worktrees listed, indented, under the workspace of its main checkout.
/// A repository groups only when both are open; otherwise every workspace
/// keeps its own place. Mirrors herdr's `workspace_entries`.
public enum WorktreeGroups {
    public struct Entry: Equatable, Sendable {
        /// Index into the workspaces handed in.
        public let index: Int
        /// A linked worktree under its main checkout.
        public let indented: Bool
        /// The group's last worktree, for the tree line's elbow.
        public let lastChild: Bool

        public init(index: Int, indented: Bool, lastChild: Bool) {
            self.index = index
            self.indented = indented
            self.lastChild = lastChild
        }
    }

    /// Repository keys that have an open main checkout and at least one open
    /// linked worktree.
    public static func groupedKeys(_ workspaces: [WorkspaceInfo]) -> Set<String> {
        var parents = Set<String>(), children = Set<String>()
        for case let worktree? in workspaces.map(\.worktree) {
            if worktree.isLinkedWorktree { children.insert(worktree.repoKey) } else { parents.insert(worktree.repoKey) }
        }
        return parents.intersection(children)
    }

    /// Display order: each group appears where its first member is, main
    /// checkout first, then its worktrees in herdr's order.
    public static func entries(_ workspaces: [WorkspaceInfo]) -> [Entry] {
        let grouped = groupedKeys(workspaces)
        var emitted = Set<String>()
        var entries: [Entry] = []
        for (index, workspace) in workspaces.enumerated() {
            guard let key = workspace.worktree?.repoKey, grouped.contains(key) else {
                entries.append(Entry(index: index, indented: false, lastChild: false))
                continue
            }
            guard emitted.insert(key).inserted else { continue }
            let members = workspaces.indices.filter { workspaces[$0].worktree?.repoKey == key }
            for parent in members where workspaces[parent].worktree?.isLinkedWorktree == false {
                entries.append(Entry(index: parent, indented: false, lastChild: false))
            }
            let children = members.filter { workspaces[$0].worktree?.isLinkedWorktree == true }
            for (position, child) in children.enumerated() {
                entries.append(Entry(index: child, indented: true, lastChild: position == children.count - 1))
            }
        }
        return entries
    }

    /// What moves when `workspaceID` is dragged: a group's main checkout
    /// brings its worktrees along; anything else moves alone.
    public static func block(of workspaceID: String, in workspaces: [WorkspaceInfo]) -> [String] {
        guard let workspace = workspaces.first(where: { $0.workspaceID == workspaceID }),
              let worktree = workspace.worktree, !worktree.isLinkedWorktree,
              groupedKeys(workspaces).contains(worktree.repoKey)
        else { return [workspaceID] }
        return entries(workspaces).map { workspaces[$0.index] }
            .filter { $0.worktree?.repoKey == worktree.repoKey }
            .map(\.workspaceID)
    }

    /// A drop of `moving` on `onto` in the grouped list, as one
    /// `workspace.move_block`. A drop on a group from outside lands before
    /// or after the whole group, never inside it; a worktree dropped among
    /// its own group's worktrees reorders within it. Nil when nothing moves.
    public static func plan(
        moving: String, onto: String, placeAfter: Bool, workspaces: [WorkspaceInfo]
    ) -> WorkspaceReorder.Plan? {
        guard moving != onto,
              workspaces.contains(where: { $0.workspaceID == moving }),
              let target = workspaces.first(where: { $0.workspaceID == onto })
        else { return nil }
        let order = entries(workspaces).map { workspaces[$0.index].workspaceID }
        let movingBlock = block(of: moving, in: workspaces)
        guard !movingBlock.contains(onto) else { return nil }

        let movingKey = workspaces.first { $0.workspaceID == moving }?.worktree
        let withinOwnGroup = movingKey?.isLinkedWorktree == true
            && target.worktree?.repoKey == movingKey?.repoKey && target.worktree?.isLinkedWorktree == true
        let targetBlock: [String]
        if withinOwnGroup {
            targetBlock = [onto]
        } else if let key = target.worktree?.repoKey, groupedKeys(workspaces).contains(key) {
            targetBlock = order.filter { id in workspaces.first { $0.workspaceID == id }?.worktree?.repoKey == key }
        } else {
            targetBlock = [onto]
        }
        let rest = order.filter { !movingBlock.contains($0) }
        let before: String?
        if placeAfter {
            guard let last = targetBlock.last, let index = rest.firstIndex(of: last) else { return nil }
            before = index + 1 < rest.count ? rest[index + 1] : nil
        } else {
            before = targetBlock.first
        }
        // In herdr's own order, which move_block keeps for the moved ids.
        let ids = workspaces.map(\.workspaceID).filter(movingBlock.contains)
        let plan = WorkspaceReorder.Plan(workspaceIDs: ids, beforeWorkspaceID: before)
        let moved = WorkspaceReorder.applying(workspaces, id: \.workspaceID, plan: plan)
        return entries(moved).map { moved[$0.index].workspaceID } == order ? nil : plan
    }
}
