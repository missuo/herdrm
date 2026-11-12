import HerdrKit
import SwiftUI

// Shared building blocks of the Project pane's "config page" layout: inset cards under a caps
// label, kind tiles, a header summary strip and a disclosure card.

enum ProjectMetrics {
    static let rowHeight: CGFloat = 28
    static let twoLineRowHeight: CGFloat = 44
    static let textSize: CGFloat = 12.5
    static let cardRadius: CGFloat = 10
    static let cardSpacing: CGFloat = 14
    static let pagePadding: CGFloat = 14
    static let tileSize: CGFloat = 22
    static let tileRadius: CGFloat = 6
    static let tileGlyph: CGFloat = 11
    static let gridMinimum: CGFloat = 150
    static let gridSpacing: CGFloat = 6
    static let meterHeight: CGFloat = 4
}

/// What a row or tile stands for; decides its glyph and tint.
enum ProjectKind {
    case hotReload, frontend, backend, tooling, listener, compose, container, vm, host, mac, link, file

    var symbol: String {
        switch self {
        case .hotReload: return "bolt.fill"
        case .frontend: return "macwindow"
        case .backend: return "cpu"
        case .tooling: return "wrench.and.screwdriver"
        case .listener: return "network"
        case .compose: return "square.stack.3d.down.right.fill"
        case .container: return "cube"
        case .vm: return "pc"
        case .host: return "server.rack"
        case .mac: return "laptopcomputer"
        case .link: return "globe"
        case .file: return "doc"
        }
    }

    var tint: Color {
        switch self {
        case .hotReload, .frontend, .backend, .tooling: return Theme.accent
        case .compose, .container: return Theme.working
        case .vm: return Theme.devicePalette[0]
        case .host: return Theme.devicePalette[1]
        case .listener, .mac, .link, .file: return Theme.textSecondary
        }
    }

    static func forRole(_ role: ServiceRole) -> ProjectKind {
        switch role {
        case .frontend: return .frontend
        case .backend: return .backend
        case .tooling: return .tooling
        case .other: return .listener
        }
    }
}

/// Rounded square with a glyph, the leading mark of a row.
struct ProjectKindTile: View {
    let symbol: String
    let tint: Color

    init(kind: ProjectKind, tint: Color? = nil) {
        self.init(symbol: kind.symbol, tint: tint ?? kind.tint)
    }

    init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        RoundedRectangle(cornerRadius: ProjectMetrics.tileRadius)
            .fill(tint.opacity(0.13))
            .frame(width: ProjectMetrics.tileSize, height: ProjectMetrics.tileSize)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: ProjectMetrics.tileGlyph, weight: .medium))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

enum ProjectSectionID: String {
    case overview, hot, docker, hosts, links, files, other, hidden
}

/// Makes a card's label row a toggle; a collapsed card draws no body at all.
struct ProjectDisclosure {
    let isExpanded: Bool
    let toggle: () -> Void
}

/// A caps label with an optional count and trailing control above an inset rounded card.
struct ProjectCard<Trailing: View, Content: View>: View {
    let title: LocalizedStringKey
    let count: Int?
    let id: ProjectSectionID?
    let disclosure: ProjectDisclosure?
    let trailing: Trailing
    let content: Content

    init(
        _ title: LocalizedStringKey, count: Int? = nil, id: ProjectSectionID? = nil,
        disclosure: ProjectDisclosure? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.id = id
        self.disclosure = disclosure
        self.trailing = trailing()
        self.content = content()
    }

    private var labelRow: some View {
        HStack(spacing: 6) {
            if let disclosure {
                Button(action: disclosure.toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
                            .frame(width: 10)
                        labelAndCount
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
            } else {
                labelAndCount
                Spacer(minLength: 8)
            }
            trailing
        }
        .padding(.horizontal, 4)
    }

    private var labelAndCount: some View {
        HStack(spacing: 6) {
            SheetSectionLabel(title)
            if let count, count > 0 {
                Text(verbatim: "\(count)").font(.system(size: 10.5)).foregroundStyle(Theme.textGhost)
            }
        }
    }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 6) {
            labelRow
            if disclosure?.isExpanded ?? true { cardBody }
        }
        if let id {
            card.id(id).accessibilityIdentifier("project.section.\(id.rawValue)")
        } else {
            card
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: ProjectMetrics.cardRadius).fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ProjectMetrics.cardRadius)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Homogeneous rows with an inset hairline between consecutive ones.
struct ProjectCardList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let row: (Item) -> Row

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 30)
            }
            row(item)
        }
    }
}

/// A short muted line inside a card ("No dev servers are running ...").
struct ProjectCardNote: View {
    let text: LocalizedStringKey
    let tint: Color
    let systemImage: String?

    init(_ text: LocalizedStringKey, tint: Color = Theme.textTertiary, systemImage: String? = nil) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
            Text(text)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(tint)
        .frame(minHeight: ProjectMetrics.rowHeight, alignment: .leading)
    }
}

/// A card whose label row toggles its content; collapsed content is not rendered at all.
struct ProjectDisclosureCard<Content: View>: View {
    let title: LocalizedStringKey
    let count: Int?
    let id: ProjectSectionID?
    @Binding var isExpanded: Bool
    let content: Content

    init(
        _ title: LocalizedStringKey, count: Int? = nil, id: ProjectSectionID? = nil,
        isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.id = id
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        ProjectCard(
            title, count: count, id: id,
            disclosure: ProjectDisclosure(isExpanded: isExpanded, toggle: { isExpanded.toggle() })
        ) {
            content
        }
    }
}

/// One-line totals under the pane title: dev servers, containers, VMs and hosts.
struct ProjectSummaryStrip: View {
    let snapshot: ProjectSnapshot
    let linkedHostCount: Int

    private struct Item: Identifiable {
        let kind: ProjectKind
        let label: String
        let value: String
        var id: String { label }
    }

    private var items: [Item] {
        let devServers = snapshot.devServers.filter { !$0.isHidden }.count
        let total = snapshot.compose.reduce(0) { $0 + $1.total } + snapshot.attachedContainers.count
        let running = snapshot.compose.reduce(0) { $0 + $1.running }
            + snapshot.attachedContainers.filter { $0.state == "running" }.count
        var items: [Item] = []
        if devServers > 0 { items.append(Item(kind: .hotReload, label: String(localized: "Dev servers"), value: "\(devServers)")) }
        if total > 0 { items.append(Item(kind: .compose, label: String(localized: "Containers"), value: "\(running)/\(total)")) }
        if !snapshot.vms.isEmpty { items.append(Item(kind: .vm, label: String(localized: "VMs"), value: "\(snapshot.vms.count)")) }
        items.append(Item(kind: .host, label: String(localized: "Hosts"), value: "\(1 + linkedHostCount)"))
        return items
    }

    private var summaryText: String {
        items.map { "\($0.label) \($0.value)" }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Text(verbatim: "·").foregroundStyle(Theme.textGhost) }
                HStack(spacing: 4) {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 9.5))
                        .foregroundStyle(item.kind.tint)
                    Text(verbatim: item.label).foregroundStyle(Theme.textSecondary)
                    Text(verbatim: item.value).monospacedDigit().foregroundStyle(Theme.text)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summaryText))
        .accessibilityIdentifier("project.summary")
    }
}
