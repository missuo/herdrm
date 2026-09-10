import Foundation
import HerdrKit
import SwiftUI

/// Connection state for one device, mirroring the Mac app's session states.
enum MobileConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

/// One device's live herdr view: transport + snapshot + event pump.
@MainActor
final class MobileDeviceSession {
    let device: MobileDevice
    var state: MobileConnectionState = .idle
    var snapshot: SessionSnapshot?
    private(set) var transport: MobileTransport?
    private var eventTask: Task<Void, Never>?
    private var refreshPending = false

    var onChange: (() -> Void)?

    init(device: MobileDevice) {
        self.device = device
    }

    func connect() async {
        guard case .connecting = state else {
            state = .connecting
            onChange?()
            do {
                let transport: MobileTransport
                switch device.kind {
                case .ssh:
                    transport = try await SSHDirectTransport.connect(device: device)
                case .tailcat:
                    transport = try await TailcatMobileTransport.connect(device: device)
                }
                let pong = try await transport.request(
                    method: "ping", params: .object([:]), as: PingResult.self
                )
                guard pong.protocolVersion >= 17 else {
                    await transport.close()
                    throw HerdrError.incompatibleProtocol(pong.protocolVersion)
                }
                self.transport = transport
                state = .connected(version: pong.version)
                await refresh()
                startEventPump()
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            onChange?()
            return
        }
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        if let transport {
            await transport.close()
        }
        transport = nil
        state = .idle
        onChange?()
    }

    func refresh() async {
        guard let transport else { return }
        struct Envelope: Codable { let snapshot: SessionSnapshot }
        do {
            snapshot = try await transport.request(
                method: "session.snapshot", as: Envelope.self
            ).snapshot
            onChange?()
        } catch {
            // A failed refresh keeps the last snapshot; the event pump's own
            // failure handling decides when the connection is actually gone.
        }
    }

    private func startEventPump() {
        guard let transport else { return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            do {
                for try await _ in transport.events(kinds: HerdrEvent.allKinds) {
                    await self?.scheduleRefresh()
                }
            } catch {}
            // Stream ended: the connection is likely gone. Reflect it so the
            // UI offers Reconnect instead of silently going stale.
            guard let self, !Task.isCancelled else { return }
            if case .connected = self.state {
                self.state = .failed(String(localized: "Connection lost"))
                self.onChange?()
            }
        }
    }

    /// Coalesces event bursts into one snapshot fetch per 300 ms.
    private func scheduleRefresh() async {
        guard !refreshPending else { return }
        refreshPending = true
        try? await Task.sleep(for: .milliseconds(300))
        refreshPending = false
        await refresh()
    }
}

@MainActor
@Observable
final class MobileAppModel {
    var devices: [MobileDevice] = []
    var selectedDeviceID: UUID?
    var selectedSpaceID: String?
    var selectedAgentPaneID: String?
    var showAddDevice = false
    /// Bumped by sessions to publish nested (non-Observable) state changes.
    private(set) var revision = 0

    private let store = MobileDeviceStore()
    private var sessions: [UUID: MobileDeviceSession] = [:]

    init() {
        devices = store.load()
        selectedDeviceID = devices.first?.id
    }

    var selectedDevice: MobileDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    func session(for deviceID: UUID) -> MobileDeviceSession? {
        if let existing = sessions[deviceID] { return existing }
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        let session = MobileDeviceSession(device: device)
        session.onChange = { [weak self] in self?.revision += 1 }
        sessions[deviceID] = session
        return session
    }

    var selectedSession: MobileDeviceSession? {
        guard let selectedDeviceID else { return nil }
        return session(for: selectedDeviceID)
    }

    /// Observable connection state: sessions are plain classes, so views must
    /// read this (revision-tracked) rather than session.state directly.
    var selectedConnectionState: MobileConnectionState {
        _ = revision
        return selectedSession?.state ?? .idle
    }

    func connectSelected() {
        guard let session = selectedSession else { return }
        Task { await session.connect() }
    }

    func selectDevice(_ id: UUID) {
        guard id != selectedDeviceID else { return }
        selectedDeviceID = id
        selectedSpaceID = nil
        selectedAgentPaneID = nil
        connectSelected()
    }

    // MARK: - Device management

    func addDevice(
        name: String,
        host: String,
        port: UInt16,
        username: String,
        authMethod: MobileDevice.AuthMethod,
        password: String
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = MobileDevice(
            name: trimmedName.isEmpty ? host : trimmedName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod
        )
        if authMethod == .password {
            MobileSecretStore.setPassword(password, for: device.id)
        }
        devices.append(device)
        store.save(devices)
        selectDevice(device.id)
    }

    /// Adds a tailcat device: the token goes to the Keychain (keyed by the
    /// new device id), never into the device list. Same posture as the Mac
    /// app's `addTailcatDevice`; no host probe — tailcat has no shell.
    func addTailcatDevice(name: String, token: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = MobileDevice(
            kind: .tailcat,
            name: trimmedName.isEmpty ? String(localized: "Tailcat device") : trimmedName
        )
        do {
            try TailcatCredentialStore.setToken(token, for: device.id)
        } catch {
            return
        }
        devices.append(device)
        store.save(devices)
        selectDevice(device.id)
    }

    /// The line to enroll on a Mac: `echo '<line>' >> ~/.ssh/authorized_keys`.
    var deviceKeyAuthorizedLine: String {
        DeviceKey.authorizedKeysLine(DeviceKey.ensure())
    }

    func removeDevice(_ device: MobileDevice) {
        if let session = sessions.removeValue(forKey: device.id) {
            Task { await session.disconnect() }
        }
        MobileSecretStore.removePassword(for: device.id)
        if device.isTailcat {
            TailcatCredentialStore.removeToken(for: device.id)
            Task { await TailcatBridgeManager.shared.tearDown(deviceID: device.id) }
        }
        KnownHostsStore.unpin(host: device.host, port: device.port)
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        if selectedDeviceID == device.id {
            selectedDeviceID = devices.first?.id
            selectedSpaceID = nil
            selectedAgentPaneID = nil
            connectSelected()
        }
    }

    // MARK: - Derived lists (mirror the Mac sidebar)

    var spaces: [WorkspaceInfo] {
        _ = revision
        return selectedSession?.snapshot?.workspaces ?? []
    }

    /// Agents in the selected space (nil = all), waiting-on-you first —
    /// the same Blocked > Done > Working > Idle order as the Mac app and Heeler.
    var agents: [AgentInfo] {
        _ = revision
        guard let snapshot = selectedSession?.snapshot else { return [] }
        var list = snapshot.agents
        if let selectedSpaceID {
            list = list.filter { $0.workspaceID == selectedSpaceID }
        }
        return list.sorted {
            if $0.status.sortBucket != $1.status.sortBucket {
                return $0.status.sortBucket < $1.status.sortBucket
            }
            return $0.paneID < $1.paneID
        }
    }

    func tabLabel(for agent: AgentInfo) -> String? {
        _ = revision
        return selectedSession?.snapshot?.tabs?
            .first { $0.tabID == agent.tabID }?.customLabel
    }

    func spaceName(for workspaceID: String) -> String {
        _ = revision
        return selectedSession?.snapshot?.workspaces
            .first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    var selectedAgent: AgentInfo? {
        _ = revision
        return selectedSession?.snapshot?.agents.first { $0.paneID == selectedAgentPaneID }
    }

    /// Bare herdr terminal panes in the selected space (nil = all).
    var terminalPanes: [PaneInfo] {
        _ = revision
        guard let snapshot = selectedSession?.snapshot else { return [] }
        var panes = snapshot.ordinaryTerminalPanes
        if let selectedSpaceID {
            panes = panes.filter { $0.workspaceID == selectedSpaceID }
        }
        return panes.sorted { $0.paneID < $1.paneID }
    }

    var selectedTerminalPane: PaneInfo? {
        _ = revision
        return terminalPanes.first { $0.paneID == selectedAgentPaneID }
    }

    func terminalLabel(for pane: PaneInfo) -> String {
        _ = revision
        if let tabID = pane.tabID,
           let label = selectedSession?.snapshot?.tabs?
               .first(where: { $0.tabID == tabID })?.customLabel {
            return label
        }
        if let title = pane.terminalTitle, !title.isEmpty { return title }
        return String(localized: "Terminal")
    }
}
