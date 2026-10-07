import Darwin
import Foundation
import HerdrKit

@_silgen_name("flock")
private func managedAgentFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Persisted identity for a pane declared as a Herdr agent.
///
/// The JSON schema is deliberately data-driven. HerdrM never switches on specific
/// agent brands here: any kind advertised by Herdr can use the same record.
struct ManagedAgentIntent: Equatable {
    var tabLabel: String?
    var cwd: String?
    var name: String
    var kind: String
    var paneID: String?
    var tabID: String?
    var terminalID: String?
    var workspaceID: String?

    init?(
        json: [String: Any]
    ) {
        let optionalFields = ["tab_label", "cwd", "pane_id", "terminal_id", "tab_id", "workspace_id"]
        guard let name = json["name"] as? String, name.nilIfEmpty != nil,
              let kind = json["kind"] as? String, kind.nilIfEmpty != nil,
              optionalFields.allSatisfy({ field in
                  guard let value = json[field], !(value is NSNull) else { return true }
                  return (value as? String)?.nilIfEmpty != nil
              })
        else { return nil }

        self.name = name
        self.kind = kind
        self.tabLabel = (json["tab_label"] as? String)?.nilIfEmpty
        self.cwd = (json["cwd"] as? String)?.nilIfEmpty
        self.paneID = (json["pane_id"] as? String)?.nilIfEmpty
        self.terminalID = (json["terminal_id"] as? String)?.nilIfEmpty
        self.tabID = (json["tab_id"] as? String)?.nilIfEmpty
        self.workspaceID = (json["workspace_id"] as? String)?.nilIfEmpty

    }

    init(
        tabLabel: String?,
        cwd: String?,
        name: String,
        kind: String,
        paneID: String?,
        tabID: String?,
        terminalID: String? = nil,
        workspaceID: String? = nil
    ) {
        self.tabLabel = tabLabel?.nilIfEmpty
        self.cwd = cwd?.nilIfEmpty
        self.name = name
        self.kind = kind
        self.paneID = paneID?.nilIfEmpty
        self.tabID = tabID?.nilIfEmpty
        self.terminalID = terminalID?.nilIfEmpty
        self.workspaceID = workspaceID
    }

    /// Resolve an intent against a live snapshot without relying on volatile
    /// sidebar ordering. Stable ids win; cwd + user tab label is the fallback.
    func matchingPane(in panes: [PaneInfo], tabs: [TabInfo]) -> PaneInfo? {
        let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.tabID, $0) })

        // A persisted terminal identity survives cwd and pane layout changes.
        // Never attach it to a replacement terminal that reuses an old pane ID.
        if let terminalID {
            let matches = panes.filter { $0.terminalID == terminalID }
            return matches.count == 1 ? matches[0] : nil
        }

        func cwdMatches(_ pane: PaneInfo) -> Bool {
            guard let cwd else { return true }
            return pane.cwd == cwd
        }

        if let paneID,
           let pane = panes.first(where: { $0.paneID == paneID && cwdMatches($0) }) {
            return pane
        }

        if let tabID {
            let matches = panes.filter { $0.tabID == tabID && cwdMatches($0) }
            if matches.count == 1 { return matches[0] }
        }

        let fallback = panes.filter { pane in
            guard cwdMatches(pane) else { return false }
            guard let tabLabel else { return cwd != nil }
            guard let paneTabID = pane.tabID,
                  let tab = tabsByID[paneTabID]
            else { return false }
            return (tab.customLabel ?? tab.label) == tabLabel
        }
        return fallback.count == 1 ? fallback[0] : nil
    }

    func rebound(to pane: PaneInfo, tab: TabInfo?) -> ManagedAgentIntent {
        ManagedAgentIntent(
            tabLabel: tab?.customLabel ?? tab?.label ?? tabLabel,
            cwd: pane.cwd ?? cwd,
            name: name,
            kind: kind,
            paneID: pane.paneID,
            tabID: pane.tabID ?? tabID,
            terminalID: pane.terminalID,
            workspaceID: pane.workspaceID
        )
    }
}

enum ManagedAgentRegistryError: Error, LocalizedError {
    case malformedRoot, malformedTargets, unsafeStorage, storageUnavailable, storageChanged, payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedRoot: return "The saved agent registry format or version is invalid."
        case .malformedTargets: return "Saved agent identities are incomplete; existing settings were preserved."
        case .unsafeStorage: return "The agent registry must not traverse links and must be privately owned by the current user."
        case .storageUnavailable: return "Could not safely access saved agent identities."
        case .storageChanged: return "The agent registry changed during the operation."
        case .payloadTooLarge: return "The agent registry must not exceed 64 KiB."
        }
    }
}

/// Registry used by the app-level identity reconciler.
///
/// Existing unknown top-level and per-target JSON fields are preserved when an
/// intent is upserted, allowing local extensions without HerdrM erasing them.
struct ManagedAgentRegistry {
    static let maximumFileBytes = 65_536
    let fileURL: URL
    // A deterministic seam for testing uncooperative external replacements.
    private let beforeCommit: (() throws -> Void)?
    private let afterCommit: (() throws -> Void)?

    init(fileURL: URL? = nil, beforeCommit: (() throws -> Void)? = nil, afterCommit: (() throws -> Void)? = nil) {
        self.beforeCommit = beforeCommit
        self.afterCommit = afterCommit
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/herdr/agent-reconcile.json")
        }
    }

    func load() throws -> [ManagedAgentIntent] {
        guard let directory = try ManagedAgentRegistryStorage.openParent(fileURL, create: false) else { return [] }
        defer { Darwin.close(directory) }
        guard let snapshot = try ManagedAgentRegistryStorage.read(name: fileURL.lastPathComponent, parent: directory) else { return [] }
        try ManagedAgentRegistryStorage.checkParent(directory, url: fileURL)
        return try decodeRoot(snapshot.bytes).targets
    }

    /// Merge a record in-place while preserving fields HerdrM does not know.
    func upsert(_ intent: ManagedAgentIntent, onCommitted: (() -> Void)? = nil) throws {
        try mutate(onCommitted: onCommitted) { root in
            guard var targets = root["targets"] as? [[String: Any]] else {
                throw ManagedAgentRegistryError.malformedTargets
            }

            let terminalIndex = intent.terminalID.flatMap { id in
                targets.firstIndex { ($0["terminal_id"] as? String) == id }
            }
            let paneIndex = intent.paneID.flatMap { id in
                targets.firstIndex { row in
                    guard (row["pane_id"] as? String) == id else { return false }
                    if let actual = row["terminal_id"] as? String {
                        return actual == intent.terminalID
                    }
                    return true
                }
            }
            let nameIndex = targets.firstIndex { ($0["name"] as? String) == intent.name }
            let legacyIndex = targets.firstIndex { row in
                guard row["pane_id"] == nil, row["terminal_id"] == nil else { return false }
                if let tabID = intent.tabID, (row["tab_id"] as? String) == tabID { return true }
                if let label = intent.tabLabel, let cwd = intent.cwd {
                    return (row["tab_label"] as? String) == label && (row["cwd"] as? String) == cwd
                }
                return false
            }
            let index = terminalIndex ?? nameIndex ?? paneIndex ?? legacyIndex

            var row = index.map { targets[$0] } ?? [:]
            row["name"] = intent.name
            row["kind"] = intent.kind
            if let tabLabel = intent.tabLabel { row["tab_label"] = tabLabel }
            if let cwd = intent.cwd { row["cwd"] = cwd }
            if let paneID = intent.paneID { row["pane_id"] = paneID }
            if let tabID = intent.tabID { row["tab_id"] = tabID }
            if let terminalID = intent.terminalID { row["terminal_id"] = terminalID }
            if let workspaceID = intent.workspaceID { row["workspace_id"] = workspaceID }


            if let index {
                targets[index] = row
            } else {
                targets.append(row)
            }
            if root["version"] == nil { root["version"] = 1 }
            root["targets"] = targets

        }
    }

    func remove(paneIDs: Set<String>, names: Set<String> = [], terminalIDs: Set<String> = []) throws {
        try mutate(create: false) { root in
            guard let targets = root["targets"] as? [[String: Any]] else {
                throw ManagedAgentRegistryError.malformedTargets
            }
            let retained = targets.filter { row in
                let terminal = row["terminal_id"] as? String
                let terminalMatches = terminal.map(terminalIDs.contains) ?? false
                let paneMatches = terminal == nil
                    && ((row["pane_id"] as? String).map(paneIDs.contains) ?? false)
                // Captured names are only a legacy fallback. A newer terminal
                // with the same name must survive an older close response.
                let nameMatches = terminal == nil
                    && ((row["name"] as? String).map(names.contains) ?? false)
                return !terminalMatches && !paneMatches && !nameMatches
            }
            guard retained.count != targets.count else { return }
            root["targets"] = retained
        }
    }

    private func decodeRoot(_ data: Data) throws -> (root: [String: Any], targets: [ManagedAgentIntent]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int, version == 1 else {
            throw ManagedAgentRegistryError.malformedRoot
        }
        guard let targets = root["targets"] as? [[String: Any]] else {
            throw ManagedAgentRegistryError.malformedTargets
        }
        let intents = targets.compactMap(ManagedAgentIntent.init(json:))
        guard intents.count == targets.count else {
            throw ManagedAgentRegistryError.malformedTargets
        }
        return (root, intents)
    }

    private func mutate(create: Bool = true, onCommitted: (() -> Void)? = nil, _ operation: (inout [String: Any]) throws -> Void) throws {
        guard let parent = try ManagedAgentRegistryStorage.openParent(fileURL, create: create) else { return }
        defer { Darwin.close(parent) }
        let lock = try ManagedAgentRegistryStorage.lock(
            name: fileURL.lastPathComponent + ".write.lock", parent: parent
        )
        defer { Darwin.close(lock) }
        try ManagedAgentRegistryStorage.checkParent(parent, url: fileURL)
        let original = try ManagedAgentRegistryStorage.read(name: fileURL.lastPathComponent, parent: parent)
        if !create, original == nil { return }
        var root = try original.map { try decodeRoot($0.bytes).root }
            ?? ["version": 1, "targets": [[String: Any]]()]
        try operation(&root)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= Self.maximumFileBytes else { throw ManagedAgentRegistryError.payloadTooLarge }
        _ = try decodeRoot(data)
        try ManagedAgentRegistryStorage.commit(
            data, original: original, parent: parent, url: fileURL, onCommitted: onCommitted, afterCommit: afterCommit, beforeCommit: {
                try beforeCommit?()
                try ManagedAgentRegistryStorage.checkLock(
                    lock, name: fileURL.lastPathComponent + ".write.lock", parent: parent
                )
            }
        )
    }

}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}


/// A presentation of saved identities over the server's current runtime snapshot.
/// No process is started, and a missing runtime keeps an unknown status.
struct ManagedAgentProjection {
    var agents: [AgentInfo]
    var kindsByPane: [String: String]
    var boundIntents: [ManagedAgentIntent]

    /// A saved declaration cannot authorize agent attachment when runtime detection is absent.
    static func attachmentTarget(agent: AgentInfo, managedKind: String?) -> TerminalAttachTarget {
        if managedKind != nil, agent.agentKindRaw == nil, let terminalID = agent.terminalID {
            return .terminal(terminalID: terminalID)
        }
        return .agent(paneID: agent.paneID)
    }

    static func resolve(
        agents: [AgentInfo],
        panes: [PaneInfo],
        tabs: [TabInfo],
        intents: [ManagedAgentIntent]
    ) -> ManagedAgentProjection {
        var result = ManagedAgentProjection(agents: agents, kindsByPane: [:], boundIntents: [])
        let panesByID = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0) })
        let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.tabID, $0) })
        var represented = Set(agents.map(\.paneID))

        for intent in intents {
            // A server-owned name is an explicit identity; it survives moves.
            let named = agents.first { $0.name == intent.name }
            guard let pane = named.flatMap({ panesByID[$0.paneID] })
                    ?? intent.matchingPane(in: panes, tabs: tabs),
                  let tabID = pane.tabID
            else { continue }

            // Never claim a pane now owned by a different named agent.
            if let occupant = agents.first(where: { $0.paneID == pane.paneID }),
               let name = occupant.name, name != intent.name {
                continue
            }
            guard result.kindsByPane[pane.paneID] == nil else { continue }
            result.kindsByPane[pane.paneID] = intent.kind
            result.boundIntents.append(intent.rebound(to: pane, tab: tabsByID[tabID]))
            guard !represented.contains(pane.paneID), let terminalID = pane.terminalID else {
                continue
            }

            // Use the public wire decoder; the declared kind stays separate from
            // agentKindRaw, which describes actual runtime detection.
            var fields: [String: Any] = [
                "pane_id": pane.paneID, "tab_id": tabID,
                "workspace_id": pane.workspaceID, "terminal_id": terminalID,
                "name": intent.name, "agent_status": "unknown",
            ]
            if let cwd = pane.cwd { fields["cwd"] = cwd }
            if let title = pane.terminalTitle { fields["terminal_title"] = title }
            guard let data = try? JSONSerialization.data(withJSONObject: fields),
                  let agent = try? JSONDecoder().decode(AgentInfo.self, from: data)
            else { continue }
            result.agents.append(agent)
            represented.insert(pane.paneID)
        }
        return result
    }
}

/// Capture before awaiting server close; subsequent refresh may remove the pane.
struct ManagedAgentRemoval {
    let paneIDs: Set<String>
    let names: Set<String>
    let terminalIDs: Set<String>

    init(paneIDs: Set<String>, agents: [AgentInfo], panes: [PaneInfo]) {
        self.paneIDs = paneIDs
        self.names = Set(agents.filter { paneIDs.contains($0.paneID) }.compactMap(\.name))
        self.terminalIDs = Set(panes.filter { paneIDs.contains($0.paneID) }.compactMap(\.terminalID))
            .union(agents.filter { paneIDs.contains($0.paneID) }.compactMap(\.terminalID))
    }
}

private enum ManagedAgentRegistryStorage {
    final class PrivateACL {
        let value: acl_t
        init(_ value: acl_t) { self.value = value }
        deinit { Darwin.acl_free(UnsafeMutableRawPointer(value)) }
    }

    struct Snapshot {
        let bytes: Data
        let info: stat
        let acl: PrivateACL?
    }

    static func openParent(_ url: URL, create: Bool) throws -> Int32? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else {
            throw ManagedAgentRegistryError.unsafeStorage
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ManagedAgentRegistryError.storageUnavailable }
        do {
            for component in url.deletingLastPathComponent().pathComponents.dropFirst() {
                var child = Darwin.openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT {
                    if !create { Darwin.close(directory); return nil }
                    guard Darwin.mkdirat(directory, component, 0o700) == 0 || errno == EEXIST else {
                        throw ManagedAgentRegistryError.storageUnavailable
                    }
                    child = Darwin.openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw ManagedAgentRegistryError.unsafeStorage }
                Darwin.close(directory)
                directory = child
            }
            var info = stat()
            guard Darwin.fstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else {
                throw ManagedAgentRegistryError.unsafeStorage
            }
            try checkPrivateACL(directory)
            return directory
        } catch { Darwin.close(directory); throw error }
    }

    static func checkParent(_ parent: Int32, url: URL) throws {
        guard let current = try openParent(url, create: false) else {
            throw ManagedAgentRegistryError.storageChanged
        }
        defer { Darwin.close(current) }
        var held = stat(); var named = stat()
        guard Darwin.fstat(parent, &held) == 0, Darwin.fstat(current, &named) == 0,
              sameIdentity(held, named) else { throw ManagedAgentRegistryError.storageChanged }
    }

    static func validFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
            && (info.st_mode & 0o077) == 0 && (info.st_mode & 0o111) == 0
            && info.st_size >= 0 && info.st_size <= ManagedAgentRegistry.maximumFileBytes
    }

    /// POSIX modes do not account for macOS ACL grants or inheritance. Keep
    /// deny-only ACLs, but fail closed on grants rather than changing user ACLs.
    @discardableResult
    static func checkPrivateACL(_ descriptor: Int32) throws -> PrivateACL? {
        guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT when this open inode has no extended ACL.
            if errno == ENOENT { return nil }
            throw ManagedAgentRegistryError.storageUnavailable
        }
        let captured = PrivateACL(acl)
        guard Darwin.acl_valid(acl) == 0 else { throw ManagedAgentRegistryError.unsafeStorage }
        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY.rawValue
        while Darwin.acl_get_entry(acl, entryID, &entry) == 0 {
            var tag = ACL_UNDEFINED_TAG
            guard let entry, Darwin.acl_get_tag_type(entry, &tag) == 0,
                  tag == ACL_EXTENDED_DENY else {
                throw ManagedAgentRegistryError.unsafeStorage
            }
            entryID = ACL_NEXT_ENTRY.rawValue
        }
        // Darwin uses EINVAL to signal the end of a valid ACL's entries.
        guard errno == EINVAL else { throw ManagedAgentRegistryError.storageUnavailable }
        return captured
    }

    static func sameIdentity(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    static func unchanged(_ left: stat, _ right: stat) -> Bool {
        sameIdentity(left, right) && left.st_size == right.st_size
            && left.st_mode == right.st_mode && left.st_uid == right.st_uid && left.st_nlink == right.st_nlink
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }

    static func read(name: String, parent: Int32) throws -> Snapshot? {
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ManagedAgentRegistryError.unsafeStorage }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0, validFile(before) else {
            throw ManagedAgentRegistryError.unsafeStorage
        }
        let capturedACL = try checkPrivateACL(descriptor)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ManagedAgentRegistryError.storageUnavailable }
            if count == 0 { break }
            guard bytes.count + count <= ManagedAgentRegistry.maximumFileBytes else {
                throw ManagedAgentRegistryError.payloadTooLarge
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(); var named = stat()
        guard Darwin.fstat(descriptor, &after) == 0, validFile(after), unchanged(before, after),
              Darwin.fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              validFile(named), unchanged(after, named), bytes.count == before.st_size else {
            throw ManagedAgentRegistryError.storageChanged
        }
        try checkPrivateACL(descriptor)
        return Snapshot(bytes: bytes, info: after, acl: capturedACL)
    }

    static func lock(name: String, parent: Int32) throws -> Int32 {
        let descriptor = Darwin.openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManagedAgentRegistryError.unsafeStorage }
        do {
            var held = stat()
            guard Darwin.fstat(descriptor, &held) == 0, validFile(held), held.st_size == 0 else {
                throw ManagedAgentRegistryError.unsafeStorage
            }
            try checkPrivateACL(descriptor)
            // Writes fail closed on contention rather than block the UI indefinitely.
            if managedAgentFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                throw ManagedAgentRegistryError.storageUnavailable
            }
            var named = stat()
            guard Darwin.fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  validFile(named), sameIdentity(held, named) else {
                throw ManagedAgentRegistryError.storageChanged
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    static func checkLock(_ descriptor: Int32, name: String, parent: Int32) throws {
        var held = stat(); var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0, validFile(held), held.st_size == 0,
              Darwin.fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              validFile(named), sameIdentity(held, named) else {
            throw ManagedAgentRegistryError.storageChanged
        }
        try checkPrivateACL(descriptor)
    }

    static func commit(
        _ data: Data, original: Snapshot?, parent: Int32, url: URL,
        onCommitted: (() -> Void)?, afterCommit: (() throws -> Void)?, beforeCommit: (() throws -> Void)?
    ) throws {
        let temporary = ".agent-registry-" + UUID().uuidString
        let descriptor = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManagedAgentRegistryError.storageUnavailable }
        var created = stat()
        guard Darwin.fstat(descriptor, &created) == 0 else {
            Darwin.close(descriptor)
            throw ManagedAgentRegistryError.storageUnavailable
        }
        defer {
            Darwin.close(descriptor)
            var named = stat()
            if Darwin.fstatat(parent, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
               sameIdentity(created, named) { _ = Darwin.unlinkat(parent, temporary, 0) }
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw ManagedAgentRegistryError.storageUnavailable }
        try checkPrivateACL(descriptor)
        // Keep the original inode's deny rules across atomic replacement.
        // Validate inherited ACLs first: unsafe grants must never be stripped
        // silently to make an otherwise unsafe location appear acceptable.
        if let originalACL = original?.acl {
            guard Darwin.acl_set_fd_np(descriptor, originalACL.value, ACL_TYPE_EXTENDED) == 0 else {
                throw ManagedAgentRegistryError.storageUnavailable
            }
            try checkPrivateACL(descriptor)
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard written, Darwin.fsync(descriptor) == 0 else { throw ManagedAgentRegistryError.storageUnavailable }
        try beforeCommit?()
        try checkParent(parent, url: url)
        let current = try read(name: url.lastPathComponent, parent: parent)
        switch (original, current) {
        case (nil, nil): break
        case (let original?, let current?):
            guard unchanged(original.info, current.info), original.bytes == current.bytes else {
                throw ManagedAgentRegistryError.storageChanged
            }
        default: throw ManagedAgentRegistryError.storageChanged
        }
        var held = stat(); var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0, validFile(held), held.st_size == data.count,
              Darwin.fstatat(parent, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
              validFile(named), sameIdentity(held, named) else { throw ManagedAgentRegistryError.storageChanged }
        try checkPrivateACL(descriptor)
        // Cooperating writers are serialized by the separate write lock. CAS
        // above also detects external changes before the atomic replacement.
        let renamed: Int32
        if original == nil {
            // Atomic exclusive creation closes the absence-check/rename race.
            renamed = Darwin.renameatx_np(parent, temporary, parent, url.lastPathComponent, UInt32(RENAME_EXCL))
        } else {
            renamed = Darwin.renameat(parent, temporary, parent, url.lastPathComponent)
        }
        guard renamed == 0 else {
            if errno == EEXIST { throw ManagedAgentRegistryError.storageChanged }
            throw ManagedAgentRegistryError.storageUnavailable
        }
        onCommitted?()
        try afterCommit?()
        try checkParent(parent, url: url)
        guard Darwin.fsync(parent) == 0 else { throw ManagedAgentRegistryError.storageUnavailable }
    }
}
