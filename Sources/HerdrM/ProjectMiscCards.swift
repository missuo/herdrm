import HerdrKit
import SwiftUI

// The smaller cards of the Project pane: URL chips, project files and the warnings footnote.

/// Wraps subviews left to right; each line is as tall as its tallest item.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func place(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (points, y + lineHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: place(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = place(subviews, width: bounds.width).points
        for (subview, point) in zip(subviews, points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
}

/// One URL as a rounded chip; a loopback URL on a remote host is ghost text, never a button.
struct ProjectLinkChip: View {
    let url: ProjectURL
    let isRemote: Bool

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe").font(.system(size: 9.5)).accessibilityHidden(true)
            Text(verbatim: url.label)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        if isRemote && url.loopbackOnHost {
            // Accessibility modifiers go on the element itself, before the context menu wraps it:
            // applied after, the identifier lands on the wrapper and the enclosing card's wins.
            label.foregroundStyle(Theme.textGhost)
                .accessibilityIdentifier("project.link.\(url.url)")
                .help("Only reachable from the host itself")
                .contextMenu { Button("Copy URL") { ProjectURLActions.copy(url) } }
        } else {
            Button { ProjectURLActions.open(url) } label: { label.foregroundStyle(Theme.text) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: url.label))
                .accessibilityIdentifier("project.link.\(url.url)")
                .help("Open this URL")
                .contextMenu { Button("Copy URL") { ProjectURLActions.copy(url) } }
        }
    }
}

/// Previous/next control for a card that shows `pageSize` items at a time; hidden for one page.
struct ProjectPager: View {
    @Binding var page: Int
    let pageCount: Int
    let identifier: String

    var body: some View {
        if pageCount > 1 {
            HStack(spacing: 2) {
                ProjectIconButton(systemImage: "chevron.left", label: "Previous page") { page = max(0, page - 1) }
                    .disabled(page == 0)
                Text(verbatim: "\(page + 1)/\(pageCount)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityIdentifier(identifier)
                ProjectIconButton(systemImage: "chevron.right", label: "Next page") { page = min(pageCount - 1, page + 1) }
                    .disabled(page == pageCount - 1)
            }
        }
    }
}

struct ProjectLinksCard: View {
    let urls: [ProjectURL]
    let isRemote: Bool
    /// Chips per page; a project with dozens of published ports stays one screen tall.
    static let pageSize = 12
    @State private var page = 0

    private var pageCount: Int { max(1, (urls.count + Self.pageSize - 1) / Self.pageSize) }

    private var visible: [ProjectURL] {
        let start = min(page, pageCount - 1) * Self.pageSize
        return Array(urls[start..<min(start + Self.pageSize, urls.count)])
    }

    var body: some View {
        if !urls.isEmpty {
            ProjectCard("Links", count: urls.count, id: .links, trailing: { pager }) {
                // A grid, not FlowLayout: children of a custom Layout reach the accessibility
                // tree only intermittently, and the columns read better for a dozen URLs.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: ProjectMetrics.gridSpacing, alignment: .leading)],
                    alignment: .leading, spacing: ProjectMetrics.gridSpacing
                ) {
                    ForEach(visible, id: \.url) { ProjectLinkChip(url: $0, isRemote: isRemote) }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: urls.count) { page = min(page, pageCount - 1) }
        }
    }

    private var pager: some View {
        ProjectPager(page: $page, pageCount: pageCount, identifier: "project.links.page")
    }
}

/// Project files and the variable names (never the values) of their env files.
struct ProjectFilesCard: View {
    let files: [String]
    /// Env variable names by file; values can be secrets and never reach the view.
    let envByFile: [String: [String]]

    private static let keyLimit = 12
    @State private var page = 0

    private func fileRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            ProjectKindTile(kind: .file)
            Text(verbatim: name)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: ProjectMetrics.rowHeight)
    }

    private func envRow(_ file: String, keys: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProjectKindTile(kind: .file)
            Text(verbatim: file)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 3)
            FlowLayout {
                ForEach(keys.prefix(Self.keyLimit), id: \.self) { ProjectVerbatimTag(text: $0, systemImage: "key") }
                if keys.count > Self.keyLimit { ProjectTag("+\(keys.count - Self.keyLimit) more") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(minHeight: ProjectMetrics.rowHeight)
    }

    /// Files first, then env files, twelve rows a page.
    private enum Row: Identifiable {
        case file(String)
        case env(file: String, keys: [String])
        var id: String {
            switch self {
            case .file(let name): "file:\(name)"
            case .env(let file, _): "env:\(file)"
            }
        }
    }

    private var rows: [Row] {
        files.map(Row.file) + envByFile.keys.sorted().map { Row.env(file: $0, keys: envByFile[$0] ?? []) }
    }

    private var pageCount: Int { max(1, (rows.count + ProjectLinksCard.pageSize - 1) / ProjectLinksCard.pageSize) }

    private var visible: [Row] {
        let start = min(page, pageCount - 1) * ProjectLinksCard.pageSize
        return Array(rows[start..<min(start + ProjectLinksCard.pageSize, rows.count)])
    }

    var body: some View {
        if !files.isEmpty || !envByFile.isEmpty {
            ProjectCard("Project files", count: files.count, id: .files, trailing: {
                ProjectPager(page: $page, pageCount: pageCount, identifier: "project.files.page")
            }) {
                ProjectCardList(visible) { row in
                    switch row {
                    case .file(let name): fileRow(name)
                    case .env(let file, let keys): envRow(file, keys: keys)
                    }
                }
            }
            .onChange(of: rows.count) { page = min(page, pageCount - 1) }
        }
    }
}

struct ProjectWarningsFootnote: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SheetSectionLabel("Warnings")
                ForEach(warnings, id: \.self) { warning in
                    Text(verbatim: warning).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
