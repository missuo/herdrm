import AppKit
import HerdrKit
import SwiftUI

/// Meter fill colors: calm until a resource is nearly gone.
private func levelColor(_ percent: Double) -> Color {
    if percent >= 90 { return Theme.danger }
    if percent >= 75 { return Theme.warning }
    return Theme.textSecondary
}

// MARK: - Sidebar indicator

/// Whether the sidebar shows the meters (View ▸ Show Machine Stats). Off also
/// stops the sampler, since the sampler only runs while the meters are on screen.
enum MachineStatsDefaults {
    static let showKey = "sidebar.showMachineStats"
}

/// CPU / RAM / DISK meters for the selected pane's host, in the sidebar footer
/// just above the device switcher. Clicking opens `MachineStatsPanel`. Runs the
/// sampler while it is on screen and the window is visible.
struct SidebarMachineStats: View {
    @ObservedObject var stats: MachineStatsModel
    let device: Device
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovered = false
    @State private var windowVisible = true

    private struct WatchKey: Hashable {
        let device: Device
        let visible: Bool
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                SidebarMeter(label: "CPU", percent: snapshot?.cpuPercent)
                SidebarMeter(label: "RAM", percent: snapshot.map { $0.memFraction * 100 })
                SidebarMeter(label: "DISK", percent: snapshot?.fullestDisk.map { $0.fraction * 100 })
                if case .failed(let message) = stats.state, snapshot == nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.warning)
                        .help(message)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered || isOpen ? AnyShapeStyle(Theme.itemWash) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(String(localized: "\(device.name) health — click for details"))
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("sidebar.machineStats")
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .task(id: WatchKey(device: device, visible: windowVisible)) {
            guard windowVisible else { return }
            await stats.run(device: device)
        }
    }

    private var snapshot: MachineSnapshot? {
        stats.deviceID == device.id ? stats.snapshot : nil
    }

    private var accessibilityText: String {
        guard let snapshot else { return String(localized: "\(device.name) health") }
        let cpu = snapshot.cpuPercent.map(MachineStatsFormat.percent) ?? "—"
        let ram = MachineStatsFormat.percent(snapshot.memFraction * 100)
        let disk = snapshot.fullestDisk.map { MachineStatsFormat.percent($0.fraction * 100) } ?? "—"
        return String(localized: "\(device.name): CPU \(cpu), memory \(ram), disk \(disk)")
    }
}

/// One compact meter column: `CPU … 34%` over a level-tinted bar that fills its
/// share of the row. Equal-width columns so the block adapts to the sidebar width.
private struct SidebarMeter: View {
    let label: String
    let percent: Double?

    var body: some View {
        let value = percent.map { min(100, max(0, $0)) }
        let tint = value.map(levelColor) ?? Theme.textGhost
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.2)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 2)
                Text(value.map(MachineStatsFormat.percent) ?? "—")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(value.map { $0 >= 75 ? tint : Theme.textSecondary } ?? Theme.textGhost)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textGhost.opacity(0.22))
                    Capsule()
                        .fill(tint)
                        .frame(width: max((value ?? 0) > 0 ? 3 : 0, proxy.size.width * (value ?? 0) / 100))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.35), value: value ?? -1)
    }
}

/// Reports whether the hosting window is on screen, so the sampler stops while
/// the window is minimized, hidden, or fully covered.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.report()
            }
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            onChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - Dropdown panel

/// In-window panel above the meters (NSPopover crashes in ViewBridge on
/// macOS 26+): machine totals, then CPU/RAM by herdr, agent, MCP server, and the rest.
struct MachineStatsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stats: MachineStatsModel
    let device: Device
    @Binding var isPresented: Bool
    @State private var collapsedGroups: Set<String> = []
    @State private var otherExpanded = false

    /// Instances listed per agent kind before "+N more".
    private let instanceLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 6)
            if let snapshot {
                resources(snapshot)
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 6)
                processes(snapshot)
                Text("CPU counts one full core as 100, as in top. RAM is resident memory.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textGhost)
                    .padding(.horizontal, 9)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            } else {
                placeholder
            }
        }
        .padding(5)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .task(id: agentPaneSignature) {
            await stats.resolvePanes(
                service: model.service(for: device),
                deviceID: device.id,
                paneIDs: agents.map(\.paneID)
            )
        }
    }

    private var snapshot: MachineSnapshot? {
        stats.deviceID == device.id ? stats.snapshot : nil
    }

    private var agents: [AgentInfo] { model.session(device.id).agents }

    private var agentPaneSignature: String {
        device.id.uuidString + agents.map(\.paneID).joined(separator: ",")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 14)
                .foregroundStyle(Theme.deviceTint(device))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(headerDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
    }

    private var headerDetail: String {
        guard let snapshot else { return device.subtitle }
        var parts: [String] = []
        if !snapshot.host.isEmpty { parts.append(snapshot.host) }
        parts.append(String(localized: "\(snapshot.cpuCount) cores"))
        if let uptime = snapshot.uptime {
            parts.append(String(localized: "up \(MachineStatsFormat.uptime(uptime))"))
        }
        if !snapshot.load.isEmpty {
            let load = snapshot.load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " ")
            parts.append(String(localized: "load \(load)"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var placeholder: some View {
        HStack(spacing: 8) {
            if case .failed(let message) = stats.state {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
                Text("Reading \(device.name)…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    // MARK: Resources

    private func resources(_ snapshot: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ResourceBar(
                title: "CPU",
                value: snapshot.cpuPercent.map(MachineStatsFormat.percent) ?? "—",
                percent: snapshot.cpuPercent ?? 0,
                history: stats.cpuHistory
            )
            ResourceBar(
                title: "RAM",
                value: String(localized: "\(MachineStatsFormat.bytes(snapshot.memUsedBytes)) of \(MachineStatsFormat.bytes(snapshot.memTotalBytes))"),
                percent: snapshot.memFraction * 100
            )
            if snapshot.swapTotalBytes > 0, snapshot.swapUsedBytes > 0 {
                ResourceBar(
                    title: String(localized: "Swap"),
                    value: String(localized: "\(MachineStatsFormat.bytes(snapshot.swapUsedBytes)) of \(MachineStatsFormat.bytes(snapshot.swapTotalBytes))"),
                    percent: Double(snapshot.swapUsedBytes) / Double(snapshot.swapTotalBytes) * 100,
                    compact: true
                )
            }
            ForEach(snapshot.disks) { disk in
                ResourceBar(
                    title: snapshot.disks.count > 1
                        ? String(localized: "Disk \(disk.mount)")
                        : String(localized: "Disk"),
                    value: String(localized: "\(MachineStatsFormat.bytes(disk.usedBytes)) of \(MachineStatsFormat.bytes(disk.totalBytes))"),
                    percent: disk.fraction * 100
                )
            }
        }
        .padding(.horizontal, 9)
    }

    // MARK: Processes

    private func processes(_ snapshot: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text("PROCESSES")
                    .font(.system(size: 10.5, weight: .medium))
                    .kerning(0.3)
                Spacer(minLength: 0)
                Text("CPU").frame(width: UsageColumns.cpu, alignment: .trailing)
                Text("RAM").frame(width: UsageColumns.ram, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 9)
            .frame(height: 22)

            ForEach(snapshot.groups) { group in
                groupRows(group)
            }
            if snapshot.groups.allSatisfy({ if case .agent = $0.kind { return false }; return true }) {
                Text("No agents running")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textGhost)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
            }
            mcpRows(snapshot)
            otherRows(snapshot)
        }
    }

    /// MCP servers apart from the agents that start them: one row per server,
    /// with services (one copy for every client) apart from per-session copies.
    @ViewBuilder
    private func mcpRows(_ snapshot: MachineSnapshot) -> some View {
        if !snapshot.mcpServers.isEmpty {
            let expanded = !collapsedGroups.contains("mcp")
            UsageRow(
                icon: .symbol("puzzlepiece.extension"),
                title: String(localized: "MCP servers"),
                count: snapshot.mcpServers.reduce(0) { $0 + $1.instances },
                usage: snapshot.mcpUsage,
                expanded: expanded
            ) {
                if expanded { collapsedGroups.insert("mcp") } else { collapsedGroups.remove("mcp") }
            }
            if expanded {
                ForEach(snapshot.mcpServers) { server in
                    UsageRow(
                        icon: nil,
                        title: server.isService ? String(localized: "\(server.name) · service") : server.name,
                        count: server.instances > 1 ? server.instances : nil,
                        usage: server.usage,
                        indent: true
                    )
                    .help(server.isService
                        ? String(localized: "Runs on its own; one copy serves every client")
                        : String(localized: "Started by agent sessions; one copy per session"))
                }
            }
        }
    }

    @ViewBuilder
    private func groupRows(_ group: ProcessGroup) -> some View {
        switch group.kind {
        case .herdr:
            UsageRow(
                icon: .symbol("square.split.2x2"),
                title: "herdr",
                count: group.usage.processCount,
                countIsProcesses: true,
                usage: group.usage
            )
        case .agent(let kind):
            let expanded = !collapsedGroups.contains(group.id)
            UsageRow(
                icon: BrandIconLoader.agentIcon(for: kind).map(UsageRow.Icon.brand) ?? .symbol("sparkle"),
                title: AgentKindDisplay.name(kind),
                count: group.instances.count,
                usage: group.usage,
                expanded: expanded
            ) {
                if expanded { collapsedGroups.insert(group.id) } else { collapsedGroups.remove(group.id) }
            }
            if expanded {
                ForEach(group.instances.prefix(instanceLimit)) { instance in
                    instanceRow(instance)
                }
                if group.instances.count > instanceLimit {
                    Text("+\(group.instances.count - instanceLimit) more")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textGhost)
                        .padding(.leading, 36)
                        .frame(height: 20)
                }
            }
        case .other:
            EmptyView()
        }
    }

    private func instanceRow(_ instance: AgentInstance) -> some View {
        let paneID = stats.paneID(for: instance)
        let agent = paneID.flatMap { id in agents.first { $0.paneID == id } }
        let title = agent.map { model.agentEntry(device: device, agent: $0).title }
            ?? String(localized: "Outside herdr · pid \(String(instance.rootPID))")
        let isSelected = paneID != nil && model.selectedPane == PaneRef(deviceID: device.id, paneID: paneID!)
        return UsageRow(
            icon: nil,
            title: title,
            count: instance.usage.processCount > 1 ? instance.usage.processCount : nil,
            countIsProcesses: true,
            usage: instance.usage,
            indent: true,
            selected: isSelected,
            action: paneID.map { id in
                {
                    isPresented = false
                    model.selectAgent(PaneRef(deviceID: device.id, paneID: id))
                }
            }
        )
        .help(agent == nil
            ? String(localized: "Not running in a herdr pane on this device")
            : String(localized: "Show this agent"))
    }

    @ViewBuilder
    private func otherRows(_ snapshot: MachineSnapshot) -> some View {
        UsageRow(
            icon: .symbol("ellipsis.circle"),
            title: String(localized: "Everything else"),
            count: snapshot.other.processCount,
            countIsProcesses: true,
            usage: snapshot.other,
            expanded: otherExpanded
        ) {
            otherExpanded.toggle()
        }
        if otherExpanded {
            ForEach(snapshot.topOther) { usage in
                UsageRow(
                    icon: nil,
                    title: usage.name,
                    count: usage.processCount > 1 ? usage.processCount : nil,
                    usage: usage,
                    indent: true
                )
            }
        }
    }
}

enum AgentKindDisplay {
    static func name(_ kind: String) -> String {
        switch kind {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        case "cursor-agent": return "Cursor"
        case "copilot": return "Copilot"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
}

private enum UsageColumns {
    static let cpu: CGFloat = 50
    static let ram: CGFloat = 64
}

/// Label, value, and a level-tinted bar; CPU also draws its recent history.
private struct ResourceBar: View {
    let title: String
    let value: String
    let percent: Double
    var history: [Double] = []
    var compact = false

    var body: some View {
        let clamped = min(100, max(0, percent))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: compact ? 11 : 11.5, weight: .medium))
                    .foregroundStyle(compact ? Theme.textTertiary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(clamped >= 75 ? levelColor(clamped) : Theme.textTertiary)
                    .lineLimit(1)
            }
            if history.count > 1 {
                Sparkline(values: history)
                    .stroke(levelColor(clamped).opacity(0.85), lineWidth: 1.2)
                    .background(Sparkline(values: history, closed: true).fill(levelColor(clamped).opacity(0.12)))
                    .frame(height: 22)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.itemWash)
                    Capsule()
                        .fill(levelColor(clamped))
                        .frame(width: max(clamped > 0 ? 3 : 0, proxy.size.width * clamped / 100))
                }
            }
            .frame(height: compact ? 3 : 4)
        }
        .animation(.easeOut(duration: 0.35), value: clamped)
    }
}

/// CPU history, 0–100 bottom to top, newest on the right.
private struct Sparkline: Shape {
    let values: [Double]
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(MachineStatsModel.historyLength - 1)
        let start = rect.maxX - step * CGFloat(values.count - 1)
        func point(_ index: Int) -> CGPoint {
            let value = min(100, max(0, values[index]))
            return CGPoint(x: start + step * CGFloat(index), y: rect.maxY - rect.height * CGFloat(value / 100))
        }
        path.move(to: point(0))
        for index in values.indices.dropFirst() { path.addLine(to: point(index)) }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: start, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// One process-table row: icon, title, count, CPU, RAM; optionally a
/// disclosure toggle or a click action.
private struct UsageRow: View {
    enum Icon {
        case brand(String)
        case symbol(String)
    }

    let icon: Icon?
    let title: String
    var count: Int?
    var countIsProcesses = false
    let usage: ProcessUsage
    var indent = false
    var selected = false
    var expanded: Bool?
    var action: (() -> Void)?

    init(
        icon: Icon?,
        title: String,
        count: Int? = nil,
        countIsProcesses: Bool = false,
        usage: ProcessUsage,
        indent: Bool = false,
        selected: Bool = false,
        expanded: Bool? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.count = count
        self.countIsProcesses = countIsProcesses
        self.usage = usage
        self.indent = indent
        self.selected = selected
        self.expanded = expanded
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(SidebarRowButtonStyle(selected: selected))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
                )
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            if let expanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textGhost)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
            } else {
                Spacer().frame(width: indent ? 26 : 10)
            }
            if let icon {
                Group {
                    switch icon {
                    case .brand(let resource): BrandIcon(resource: resource, size: 12)
                    case .symbol(let name): Image(systemName: name).font(.system(size: 11))
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 14)
            }
            Text(title)
                .font(.system(size: indent ? 11.5 : 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(indent && !selected ? Theme.textSecondary : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let count {
                Text(countIsProcesses ? String(localized: "\(count) proc") : "×\(count)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textGhost)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            Text(MachineStatsFormat.percent(usage.cpuPercent))
                .foregroundStyle(usage.cpuPercent >= 90 ? levelColor(usage.cpuPercent) : Theme.textSecondary)
                .frame(width: UsageColumns.cpu, alignment: .trailing)
            Text(MachineStatsFormat.bytes(usage.rssBytes))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: UsageColumns.ram, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 9)
        .frame(height: indent ? 22 : 26)
        .contentShape(Rectangle())
    }
}
