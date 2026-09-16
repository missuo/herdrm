import SwiftUI

/// Sidebar section sticky-header contract. UI (`SidebarView`) and tests share
/// these values so pin behavior cannot drift silently.
enum SidebarSectionID: String, CaseIterable, Sendable {
    case spaces
    case agents
    case terminals

    var accessibilityIdentifier: String { "sidebar.section.\(rawValue)" }

    var title: LocalizedStringKey {
        switch self {
        case .spaces: return "Spaces"
        case .agents: return "Agents"
        case .terminals: return "Terminals"
        }
    }
}

enum SidebarStickyLayout {
    /// Matches the existing group header row height.
    static let headerHeight: CGFloat = 28
    /// Gap between sections; scrolls away so the next sticky header sits flush.
    static let interSectionGap: CGFloat = 10
    /// Production and probe stacks must pin the same views.
    static let pinnedViews: PinnedScrollableViews = [.sectionHeaders]
    static let pinsSectionHeaders = true

    static func visibleSections(terminalsVisible: Bool) -> [SidebarSectionID] {
        if terminalsVisible {
            return [.spaces, .agents, .terminals]
        }
        return [.spaces, .agents]
    }

    /// Which header should be pinned at the top for a given scroll progress
    /// through equally tall sections (unit model of flow-sticky takeover).
    static func pinnedSection(
        scrollOffsetY: CGFloat,
        sectionBodyHeights: [SidebarSectionID: CGFloat],
        terminalsVisible: Bool
    ) -> SidebarSectionID {
        let sections = visibleSections(terminalsVisible: terminalsVisible)
        var frontier = CGFloat.zero
        var current = sections[0]
        for id in sections {
            current = id
            let body = sectionBodyHeights[id] ?? 0
            let gap = id == sections.last ? 0 : interSectionGap
            let span = headerHeight + body + gap
            let nextFrontier = frontier + span
            // This header owns the pin until the next section's header reaches the top.
            if scrollOffsetY < nextFrontier {
                return id
            }
            frontier = nextFrontier
        }
        return current
    }
}
