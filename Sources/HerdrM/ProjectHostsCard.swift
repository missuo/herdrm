import AppKit
import HerdrKit
import SwiftUI

// The "Hosts & VMs" card of the Project pane: host health with load and memory meters, the VMs
// matched to the project, linked hosts and a menu to attach other VMs.

/// Meter fill colors: calm until a resource is nearly gone (same thresholds as the sidebar stats).
private enum ProjectMeterColor {
    static func level(_ percent: Double) -> Color {
        if percent >= 90 { return Theme.danger }
        if percent >= 75 { return Theme.warning }
        return Theme.textSecondary
    }
}

/// A thin capsule gauge; the value is always spoken by the text next to it.
struct MiniMeter: View {
    let fraction: Double
    var width: CGFloat = 60

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(Theme.itemWash)
            .frame(width: width, height: ProjectMetrics.meterHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(ProjectMeterColor.level(fraction * 100))
                    .frame(width: max(3, width * clamped))
            }
            .accessibilityHidden(true)
    }
}

struct HostHealthRow: View {
    let host: HostHealth

    private var loadText: String? {
        guard let load = host.load1 else { return nil }
        let value = load.formatted(.number.precision(.fractionLength(2)))
        return host.cpuCount.map { "\(value) / \($0)" } ?? value
    }

    private var loadFraction: Double? {
        guard let load = host.load1, let cpus = host.cpuCount, cpus > 0 else { return nil }
        return load / Double(cpus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ProjectKindTile(kind: .host)
                Text(verbatim: host.hostname ?? "—")
                    .font(.system(size: ProjectMetrics.textSize, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let docker = host.dockerServerVersion { metric("Docker", docker) }
                if host.hotLanes.total > 0 { metric("Hot lanes", "\(host.hotLanes.up)/\(host.hotLanes.total)") }
                if host.dockerLanes.total > 0 { metric("Docker lanes", "\(host.dockerLanes.up)/\(host.dockerLanes.total)") }
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                if let loadText {
                    HStack(spacing: 6) {
                        metric("Load", loadText)
                        if let loadFraction { MiniMeter(fraction: loadFraction) }
                    }
                    .accessibilityIdentifier("project.host.meter.load")
                    .accessibilityElement(children: .contain)
                }
                if let mem = host.memUsedFraction {
                    HStack(spacing: 6) {
                        metric("Memory", mem.formatted(.percent.precision(.fractionLength(0))))
                        MiniMeter(fraction: mem)
                    }
                    .accessibilityIdentifier("project.host.meter.memory")
                    .accessibilityElement(children: .contain)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, ProjectMetrics.tileSize + 10)
        }
        .frame(minHeight: ProjectMetrics.twoLineRowHeight)
        .contextMenu {
            if let hostname = host.hostname {
                Button("Copy hostname") { copyToPasteboard(hostname) }
            }
        }
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            Text(verbatim: value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
        }
    }
}

private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

extension VMRow {
    /// Localized provider name shown as a tag.
    var providerName: LocalizedStringKey {
        switch provider {
        case .parallels: "Parallels"
        case .vmpal: "VMPal"
        case .lima: "Lima"
        }
    }
}

struct VMRowView: View {
    let vm: VMRow
    var onAttach: (() -> Void)?
    var onDetach: (() -> Void)?

    private var matchBadge: LocalizedStringKey? {
        switch vm.match {
        case .attached: "attached"
        case .declared: "declared"
        case .suggested: "suggested"
        case nil: nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProjectKindTile(kind: .vm)
            StatusDot(color: vm.state.lowercased() == "running" ? Theme.success : Theme.textTertiary)
            Text(verbatim: vm.name)
                .font(.system(size: ProjectMetrics.textSize))
                .foregroundStyle(Theme.text)
            ProjectTag(vm.providerName)
            Text(verbatim: vm.state)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            if let ip = vm.ip {
                Text(verbatim: ip).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
            if let matchBadge { ProjectTag(matchBadge, tint: Theme.accent) }
            Spacer(minLength: 8)
            if let onAttach { Button("Attach", action: onAttach).controlSize(.small) }
            if let onDetach { Button("Detach", action: onDetach).controlSize(.small) }
        }
        .frame(minHeight: ProjectMetrics.rowHeight)
        .contextMenu {
            if let ip = vm.ip { Button("Copy IP") { copyToPasteboard(ip) } }
        }
    }
}

/// A host linked to the project, with the way back.
struct LinkedHostRow: View {
    let device: Device
    let root: String
    let onUnlink: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProjectKindTile(kind: .host)
            DeviceChip(device: device)
            Text(verbatim: root)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ProjectTag("linked", tint: Theme.accent)
            Spacer(minLength: 8)
            Button("Unlink", action: onUnlink).controlSize(.small)
        }
        .frame(minHeight: ProjectMetrics.rowHeight)
    }
}

struct ProjectHostsCard: View {
    let snapshot: ProjectSnapshot
    let linked: [(device: Device, root: String)]
    let onAttachVM: (VMRow) -> Void
    let onDetachVM: (String) -> Void
    let onUnlink: (UUID) -> Void

    var body: some View {
        ProjectCard("Hosts & VMs", count: snapshot.vms.count, id: .hosts) {
            HostHealthRow(host: snapshot.host)
            ProjectCardList(snapshot.vms) { vm in
                VMRowView(
                    vm: vm,
                    onAttach: vm.match == .suggested ? { onAttachVM(vm) } : nil,
                    onDetach: vm.match == .attached ? { onDetachVM(vm.id) } : nil)
            }
            ForEach(linked, id: \.device.id) { link in
                LinkedHostRow(device: link.device, root: link.root) { onUnlink(link.device.id) }
            }
            if !snapshot.otherVMs.isEmpty {
                Menu("Attach VM…") {
                    ForEach(snapshot.otherVMs) { vm in
                        Button("\(vm.name) (\(vm.provider.rawValue))") { onAttachVM(vm) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(minHeight: ProjectMetrics.rowHeight)
            }
        }
    }
}
