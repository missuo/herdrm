import AppKit
import HerdrKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var collapsed: Bool
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

    var body: some View {
        VStack(spacing: 0) {
            // 28pt titlebar strip: traffic lights on the left, collapse toggle on the right
            HStack {
                Spacer()
                TitlebarIconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘B)") {
                    collapsed = true
                }
            }
            .padding(.horizontal, 10)
            .frame(height: TitlebarMetrics.height)

            Spacer().frame(height: 8)

            VStack(spacing: 1) {
                actionRow(icon: "square.and.pencil", label: "New Agent") {
                    model.showNewAgent = true
                }
                // Terminals — herdr-owned or standalone — are listed under
                // TERMINALS below; the ⌘D split beside an agent is separate.
                actionRow(icon: "terminal", label: "New Terminal") {
                    model.showNewTerminal = true
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

            ScrollView {
                VStack(spacing: 1) {
                    // Title + chevron used to be a decorative HStack with no
                    // tap target, so the chevron promised a disclosure that
                    // never fired. Trailing New Space stays a sibling Button
                    // so it does not toggle the section.
                    groupHeader("Spaces", expanded: $spacesExpanded) {
                        Button {
                            model.showNewSpace = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textGhost)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New Space")
                        .focusEffectDisabled()
                    }
                    if spacesExpanded {
                        allSpacesRow
                        ForEach(model.visibleSpaces) { entry in
                            SpaceRowView(
                                entry: entry,
                                model: model,
                                draggingSpaceID: $draggingSpaceID,
                                spaceDrop: $spaceDrop
                            )
                        }
                    }

                    Spacer().frame(height: 10)

                    groupHeader("Agents", expanded: $agentsExpanded)
                    if agentsExpanded {
                        if model.visibleAgents.isEmpty {
                            Text(emptyAgentsHint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textGhost)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        ForEach(model.visibleAgents) { entry in
                            AgentRowView(
                                entry: entry,
                                model: model,
                                draggingAgentID: $draggingAgentID,
                                agentDrop: $agentDrop
                            )
                        }
                    }

                    if !model.visibleTerminals.isEmpty || !model.shellSessions.isEmpty {
                        Spacer().frame(height: 10)
                        groupHeader("Terminals", expanded: $terminalsExpanded)
                        if terminalsExpanded {
                            ForEach(model.visibleTerminals) { entry in
                                TerminalRowView(
                                    entry: entry,
                                    model: model,
                                    draggingTerminalID: $draggingTerminalID,
                                    terminalDrop: $terminalDrop
                                )
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
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)
            footer
        }
        .frame(width: 260)
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
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

    private func groupHeader(_ title: LocalizedStringKey, expanded: Binding<Bool>) -> some View {
        groupHeader(title, expanded: expanded) { EmptyView() }
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
                    .foregroundStyle(Theme.textGhost)
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
        @Binding var draggingTerminalID: String?
        @Binding var terminalDrop: (id: String, after: Bool)?
        @State private var hovered = false

        var body: some View {
            let selected = !model.isFileManagerActive
                && model.selectedPane == entry.ref
                && model.selectedShellID == nil
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
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
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.showsRowDeviceBadges {
                        DeviceChip(device: entry.device)
                    }
                }
            }
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
                    onClick: { model.selectAgent(entry.ref) },
                    onRename: { model.terminalToRename = entry },
                    onClose: { model.requestClosePane(entry.ref, name: entry.title) },
                    onDragStart: { draggingTerminalID = $0 },
                    onDragEnd: {
                        draggingTerminalID = nil
                        terminalDrop = nil
                    },
                    onDropHover: { after in
                        terminalDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.visibleTerminals
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
            .accessibilityLabel(entry.title)
        }
    }

    /// App-owned standalone shell (local login shell or plain ssh), outside
    /// any herdr space.
    private func shellRow(_ session: ShellSession) -> some View {
        let selected = !model.isFileManagerActive && model.selectedShellID == session.id
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

    private struct AgentRowView: View {
    let entry: AppModel.AgentEntry
    @ObservedObject var model: AppModel
    @Binding var draggingAgentID: String?
    @Binding var agentDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let agent = entry.agent
        let selected = !model.isFileManagerActive
            && model.selectedPane == entry.ref
            && model.selectedShellID == nil
        let unread = model.isUnread(entry)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                AgentStatusGlyph(status: agent.status, unreadDone: unread)
            }
            HStack(spacing: 5) {
                AgentKindBadge(kind: agent.agent)
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
        }
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
            isDragging: draggingAgentID == entry.id,
            dropAfter: agentDrop?.after,
            isTarget: agentDrop?.id == entry.id
        )
        .overlay {
            AgentRowDragHost(
                entryID: entry.id,
                onClick: { model.selectAgent(entry.ref) },
                onRename: { model.agentToRename = entry },
                onClose: { model.requestClosePane(entry.ref, name: entry.title) },
                onDragStart: { draggingAgentID = $0 },
                onDragEnd: {
                    draggingAgentID = nil
                    agentDrop = nil
                },
                    onDropHover: { after in
                        agentDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.visibleAgents
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
        .accessibilityLabel(accessibilityLabel(unread: unread))
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
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
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

/// Small icon button that sits in the 28pt titlebar strip.
struct TitlebarIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? AnyShapeStyle(Theme.itemWash) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(help)
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
    @Binding var draggingSpaceID: String?
    @Binding var spaceDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let selected = model.selectedSpace == entry.ref
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
                .foregroundStyle(Theme.textGhost)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
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
        .overlay {
            SpaceRowDragHost(
                entryID: entry.id,
                label: entry.workspace.label,
                onClick: { model.selectSpace(entry.ref) },
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
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
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
