import AppKit
import HerdrKit
import SwiftUI

// The dev-server cards of the Project pane: Hot reload, Other listeners and Hidden.

/// One dev server on two lines: framework, role, address and flags, then unit, log and URLs.
struct DevServerRow: View {
    let server: DevServer
    let overrideURL: String?
    var isRemote = false
    /// Nil hides "Set URL…" in the menu (listeners that are not part of the project).
    let onSetURL: ((String?) -> Void)?
    let onToggleHidden: () -> Void

    private var roleName: LocalizedStringKey {
        switch server.role {
        case .frontend: "Frontend"
        case .backend: "Backend"
        case .tooling: "Tooling"
        case .other: "Other"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProjectKindTile(
                kind: ProjectKind.forRole(server.role),
                tint: server.hotReload ? Theme.accent : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                firstLine
                secondLine
            }
            Spacer(minLength: 8)
            DevServerMenu(
                server: server, isRemote: isRemote, overrideURL: overrideURL,
                onSetURL: onSetURL, onToggleHidden: onToggleHidden)
        }
        .frame(minHeight: ProjectMetrics.twoLineRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.server.\(server.signature)")
    }

    private var firstLine: some View {
        HStack(spacing: 8) {
            Text(verbatim: server.framework)
                .font(.system(size: ProjectMetrics.textSize, weight: .medium))
                .foregroundStyle(server.isHidden ? Theme.textTertiary : Theme.text)
                .lineLimit(1)
                .layoutPriority(0)
            Text(roleName)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Text(verbatim: "\(server.bind):\(server.port)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            if server.isPublicBind {
                ProjectTag("public", tint: Theme.warning)
            } else {
                ProjectTag("loopback only")
            }
            if server.hotReload {
                ProjectTag("hot reload", tint: Theme.accent, systemImage: "bolt.fill")
            }
        }
    }

    private var secondLine: some View {
        HStack(spacing: 8) {
            if let unit = server.unit {
                ProjectVerbatimTag(text: unit, systemImage: "gearshape")
            }
            if let log = server.logPath {
                ProjectVerbatimTag(text: (log as NSString).lastPathComponent, systemImage: "doc.text", help: log)
            }
            ProjectURLButtons(urls: server.urls, isRemote: isRemote, showsCopy: false)
        }
        .font(.system(size: 11))
    }
}

/// The row's only controls: open or copy a URL, set an override, hide or unhide.
struct DevServerMenu: View {
    let server: DevServer
    var isRemote = false
    let overrideURL: String?
    let onSetURL: ((String?) -> Void)?
    let onToggleHidden: () -> Void
    @State private var editing = false

    /// A loopback-only URL on a remote device would open the Mac's own localhost.
    private var openable: [ProjectURL] {
        server.urls.filter { !(isRemote && $0.loopbackOnHost) }
    }

    var body: some View {
        Menu {
            urlItems
            if onSetURL != nil {
                Button("Set URL…") { editing = true }
            }
            Divider()
            Button(server.isHidden ? "Unhide" : "Hide", action: onToggleHidden)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.textSecondary)
        .accessibilityLabel("More")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            URLOverridePopover(
                initial: overrideURL ?? "",
                onSave: { value in
                    onSetURL?(value)
                    editing = false
                },
                onCancel: { editing = false })
        }
    }

    @ViewBuilder
    private var urlItems: some View {
        // Opening a remote loopback URL would hit the Mac's own localhost; copying it is harmless.
        if openable.count == 1, let url = openable.first {
            Button("Open URL") { ProjectURLActions.open(url) }
        } else if openable.count > 1 {
            Menu("Open") {
                ForEach(Array(openable.enumerated()), id: \.offset) { _, url in
                    Button(url.label) { ProjectURLActions.open(url) }
                }
            }
        }
        if server.urls.count == 1, let url = server.urls.first {
            Button("Copy URL") { ProjectURLActions.copy(url) }
        } else if server.urls.count > 1 {
            Menu("Copy URL") {
                ForEach(Array(server.urls.enumerated()), id: \.offset) { _, url in
                    Button(url.label) { ProjectURLActions.copy(url) }
                }
            }
        }
    }
}

/// Running project dev servers, with the stale-override note.
struct ProjectHotReloadCard: View {
    let snapshot: ProjectSnapshot
    let isRemote: Bool
    let overrideURL: (DevServer) -> String?
    let onSetURL: (String, String?) -> Void
    let onToggleHidden: (String) -> Void

    var body: some View {
        let visible = snapshot.devServers.filter { !$0.isHidden }
        ProjectCard("Hot reload", count: visible.count, id: .hot) {
            if visible.isEmpty { ProjectCardNote("No dev servers are running for this project.") }
            ProjectCardList(visible) { server in
                DevServerRow(
                    server: server, overrideURL: overrideURL(server), isRemote: isRemote,
                    onSetURL: { onSetURL(server.signature, $0) },
                    onToggleHidden: { onToggleHidden(server.signature) })
            }
            if !snapshot.staleOverrides.isEmpty {
                ProjectCardNote("URL overrides without a running server: \(snapshot.staleOverrides.joined(separator: ", "))")
            }
        }
    }
}

/// Listening processes that are not part of the project; collapsed by default.
struct ProjectOtherListenersCard: View {
    let listeners: [DevServer]
    let isRemote: Bool
    let isExpanded: Binding<Bool>
    let onToggleHidden: (String) -> Void

    var body: some View {
        let visible = listeners.filter { !$0.isHidden }
        if !visible.isEmpty {
            ProjectDisclosureCard("Other listeners", count: visible.count, id: .other, isExpanded: isExpanded) {
                ProjectCardList(visible) { server in
                    DevServerRow(
                        server: server, overrideURL: nil, isRemote: isRemote, onSetURL: nil,
                        onToggleHidden: { onToggleHidden(server.signature) })
                }
            }
        }
    }
}

/// Hidden dev servers and listeners, collapsed; each row keeps Unhide in its menu.
struct ProjectHiddenCard: View {
    let devServers: [DevServer]
    let listeners: [DevServer]
    let isRemote: Bool
    let isExpanded: Binding<Bool>
    let onSetURL: (String, String?) -> Void
    let onToggleHidden: (String) -> Void

    var body: some View {
        let dev = devServers.filter(\.isHidden)
        let other = listeners.filter(\.isHidden)
        if !dev.isEmpty || !other.isEmpty {
            ProjectDisclosureCard("Hidden (\(dev.count + other.count))", id: .hidden, isExpanded: isExpanded) {
                ProjectCardList(dev) { server in
                    DevServerRow(
                        server: server, overrideURL: server.urls.first { $0.source == .override }?.url,
                        isRemote: isRemote, onSetURL: { onSetURL(server.signature, $0) },
                        onToggleHidden: { onToggleHidden(server.signature) })
                }
                if !dev.isEmpty && !other.isEmpty {
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 30)
                }
                ProjectCardList(other) { server in
                    DevServerRow(
                        server: server, overrideURL: nil, isRemote: isRemote, onSetURL: nil,
                        onToggleHidden: { onToggleHidden(server.signature) })
                }
            }
        }
    }
}
