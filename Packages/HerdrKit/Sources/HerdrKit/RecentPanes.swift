import Foundation

/// A pane the ⌃Tab switcher can go back to. Pane ids like "w1:p1" repeat
/// across devices, so the device is part of the identity.
public struct RecentPane: Codable, Hashable, Sendable {
    public let deviceID: UUID
    public let paneID: String

    public init(deviceID: UUID, paneID: String) {
        self.deviceID = deviceID
        self.paneID = paneID
    }
}

/// Panes in the order they were last selected, newest first.
public enum RecentPanes {
    public static let limit = 50
    public static let defaultsKey = "switcher.recentPanes"

    public static func recording(_ pane: RecentPane, into list: [RecentPane]) -> [RecentPane] {
        Array(([pane] + list.filter { $0 != pane }).prefix(limit))
    }

    /// Drops the device's panes that its latest snapshot no longer has (closed).
    /// Other devices are untouched: one that is disconnected or not loaded yet
    /// keeps its panes until it reports.
    public static func pruning(_ list: [RecentPane], deviceID: UUID, keeping paneIDs: Set<String>) -> [RecentPane] {
        list.filter { $0.deviceID != deviceID || paneIDs.contains($0.paneID) }
    }

    public static func removingDevice(_ deviceID: UUID, from list: [RecentPane]) -> [RecentPane] {
        list.filter { $0.deviceID != deviceID }
    }

    /// Everything in `all`, the recent ones first in recency order, then the
    /// rest in their given (sidebar) order. Recent ids missing from `all` are skipped.
    public static func ordered<ID: Hashable>(_ all: [ID], recent: [ID]) -> [ID] {
        let present = Set(all)
        var seen = Set<ID>()
        let head = recent.filter { present.contains($0) && seen.insert($0).inserted }
        return head + all.filter { !seen.contains($0) }
    }

    public static func load(from defaults: UserDefaults = .standard) -> [RecentPane] {
        guard let data = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([RecentPane].self, from: data)
        else { return [] }
        return list
    }

    public static func save(_ list: [RecentPane], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(Array(list.prefix(limit))) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// One ⌃Tab session, like ⌘Tab: the list is fixed when it opens, so stepping
/// through it never reorders it, and only the committed choice is recorded.
public struct RecentSwitcher<Item: Hashable> {
    public let items: [Item]
    public private(set) var highlighted: Int

    /// Nil when there is nothing to switch to. `current` is the item on screen,
    /// which is never the starting highlight: the first tap goes to the most
    /// recent other item, or with `backward` (⇧ held) to the oldest.
    public init?(items: [Item], current: Item?, backward: Bool = false) {
        let start = backward
            ? items.lastIndex { $0 != current }
            : items.firstIndex { $0 != current }
        guard let start else { return nil }
        self.items = items
        highlighted = start
    }

    public var selection: Item { items[highlighted] }

    /// Tab moves one further back (down the list); ⇧Tab moves forward. Both wrap.
    public mutating func step(backward: Bool = false) {
        let count = items.count
        highlighted = (highlighted + (backward ? count - 1 : 1)) % count
    }

    public mutating func highlight(_ item: Item) {
        if let index = items.firstIndex(of: item) { highlighted = index }
    }
}
