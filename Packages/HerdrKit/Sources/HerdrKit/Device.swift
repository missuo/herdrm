import Foundation

/// A machine running herdr. `local` talks straight to the Unix socket;
/// `ssh` reaches the remote socket through an OpenSSH stream-local forward
/// (Unix hosts) or `herdr remote-api-bridge` over SSH stdio (Windows hosts);
/// `tailcat` reaches a socket exposed by the herdr.tailcat server plugin
/// through a WireGuard/DERP tunnel (token in the Keychain, keyed by id).
public struct Device: Codable, Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: Codable, Sendable, Equatable, Hashable {
        case local
        case ssh(target: String)   // e.g. "vincent@10.10.10.87" or "vincent@mac-studio.tail"
        case tailcat
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Socket path override; nil means the default session socket (~/.config/herdr/herdr.sock).
    public var socketPath: String?
    /// Sniffed operating system id ("macos", "ubuntu", "debian", …); cached after first probe.
    public var osID: String?
    /// The herdr named session an SSH device talks to (`herdr --session <name>` on the
    /// remote, issue #190); nil means the remote's default session. Local named
    /// sessions are discovered instead and use `socketPath`.
    public var sessionName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        socketPath: String? = nil,
        osID: String? = nil,
        sessionName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.socketPath = socketPath
        self.osID = osID
        self.sessionName = Self.normalizedSessionName(sessionName)
    }

    /// A session name as stored: trimmed, with "" and herdr's reserved "default"
    /// folded into nil (both mean the default session).
    public static func normalizedSessionName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != "default"
        else { return nil }
        return trimmed
    }

    /// Whether `raw` can name a session. The name becomes a directory under
    /// `~/.config/herdr/sessions/` and is spliced into remote shell commands, so only
    /// letters, digits, `.`, `_` and `-` pass, and never a bare `.` or `..`. Empty
    /// (the default session) is valid.
    public static func isValidSessionName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard trimmed.count <= 64, trimmed != ".", trimmed != ".." else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }

    public static let local = Device(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Local",
        kind: .local,
        osID: "macos"
    )

    public var isLocal: Bool {
        if case .local = kind { return true }
        return false
    }

    public var sshTarget: String? {
        if case .ssh(let target) = kind { return target }
        return nil
    }

    public var isTailcat: Bool {
        if case .tailcat = kind { return true }
        return false
    }

    /// A named herdr session surfaced as a Local device (issue #81): local, but
    /// pointed at `~/.config/herdr/sessions/<name>/herdr.sock` via `socketPath`.
    public var isNamedSession: Bool {
        isLocal && socketPath != nil
    }

    public var subtitle: String {
        switch kind {
        case .local: return isNamedSession ? "This Mac · session \(name)" : "This Mac · herdr.sock"
        case .ssh(let target):
            if let sessionName { return "\(target) · session \(sessionName) · SSH" }
            return "\(target) · SSH"
        case .tailcat: return "tailcat tunnel"
        }
    }
}

/// Persists the device list as JSON under Application Support.
public final class DeviceStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "sb.moe.herdrm.devices")

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("devices.json")
    }

    public func load() -> [Device] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let devices = try? JSONDecoder().decode([Device].self, from: data),
                  !devices.isEmpty
            else { return [.local] }
            // Local is always present and always first.
            var list = devices.filter { !$0.isLocal }
            list.insert(.local, at: 0)
            return list
        }
    }

    public func save(_ devices: [Device]) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(devices) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
