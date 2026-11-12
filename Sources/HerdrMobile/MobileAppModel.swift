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
    private var refreshDebounceTask: Task<Void, Never>?
    private var refreshDebouncePending = false
    private var snapshotRefreshTask: Task<Bool, Never>?
    private var snapshotRefreshToken: UUID?
    private var refreshRequested = false
    private var statusGeneration: UInt64 = 0
    private var probing = false

    var onChange: (() -> Void)?

    init(device: MobileDevice) {
        self.device = device
    }

    func connect() async {
        if case .connecting = state { return }
        guard !probing else { return }
        // Back from the background (or an app switch) the old connection is
        // usually still up: keep it, with its open terminals, when it answers.
        if case .connected = state, let transport {
            probing = true
            let alive = await Self.answers(transport)
            probing = false
            if alive, self.transport === transport {
                if eventTask == nil { startEventPump() }
                await refresh()
                return
            }
        }
        await dropTransport()
        state = .connecting
        onChange?()
        do {
            let transport: MobileTransport
            switch device.kind {
            case .ssh, .relay:
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
    }

    /// Whether `transport` still answers a ping within a few seconds.
    private static func answers(_ transport: MobileTransport) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await transport.request(method: "ping", params: .object([:]), as: PingResult.self)) != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Stops the event pump and closes the transport, keeping the snapshot so
    /// the lists stay on screen while the connection comes back.
    private func dropTransport() async {
        eventTask?.cancel()
        eventTask = nil
        if let transport {
            self.transport = nil
            await transport.close()
        }
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        refreshDebouncePending = false
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = nil
        snapshotRefreshToken = nil
        refreshRequested = false
        if let transport {
            await transport.close()
        }
        transport = nil
        state = .idle
        onChange?()
    }

    @discardableResult
    func refresh() async -> Bool {
        refreshRequested = true
        if let task = snapshotRefreshTask {
            return await task.value
        }
        let token = UUID()
        snapshotRefreshToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            var latestSucceeded = false
            while !Task.isCancelled, self.refreshRequested {
                self.refreshRequested = false
                latestSucceeded = await self.performRefresh()
            }
            if self.snapshotRefreshToken == token {
                self.snapshotRefreshToken = nil
                self.snapshotRefreshTask = nil
            }
            return latestSucceeded
        }
        snapshotRefreshTask = task
        return await task.value
    }

    private func performRefresh() async -> Bool {
        guard let transport else { return false }
        let generation = statusGeneration
        struct Envelope: Codable { let snapshot: SessionSnapshot }
        do {
            let fetched = try await transport.request(
                method: "session.snapshot", as: Envelope.self
            ).snapshot
            guard !Task.isCancelled, self.transport === transport else {
                return false
            }
            guard statusGeneration == generation else {
                refreshRequested = true
                return true
            }
            snapshot = fetched
            onChange?()
            return true
        } catch {
            // A failed refresh keeps the last snapshot; the event pump's own
            // failure handling decides when the connection is actually gone.
            return false
        }
    }

    private func startEventPump() {
        guard let transport else { return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            do {
                eventSubscriptions: while !Task.isCancelled {
                    guard let self else { return }
                    let subscribedPaneIDs = self.statusSubscriptionPaneIDs
                    let stream = transport.events(
                        kinds: HerdrEvent.allKinds,
                        statusPaneIDs: subscribedPaneIDs
                    )
                    var needsResubscribe = false
                    var resubscribeDelay = Duration.milliseconds(100)
                    for try await event in stream {
                        guard !Task.isCancelled else { return }
                        if event.kind == HerdrEvent.agentStatusChangedKind,
                           self.applyAgentStatusEvent(event) {
                            self.scheduleRefresh()
                        } else if event.kind == HerdrEvent.subscriptionStartedKind
                            || event.kind == HerdrEvent.agentStatusChangedKind
                            || Self.paneTopologyEventKinds.contains(event.kind) {
                            if !(await self.refresh()) {
                                needsResubscribe = true
                                resubscribeDelay = .milliseconds(500)
                                break
                            }
                        } else {
                            self.scheduleRefresh()
                        }

                        if event.kind == HerdrEvent.subscriptionStartedKind
                            || Self.paneTopologyEventKinds.contains(event.kind),
                           self.statusSubscriptionPaneIDs != subscribedPaneIDs {
                            needsResubscribe = true
                            break
                        }
                    }
                    if needsResubscribe {
                        try? await Task.sleep(for: resubscribeDelay)
                        continue eventSubscriptions
                    }
                    guard !Task.isCancelled else { return }
                    throw HerdrError.connectionFailed("event stream ended")
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
    private func scheduleRefresh() {
        guard refreshDebounceTask == nil else {
            refreshDebouncePending = true
            return
        }
        refreshDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            await self.refresh()
            self.refreshDebounceTask = nil
            if self.refreshDebouncePending {
                self.refreshDebouncePending = false
                self.scheduleRefresh()
            }
        }
    }

    private var statusSubscriptionPaneIDs: [String] {
        guard let snapshot else { return [] }
        return Array(Set(
            snapshot.agents.map(\.paneID)
                + snapshot.ordinaryTerminalPanes.map(\.paneID)
        )).sorted()
    }

    private func applyAgentStatusEvent(_ event: HerdrEvent) -> Bool {
        guard let paneID = event.payload["data"]?["pane_id"]?.stringValue,
              let statusRaw = event.payload["data"]?["agent_status"]?.stringValue,
              let updated = snapshot?.updatingAgentStatus(
                  paneID: paneID,
                  status: AgentStatus(wire: statusRaw)
              )
        else { return false }
        snapshot = updated
        statusGeneration &+= 1
        onChange?()
        return true
    }

    private static let paneTopologyEventKinds: Set<String> = [
        "pane.created",
        "pane.closed",
        "pane.moved",
        "pane.agent_detected",
    ]
}

@MainActor
@Observable
final class MobileAppModel {
    var devices: [MobileDevice] = []
    var selectedDeviceID: UUID?
    var selectedSpaceID: String?
    var selectedAgentPaneID: String?
    var showAddDevice = false
    /// A herdr pairing link the system opened Herdrm with (the iPhone Camera
    /// scanned the Mac's code); Add Device pairs with it right away.
    var pendingPairingLink: RelayPairingLink?

    func openPairingURL(_ url: URL) {
        guard let link = RelayPairingLink(url: url) else { return }
        pendingPairingLink = link
        showAddDevice = true
    }
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
        password: String,
        identityID: UUID? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = MobileDevice(
            name: trimmedName.isEmpty ? host : trimmedName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod,
            identityID: identityID
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

    /// A Mac paired by QR code through the relay (`MobileRelay.pair`). If it
    /// was paired before, the old entry is replaced so the Mac appears once.
    func addRelayDevice(_ device: MobileDevice) {
        if let old = devices.first(where: { $0.kind == .relay && $0.relay?.hostID == device.relay?.hostID }) {
            removeDevice(old)
        }
        devices.append(device)
        store.save(devices)
        selectDevice(device.id)
    }

    /// The line to enroll on a Mac: `echo '<line>' >> ~/.ssh/authorized_keys`.
    var deviceKeyAuthorizedLine: String {
        DeviceKey.authorizedKeysLine(DeviceKey.ensure())
    }

    /// This install's tailcat client public key ("nodekey:…") for a host's
    /// allow.list. Loaded lazily by the tailcat UI so SSH-only installs never
    /// create a client key.
    private(set) var tailcatClientPublicKey: String?
    /// Why the client key could not be read or replaced; shown in its place.
    private(set) var tailcatClientKeyError: String?

    func loadTailcatClientPublicKey() {
        guard tailcatClientPublicKey == nil else { return }
        do {
            tailcatClientPublicKey = try TailcatClientKeyStore.publicKey()
            tailcatClientKeyError = nil
        } catch {
            tailcatClientKeyError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Replaces the shared client key, then restarts every tailcat bridge so
    /// it picks up the new identity: `ensureUp` hands back a live bridge
    /// as-is, so each one must be torn down before the reconnect.
    func regenerateTailcatClientKey() {
        do {
            tailcatClientPublicKey = try TailcatClientKeyStore.regenerate()
            tailcatClientKeyError = nil
        } catch {
            tailcatClientKeyError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return
        }
        let tailcatIDs = devices.filter(\.isTailcat).map(\.id)
        let dropped = tailcatIDs.compactMap { sessions.removeValue(forKey: $0) }
        let reconnectSelected = selectedDevice?.isTailcat == true
        Task {
            // Sequential on purpose: sessions close, then bridges go down,
            // and only then does the selected device reconnect.
            for session in dropped {
                await session.disconnect()
            }
            for id in tailcatIDs {
                await TailcatBridgeManager.shared.tearDown(deviceID: id)
            }
            if reconnectSelected {
                connectSelected()
            }
        }
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
        if device.kind == .relay {
            MobileRelay.forget(device.id)
            if let hostID = device.relay?.hostID { KnownHostsStore.unpin(host: "relay:\(hostID)", port: 0) }
        }
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        if selectedDeviceID == device.id {
            selectedDeviceID = devices.first?.id
            selectedSpaceID = nil
            selectedAgentPaneID = nil
            connectSelected()
        }
    }

    // MARK: - New terminal / agent (same RPCs as the Mac app)

    /// Why the last create failed; shown as an alert.
    var actionError: String?
    private(set) var isCreating = false

    /// The space new tabs go into: the one on screen, else the server's
    /// focused or first space (nil only when the server has none).
    private var targetWorkspaceID: String? {
        guard let snapshot = selectedSession?.snapshot else { return selectedSpaceID }
        return selectedSpaceID ?? snapshot.focusedWorkspaceID ?? snapshot.workspaces.first?.workspaceID
    }

    func newTerminal() {
        create { session, transport, workspaceID in
            try await Self.newTab(transport, workspaceID: workspaceID, label: nil)
        }
    }

    /// A fresh tab in the space plus `agent.start`. Agent names are global on
    /// a herdr server, so a taken name retries with a short suffix.
    func newAgent(kind: String) {
        let label = newAgentLabel(kind: kind)
        create { session, transport, workspaceID in
            let paneID = try await Self.newTab(transport, workspaceID: workspaceID, label: label)
            do {
                do {
                    try await Self.startAgent(transport, name: kind, kind: kind, paneID: paneID)
                } catch HerdrError.rpc(let code, _) where code == "agent_name_taken" {
                    let suffix = String(UUID().uuidString.prefix(4)).lowercased()
                    try await Self.startAgent(transport, name: "\(kind)-\(suffix)", kind: kind, paneID: paneID)
                }
            } catch {
                _ = try? await transport.request(method: "pane.close", params: .object(["pane_id": .string(paneID)]))
                throw error
            }
            return paneID
        }
    }

    private func create(
        _ make: @escaping (MobileDeviceSession, MobileTransport, String?) async throws -> String
    ) {
        guard !isCreating, let session = selectedSession, let transport = session.transport else { return }
        let workspaceID = targetWorkspaceID
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let paneID = try await make(session, transport, workspaceID)
                await session.refresh()
                if selectedSession === session { selectedAgentPaneID = paneID }
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// `tab.create` in the space; with no space yet, a new space whose first
    /// pane is used instead (as on the Mac).
    private static func newTab(_ transport: MobileTransport, workspaceID: String?, label: String?) async throws -> String {
        var params: [String: JSONValue] = ["focus": .bool(false)]
        guard let workspaceID else {
            let result = try await transport.request(method: "workspace.create", params: .object(params))
            guard let paneID = result["root_pane"]?["pane_id"]?.stringValue
            else { throw HerdrError.malformedResponse("workspace.create returned no root_pane.pane_id") }
            return paneID
        }
        params["workspace_id"] = .string(workspaceID)
        if let label { params["label"] = .string(label) }
        let result = try await transport.request(method: "tab.create", params: .object(params))
        guard let paneID = result["root_pane"]?["pane_id"]?.stringValue
        else { throw HerdrError.malformedResponse("tab.create returned no root_pane.pane_id") }
        return paneID
    }

    /// `agent.start`, retried for up to two seconds while the new tab's shell
    /// is still starting (herdr answers `agent_pane_busy` until then).
    private static func startAgent(_ transport: MobileTransport, name: String, kind: String, paneID: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            do {
                _ = try await transport.request(method: "agent.start", params: .object([
                    "name": .string(name),
                    "kind": .string(kind),
                    "pane_id": .string(paneID),
                    "args": .array([]),
                ]))
                return
            } catch HerdrError.rpc(let code, let message) where code == "agent_pane_busy" {
                guard ContinuousClock.now < deadline else { throw HerdrError.rpc(code: code, message: message) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Named after the space, like the Mac app ("cotabby", then "cotabby 2").
    private func newAgentLabel(kind: String) -> String {
        guard let snapshot = selectedSession?.snapshot else { return kind }
        let space = targetWorkspaceID.flatMap { id in snapshot.workspaces.first { $0.workspaceID == id } }
        let taken = Set(snapshot.agents.map { agent in
            agent.title(tabLabel: snapshot.tabs?.first { $0.tabID == agent.tabID }?.customLabel)
        })
        return NewAgentLabel.make(spaceLabel: space?.label, kind: kind, taken: taken)
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
