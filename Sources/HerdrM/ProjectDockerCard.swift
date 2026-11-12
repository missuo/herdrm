import HerdrKit
import SwiftUI

// The Docker card of the Project pane: compose groups and loose containers as a grid of small
// tiles. A tile only selects; the detail strip under the grid is the single action surface.

struct ProjectDockerActions {
    var attachCompose: (String) -> Void
    var detachCompose: (String) -> Void
    var attachContainer: (String) -> Void
    var dismissSuggestion: (String) -> Void
    var detachContainer: (String) -> Void
}

enum ContainerTileContext { case compose, otherCompose, attached, suggested }

enum ContainerPorts {
    /// "8080→80, 5432→5432": host port to container port, duplicates removed in order.
    static func summary(_ ports: [PublishedPort]) -> String {
        var seen = Set<String>()
        return ports.map { "\($0.hostPort)→\($0.containerPort)" }
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    static let displayLimit = 12

    /// Docker reports a dual-stack mapping twice (`0.0.0.0` and `::`); show it once, order preserved.
    static func displayPorts(_ ports: [PublishedPort]) -> [PublishedPort] {
        var seen = Set<String>()
        var out: [PublishedPort] = []
        for port in ports {
            var port = port
            if port.hostIP == "0.0.0.0" || port.hostIP == "::" { port.hostIP = "0.0.0.0" }
            guard seen.insert("\(port.hostIP)|\(port.hostPort)|\(port.containerPort)|\(port.proto)").inserted else { continue }
            out.append(port)
        }
        return out
    }

    static func detail(_ port: PublishedPort) -> String {
        "\(port.hostIP):\(port.hostPort) → \(port.containerPort)/\(port.proto)"
    }
}

private func containerHealthTag(_ container: ContainerRow) -> (key: LocalizedStringKey, tint: Color)? {
    switch container.health {
    case "healthy": ("healthy", Theme.success)
    case "unhealthy": ("unhealthy", Theme.danger)
    case "starting": ("starting", Theme.warning)
    default: nil
    }
}

// MARK: - Tile

struct ContainerTile: View {
    let container: ContainerRow
    let isSelected: Bool
    let action: () -> Void

    private var isUnhealthy: Bool { container.health == "unhealthy" }
    private var isRunning: Bool { container.state == "running" }

    private var dotColor: Color {
        if isUnhealthy { return Theme.danger }
        return isRunning ? Theme.success : Theme.textTertiary
    }

    private var nameColor: Color {
        if isUnhealthy { return Theme.danger }
        return isRunning ? Theme.text : Theme.textTertiary
    }

    private var secondLine: String {
        let ports = ContainerPorts.summary(container.ports)
        return ports.isEmpty ? (container.health ?? container.statusText) : ports
    }

    private var label: String {
        let name = container.service ?? container.name
        return "\(name), \(container.state)" + (isUnhealthy ? ", unhealthy" : "")
    }

    private var fill: Color {
        if isSelected { return Theme.itemWashSelected }
        return isUnhealthy ? Theme.danger.opacity(0.10) : Theme.itemWash
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    StatusDot(color: dotColor)
                    Text(verbatim: container.service ?? container.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(verbatim: secondLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(container.name + " · " + container.image)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("project.container.\(container.id)")
    }
}

// MARK: - Grid

struct ContainerTileGrid: View {
    let containers: [ContainerRow]
    let context: ContainerTileContext
    let isRemote: Bool
    @Binding var selection: String?
    let actions: ProjectDockerActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: ProjectMetrics.gridMinimum), spacing: ProjectMetrics.gridSpacing)],
                spacing: ProjectMetrics.gridSpacing
            ) {
                ForEach(containers) { container in
                    ContainerTile(container: container, isSelected: container.id == selection) {
                        selection = selection == container.id ? nil : container.id
                    }
                }
            }
            .padding(.vertical, 6)
            if let selected = containers.first(where: { $0.id == selection }) {
                ContainerDetailStrip(
                    container: selected, context: context, isRemote: isRemote, actions: actions,
                    onClose: { selection = nil })
                    .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Detail strip

struct ContainerDetailStrip: View {
    let container: ContainerRow
    let context: ContainerTileContext
    let isRemote: Bool
    let actions: ProjectDockerActions
    let onClose: () -> Void

    private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(container.image, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProjectKindTile(kind: .container)
                Text(verbatim: container.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: container.statusText)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                if let tag = containerHealthTag(container) { ProjectTag(tag.key, tint: tag.tint) }
                Spacer(minLength: 8)
                switch context {
                case .suggested:
                    Button("Attach") { actions.attachContainer(container.name) }.controlSize(.small)
                    Button("Dismiss") { actions.dismissSuggestion(container.name) }.controlSize(.small)
                case .attached:
                    Button("Detach") { actions.detachContainer(container.name) }.controlSize(.small)
                case .compose, .otherCompose:
                    EmptyView()
                }
                ProjectIconButton(systemImage: "xmark", label: "Close", action: onClose)
            }
            HStack(spacing: 8) {
                Text("Image").foregroundStyle(Theme.textTertiary)
                Text(verbatim: container.image)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                ProjectIconButton(systemImage: "doc.on.doc", label: "Copy image name", action: copyImage)
            }
            if !container.ports.isEmpty {
                let ports = ContainerPorts.displayPorts(container.ports)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Ports").foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 8) {
                        ForEach(Array(ports.prefix(ContainerPorts.displayLimit).enumerated()), id: \.offset) { _, port in
                            Text(verbatim: ContainerPorts.detail(port))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        if ports.count > ContainerPorts.displayLimit {
                            ProjectTag("+\(ports.count - ContainerPorts.displayLimit) more")
                        }
                    }
                }
            }
            if !container.urls.isEmpty {
                ProjectURLButtons(urls: container.urls, isRemote: isRemote)
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.itemWash))
        .accessibilityIdentifier("project.containerDetail")
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Compose header

struct ComposeGroupHeader: View {
    let group: ComposeGroup
    let isAttached: Bool
    let onToggle: () -> Void

    private var matchBadge: LocalizedStringKey? {
        switch group.match {
        case .path: "matched by path"
        case .name: "matched by name"
        case .attached: "attached"
        case nil: nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProjectKindTile(kind: .compose)
            Text(verbatim: group.name)
                .font(.system(size: ProjectMetrics.textSize, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(verbatim: "\(group.running)/\(group.total)")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(group.running == group.total && group.total > 0 ? Theme.success : Theme.textSecondary)
            if let matchBadge { ProjectTag(matchBadge, tint: Theme.accent) }
            Spacer(minLength: 8)
            Button(isAttached ? "Detach" : "Attach", action: onToggle).controlSize(.small)
        }
        .frame(minHeight: ProjectMetrics.rowHeight)
    }
}

// MARK: - Card

struct ProjectDockerCard: View {
    let snapshot: ProjectSnapshot
    let isRemote: Bool
    let isOtherExpanded: Binding<Bool>
    let actions: ProjectDockerActions

    /// Selected container id per grid, keyed "compose:<name>", "other:<name>", "attached", "suggested".
    @State private var selected: [String: String] = [:]

    private func selectionBinding(_ key: String) -> Binding<String?> {
        Binding(get: { selected[key] }, set: { selected[key] = $0 })
    }

    /// Every grid's current container ids, by selection key.
    private var groups: [String: Set<String>] {
        var result: [String: Set<String>] = [
            "attached": Set(snapshot.attachedContainers.map(\.id)),
            "suggested": Set(snapshot.suggestedContainers.map(\.id)),
        ]
        for group in snapshot.compose { result["compose:\(group.name)"] = Set(group.containers.map(\.id)) }
        for group in snapshot.otherCompose { result["other:\(group.name)"] = Set(group.containers.map(\.id)) }
        return result
    }

    private func pruneSelection() {
        let current = groups
        selected = selected.filter { key, id in current[key]?.contains(id) ?? false }
    }

    private func grid(_ containers: [ContainerRow], key: String, context: ContainerTileContext) -> some View {
        ContainerTileGrid(
            containers: containers, context: context, isRemote: isRemote,
            selection: selectionBinding(key), actions: actions)
    }

    var body: some View {
        let isEmpty = snapshot.compose.isEmpty && snapshot.attachedContainers.isEmpty
            && snapshot.suggestedContainers.isEmpty
        ProjectCard("Docker", count: snapshot.compose.count + snapshot.attachedContainers.count, id: .docker) {
            if let error = snapshot.host.dockerError {
                ProjectCardNote(
                    "Docker is not reachable: \(error)", tint: Theme.warning, systemImage: "exclamationmark.triangle")
            } else if isEmpty {
                ProjectCardNote("No Docker containers belong to this project.")
            }
            ForEach(snapshot.compose) { group in
                ComposeGroupHeader(group: group, isAttached: true) { actions.detachCompose(group.name) }
                grid(group.containers, key: "compose:\(group.name)", context: .compose)
            }
            if !snapshot.attachedContainers.isEmpty {
                SheetSectionLabel("Attached containers").padding(.top, 6)
                grid(snapshot.attachedContainers, key: "attached", context: .attached)
            }
            if !snapshot.suggestedContainers.isEmpty {
                SheetSectionLabel("Suggested containers").padding(.top, 6)
                grid(snapshot.suggestedContainers, key: "suggested", context: .suggested)
            }
            if !snapshot.otherCompose.isEmpty {
                ProjectDisclosureCard("Other Compose projects", isExpanded: isOtherExpanded) {
                    ForEach(snapshot.otherCompose) { group in
                        ComposeGroupHeader(group: group, isAttached: false) { actions.attachCompose(group.name) }
                        grid(group.containers, key: "other:\(group.name)", context: .otherCompose)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .onChange(of: snapshot.probedAt) { pruneSelection() }
    }
}
