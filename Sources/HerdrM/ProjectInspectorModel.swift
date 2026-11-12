import Foundation
import HerdrKit

/// What the view knows about a Space when it asks for a probe.
struct ProjectContext: Equatable {
    var device: Device
    var workspaceLabel: String
    var cwds: [String]
    var focusedCwd: String?
}

/// Probes a Space's device, classifies the result into a `ProjectSnapshot` and caches it per
/// project key, so two Spaces on one project share a snapshot.
@MainActor
final class ProjectInspectorModel: ObservableObject {
    enum State: Equatable { case idle, probing, live, failed(String) }

    struct Entry: Equatable {
        var snapshot: ProjectSnapshot?
        var state: State
        var lastProbe: Date?
        var rawProbe: ProjectProbe?
        var localVMs: ProjectProbe?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var keyBySpace: [SpaceRef: String] = [:]

    private let runner: ProjectProbeRunning
    private let store: ProjectStore
    private let localDevice: Device
    private let now: () -> Date
    private var inFlight: [UUID: Int] = [:]
    private var contexts: [SpaceRef: ProjectContext] = [:]
    private var generation: [SpaceRef: Int] = [:]
    private var reclassifySeq: [String: Int] = [:]
    private var reclassifyTasks: [Int: Task<Void, Never>] = [:]
    private var reclassifyCounter = 0

    init(
        runner: ProjectProbeRunning = DeviceProjectProbeRunner(), store: ProjectStore = ProjectStore(),
        localDevice: Device = .local, now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.store = store
        self.localDevice = localDevice
        self.now = now
    }

    // MARK: - Reading

    func entry(for space: SpaceRef) -> Entry? {
        keyBySpace[space].flatMap { entries[$0] }
    }

    func identity(for space: SpaceRef) -> ProjectIdentity? {
        entry(for: space)?.snapshot?.identity
    }

    /// Test seam: shows `entry` for `space` without probing.
    #if DEBUG
    var pendingReclassifyCount: Int { reclassifyTasks.count }

    func _setEntryForTesting(space: SpaceRef, key: String, entry: Entry) {
        entries[key] = entry
        keyBySpace[space] = key
    }
    #endif

    // MARK: - Probing

    enum ProbeOutcome: Equatable {
        /// The snapshot was stored.
        case applied
        /// A newer probe or a root change superseded this one, or the caller was cancelled.
        case dropped
        /// Nothing to probe (unsupported device, no directory yet); not a transient failure.
        case skipped
        case failed
    }

    /// Seconds to wait before the next tick: 15 while healthy, 2 doubling to 60 after failures.
    nonisolated static func pollDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 15 }
        return min(60, 2 * pow(2, Double(min(failures - 1, 10))))
    }

    /// Probe now, then every 15 s while the caller's task lives; backs off after failures.
    func run(space: SpaceRef, context: ProjectContext) async {
        var failures = 0
        while !Task.isCancelled {
            if inFlight[context.device.id, default: 0] == 0 {
                switch await probe(space: space, context: context) {
                case .applied: failures = 0
                case .failed: failures += 1
                case .dropped, .skipped: break
                }
            }
            do { try await Task.sleep(for: .seconds(Self.pollDelay(failures: failures))) } catch { return }
        }
    }

    /// One probe. A result for a Space whose project key changed during the probe (see
    /// `setRoot`), or that a newer probe of the same Space superseded, is dropped.
    @discardableResult
    func probe(space: SpaceRef, context: ProjectContext) async -> ProbeOutcome {
        contexts[space] = context
        let device = context.device
        let overrideRoot = store.spaceRoot(deviceID: device.id, workspaceLabel: context.workspaceLabel)
        let startKey = settledKey(space) ?? overrideRoot.map { Self.key(device: device, root: $0) }
        let failKey = startKey ?? Self.pendingKey(space)

        guard ProjectProbeScript.isSupported(device) else {
            fail(
                space: space, key: failKey,
                message: String(localized: "Project details need a shell (tailcat and Windows devices are not supported)"))
            return .skipped
        }
        // Paths a remote login shell could misread are not probed; nothing left is "no directory",
        // not a failure, so it does not grow the backoff.
        let cwds = DeviceProjectProbeRunner.safeCwds(
            Self.unique(context.cwds + (overrideRoot.map { [$0] } ?? [])), for: device)
        guard !cwds.isEmpty else {
            fail(space: space, key: failKey, message: String(localized: "No project directory found for this Space"))
            return .skipped
        }

        generation[space, default: 0] += 1
        let mine = generation[space, default: 0]
        func current() -> Bool { generation[space] == mine && settledKey(space) == startKey }

        if entries[failKey]?.snapshot == nil {
            update(key: failKey) { $0.state = .probing }
            if keyBySpace[space] == nil { keyBySpace[space] = failKey }
        }

        let local = device.isLocal
        let busy = local ? [device.id] : [device.id, localDevice.id]
        busy.forEach { inFlight[$0, default: 0] += 1 }
        defer { busy.forEach { inFlight[$0, default: 1] -= 1 } }

        let sections = local ? ProjectProbeScript.allSections : ProjectProbeScript.allSections.filter { $0 != "vms" }
        let runner = self.runner
        let localDevice = self.localDevice

        let mainText: String
        let vmText: String?
        do {
            async let mainRun = runner.run(device: device, sections: sections, cwds: cwds)
            async let vmRun: String? = local ? nil : (try? await runner.run(device: localDevice, sections: ["host", "vms"], cwds: []))
            mainText = try await mainRun
            vmText = await vmRun
        } catch {
            // The view's task was cancelled mid-probe: not a failure of the device.
            if error is CancellationError || Task.isCancelled {
                update(key: failKey) { if $0.state == .probing { $0.state = .idle } }
                return .dropped
            }
            guard current() else { return .dropped }
            fail(space: space, key: failKey, message: error.localizedDescription)
            return .failed
        }
        // The optional VM probe can swallow CancellationError after the main
        // probe has completed. Do not parse or apply that cancelled request.
        guard !Task.isCancelled else {
            update(key: failKey) { if $0.state == .probing { $0.state = .idle } }
            return .dropped
        }
        // A frame cut short (timeout, dropped ssh) parses as `partial` and is still shown.
        let parsed = await Task.detached {
            (ProjectProbeParser.parse(mainText), vmText.map(ProjectProbeParser.parse))
        }.value
        let main = parsed.0
        let localVMs = local ? main : parsed.1
        guard current() else { return .dropped }

        let home = homeDirectory(for: device, probe: main)
        guard let resolved = ProjectRootResolver.resolve(
            roots: main.roots, focusedCwd: context.focusedCwd, home: home, override: overrideRoot)
        else {
            fail(space: space, key: failKey, message: String(localized: "No project directory found for this Space"))
            return .failed
        }

        let identity = ProjectIdentity(deviceID: device.id, root: resolved.root, worktreeRoots: resolved.worktreeRoots)
        let overrides = store.overrides(for: identity.key)
        let stamp = now()
        let snapshot = await Task.detached {
            ProjectClassifier.classify(
                probe: main, localVMs: localVMs, identity: identity, device: device, overrides: overrides, now: stamp)
        }.value
        guard current() else { return .dropped }

        if let old = keyBySpace[space], old != identity.key, Self.isPending(old) { entries[old] = nil }
        keyBySpace[space] = identity.key
        entries[identity.key] = Entry(snapshot: snapshot, state: .live, lastProbe: stamp, rawProbe: main, localVMs: localVMs)
        return .applied
    }

    // MARK: - Mutations (re-classify from the cached probe, no network)

    func setURLOverride(space: SpaceRef, signature: String, url: String?) {
        mutate(space) { $0.services[signature, default: ServiceOverride()].url = url }
    }

    func setHidden(space: SpaceRef, signature: String, hidden: Bool) {
        mutate(space) { $0.services[signature, default: ServiceOverride()].hidden = hidden }
    }

    func attachCompose(space: SpaceRef, name: String) {
        mutate(space) {
            $0.detachedCompose.removeAll { $0 == name }
            if !$0.attachedCompose.contains(name) { $0.attachedCompose.append(name) }
        }
    }

    /// A group the user attached by hand just loses the attachment; a path- or name-matched one
    /// is detached. Either way it moves to "Other Compose projects", where Attach undoes it.
    func detachCompose(space: SpaceRef, name: String) {
        let wasAttached = entry(for: space)?.snapshot?.compose.first { $0.name == name }?.match == .attached
        mutate(space) {
            $0.attachedCompose.removeAll { $0 == name }
            if !wasAttached, !$0.detachedCompose.contains(name) { $0.detachedCompose.append(name) }
        }
    }

    func attachContainer(space: SpaceRef, name: String) {
        mutate(space) { if !$0.attachedContainers.contains(name) { $0.attachedContainers.append(name) } }
    }

    func detachContainer(space: SpaceRef, name: String) {
        mutate(space) { $0.attachedContainers.removeAll { $0 == name } }
    }

    func dismissSuggestion(space: SpaceRef, name: String) {
        mutate(space) { if !$0.dismissedSuggestions.contains(name) { $0.dismissedSuggestions.append(name) } }
    }

    func attachVM(space: SpaceRef, vm: VMRow) {
        mutate(space) {
            $0.attachedVMs.removeAll { $0.provider == vm.provider && $0.id == vm.vmID }
            $0.attachedVMs.append(AttachedVM(provider: vm.provider, id: vm.vmID, name: vm.name))
        }
    }

    /// `id` is a probed VM id or the provider-qualified `VMRow.id`.
    func detachVM(space: SpaceRef, id: String) {
        mutate(space) { $0.attachedVMs.removeAll { $0.id == id || "\($0.provider.rawValue):\($0.id)" == id } }
    }

    /// Hosts linked to the Space's project, from the saved overrides.
    func linkedDevices(for space: SpaceRef) -> [LinkedDevice] {
        guard let key = keyBySpace[space], !Self.isPending(key) else { return [] }
        return store.overrides(for: key).linkedDevices
    }

    func linkDevice(space: SpaceRef, device: Device, root: String) {
        mutate(space) {
            $0.linkedDevices.removeAll { $0.deviceID == device.id }
            $0.linkedDevices.append(LinkedDevice(deviceID: device.id, root: root))
        }
    }

    func unlinkDevice(space: SpaceRef, deviceID: UUID) {
        mutate(space) { $0.linkedDevices.removeAll { $0.deviceID == deviceID } }
    }

    /// Pins (or with nil clears) the project root of a Space, moves the Space to that project's
    /// entry at once and re-probes. Any probe already running for the old key is discarded.
    @discardableResult
    func setRoot(space: SpaceRef, context: ProjectContext, root: String?) -> Task<Void, Never>? {
        store.setSpaceRoot(deviceID: context.device.id, workspaceLabel: context.workspaceLabel, root: root)
        if let old = keyBySpace[space], Self.isPending(old) { entries[old] = nil }
        keyBySpace[space] = root.map { Self.key(device: context.device, root: $0) }
        return Task { [weak self] in await self?.probe(space: space, context: context) }
    }

    /// Forgets every override of the Space's project (URLs, hidden listeners, attachments, links).
    func resetOverrides(space: SpaceRef) {
        mutate(space) { $0 = ProjectOverrides() }
    }

    // MARK: - Internals

    private func mutate(_ space: SpaceRef, _ change: (inout ProjectOverrides) -> Void) {
        guard let key = keyBySpace[space], !Self.isPending(key) else { return }
        store.update(key: key, change)
        reclassify(space: space, key: key)
    }

    /// Re-classifies the cached probe off the main actor; the caller sees the result after
    /// `settleMutations()`. Only the newest request for a key, against an unchanged probe, applies.
    private func reclassify(space: SpaceRef, key: String) {
        guard let entry = entries[key], let probe = entry.rawProbe, let identity = entry.snapshot?.identity,
              let device = contexts[space]?.device
        else { return }
        reclassifySeq[key, default: 0] += 1
        let seq = reclassifySeq[key, default: 0]
        let localVMs = entry.localVMs
        let overrides = store.overrides(for: key)
        let stamp = entry.lastProbe ?? now()
        reclassifyCounter += 1
        let taskID = reclassifyCounter
        // A finished task removes itself, so the table never outgrows the edits in flight.
        reclassifyTasks[taskID] = Task { [weak self] in
            defer { self?.reclassifyTasks[taskID] = nil }
            let snapshot = await Task.detached {
                ProjectClassifier.classify(
                    probe: probe, localVMs: localVMs, identity: identity, device: device, overrides: overrides, now: stamp)
            }.value
            guard let self, self.reclassifySeq[key] == seq, var current = self.entries[key], current.rawProbe == probe
            else { return }
            current.snapshot = snapshot
            self.entries[key] = current
        }
    }

    /// Waits until every mutator's re-classification has been applied.
    func settleMutations() async {
        while let task = reclassifyTasks.values.first {
            await task.value
        }
    }

    private func fail(space: SpaceRef, key: String, message: String) {
        update(key: key) { $0.state = .failed(message) }
        if keyBySpace[space] == nil { keyBySpace[space] = key }
    }

    private func update(key: String, _ change: (inout Entry) -> Void) {
        var entry = entries[key] ?? Entry(snapshot: nil, state: .idle, lastProbe: nil, rawProbe: nil, localVMs: nil)
        change(&entry)
        entries[key] = entry
    }

    /// The Space's key, or nil while it only has a placeholder entry.
    private func settledKey(_ space: SpaceRef) -> String? {
        keyBySpace[space].flatMap { Self.isPending($0) ? nil : $0 }
    }

    /// Where a Space's state lives before its project root is known.
    private static func pendingKey(_ space: SpaceRef) -> String { "pending:\(space.deviceID.uuidString):\(space.workspaceID)" }
    private static func isPending(_ key: String) -> Bool { key.hasPrefix("pending:") }
    private static func key(device: Device, root: String) -> String {
        ProjectIdentity(deviceID: device.id, root: root, worktreeRoots: [root]).key
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Local: the real home. Remote: the `$HOME` the probe reported, else the `/home/<user>` or
    /// `/Users/<user>` prefix of a probed cwd, else the ssh user's conventional home.
    private func homeDirectory(for device: Device, probe: ProjectProbe) -> String {
        if device.isLocal { return NSHomeDirectory() }
        if let home = probe.host?.home, home.hasPrefix("/") { return home }
        for root in probe.roots {
            let parts = root.cwd.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "home" || parts[0] == "Users" { return "/\(parts[0])/\(parts[1])" }
        }
        if let target = device.sshTarget, target.contains("@"), let user = target.split(separator: "@").first {
            return user == "root" ? "/root" : "/home/\(user)"
        }
        return "/root"
    }
}
