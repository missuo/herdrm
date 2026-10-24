import AppKit
import HerdrKit
import SwiftUI
import StickySectionHeaders

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // Drawn without blending, the sidebar material is the system's opaque
        // sidebar color (the one Finder shows in a background window). Blending
        // let a white window behind HerdrM lift the dark sidebar from gray ~42
        // to ~81, where the section text and header buttons wash out.
        view.state = .inactive
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var collapsed: Bool
    var width: CGFloat = SidebarWidth.defaultWidth
    /// Usage readings behind the footer's USAGE column. Its own model — the
    /// sheet's per-presentation instance is gone by dismiss — so the column
    /// keeps the states it read, and the store's cache keeps re-reads cheap.
    @StateObject private var usageHint = UsageModel()
    @State private var deviceButtonHovered = false
    @State private var draggingSpaceID: String?
    @State private var spaceDrop: (id: String, after: Bool)?
    @State private var draggingAgentID: String?
    @State private var agentDrop: (id: String, after: Bool)?
    @State private var draggingTerminalID: String?
    @State private var terminalDrop: (id: String, after: Bool)?
    @State private var spacesExpanded = true
    @State private var agentsExpanded = true
    @State private var terminalsExpanded = true
    @AppStorage(MachineStatsDefaults.showKey) private var showsMachineStats = true
    /// Grouped mode: the Spaces section lists each space's panes as a tree.
    /// Turning it on collapses Agents and Terminals (they stay available),
    /// turning it off expands them again.
    @AppStorage(SidebarDefaults.groupBySpaceKey) private var groupBySpace = false

    var body: some View {
        VStack(spacing: 0) {
            // 28pt titlebar strip: traffic lights on the left, collapse toggle on the right
            HStack(spacing: 2) {
                Spacer()
                TitlebarIconButton(
                    systemName: "list.bullet.indent",
                    help: groupBySpace ? "Ungroup Sidebar" : "Group Sidebar by Space",
                    active: groupBySpace
                ) {
                    groupBySpace.toggle()
                }
                .accessibilityIdentifier("sidebar.groupBySpace")
                TitlebarIconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘B)") {
                    collapsed = true
                }
            }
            .padding(.horizontal, 10)
            .frame(height: TitlebarMetrics.height)
            .windowTitlebarInteraction()
            .onAppear { applyGrouping(groupBySpace, animated: false) }
            .onChange(of: groupBySpace) { _, grouped in applyGrouping(grouped, animated: true) }

            Spacer().frame(height: 8)

            VStack(spacing: 1) {
                actionRow(icon: "square.and.pencil", label: "New Agent") {
                    model.showNewAgent = true
                }
                // Terminals — herdr-owned or standalone — are listed under
                // TERMINALS below; the local-shell split (⌃⇧D) beside an agent is separate.
                actionRow(icon: "terminal", label: "New Terminal") {
                    model.showNewTerminal = true
                }
                // Also reachable from the folder.badge.plus by the Spaces
                // header; promoted here alongside the other New … actions (#84).
                actionRow(icon: "folder.badge.plus", label: "New Space") {
                    model.showNewSpace = true
                }
                actionRow(icon: "folder", label: "Files") {
                    model.openFileManager()
                }
                actionRow(icon: "magnifyingglass", label: "Search") {
                    model.showSearch = true
                }
            }
            .padding(.horizontal, 10)

            Spacer().frame(height: 10)

            // Section headers pin at the top and hand off with a scroll-linked
            // fade (StickySectionHeaders). Each section = header + rows + gap.
            ScrollView {
                VStack(spacing: 1) {
                    StickySection(background: { VisualEffectView(material: .sidebar) }) {
                        // Title + chevron used to be a decorative HStack with no
                        // tap target, so the chevron promised a disclosure that
                        // never fired. Trailing New Space stays a sibling Button
                        // so it does not toggle the section.
                        groupHeader("Spaces", expanded: $spacesExpanded) {
                            SidebarHeaderButton(systemName: "folder.badge.plus", title: "New Space") {
                                model.showNewSpace = true
                            }
                        }
                        .accessibilityIdentifier("sidebar.section.spaces")
                    } content: {
                        if spacesExpanded {
                            allSpacesRow
                            ForEach(model.visibleSpaces) { entry in
                                SpaceRowView(
                                    entry: entry,
                                    model: model,
                                    grouped: groupBySpace,
                                    draggingSpaceID: $draggingSpaceID,
                                    spaceDrop: $spaceDrop
                                )
                                if groupBySpace, model.isSpaceExpanded(entry) {
                                    ForEach(model.spaceTreeRows(entry)) { row in
                                        treeRow(row)
                                    }
                                }
                            }
                        }
                        Spacer().frame(height: 10)
                    }

                    StickySection(background: { VisualEffectView(material: .sidebar) }) {
                        groupHeader("Agents", expanded: $agentsExpanded) {
                            SidebarHeaderButton(systemName: "square.and.pencil", title: "New Agent") {
                                model.showNewAgent = true
                            }
                        }
                        .accessibilityIdentifier("sidebar.section.agents")
                    } content: {
                        if agentsExpanded {
                            if model.visibleAgents.isEmpty {
                                Text(emptyAgentsHint)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textGhost)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            // Either kind: a shell split off an agent lists here, under it.
                            ForEach(model.agentSectionRows) { row in
                                sectionRow(row)
                            }
                        }
                        if terminalsSectionVisible {
                            Spacer().frame(height: 10)
                        }
                    }

                    if terminalsSectionVisible {
                        StickySection(background: { VisualEffectView(material: .sidebar) }) {
                            groupHeader("Terminals", expanded: $terminalsExpanded) {
                                SidebarHeaderButton(systemName: "terminal", title: "New Terminal") {
                                    model.showNewTerminal = true
                                }
                            }
                            .accessibilityIdentifier("sidebar.section.terminals")
                        } content: {
                            if terminalsExpanded {
                                ForEach(model.terminalSectionRows) { row in
                                    sectionRow(row)
                                }
                                ForEach(model.shellSessions) { session in
                                    shellRow(session)
                                        .contextMenu {
                                            Button("Close Terminal", role: .destructive) {
                                                model.closeShellSession(session.id)
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .stickySectionHeaders()
            }
            .clipped()

            Spacer(minLength: 0)
            if showsMachineStats, let device = model.statsDevice {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                SidebarUsageStats(meters: usageMeters, onOpenSheet: openUsage)
                    .padding(.horizontal, 6)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                SidebarMachineStats(
                    stats: model.machineStats,
                    device: device,
                    isOpen: model.showMachineStats
                ) {
                    model.showMachineStats.toggle()
                }
                .padding(.horizontal, 6)
                .frame(height: SidebarFooterMetrics.statsHeight)
                // Round one's refresh discipline (the `600ce7d` lesson):
                // anchored to the stats block — a real view that renders
                // whenever a pane is selected — never to a conditional row.
                .task(id: model.devices.map(\.id)) {
                    await Self.refreshUsageReads(
                        states: usageHint.states, devices: model.devices
                    ) { device, force in
                        await usageHint.refresh(device, force: force)
                    }
                }
            }
            footer
        }
        // The details panel opens from the meters; with them gone it has no anchor.
        .onChange(of: showsMachineStats) { _, shown in
            if !shown { model.showMachineStats = false }
        }
        .frame(width: width)
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
    }

    /// The usage row's meters: one per picked agent (picked in the Usage
    /// sheet, `usage.sidebarAgents`). Window-bearing agents get a line per
    /// open window — the ~5h session and the longer limit — percent used
    /// and time until reset; Claude's limit respects the watched model.
    /// Tokens-only agents get a compact total.
    private var usageMeters: [UsageMeterValue] {
        let now = Date()
        return model.sidebarAgentProviders.map { provider in
            func line(_ found: (device: Device, window: GrazrWindow)?) -> UsageWindowValue? {
                guard let found else { return nil }
                return UsageWindowValue(
                    label: Self.windowLabel(found.window),
                    percentUsed: 100 - Double(found.window.left(now: now)),
                    untilReset: Self.untilReset(found.window.resetsAt, now: now)
                )
            }
            let session = line(UsageSelection.tightestSession(
                states: usageHint.states, devices: model.devices, provider: provider, now: now))
            let limit = line(UsageSelection.tightestLimit(
                states: usageHint.states, devices: model.devices, provider: provider, scope: nil, now: now))
            let windows = [session, limit].compactMap { $0 }
            return UsageMeterValue(
                provider: provider,
                windows: windows,
                tokenTotal: windows.isEmpty
                    ? Self.tokenTotal(provider, states: usageHint.states)
                    : nil
            )
        }
    }

    /// A window line's label: the ~5h session, the week, or the window's
    /// own span (30D) when an agent reports something else.
    static func windowLabel(_ window: GrazrWindow) -> String {
        switch window.group {
        case "session": return "5H"
        case "weekly": return "7D"
        default: return window.group.uppercased()
        }
    }

    /// `45m`, `2h51m`, `1d2h` — how long until the window refills; nil
    /// when the reading carries no reset time.
    static func untilReset(_ resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let minutes = Int((max(0, resetsAt.timeIntervalSince(now)) / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h\(minutes % 60)m" }
        return "\(hours / 24)d\(hours % 24)h"
    }

    /// The picked agents' compact token total across devices — the meter
    /// value for agents that report no quota windows. Sourced from the
    /// quota readings (OpenCode's `opencode stats` totals ride along with
    /// them), so the row needs no history fetch of its own.
    static func tokenTotal(
        _ provider: UsageProvider,
        states: [UUID: [UsageProvider: UsageProviderState]]
    ) -> String? {
        var total = 0
        for perProvider in states.values {
            guard case .readings(let readings) = perProvider[provider] else { continue }
            for reading in readings {
                guard let tokens = reading.tokens else { continue }
                total += tokens.input + tokens.output + tokens.reasoning + tokens.cacheRead + tokens.cacheWrite
            }
        }
        guard total > 0 else { return nil }
        return UsageFormat.compact(total)
    }

    /// The usage row's tap: the Usage sheet, on the watched window's
    /// device — the local device (else the first) while nothing is open.
    private func openUsage() {
        let window = UsageSelection.tightestWindow(
            states: usageHint.states,
            devices: model.devices,
            scope: nil,
            now: Date()
        )
        model.usageDevice = window?.device
            ?? model.devices.first(where: \.isLocal)
            ?? model.devices.first
        model.usageOpens += 1
    }

    /// First read for devices with no states yet, and — when the stats
    /// block's `.task` refires on a device-set change — a retry for
    /// devices where any provider stands `.failed` or `.unknown`. Plain
    /// non-forced refreshes: the store's five-minute cache and
    /// single-flight fold bound the cost.
    static func refreshUsageReads(
        states: [UUID: [UsageProvider: UsageProviderState]],
        devices: [Device],
        refresh: (Device, Bool) async -> Void
    ) async {
        for device in devices where needsUsageRead(states[device.id]) {
            await refresh(device, false)
        }
    }

    /// Whether `device`'s states call for a read: never read, any provider
    /// standing `.failed` or `.unknown`, or every watched window past its
    /// reset — a fully-reset reading is stale by definition (the gauges
    /// show it refilled; the numbers behind it are gone). Plain
    /// non-forced refreshes; the store's five-minute cache bounds the cost.
    static func needsUsageRead(_ states: [UsageProvider: UsageProviderState]?) -> Bool {
        guard let states else { return true }
        if states.contains { _, state in
            switch state {
            case .failed, .unknown: return true
            default: return false
            }
        } { return true }
        let now = Date()
        let windows = states.values.flatMap { state -> [GrazrWindow] in
            guard case .readings(let readings) = state else { return [] }
            return readings.flatMap(\.windows)
        }
        return !windows.isEmpty && windows.allSatisfy { !$0.isOpen(now: now) }
    }

    private var terminalsSectionVisible: Bool {
        !model.terminalSectionRows.isEmpty || !model.shellSessions.isEmpty
    }

    private func applyGrouping(_ grouped: Bool, animated: Bool) {
        model.groupSidebarBySpace = grouped
        // Collapse the Agents/Terminals sections while grouping is on so their
        // panes aren't listed a second time under the spaces. This must run on
        // first appear too (agentsExpanded/terminalsExpanded are @State and reset
        // to true each launch): otherwise relaunching with grouping on shows
        // every pane twice until the toggle is flipped.
        let apply = {
            agentsExpanded = !grouped
            terminalsExpanded = !grouped
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { apply() }
        } else {
            apply()
        }
    }

    /// A pane row in the Agents or Terminals section: an agent or terminal row
    /// at its depth in the pane tree. Top-level rows drag (they stand for tabs).
    @ViewBuilder
    private func sectionRow(_ row: AppModel.SidebarRow) -> some View {
        paneRow(row, showsSpace: true, draggable: row.indent == 0)
    }

    /// A pane row inside a space's tree: the same rows, without the space line
    /// (the space is the parent) and without drag (tab order is edited in the
    /// sections).
    @ViewBuilder
    private func treeRow(_ row: AppModel.SidebarRow) -> some View {
        paneRow(row, showsSpace: false, draggable: false)
    }

    @ViewBuilder
    private func paneRow(_ row: AppModel.SidebarRow, showsSpace: Bool, draggable: Bool) -> some View {
        switch row.entry {
        case .agent(let entry):
            AgentRowView(
                entry: entry,
                model: model,
                indent: row.indent,
                showsPaneGlyph: row.isChild,
                showsSpace: showsSpace,
                draggable: draggable,
                draggingAgentID: $draggingAgentID,
                agentDrop: $agentDrop
            )
        case .terminal(let entry):
            TerminalRowView(
                entry: entry,
                model: model,
                indent: row.indent,
                showsPaneGlyph: row.isChild,
                showsSpace: showsSpace,
                draggable: draggable,
                draggingTerminalID: $draggingTerminalID,
                terminalDrop: $terminalDrop
            )
        }
    }

    private var emptyAgentsHint: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        default: return String(localized: "No agents")
        }
    }

    // MARK: - Rows

    private func actionRow(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        // CSS `outline: none` is not a SwiftUI concept. This is the native
        // equivalent for chrome (New Agent / New Terminal / Search). List
        // rows keep their focus ring for keyboard access.
        .focusEffectDisabled()
    }

    private func groupHeader<Trailing: View>(
        _ title: LocalizedStringKey,
        expanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .disclosureAccessibility(expanded: expanded.wrappedValue)

            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var allSpacesRow: some View {
        let selected = model.selectedSpace == nil
        return Button {
            model.selectSpace(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                Text("All Spaces")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer()
                SpaceAttentionGlyph(attention: model.scopeAttention)
                Text("\(model.scopeAgentCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary) // the name's color
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    private struct TerminalRowView: View {
        let entry: AppModel.TerminalEntry
        @ObservedObject var model: AppModel
        /// Depth in the pane tree; each level indents the content, not the wash.
        var indent = 0
        /// Secondary pane of its tab.
        var showsPaneGlyph = false
        /// Off inside a space's tree, where the space is the parent row.
        var showsSpace = true
        var draggable = true
        @Binding var draggingTerminalID: String?
        @Binding var terminalDrop: (id: String, after: Bool)?
        @State private var hovered = false

        var body: some View {
            let selected = !model.isDetailCovered
                && model.selectedPane == entry.ref
                && model.selectedShellID == nil
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if showsPaneGlyph { PaneChildGlyph() }
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Text(entry.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    if showsSpace {
                        Image(systemName: "folder")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.textTertiary)
                        Text(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.showsRowDeviceBadges {
                        DeviceChip(device: entry.device)
                    }
                }
            }
            .padding(.leading, SidebarDefaults.indentWidth * CGFloat(indent))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(height: 51)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
            .onHover { hovered = $0 }
            .sidebarDragChrome(
                isDragging: draggingTerminalID == entry.id,
                dropAfter: terminalDrop?.after,
                isTarget: terminalDrop?.id == entry.id
            )
            .overlay {
                TerminalRowDragHost(
                    entryID: entry.id,
                    allowsDrag: draggable,
                    onClick: { model.selectAgent(entry.ref) },
                    onRename: { model.terminalToRename = entry },
                    onOpenProject: { model.openProject(for: .terminal(entry)) },
                    onClose: { model.requestClosePane(entry.ref, name: entry.title) },
                    onDragStart: { draggingTerminalID = $0 },
                    onDragEnd: {
                        draggingTerminalID = nil
                        terminalDrop = nil
                    },
                    onDropHover: { after in
                        // Top-level rows stand for tabs; "after" one means before
                        // the next top-level row, skipping that tab's children.
                        terminalDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.draggableTerminals
                        )
                    },
                    onHoverExit: {
                        if terminalDrop?.id == entry.id { terminalDrop = nil }
                    },
                    onDrop: { sourceID, after in
                        draggingTerminalID = nil
                        terminalDrop = nil
                        guard let source = model.visibleTerminals.first(where: { $0.id == sourceID })
                        else { return }
                        model.moveTerminal(source, onto: entry, placeAfter: after)
                    }
                )
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectAgent(entry.ref) }
            .accessibilityLabel(entry.title)
        }
    }

    /// App-owned standalone shell (local login shell or plain ssh), outside
    /// any herdr space.
    private func shellRow(_ session: ShellSession) -> some View {
        let selected = !model.isDetailCovered && model.selectedShellID == session.id
        return Button {
            model.selectShell(session.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text(session.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(session.device.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    /// Colours for the plugin stats lines under an agent row.
    private enum AgentStatsStyle {
        static func color(for kind: AgentStatsLine.Kind) -> Color {
            switch kind {
            case .account: return Theme.statsAccount
            case .model: return Theme.textSecondary
            case .context, .usage: return Theme.textTertiary
            }
        }
    }

    private struct AgentRowView: View {
    let entry: AppModel.AgentEntry
    @ObservedObject var model: AppModel
    /// Depth in the pane tree; each level indents the content, not the wash.
    var indent = 0
    /// Secondary pane of its tab.
    var showsPaneGlyph = false
    /// Off inside a space's tree, where the space is the parent row.
    var showsSpace = true
    var draggable = true
    @Binding var draggingAgentID: String?
    @Binding var agentDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let agent = entry.agent
        let statsLines = agent.statsLines
        let supportsHistory = ["claude", "claude-code"].contains(agent.agent.lowercased())
        let selected = !model.isDetailCovered
            && model.selectedPane == entry.ref
            && model.selectedShellID == nil
        let unread = model.isUnread(entry)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if showsPaneGlyph { PaneChildGlyph() }
                Text(entry.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                AgentStatusGlyph(status: agent.status, unreadDone: unread)
            }
            HStack(spacing: 5) {
                AgentKindBadge(kind: agent.agent)
                if showsSpace {
                    Text("·")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textGhost)
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if agent.status == .blocked {
                    Text("needs input")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                }
                if model.showsRowDeviceBadges {
                    DeviceChip(device: entry.device)
                }
            }
            .padding(.trailing, supportsHistory && statsLines.isEmpty ? 24 : 0)
            // Plugin stats (grazr account, Claude model / context / usage),
            // one line each, only for the tokens the pane actually carries.
            ForEach(statsLines, id: \.kind) { line in
                HStack(spacing: 3) {
                    // An agent on an account of its own, not the shared rotation.
                    if line.isPinnedAccount {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                            .help("Pinned to this account; grazr's rotation leaves it alone")
                    }
                    Text(line.displayText)
                        .font(.system(size: 11, weight: line.kind == .model ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(AgentStatsStyle.color(for: line.kind))
                .padding(.trailing, supportsHistory && line.kind == statsLines.last?.kind ? 24 : 0)
            }
        }
        .padding(.leading, SidebarDefaults.indentWidth * CGFloat(indent))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 51)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
        .sidebarDragChrome(
            isDragging: draggingAgentID == entry.id,
            dropAfter: agentDrop?.after,
            isTarget: agentDrop?.id == entry.id
        )
        .overlay {
            AgentRowDragHost(
                entryID: entry.id,
                paneID: entry.agent.paneID,
                isClaude: entry.agent.agent == "claude",
                pluginActions: model.session(entry.device.id).pluginActions,
                grazrReport: model.session(entry.device.id).grazrReport,
                allowsDrag: draggable,
                onClick: { model.selectAgent(entry.ref) },
                onRename: { model.agentToRename = entry },
                onOpenProject: { model.openProject(for: .agent(entry)) },
                onPluginAction: { model.runPluginAction($0, for: entry) },
                onGrazrAccounts: { model.grazrAccountsDevice = entry.device },
                onSwitchGrazrAccount: { model.switchGrazrAccount($0, on: entry.device) },
                onReauthenticateGrazrAccount: {
                    model.reauthenticateGrazrAccount($0, on: entry.device, workspaceID: entry.agent.workspaceID)
                },
                onPinGrazrAccount: {
                    model.pinGrazrAccount(
                        $0, paneID: entry.agent.paneID, on: entry.device, workspaceID: entry.agent.workspaceID
                    )
                },
                onMenuOpen: { Task { await model.loadPluginActions(deviceID: entry.device.id) } },
                onClose: { model.requestClosePane(entry.ref, name: entry.title) },
                onDragStart: { draggingAgentID = $0 },
                onDragEnd: {
                    draggingAgentID = nil
                    agentDrop = nil
                },
                    onDropHover: { after in
                        // Top-level rows stand for tabs; "after" one means before
                        // the next top-level row, skipping that tab's children.
                        agentDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.draggableAgents
                        )
                    },
                onHoverExit: {
                    if agentDrop?.id == entry.id { agentDrop = nil }
                },
                onDrop: { sourceID, after in
                    draggingAgentID = nil
                    agentDrop = nil
                    guard let source = model.visibleAgents.first(where: { $0.id == sourceID })
                    else { return }
                    model.moveAgent(source, onto: entry, placeAfter: after)
                }
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectAgent(entry.ref) }
        .accessibilityLabel(accessibilityLabel(unread: unread))
        // The drag host covers the row. Place this control above it so a
        // footer click opens this agent's history instead of selecting alone.
        .overlay(alignment: .bottomTrailing) {
            if supportsHistory {
                Button { model.toggleConversationHistory(for: entry.ref) } label: {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11.5))
                        .frame(width: 20, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Read full conversation (⇧⌘H)")
                .accessibilityLabel("Read full conversation")
                .accessibilityIdentifier("sidebar.agent.history.\(entry.id)")
                .padding(.trailing, 8)
                .padding(.bottom, 7)
            }
        }
    }

    private func accessibilityLabel(unread: Bool) -> String {
        var parts = [entry.title]
        switch entry.agent.status {
        case .working: parts.append(String(localized: "Working"))
        case .blocked: parts.append(String(localized: "Needs input"))
        case .done where unread: parts.append(String(localized: "Unread"))
        case .done: break
        case .idle, .unknown: break
        }
        if let account = entry.agent.statsLines.first(where: { $0.kind == .account }) {
            parts.append(account.isPinnedAccount
                ? String(localized: "pinned to \(account.displayText)")
                : account.text)
        }
        return parts.joined(separator: ", ")
    }
}

    // MARK: - Footer (device filter)

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                model.showDevicePanel.toggle()
            } label: {
                HStack(spacing: 6) {
                    if let device = model.filteredDevice {
                        DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 10)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(model.filteredDevice?.name ?? "All Devices")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 6, height: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(deviceButtonHovered || model.showDevicePanel
                          ? AnyShapeStyle(Theme.itemWashSelected)
                          : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.hairline, lineWidth: deviceButtonHovered ? 1 : 0)
            )
            .scaleEffect(deviceButtonHovered ? 1.04 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: deviceButtonHovered)
            .onHover { deviceButtonHovered = $0 }

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text("Settings"))
        }
        .padding(.horizontal, 10)
        .frame(height: SidebarFooterMetrics.deviceSwitcherHeight)
    }

    private var connectionDotColor: Color {
        switch model.connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }
}

/// The small "new" button at the right end of a section header; same icon as
/// the matching New … action row above the list. `title` is the tooltip and
/// what VoiceOver reads (an icon alone is read by its symbol name).
enum SidebarDefaults {
    /// Group the Spaces section as space > tab main pane > children.
    static let groupBySpaceKey = "sidebar.groupBySpace"
    /// Leading inset per level of the pane tree.
    static let indentWidth: CGFloat = 14
}

/// Marks a row as a secondary pane of its tab, split off the pane above it.
struct PaneChildGlyph: View {
    var body: some View {
        Image(systemName: "rectangle.split.2x1")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityLabel("Split pane")
    }
}

struct SidebarHeaderButton: View {
    let systemName: String
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The section title's color: ghost gray was under 2.2:1 on the sidebar.
            Image(systemName: systemName)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .focusEffectDisabled()
    }
}

/// Small icon button that sits in the 28pt titlebar strip.
struct TitlebarIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    /// A toggle that is on: accent glyph on a wash, so the state reads at a glance.
    var active = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(active ? Theme.accent : Theme.textTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered || active ? AnyShapeStyle(Theme.itemWash) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(help)
        // Without it VoiceOver reads the symbol's own name ("Gear Shape").
        .accessibilityLabel(Text(help))
    }
}

/// Custom device switcher popover, matching the DeviceSwitcher design artboard:
/// two-line device rows with OS icon, status dot, and a check on the current device.
struct DevicePopover: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("DEVICES")
                .font(.system(size: 10.5, weight: .medium))
                .kerning(0.3)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 9)
                .frame(height: 24, alignment: .leading)

            // aggregate view across every connected device
            Button {
                isPresented = false
                model.setDeviceFilter(nil)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13))
                        .foregroundStyle(model.deviceFilter == nil ? Theme.text : Theme.textSecondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All Devices")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Text(String(localized: "\(model.devices.count) devices · \(connectedCount) connected"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if model.deviceFilter == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.text)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowButtonStyle(selected: model.deviceFilter == nil))

            ForEach(model.devices) { device in
                DevicePopoverRow(
                    device: device,
                    isActive: device.id == model.deviceFilter,
                    connection: model.session(device.id).connection
                ) {
                    isPresented = false
                    model.setDeviceFilter(device.id)
                }
                .contextMenu {
                    if !device.isLocal {
                        Button(String(localized: "Edit \(device.name)…")) {
                            isPresented = false
                            model.deviceToEdit = device
                        }
                        Button(String(localized: "Remove \(device.name)"), role: .destructive) {
                            isPresented = false
                            model.removeDevice(device)
                        }
                    }
                }
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)

            actionRow(icon: "plus", label: "Add Device…") {
                isPresented = false
                model.showAddDevice = true
            }
        }
        .padding(5)
        .frame(width: 252)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var connectedCount: Int {
        model.devices.filter {
            if case .connected = model.session($0.id).connection { return true }
            return false
        }.count
    }

    private func actionRow(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
    }
}

struct DevicePopoverRow: View {
    let device: Device
    let isActive: Bool
    let connection: ConnectionState
    let action: () -> Void
    @State private var hovered = false

    private var dotColor: Color {
        switch connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 13)
                    .foregroundStyle(isActive ? Theme.text : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(device.localizedSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered || isActive ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
    }
}

/// `after A` and `before B` are the same gap. Always draw that gap on B's
/// top edge so the line does not jump when the pointer crosses the seam.
private func sidebarDropTarget<T: Identifiable>(
    onto id: T.ID, after: Bool, items: [T]
) -> (id: T.ID, after: Bool) {
    guard after,
          let index = items.firstIndex(where: { $0.id == id }),
          items.indices.contains(index + 1)
    else { return (id, after) }
    return (items[index + 1].id, false)
}

private extension View {
    func sidebarDragChrome(isDragging: Bool, dropAfter: Bool?, isTarget: Bool) -> some View {
        opacity(isDragging ? 0.4 : 1)
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .overlay(alignment: (dropAfter ?? false) ? .bottom : .top) {
                if isTarget {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 2)
                        .transaction { $0.animation = nil }
                }
            }
    }

    /// Button trait plus expanded/collapsed so VoiceOver matches the chevron.
    /// macOS SwiftUI has no `accessibilityExpanded`; VoiceOver reads the value.
    func disclosureAccessibility(expanded: Bool) -> some View {
        self
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || configuration.isPressed ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
    }
}

/// Not a `Button`: on macOS, `Button` consumes mouseDown so SwiftUI `.onDrag`
/// never starts. Click and reorder go through `SpaceRowDragHost`.
private struct SpaceRowView: View {
    let entry: AppModel.SpaceEntry
    @ObservedObject var model: AppModel
    /// Grouped mode: the row heads a tree of its panes and gets a disclosure.
    var grouped = false
    @Binding var draggingSpaceID: String?
    @Binding var spaceDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let selected = model.selectedSpace == entry.ref
        let expanded = model.isSpaceExpanded(entry)
        HStack(spacing: 0) {
            if grouped {
                // Beside the drag host, not under it: the host's AppKit view takes
                // every click inside its frame, so a chevron covered by it selected
                // the space instead of folding it.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.toggleSpaceExpanded(entry) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                        .padding(.leading, 8)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? String(localized: "Collapse space") : String(localized: "Expand space"))
            }
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                Text(entry.workspace.label)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                SpaceAttentionGlyph(attention: model.attention(in: entry))
                if model.showsRowDeviceBadges {
                    DeviceChip(device: entry.device)
                }
                Text("\(model.agentCount(in: entry))")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary) // the name's color (readable, #140)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                SpaceRowDragHost(
                    entryID: entry.id,
                    label: entry.workspace.label,
                    onClick: { model.selectSpace(entry.ref) },
                    onNewAgent: { model.showNewAgent(in: entry.ref) },
                    onNewTerminal: { model.showNewTerminal(in: entry.ref) },
                    onOpenProject: { model.openProject(entry.ref) },
                    onRename: { model.spaceToRename = entry },
                    onClose: { model.requestCloseSpace(entry) },
                    onDragStart: { draggingSpaceID = $0 },
                    onDragEnd: {
                        draggingSpaceID = nil
                        spaceDrop = nil
                    },
                    onDropHover: { after in
                        spaceDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.visibleSpaces
                        )
                    },
                    onHoverExit: {
                        if spaceDrop?.id == entry.id { spaceDrop = nil }
                    },
                    onDrop: { sourceID, after in
                        draggingSpaceID = nil
                        spaceDrop = nil
                        guard let source = model.visibleSpaces.first(where: { $0.id == sourceID })
                        else { return }
                        model.moveSpace(source, onto: entry, placeAfter: after)
                    }
                )
            }
            // On the content only, so the chevron keeps its own name for VoiceOver.
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectSpace(entry.ref) }
            .accessibilityLabel(accessibilityLabel)
        }
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
        .sidebarDragChrome(
            isDragging: draggingSpaceID == entry.id,
            dropAfter: spaceDrop?.after,
            isTarget: spaceDrop?.id == entry.id
        )
    }

    private var accessibilityLabel: String {
        var parts = [entry.workspace.label]
        switch model.attention(in: entry) {
        case .blocked: parts.append(String(localized: "Needs input"))
        case .unreadDone: parts.append(String(localized: "Unread"))
        case .working: parts.append(String(localized: "Working"))
        case .none: break
        }
        return parts.joined(separator: ", ")
    }
}

struct SpinnerView: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Usage meters row

/// One window line in a usage meter: its own label (5H, 7D, 30D), the
/// percent used, and how long until it refills.
struct UsageWindowValue: Equatable {
    let label: String
    let percentUsed: Double
    let untilReset: String?
}

/// One meter's data in the sidebar's usage row: up to two open windows —
/// the ~5h session and the longer limit (week, 30d) — or, for agents that
/// report no windows, a compact token total. Neither dims to a dash.
struct UsageMeterValue: Identifiable, Equatable {
    let provider: UsageProvider
    var windows: [UsageWindowValue] = []
    var tokenTotal: String?
    var id: UsageProvider { provider }

    /// The header percent: the most-used of the agent's windows.
    var tightestPercentUsed: Double? {
        windows.map(\.percentUsed).max()
    }
}

/// The usage row above the machine-stats row, in its visual language: one
/// meter column per picked agent. Window-bearing agents fill a
/// level-tinted bar with the percent used; tokens-only agents show a
/// compact total over a dimmed track. The whole row opens the Usage sheet.
struct SidebarUsageStats: View {
    let meters: [UsageMeterValue]
    let onOpenSheet: () -> Void

    /// The picked set's whole algebra: the comma list the sheet's picker
    /// and `AppModel.sidebarAgents` share, toggling one agent in or out.
    static func toggling(_ provider: UsageProvider, in raw: String) -> String {
        var picked = raw.split(separator: ",").map(String.init)
        if let index = picked.firstIndex(of: provider.rawValue) {
            picked.remove(at: index)
        } else {
            picked.append(provider.rawValue)
        }
        // Keep the canonical order so the list reads stably.
        let ordered = UsageProvider.allCases.map(\.rawValue)
        picked.sort { lhs, rhs in
            let l = ordered.firstIndex(of: lhs) ?? ordered.count
            let r = ordered.firstIndex(of: rhs) ?? ordered.count
            return l < r
        }
        return picked.joined(separator: ",")
    }

    var body: some View {
        Button(action: onOpenSheet) {
            // Top-aligned so every column's icon + value headline sits on
            // one line; shorter columns just leave space below.
            HStack(alignment: .top, spacing: 12) {
                ForEach(meters) { meter in
                    UsageMeter(
                        provider: meter.provider,
                        windows: meter.windows,
                        tokenTotal: meter.tokenTotal
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(String(localized: "Usage across your devices — click for details"))
        .accessibilityLabel(summary)
    }

    private var summary: String {
        let parts = meters.map { meter in
            let windows = meter.windows
                .map { "\($0.label) \(Int($0.percentUsed.rounded()))%\(($0.untilReset.map { " · \($0)" }) ?? "")" }
                .joined(separator: " · ")
            let value = windows.isEmpty ? (meter.tokenTotal ?? "—") : windows
            return "\(Self.name(meter.provider)) \(value)"
        }
        return String(localized: "Usage: \(parts.joined(separator: " · "))")
    }

    static func name(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude: return String(localized: "Claude").uppercased()
        case .codex: return String(localized: "Codex").uppercased()
        case .opencode: return String(localized: "OpenCode").uppercased()
        case .gemini: return String(localized: "Gemini").uppercased()
        }
    }
}

/// One meter column: the agent's brand icon over a line per open window —
/// label, percent used, time until reset — each above its level-tinted
/// bar. Tokens-only agents show the compact total over a single dimmed
/// track. Icons, not names: three-plus meters leave no room for words
/// ("OPENCODE" wrapped mid-name at this width).
private struct UsageMeter: View {
    let provider: UsageProvider
    let windows: [UsageWindowValue]
    let tokenTotal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let resource = BrandIconLoader.agentIcon(for: provider.rawValue) {
                    BrandIcon(resource: resource, size: 11, fallbackSystemName: fallback)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Image(systemName: fallback)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 2)
                Text(verbatim: header)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(headerTint)
                    .lineLimit(1)
            }
            if windows.isEmpty {
                track(percent: nil)
            } else {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text(verbatim: window.label)
                                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                            Text(verbatim: line(window))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(Self.levelColor(window.percentUsed) == Theme.textSecondary ? Theme.textSecondary : Self.levelColor(window.percentUsed))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        track(percent: window.percentUsed)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.35), value: windows)
    }

    /// The header value: the tightest window's percent, the token total,
    /// or a dimmed dash.
    private var header: String {
        windows.map(\.percentUsed).max().map { Self.percent($0) } ?? tokenTotal ?? "—"
    }

    private var headerTint: Color {
        windows.map(\.percentUsed).max().map(Self.levelColor) ?? Theme.textGhost
    }

    private func line(_ window: UsageWindowValue) -> String {
        let percent = Self.percent(window.percentUsed)
        return window.untilReset.map { "\(percent) · \($0)" } ?? percent
    }

    private func track(percent: Double?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textGhost.opacity(0.22))
                Capsule()
                    .fill(percent.map(Self.levelColor) ?? Theme.textGhost)
                    .frame(width: max((percent ?? 0) > 0 ? 3 : 0, proxy.size.width * (percent ?? 0) / 100))
            }
        }
        .frame(height: 4)
    }

    private static func percent(_ value: Double) -> String {
        MachineStatsFormat.percent(value)
    }

    /// The machine row's own rule, percent used: calm until the window is
    /// nearly spent.
    private static func levelColor(_ percent: Double) -> Color {
        if percent >= 90 { return Theme.danger }
        if percent >= 75 { return Theme.warning }
        return Theme.textSecondary
    }

    /// An SF fallback when no brand icon is bundled for the agent.
    private var fallback: String {
        switch provider {
        case .claude: return "sparkles"
        case .codex: return "infinity"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "wand.and.stars"
        }
    }
}
