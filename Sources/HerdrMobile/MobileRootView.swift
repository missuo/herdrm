import HerdrKit
import SwiftUI

/// iPhone: a navigation stack (lists → terminal). iPad: a split view whose
/// sidebar mirrors the Mac app — Spaces, Agents, and a device switcher footer.
struct MobileRootView: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        NavigationSplitView {
            SidebarListView(model: model)
        } detail: {
            if let device = model.selectedDevice, device.isTailcat,
               model.selectedAgentPaneID != nil {
                // tailcat carries herdr's control plane only — no shell, no
                // PTY channel — so there is no terminal byte stream to attach
                // to on iOS. Prompting stays available from the agent's row.
                ContentUnavailableView(
                    String(localized: "No Terminal over Tailcat"),
                    systemImage: "terminal",
                    description: Text(String(localized: "This device's tunnel reaches herdr's control plane only. Use an SSH device to attach to a live terminal."))
                )
            } else if let agent = model.selectedAgent,
               let transport = model.selectedSession?.transport {
                MobileTerminalScreen(
                    transport: transport,
                    target: .agent(paneID: agent.paneID),
                    paneID: agent.paneID,
                    title: agent.title(tabLabel: model.tabLabel(for: agent))
                )
                .id(agent.paneID)
            } else if let pane = model.selectedTerminalPane,
                      let terminalID = pane.terminalID,
                      let transport = model.selectedSession?.transport {
                MobileTerminalScreen(
                    transport: transport,
                    target: .terminal(terminalID: terminalID),
                    paneID: pane.paneID,
                    title: model.terminalLabel(for: pane)
                )
                .id(pane.paneID)
            } else {
                ContentUnavailableView(
                    String(localized: "No Agent Selected"),
                    systemImage: "terminal",
                    description: Text(String(localized: "Pick an agent to attach to its terminal."))
                )
            }
        }
        .sheet(isPresented: $model.showAddDevice) {
            AddDeviceSheet(model: model)
        }
        .task {
            if model.selectedDeviceID != nil { model.connectSelected() }
        }
    }
}

private struct SidebarListView: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        List(selection: $model.selectedAgentPaneID) {
            if model.devices.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Devices"), systemImage: "desktopcomputer")
                } description: {
                    Text(String(localized: "Add a Mac running herdr to get started."))
                } actions: {
                    Button(String(localized: "Add Device")) { model.showAddDevice = true }
                        .buttonStyle(.borderedProminent)
                }
                .listRowSeparator(.hidden)
            } else {
                connectionSection
                spacesSection
                agentsSection
                terminalsSection
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("herdrm")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DeviceSwitcherMenu(model: model)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showAddDevice = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await model.selectedSession?.refresh()
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if model.selectedSession != nil {
            switch model.selectedConnectionState {
            case .idle, .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "Connecting…"))
                        .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Reconnect")) { model.connectSelected() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .listRowSeparator(.hidden)
            case .connected:
                EmptyView()
            }
        }
    }

    private var spacesSection: some View {
        Section(String(localized: "Spaces")) {
            Button {
                model.selectedSpaceID = nil
            } label: {
                SpaceRow(
                    label: String(localized: "All Spaces"),
                    systemImage: "square.grid.2x2",
                    count: model.spaces.count,
                    selected: model.selectedSpaceID == nil
                )
            }
            .buttonStyle(.plain)
            ForEach(model.spaces) { space in
                Button {
                    model.selectedSpaceID = space.workspaceID
                } label: {
                    SpaceRow(
                        label: space.label,
                        systemImage: "folder",
                        count: nil,
                        selected: model.selectedSpaceID == space.workspaceID
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var terminalsSection: some View {
        if !model.terminalPanes.isEmpty {
            Section(String(localized: "Terminals")) {
                ForEach(model.terminalPanes) { pane in
                    NavigationLink(value: pane.paneID) {
                        HStack(spacing: 10) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.terminalLabel(for: pane))
                                    .lineLimit(1)
                                Text(model.spaceName(for: pane.workspaceID))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var agentsSection: some View {
        Section(String(localized: "Agents")) {
            if model.agents.isEmpty {
                Text(String(localized: "No agents"))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            ForEach(model.agents) { agent in
                NavigationLink(value: agent.paneID) {
                    AgentRow(
                        agent: agent,
                        title: agent.title(tabLabel: model.tabLabel(for: agent)),
                        spaceName: model.spaceName(for: agent.workspaceID)
                    )
                }
            }
        }
    }
}

private struct SpaceRow: View {
    let label: String
    let systemImage: String
    let count: Int?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(label)
                .fontWeight(selected ? .semibold : .regular)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct AgentRow: View {
    let agent: AgentInfo
    let title: String
    let spaceName: String

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(status: agent.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(agent.agent)
                    Text("·")
                    Text(spaceName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if agent.status == .blocked {
                Text(String(localized: "needs input"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The Mac app's status marks, phone-sized: spinner while working, exclamation
/// when the agent waits on you, check when done, dot when idle.
private struct StatusGlyph: View {
    let status: AgentStatus

    var body: some View {
        switch status {
        case .working:
            ProgressView().controlSize(.small)
        case .blocked:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .idle, .unknown:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// Top-left device switcher: a compact chip naming the current device, with
/// the device list, add, and remove actions in its menu.
private struct DeviceSwitcherMenu: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        if let device = model.selectedDevice {
            Menu {
                ForEach(model.devices) { candidate in
                    Button {
                        model.selectDevice(candidate.id)
                    } label: {
                        if candidate.id == model.selectedDeviceID {
                            Label(candidate.name, systemImage: "checkmark")
                        } else {
                            Text(candidate.name)
                        }
                    }
                }
                Divider()
                Button(String(localized: "Add Device…")) { model.showAddDevice = true }
                if let selected = model.selectedDevice {
                    Button(String(localized: "Remove \(selected.name)"), role: .destructive) {
                        model.removeDevice(selected)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    ConnectionDot(state: model.selectedConnectionState)
                    Text(device.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ConnectionDot: View {
    let state: MobileConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }
}

struct AddDeviceSheet: View {
    @Bindable var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: MobileDevice.Kind = .ssh
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: MobileDevice.AuthMethod = .deviceKey
    @State private var password = ""
    @State private var tailcatToken = ""
    @State private var copiedKey = false

    private var canAdd: Bool {
        switch kind {
        case .ssh:
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
                && !username.trimmingCharacters(in: .whitespaces).isEmpty
                && (authMethod == .deviceKey || !password.isEmpty)
                && UInt16(port) != nil
        case .tailcat:
            return !tailcatToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Connection"), selection: $kind) {
                        Text(String(localized: "SSH")).tag(MobileDevice.Kind.ssh)
                        Text(String(localized: "Tailcat")).tag(MobileDevice.Kind.tailcat)
                    }
                }

                Section(String(localized: "Device")) {
                    TextField(String(localized: "Name (optional)"), text: $name)
                    if kind == .ssh {
                        TextField(String(localized: "Host or IP"), text: $host)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField(String(localized: "Port"), text: $port)
                            .keyboardType(.numberPad)
                    }
                }

                if kind == .tailcat {
                    Section {
                        SecureField(String(localized: "Token"), text: $tailcatToken)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text(String(localized: "Tailcat Token"))
                    } footer: {
                        Text(String(localized: "From the host: herdr plugin action invoke herdr.tailcat.token — the token is stored in this device's Keychain, and the tunnel needs no SSH."))
                    }
                } else {
                    sshSections
                }
            }
            .navigationTitle(String(localized: "Add Device"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add")) {
                        switch kind {
                        case .ssh:
                            model.addDevice(
                                name: name,
                                host: host,
                                port: UInt16(port) ?? 22,
                                username: username,
                                authMethod: authMethod,
                                password: password
                            )
                        case .tailcat:
                            model.addTailcatDevice(name: name, token: tailcatToken)
                        }
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }

    @ViewBuilder
    private var sshSections: some View {
        Section(String(localized: "SSH Login")) {
            TextField(String(localized: "Username"), text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Picker(String(localized: "Authentication"), selection: $authMethod) {
                Text(String(localized: "Device Key")).tag(MobileDevice.AuthMethod.deviceKey)
                Text(String(localized: "Password")).tag(MobileDevice.AuthMethod.password)
            }
            if authMethod == .password {
                SecureField(String(localized: "Password"), text: $password)
                    .textContentType(.password)
            }
        }
        if authMethod == .deviceKey {
            Section(String(localized: "This Phone's Key")) {
                Text(model.deviceKeyAuthorizedLine)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Button(copiedKey
                    ? String(localized: "Copied")
                    : String(localized: "Copy authorized_keys Line")
                ) {
                    UIPasteboard.general.string = model.deviceKeyAuthorizedLine
                    copiedKey = true
                }
                Text(String(localized: "On the Mac, run: echo '<key>' >> ~/.ssh/authorized_keys — or paste the line into herdrm's upcoming pairing screen."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                Text(String(localized: "The password is stored in this device's Keychain and never leaves it except to log in over SSH."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
