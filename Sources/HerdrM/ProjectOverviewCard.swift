import HerdrKit
import SwiftUI

// The "Architecture" card at the top of the Project pane: the Mac, the host the Space runs on
// and any linked hosts, with one lane per kind of workload. Lanes scroll to their card.

/// What the overview draws, derived from a snapshot and the Space's device.
struct ProjectTopology: Equatable {
    struct MacNode: Equatable { var vms: [VMRow] }

    struct HostNode: Equatable {
        var device: Device
        var devServers: [DevServer]
        var compose: [ComposeGroup]
        var attachedCount: Int
        var dockerError: String?
        /// Only set for a local Space; a remote Space's VMs live on the Mac node.
        var vms: [VMRow]?
    }

    struct LinkedNode: Equatable, Identifiable {
        var device: Device
        var root: String
        var id: UUID { device.id }
    }

    var mac: MacNode?
    var host: HostNode
    var linked: [LinkedNode]
    var isRemote: Bool

    static func make(
        snapshot: ProjectSnapshot, device: Device, linked: [(device: Device, root: String)]
    ) -> ProjectTopology {
        let remote = !device.isLocal
        return ProjectTopology(
            mac: remote ? MacNode(vms: snapshot.vms) : nil,
            host: HostNode(
                device: device,
                devServers: snapshot.devServers.filter { !$0.isHidden },
                compose: snapshot.compose,
                attachedCount: snapshot.attachedContainers.count,
                dockerError: snapshot.host.dockerError,
                vms: remote ? nil : snapshot.vms),
            linked: linked.map { LinkedNode(device: $0.device, root: $0.root) },
            isRemote: remote)
    }
}

struct ProjectOverviewCard: View {
    let topology: ProjectTopology
    let scrollTo: (ProjectSectionID) -> Void

    var body: some View {
        ProjectCard("Architecture", id: .overview) {
            VStack(spacing: 0) {
                if let mac = topology.mac {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            // The Mac node hugs its VM list; the host node takes the rest.
                            macNode(mac).fixedSize(horizontal: true, vertical: false)
                            HorizontalEdge()
                            hostNode
                        }
                        VStack(spacing: 0) {
                            macNode(mac)
                            VerticalEdge(height: 22, labelled: true)
                            hostNode
                        }
                    }
                } else {
                    hostNode
                }
                ForEach(topology.linked) { link in
                    VerticalEdge(height: 14, labelled: false)
                    linkedNode(link)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Nodes

    private func macNode(_ mac: ProjectTopology.MacNode) -> some View {
        TopologyNode(identifier: "project.overview.node.mac") {
            NodeTitle { Image(systemName: "laptopcomputer").font(.system(size: 12)) } name: {
                Text("Mac")
            }
            vmsLane(mac.vms)
        }
    }

    private var hostNode: some View {
        let host = topology.host
        return TopologyNode(identifier: "project.overview.node.host") {
            NodeTitle {
                if topology.isRemote {
                    DeviceIcon(osID: host.device.osID, isLocal: host.device.isLocal, size: 12)
                } else {
                    Image(systemName: "laptopcomputer").font(.system(size: 12))
                }
            } name: {
                if topology.isRemote { Text(verbatim: host.device.name) } else { Text("This Mac") }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { hostLanes(host) }
                VStack(alignment: .leading, spacing: 8) { hostLanes(host) }
            }
        }
    }

    private func linkedNode(_ link: ProjectTopology.LinkedNode) -> some View {
        TopologyNode(
            identifier: "project.overview.node.linked.\(link.id.uuidString)",
            buttonLabel: Text(verbatim: link.device.name), action: { scrollTo(.hosts) }
        ) {
            HStack(spacing: 8) {
                DeviceChip(device: link.device)
                Text(verbatim: link.root)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProjectTag("linked", tint: Theme.accent)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Lanes

    @ViewBuilder
    private func hostLanes(_ host: ProjectTopology.HostNode) -> some View {
        hotLane(host.devServers)
        dockerLane(host)
        if let vms = host.vms { vmsLane(vms) }
    }

    private func hotLane(_ servers: [DevServer]) -> some View {
        TopologyLane(title: "Hot reload", id: "hot", label: "Hot reload lane",
            summary: servers.map { "\($0.framework) :\($0.port)" }.joined(separator: ", "), action: { scrollTo(.hot) }) {
            if servers.isEmpty {
                GhostLine("No dev servers")
            } else {
                ForEach(servers) { server in
                    HStack(spacing: 5) {
                        StatusDot(color: server.hotReload ? Theme.success : Theme.textSecondary)
                        Text(verbatim: server.framework)
                        Text(verbatim: ":\(server.port)").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func dockerLane(_ host: ProjectTopology.HostNode) -> some View {
        TopologyLane(title: "Docker", id: "docker", label: "Docker lane", summary: dockerSummary(host), action: { scrollTo(.docker) }) {
            ForEach(host.compose) { group in
                HStack(spacing: 5) {
                    StatusDot(color: group.total > 0 && group.running == group.total ? Theme.success : Theme.textSecondary)
                    Text(verbatim: group.name)
                    Text(verbatim: "\(group.running)/\(group.total)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if host.attachedCount > 0 {
                Text("\(host.attachedCount) attached").foregroundStyle(Theme.textSecondary)
            }
            if let error = host.dockerError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Docker down")
                }
                .foregroundStyle(Theme.warning)
                .help(error)
            } else if host.compose.isEmpty && host.attachedCount == 0 {
                GhostLine("No containers")
            }
        }
    }

    private func dockerSummary(_ host: ProjectTopology.HostNode) -> String {
        var parts = host.compose.map { "\($0.name) \($0.running)/\($0.total)" }
        if host.attachedCount > 0 { parts.append("\(host.attachedCount) attached") }
        if host.dockerError != nil { parts.append("Docker down") }
        return parts.joined(separator: ", ")
    }

    private func vmsLane(_ vms: [VMRow]) -> some View {
        TopologyLane(title: "VMs", id: "vms", label: "VMs lane",
            summary: vms.map { "\($0.name) \($0.state)" }.joined(separator: ", "), action: { scrollTo(.hosts) }) {
            if vms.isEmpty {
                GhostLine("No VMs")
            } else {
                ForEach(vms) { vm in
                    HStack(spacing: 5) {
                        StatusDot(color: vm.state.lowercased() == "running" ? Theme.success : Theme.textTertiary)
                        Text(verbatim: vm.name)
                        ProjectTag(vm.providerName)
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

private struct TopologyNode<Content: View>: View {
    let identifier: String
    var buttonLabel: Text?
    var action: (() -> Void)?
    @ViewBuilder let content: Content

    private var box: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.itemWash))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { box.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(buttonLabel ?? Text(verbatim: identifier))
            } else {
                box
            }
        }
        .accessibilityIdentifier(identifier)
        .accessibilityElement(children: .contain)
    }
}

private struct NodeTitle<Icon: View, Name: View>: View {
    @ViewBuilder let icon: Icon
    @ViewBuilder let name: Name

    var body: some View {
        HStack(spacing: 6) {
            icon.foregroundStyle(Theme.textSecondary)
            name.font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
        }
    }
}

private struct TopologyLane<Lines: View>: View {
    let title: LocalizedStringKey
    let id: String
    let label: LocalizedStringKey
    /// Spoken value: the lane's lines flattened, since the label replaces its children.
    let summary: String
    let action: () -> Void
    @ViewBuilder let lines: Lines

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                SheetSectionLabel(title)
                lines
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
            .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: summary))
        .accessibilityIdentifier("project.overview.lane.\(id)")
        .accessibilityElement(children: .contain)
    }
}

private struct GhostLine: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(Theme.textGhost)
    }
}

private struct SSHPill: View {
    var body: some View {
        Text("ssh")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 3)
            .background(Capsule().fill(Theme.cardBackground))
    }
}

private struct HorizontalEdge: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            SSHPill()
        }
        .frame(width: 36, height: 16)
        .padding(.top, 14)
    }
}

private struct VerticalEdge: View {
    let height: CGFloat
    let labelled: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.hairline).frame(width: 1, height: height)
            if labelled { SSHPill() }
        }
        .frame(height: height)
        .accessibilityHidden(!labelled)
    }
}
