import Foundation

/// Per-service user tweaks, keyed in `ProjectOverrides.services` by service signature
/// (`"<family>@<cwdRelative>"`, e.g. `"uvicorn@packages/api"`).
public struct ServiceOverride: Codable, Equatable, Sendable {
    public var url: String?
    public var label: String?
    /// A `ServiceRole` raw value that replaces the detected role.
    public var role: String?
    public var hidden: Bool
    public var restartCommand: String?
    public var stopCommand: String?
    public var startCommand: String?

    public init(
        url: String? = nil, label: String? = nil, role: String? = nil, hidden: Bool = false,
        restartCommand: String? = nil, stopCommand: String? = nil, startCommand: String? = nil
    ) {
        self.url = url
        self.label = label
        self.role = role
        self.hidden = hidden
        self.restartCommand = restartCommand
        self.stopCommand = stopCommand
        self.startCommand = startCommand
    }
}

public struct AttachedVM: Codable, Equatable, Sendable {
    public var provider: VMProvider
    public var id: String
    public var name: String

    public init(provider: VMProvider, id: String, name: String) {
        self.provider = provider
        self.id = id
        self.name = name
    }
}

public struct LinkedDevice: Codable, Equatable, Sendable {
    public var deviceID: UUID
    public var root: String

    public init(deviceID: UUID, root: String) {
        self.deviceID = deviceID
        self.root = root
    }
}

public struct NamedLink: Codable, Equatable, Sendable {
    public var label: String
    public var url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

/// Everything the user pinned, hid or attached for one project. The file store is separate.
public struct ProjectOverrides: Codable, Equatable, Sendable {
    public var services: [String: ServiceOverride]
    public var attachedCompose: [String]
    public var detachedCompose: [String]
    public var attachedContainers: [String]
    public var dismissedSuggestions: [String]
    public var attachedVMs: [AttachedVM]
    public var linkedDevices: [LinkedDevice]
    public var links: [NamedLink]
    public var envFile: String?

    public init(
        services: [String: ServiceOverride] = [:], attachedCompose: [String] = [],
        detachedCompose: [String] = [], attachedContainers: [String] = [],
        dismissedSuggestions: [String] = [], attachedVMs: [AttachedVM] = [],
        linkedDevices: [LinkedDevice] = [], links: [NamedLink] = [], envFile: String? = nil
    ) {
        self.services = services
        self.attachedCompose = attachedCompose
        self.detachedCompose = detachedCompose
        self.attachedContainers = attachedContainers
        self.dismissedSuggestions = dismissedSuggestions
        self.attachedVMs = attachedVMs
        self.linkedDevices = linkedDevices
        self.links = links
        self.envFile = envFile
    }
}

// Synthesized Decodable ignores init defaults, so stored blobs missing a key would fail to load.
extension ServiceOverride {
    private enum CodingKeys: String, CodingKey {
        case url, label, role, hidden, restartCommand, stopCommand, startCommand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try c.decodeIfPresent(String.self, forKey: .url),
            label: try c.decodeIfPresent(String.self, forKey: .label),
            role: try c.decodeIfPresent(String.self, forKey: .role),
            hidden: try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false,
            restartCommand: try c.decodeIfPresent(String.self, forKey: .restartCommand),
            stopCommand: try c.decodeIfPresent(String.self, forKey: .stopCommand),
            startCommand: try c.decodeIfPresent(String.self, forKey: .startCommand))
    }
}

extension ProjectOverrides {
    private enum CodingKeys: String, CodingKey {
        case services, attachedCompose, detachedCompose, attachedContainers, dismissedSuggestions
        case attachedVMs, linkedDevices, links, envFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            services: try c.decodeIfPresent([String: ServiceOverride].self, forKey: .services) ?? [:],
            attachedCompose: try c.decodeIfPresent([String].self, forKey: .attachedCompose) ?? [],
            detachedCompose: try c.decodeIfPresent([String].self, forKey: .detachedCompose) ?? [],
            attachedContainers: try c.decodeIfPresent([String].self, forKey: .attachedContainers) ?? [],
            dismissedSuggestions: try c.decodeIfPresent([String].self, forKey: .dismissedSuggestions) ?? [],
            attachedVMs: try c.decodeIfPresent([AttachedVM].self, forKey: .attachedVMs) ?? [],
            linkedDevices: try c.decodeIfPresent([LinkedDevice].self, forKey: .linkedDevices) ?? [],
            links: try c.decodeIfPresent([NamedLink].self, forKey: .links) ?? [],
            envFile: try c.decodeIfPresent(String.self, forKey: .envFile))
    }
}
