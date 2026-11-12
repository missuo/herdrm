import Foundation

/// What the Project panel renders: the classified view of one probe for one project.

public enum ServiceRole: String, Codable, Sendable { case frontend, backend, tooling, other }

public enum URLSource: Equatable, Sendable { case detected, override, suggested }

public struct ProjectURL: Equatable, Sendable {
    public var label: String
    public var url: String
    public var source: URLSource
    public var loopbackOnHost: Bool

    public init(label: String, url: String, source: URLSource, loopbackOnHost: Bool) {
        self.label = label
        self.url = url
        self.source = source
        self.loopbackOnHost = loopbackOnHost
    }
}

public struct DevServer: Equatable, Sendable, Identifiable {
    public var id: String { signature }
    /// `"<family>@<cwdRelative>"`, e.g. `"uvicorn@packages/api"`. A `#<port>` suffix is added
    /// only when two listeners would otherwise share a signature.
    public var signature: String
    public var role: ServiceRole
    public var framework: String
    public var bind: String
    public var port: Int
    public var isPublicBind: Bool
    public var pids: [Int32]
    public var ownerPID: Int32?
    public var cwdRelative: String
    public var unit: String?
    public var logPath: String?
    public var hotReload: Bool
    public var urls: [ProjectURL]
    public var isHidden: Bool

    public init(
        signature: String, role: ServiceRole, framework: String, bind: String, port: Int,
        isPublicBind: Bool, pids: [Int32], ownerPID: Int32?, cwdRelative: String, unit: String?,
        logPath: String?, hotReload: Bool, urls: [ProjectURL], isHidden: Bool
    ) {
        self.signature = signature
        self.role = role
        self.framework = framework
        self.bind = bind
        self.port = port
        self.isPublicBind = isPublicBind
        self.pids = pids
        self.ownerPID = ownerPID
        self.cwdRelative = cwdRelative
        self.unit = unit
        self.logPath = logPath
        self.hotReload = hotReload
        self.urls = urls
        self.isHidden = isHidden
    }
}

public struct PublishedPort: Equatable, Sendable {
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var proto: String

    public init(hostIP: String, hostPort: Int, containerPort: Int, proto: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }
}

public struct ContainerRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var service: String?
    public var state: String
    public var statusText: String
    /// "healthy", "unhealthy" or "starting"; nil when the container has no healthcheck.
    public var health: String?
    public var ports: [PublishedPort]
    public var urls: [ProjectURL]

    public init(
        id: String, name: String, image: String, service: String?, state: String,
        statusText: String, health: String?, ports: [PublishedPort], urls: [ProjectURL]
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.service = service
        self.state = state
        self.statusText = statusText
        self.health = health
        self.ports = ports
        self.urls = urls
    }
}

public enum ComposeMatch: Equatable, Sendable { case path, name, attached }

public struct ComposeGroup: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var workingDir: String?
    public var configFiles: [String]
    /// Why the group is listed under the project; nil for the unrelated groups in `otherCompose`.
    public var match: ComposeMatch?
    public var running: Int
    public var total: Int
    public var containers: [ContainerRow]

    public init(
        name: String, workingDir: String?, configFiles: [String], match: ComposeMatch?,
        running: Int, total: Int, containers: [ContainerRow]
    ) {
        self.name = name
        self.workingDir = workingDir
        self.configFiles = configFiles
        self.match = match
        self.running = running
        self.total = total
        self.containers = containers
    }
}

public enum VMMatch: Equatable, Sendable { case attached, declared, suggested }

public struct VMRow: Equatable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue):\(vmID)" }
    public var provider: VMProvider
    public var vmID: String
    public var name: String
    public var state: String
    public var ip: String?
    /// Why the VM is listed under the project; nil for the unrelated VMs in `otherVMs`.
    public var match: VMMatch?

    public init(provider: VMProvider, vmID: String, name: String, state: String, ip: String?, match: VMMatch?) {
        self.provider = provider
        self.vmID = vmID
        self.name = name
        self.state = state
        self.ip = ip
        self.match = match
    }
}

/// `up` of `total`; for docker, `up` counts running containers.
public struct LaneCount: Equatable, Sendable {
    public var up: Int
    public var total: Int

    public init(up: Int, total: Int) {
        self.up = up
        self.total = total
    }
}

public struct HostHealth: Equatable, Sendable {
    public var hostname: String?
    public var cpuCount: Int?
    public var load1: Double?
    public var memUsedFraction: Double?
    public var dockerServerVersion: String?
    public var dockerError: String?
    public var systemdUserState: String?
    public var hotLanes: LaneCount
    public var dockerLanes: LaneCount

    public init(
        hostname: String? = nil, cpuCount: Int? = nil, load1: Double? = nil,
        memUsedFraction: Double? = nil, dockerServerVersion: String? = nil,
        dockerError: String? = nil, systemdUserState: String? = nil,
        hotLanes: LaneCount = LaneCount(up: 0, total: 0),
        dockerLanes: LaneCount = LaneCount(up: 0, total: 0)
    ) {
        self.hostname = hostname
        self.cpuCount = cpuCount
        self.load1 = load1
        self.memUsedFraction = memUsedFraction
        self.dockerServerVersion = dockerServerVersion
        self.dockerError = dockerError
        self.systemdUserState = systemdUserState
        self.hotLanes = hotLanes
        self.dockerLanes = dockerLanes
    }
}

public struct ProjectSnapshot: Equatable, Sendable {
    public var identity: ProjectIdentity
    public var probedAt: Date
    public var partial: Bool
    public var host: HostHealth
    public var devServers: [DevServer]
    public var otherListeners: [DevServer]
    public var compose: [ComposeGroup]
    public var otherCompose: [ComposeGroup]
    public var attachedContainers: [ContainerRow]
    public var suggestedContainers: [ContainerRow]
    public var vms: [VMRow]
    public var otherVMs: [VMRow]
    public var files: [String]
    public var envEntries: [ProbeEnvEntry]
    public var warnings: [String]
    /// Signatures with a URL override but no live listener.
    public var staleOverrides: [String]

    public init(
        identity: ProjectIdentity, probedAt: Date, partial: Bool, host: HostHealth,
        devServers: [DevServer], otherListeners: [DevServer], compose: [ComposeGroup],
        otherCompose: [ComposeGroup], attachedContainers: [ContainerRow],
        suggestedContainers: [ContainerRow], vms: [VMRow], otherVMs: [VMRow], files: [String],
        envEntries: [ProbeEnvEntry], warnings: [String], staleOverrides: [String]
    ) {
        self.identity = identity
        self.probedAt = probedAt
        self.partial = partial
        self.host = host
        self.devServers = devServers
        self.otherListeners = otherListeners
        self.compose = compose
        self.otherCompose = otherCompose
        self.attachedContainers = attachedContainers
        self.suggestedContainers = suggestedContainers
        self.vms = vms
        self.otherVMs = otherVMs
        self.files = files
        self.envEntries = envEntries
        self.warnings = warnings
        self.staleOverrides = staleOverrides
    }
}
