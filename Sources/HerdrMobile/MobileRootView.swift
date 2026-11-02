import HerdrKit
import SwiftUI

/// Mirrors the Mac app's information architecture: a Server (device), its
/// Spaces, then a Space's Agents (the primary thing) and Terminals (side
/// helpers). Three columns on iPad; on iPhone the same columns collapse into a
/// push stack (servers and spaces → agents and terminals → agent).
struct MobileRootView: View {
    @Bindable var model: MobileAppModel
    /// The sidebar's selection; drives the middle column (and the push on iPhone).
    @State private var spaceRoute: SpaceRoute?

    var body: some View {
        NavigationSplitView {
            SidebarListView(model: model, spaceRoute: $spaceRoute)
        } content: {
            if spaceRoute != nil {
                SpaceContentList(model: model)
            } else {
                ContentUnavailableView(
                    String(localized: "No Space Selected"),
                    systemImage: "folder",
                    description: Text(String(localized: "Pick a space to see its agents and terminals."))
                )
            }
        } detail: {
            detail
        }
        .onChange(of: spaceRoute) { _, route in
            switch route {
            case .space(let id): model.selectedSpaceID = id
            case .all, nil: model.selectedSpaceID = nil
            }
            model.selectedAgentPaneID = nil
        }
        .onChange(of: model.selectedDeviceID) { _, _ in spaceRoute = nil }
        .sheet(isPresented: $model.showAddDevice) {
            AddDeviceSheet(model: model)
        }
        .task {
            if model.selectedDeviceID != nil { model.connectSelected() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let agent = model.selectedAgent,
           let transport = model.selectedSession?.transport {
            // The chat answers choices and sends prompts over herdr RPCs, so it
            // works over tailcat too; only the Terminal tab needs SSH.
            MobileAgentDetailView(
                transport: transport,
                agent: agent,
                title: agent.title(tabLabel: model.tabLabel(for: agent)),
                terminalAvailable: model.selectedDevice?.isTailcat != true
            )
            .id(agent.paneID)
        } else if let device = model.selectedDevice, device.isTailcat,
                  model.selectedTerminalPane != nil {
            // tailcat carries herdr's control plane only — no shell, no PTY
            // channel — so there is no terminal byte stream to attach to on iOS.
            ContentUnavailableView(
                String(localized: "No Terminal over Tailcat"),
                systemImage: "terminal",
                description: Text(String(localized: "This device's tunnel reaches herdr's control plane only. Use an SSH device to attach to a live terminal."))
            )
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
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text(String(localized: "Pick an agent to chat with it, or a terminal to attach to it."))
            )
        }
    }
}

/// Which spaces the middle column lists: all of the server's, or one.
enum SpaceRoute: Hashable {
    case all
    case space(String)
}

/// Top level: the servers, then the selected server's spaces.
private struct SidebarListView: View {
    @Bindable var model: MobileAppModel
    @Binding var spaceRoute: SpaceRoute?

    var body: some View {
        List(selection: $spaceRoute) {
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
                serversSection
                connectionSection
                spacesSection
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Herdrm")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showAddDevice = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "Add Device"))
            }
        }
        .refreshable {
            await model.selectedSession?.refresh()
        }
    }

    private var serversSection: some View {
        Section(String(localized: "Servers")) {
            ForEach(model.devices) { device in
                let selected = device.id == model.selectedDeviceID
                Button {
                    model.selectDevice(device.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                        Text(device.name)
                            .fontWeight(selected ? .semibold : .regular)
                            .lineLimit(1)
                        Spacer()
                        if selected {
                            ConnectionDot(state: model.selectedConnectionState)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(device.name)
                .accessibilityValue(selected ? String(localized: "Selected") : "")
                .accessibilityHint(String(localized: "Shows this server's spaces."))
                .contextMenu {
                    Button(String(localized: "Remove \(device.name)"), role: .destructive) {
                        model.removeDevice(device)
                    }
                }
            }
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
            NavigationLink(value: SpaceRoute.all) {
                SpaceRow(
                    label: String(localized: "All Spaces"),
                    systemImage: "square.grid.2x2",
                    count: model.spaces.count,
                    selected: spaceRoute == .all
                )
            }
            ForEach(model.spaces) { space in
                NavigationLink(value: SpaceRoute.space(space.workspaceID)) {
                    SpaceRow(
                        label: space.label,
                        systemImage: "folder",
                        count: nil,
                        selected: spaceRoute == .space(space.workspaceID)
                    )
                }
            }
        }
    }
}

/// A space's agents first (where the work happens), then its terminals.
private struct SpaceContentList: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        List(selection: $model.selectedAgentPaneID) {
            agentsSection
            terminalsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.selectedSpaceID.map(model.spaceName(for:)) ?? String(localized: "All Spaces"))
        .refreshable {
            await model.selectedSession?.refresh()
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
    @State private var kind: MobileDevice.Kind = .relay
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: MobileDevice.AuthMethod = .deviceKey
    @State private var password = ""
    @State private var tailcatToken = ""
    @State private var copiedKey = false
    @State private var copiedClientKey = false
    @State private var confirmRegenerateClientKey = false

    private var canAdd: Bool {
        switch kind {
        case .ssh:
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
                && !username.trimmingCharacters(in: .whitespaces).isEmpty
                && (authMethod == .deviceKey || !password.isEmpty)
                && UInt16(port) != nil
        case .tailcat:
            return !tailcatToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .relay:
            return false // pairing adds the device itself
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Connection"), selection: $kind) {
                        Text(String(localized: "Pair with Mac")).tag(MobileDevice.Kind.relay)
                        Text(String(localized: "SSH")).tag(MobileDevice.Kind.ssh)
                        Text(String(localized: "Tailcat")).tag(MobileDevice.Kind.tailcat)
                    }
                }

                if kind == .relay {
                    RelayPairingSections(model: model, onPaired: { dismiss() })
                } else {
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
                    tailcatClientKeySection
                } else {
                    sshSections
                }
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
                        case .relay:
                            break
                        }
                        dismiss()
                    }
                    .disabled(!canAdd)
                    .opacity(kind == .relay ? 0 : 1)
                }
            }
        }
    }

    /// The app-wide tailcat client key a host's allow list must name.
    private var tailcatClientKeySection: some View {
        Section {
            if let publicKey = model.tailcatClientPublicKey {
                Text(publicKey)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Button(copiedClientKey
                    ? String(localized: "Copied")
                    : String(localized: "Copy Client Key")
                ) {
                    UIPasteboard.general.string = publicKey
                    copiedClientKey = true
                }
            }
            if let error = model.tailcatClientKeyError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button(String(localized: "Regenerate Key"), role: .destructive) {
                confirmRegenerateClientKey = true
            }
            .confirmationDialog(
                String(localized: "Regenerate the client key?"),
                isPresented: $confirmRegenerateClientKey,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Regenerate Key"), role: .destructive) {
                    model.regenerateTailcatClientKey()
                    copiedClientKey = false
                }
            } message: {
                Text(String(localized: "Every host's allow.list must be updated with the new key, and all tailcat devices will reconnect."))
            }
        } header: {
            Text(String(localized: "Client Key"))
        } footer: {
            Text(String(localized: "If the host uses an allow list, add this key to allow.list in the folder from herdr plugin config-dir herdr.tailcat (one key per line), then run: herdr plugin action invoke herdr.tailcat.restart. All tailcat devices on this phone share this key."))
        }
        .onAppear { model.loadTailcatClientPublicKey() }
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
                Text(String(localized: "On the Mac, run: echo '<key>' >> ~/.ssh/authorized_keys — or paste the line into Herdrm's upcoming pairing screen."))
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
