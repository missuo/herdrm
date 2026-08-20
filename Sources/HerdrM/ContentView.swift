import HerdrKit
import SwiftUI

struct RootView: View {
    // Owned by AppDelegate so it outlives the window — see AppDelegate in HerdrMApp.swift.
    @ObservedObject var model: AppModel
    // Deliberately not persisted: the app always launches with the sidebar visible.
    @State private var sidebarCollapsed = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                SidebarView(model: model, collapsed: $sidebarCollapsed)
                    .frame(width: sidebarCollapsed ? 0 : 260, alignment: .trailing)
                    .clipped()
                Rectangle()
                    .fill(Theme.sidebarBorder)
                    .frame(width: sidebarCollapsed ? 0 : 1)
                    .ignoresSafeArea()
                DetailView(model: model, sidebarCollapsed: $sidebarCollapsed)
            }
            .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)

            // In-window device panel; NSPopover throws in ViewBridge on macOS 26+ betas.
            if model.showDevicePanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { model.showDevicePanel = false }
                DevicePopover(model: model, isPresented: $model.showDevicePanel)
                    .padding(.leading, 10)
                    .padding(.bottom, 46)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                    .background(
                        Button("") { model.showDevicePanel = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    )
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.showDevicePanel)
        .background(
            Button("") { sidebarCollapsed.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { model.showSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
        .focusedSceneValue(\.appModel, model)
        .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 620)
        .onAppear { model.start() }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet(model: model) }
        .sheet(isPresented: $model.showNewAgent) { NewAgentSheet(model: model) }
        .sheet(isPresented: $model.showNewSpace) { NewSpaceSheet(model: model) }
        .sheet(item: $model.spaceToRename) { entry in RenameSpaceSheet(model: model, entry: entry) }
        .sheet(item: $model.deviceToEdit) { device in EditDeviceSheet(model: model, device: device) }
        .sheet(item: $model.sshAuthenticationRequest) { request in
            SSHAuthenticationSheet(model: model, request: request)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .alert(
            model.closeRequest?.title ?? "",
            isPresented: Binding(
                get: { model.closeRequest != nil },
                set: { if !$0 { model.closeRequest = nil } }
            )
        ) {
            Button("Close", role: .destructive) {
                model.closeRequest?.perform()
                model.closeRequest = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.closeRequest?.message ?? "")
        }
    }
}

/// Titlebar metrics: 28pt matches the system traffic-light centerline (14pt) exactly.
enum TitlebarMetrics {
    static let height: CGFloat = 28
    static let trafficLightClearance: CGFloat = 78
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    @Binding var sidebarCollapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            titlebar
                .background(Theme.contentBackground)
                .zIndex(1)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            terminal
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground.ignoresSafeArea())
    }

    // MARK: - Titlebar strip (28pt, traditional)

    private var titlebar: some View {
        HStack(spacing: 8) {
            if sidebarCollapsed {
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - 10)
                TitlebarIconButton(systemName: "sidebar.left", help: "Show Sidebar (⌘B)") {
                    sidebarCollapsed = false
                }
            }
            if let entry = model.selectedEntry {
                let agent = entry.agent
                statusGlyph(agent.status)
                Text(agent.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help((agent.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                Spacer(minLength: 12)
                AgentKindBadge(kind: agent.agent)
                Text("·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textGhost)
                Text(model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                if model.showsDeviceBadges {
                    DeviceChip(device: entry.device)
                }
                statusPill(agent.status)
            } else {
                Text("No agent selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
        }
        .padding(.leading, sidebarCollapsed ? 10 : 14)
        .padding(.trailing, 12)
        .frame(height: TitlebarMetrics.height)
    }

    @ViewBuilder
    private func statusGlyph(_ status: AgentStatus) -> some View {
        switch status {
        case .working:
            SpinnerView(color: Theme.working).frame(width: 13, height: 13)
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.success)
        case .idle, .unknown:
            Circle().fill(Theme.textGhost).frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private func statusPill(_ status: AgentStatus) -> some View {
        let label: String? = {
            switch status {
            case .working: return "Working"
            case .blocked: return "Needs input"
            case .done: return "Done"
            case .idle, .unknown: return nil
            }
        }()
        if let label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.statusColor(status))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Theme.statusColor(status).opacity(0.13), in: Capsule())
        }
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage("terminal.mouseReporting") private var terminalMouseReporting = true
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private var terminal: some View {
        if let entry = model.selectedEntry {
            AttachTerminalView(
                device: entry.device,
                paneID: entry.agent.paneID,
                fontName: terminalFontName,
                fontSize: terminalFontSize,
                dark: colorScheme == .dark,
                mouseReporting: terminalMouseReporting
            )
                .id("attach-\(entry.id)-\(colorScheme)")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.terminalBackground)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textGhost)
                Text(placeholderText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                if showsStartAgentShortcut {
                    Button("New Agent…") {
                        model.showNewAgent = true
                    }
                    .controlSize(.small)
                } else if model.hasReconnectableDevice {
                    Button("Reconnect") {
                        model.reconnectFailedDevices()
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
        }
    }

    private var showsStartAgentShortcut: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    private var placeholderText: String {
        switch model.connection {
        case .connecting: return "Connecting…"
        case .failed(let reason): return reason
        default:
            if model.selectedSpace != nil && model.visibleAgents.isEmpty {
                return "No agents in this space yet"
            }
            return "Select an agent, or start a new one"
        }
    }

}

struct AddDeviceSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: "Add Device",
                subtitle: "Uses OpenSSH config, agent, Tailscale SSH, or password"
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("mac-studio", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("vincent@10.10.10.87", text: $target)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Device") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    model.addDevice(
                        name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                        sshTarget: trimmedTarget
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
    }
}

struct SSHAuthenticationSheet: View {
    @ObservedObject var model: AppModel
    let request: SSHAuthenticationRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "key.fill",
                title: "SSH Authentication",
                subtitle: request.target
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("PASSWORD")
                SecureField("SSH password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                Label(SSHCredentialStore.persistenceDescription, systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelSSHAuthentication(for: request)
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.saveSSHPassword(password, for: request)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { passwordFocused = true }
    }
}

/// Shared chrome for the app's sheets: icon-badge header, hairline sections, footer actions.
struct SheetHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct SheetSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
    }
}

struct NewSpaceSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = Device.local.id
    @State private var directory = "~"
    @State private var label = ""

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "folder.badge.plus",
                title: "New Space",
                subtitle: "A herdr workspace rooted at a project directory on \(chosenDevice.name)"
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                if model.showsDeviceBadges {
                    SheetSectionLabel("DEVICE")
                    Picker("", selection: $deviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Spacer().frame(height: 8)
                }

                SheetSectionLabel("DIRECTORY")
                HStack(spacing: 6) {
                    TextField("~/Projects/foo", text: $directory)
                        .textFieldStyle(.roundedBorder)
                    if chosenDevice.isLocal {
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                directory = (url.path as NSString).abbreviatingWithTildeInPath
                            }
                        }
                    }
                }
                if !chosenDevice.isLocal {
                    Text("Path on \(chosenDevice.name); ~ expands to its home directory")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer().frame(height: 8)

                SheetSectionLabel("NAME")
                TextField("Defaults to the folder name", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Space") {
                    model.createNewSpace(device: chosenDevice, directory: directory, label: label)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 440)
        .onAppear {
            deviceID = model.deviceFilter ?? model.devices.first?.id ?? Device.local.id
        }
    }
}

struct NewAgentSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = Device.local.id
    @State private var kind = "claude"
    @State private var workspaceID: String = ""
    @AppStorage("agent.bypassDefault") private var bypass = true

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    private var session: DeviceSessionState {
        model.session(deviceID)
    }

    /// Only agents actually installed on the chosen device; falls back to the full
    /// manifest list if sniffing failed.
    private var kinds: [String] {
        if !session.installedAgentKinds.isEmpty { return session.installedAgentKinds }
        return session.agentKinds.isEmpty ? ["claude", "codex", "gemini", "opencode", "grok"] : session.agentKinds
    }

    private var bypassFlags: [String]? {
        HerdrService.bypassFlags(for: kind)
    }

    private var spaceLabel: String {
        if workspaceID.isEmpty { return "the focused space" }
        return session.workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "sparkles",
                title: "New Agent",
                subtitle: "Starts in \(spaceLabel), attached to its live terminal"
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                if model.showsDeviceBadges {
                    SheetSectionLabel("DEVICE")
                    Picker("", selection: $deviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: deviceID) { _, _ in
                        workspaceID = ""
                        if !kinds.contains(kind) { kind = kinds.first ?? "claude" }
                    }

                    Spacer().frame(height: 8)
                }

                SheetSectionLabel("AGENT")
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                        spacing: 8
                    ) {
                        ForEach(kinds, id: \.self) { name in
                            kindCell(name)
                        }
                    }
                    .padding(1)
                }
                .frame(maxHeight: 236)

                Spacer().frame(height: 8)

                SheetSectionLabel("SPACE")
                Picker("", selection: $workspaceID) {
                    Text("Focused space").tag("")
                    ForEach(session.workspaces) { workspace in
                        Text(workspace.label).tag(workspace.workspaceID)
                    }
                }
                .labelsHidden()
                .fixedSize()

                // shown only for agents with a verified bypass flag
                if let flags = bypassFlags {
                    Spacer().frame(height: 8)

                    SheetSectionLabel("OPTIONS")
                    Toggle(isOn: $bypass) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bypass permissions")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text)
                            Text(flags.joined(separator: " "))
                                .font(.system(size: 10.5).monospaced())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Agent") {
                    model.startNewAgent(
                        device: chosenDevice,
                        kind: kind,
                        workspaceID: workspaceID.isEmpty ? nil : workspaceID,
                        bypass: bypass && bypassFlags != nil
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .onAppear {
            deviceID = model.selectedSpace?.deviceID
                ?? model.deviceFilter
                ?? model.devices.first?.id
                ?? Device.local.id
            workspaceID = model.selectedSpace?.deviceID == deviceID
                ? (model.selectedSpace?.workspaceID ?? "")
                : ""
            if !kinds.contains(kind) { kind = kinds.first ?? "claude" }
        }
    }

    private func kindCell(_ name: String) -> some View {
        let selected = kind == name
        return Button {
            kind = name
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let resource = BrandIconLoader.agentIcon(for: name) {
                        BrandIcon(resource: resource, size: 20)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 16))
                    }
                }
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Text(name)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? AnyShapeStyle(Theme.accentWash) : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

struct RenameSpaceSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.SpaceEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: "Rename Space",
                subtitle: "Rename \(entry.workspace.label) on \(entry.device.name)"
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Space name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.renameSpace(entry, label: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == entry.workspace.label)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { name = entry.workspace.label }
    }
}

struct EditDeviceSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: "Edit Device",
                subtitle: "Changing the SSH target reconnects the device"
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("SSH target", text: $target)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    model.updateDevice(
                        device.id,
                        name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                        sshTarget: trimmedTarget
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear {
            name = device.name
            target = device.sshTarget ?? ""
        }
    }
}
