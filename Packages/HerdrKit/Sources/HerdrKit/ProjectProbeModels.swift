import Foundation

/// Raw, typed output of one `ProjectProbeScript` frame. Nothing here is
/// interpreted; deciding what is a dev server, a stack or a VM belongs to later layers.

public enum VMProvider: String, Codable, Sendable { case parallels, vmpal, lima }

public struct ProbeHost: Equatable, Sendable {
    public var os: String
    public var hostname: String
    public var cpuCount: Int?
    public var load1: Double?
    public var memTotalKB: UInt64?
    public var memAvailableKB: UInt64?
    public var uptimeSeconds: Double?
    public var dockerServerVersion: String?
    public var dockerError: String?
    public var systemdUserState: String?
    public var home: String?

    public init(
        os: String = "", hostname: String = "", cpuCount: Int? = nil, load1: Double? = nil,
        memTotalKB: UInt64? = nil, memAvailableKB: UInt64? = nil, uptimeSeconds: Double? = nil,
        dockerServerVersion: String? = nil, dockerError: String? = nil, systemdUserState: String? = nil,
        home: String? = nil
    ) {
        self.home = home
        self.os = os
        self.hostname = hostname
        self.cpuCount = cpuCount
        self.load1 = load1
        self.memTotalKB = memTotalKB
        self.memAvailableKB = memAvailableKB
        self.uptimeSeconds = uptimeSeconds
        self.dockerServerVersion = dockerServerVersion
        self.dockerError = dockerError
        self.systemdUserState = systemdUserState
    }
}

public struct ProbeRoot: Equatable, Sendable {
    public var cwd: String
    public var toplevel: String?
    public var commonDir: String?

    public init(cwd: String, toplevel: String? = nil, commonDir: String? = nil) {
        self.cwd = cwd
        self.toplevel = toplevel
        self.commonDir = commonDir
    }
}

public struct ProbeListener: Equatable, Sendable {
    public var bind: String
    public var port: Int
    public var pids: [Int32]

    public init(bind: String, port: Int, pids: [Int32] = []) {
        self.bind = bind
        self.port = port
        self.pids = pids
    }
}

public struct ProbeProcess: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32?
    public var comm: String
    public var cwd: String?
    public var unit: String?
    public var stdoutPath: String?
    public var args: String

    public init(
        pid: Int32, ppid: Int32? = nil, comm: String = "", cwd: String? = nil,
        unit: String? = nil, stdoutPath: String? = nil, args: String = ""
    ) {
        self.pid = pid
        self.ppid = ppid
        self.comm = comm
        self.cwd = cwd
        self.unit = unit
        self.stdoutPath = stdoutPath
        self.args = args
    }
}

public struct ProbeComposeProject: Equatable, Sendable {
    public var name: String
    public var status: String
    public var configFiles: [String]

    public init(name: String, status: String = "", configFiles: [String] = []) {
        self.name = name
        self.status = status
        self.configFiles = configFiles
    }
}

public struct ProbeContainer: Equatable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var ports: String
    public var composeProject: String?
    public var composeService: String?
    public var workingDir: String?
    public var configFiles: [String]

    public init(
        id: String, name: String, image: String = "", state: String = "", status: String = "",
        ports: String = "", composeProject: String? = nil, composeService: String? = nil,
        workingDir: String? = nil, configFiles: [String] = []
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.composeProject = composeProject
        self.composeService = composeService
        self.workingDir = workingDir
        self.configFiles = configFiles
    }
}

public struct ProbeUnit: Equatable, Sendable {
    public var id: String
    public var load: String
    public var active: String
    public var sub: String
    public var description: String

    public init(id: String, load: String = "", active: String = "", sub: String = "", description: String = "") {
        self.id = id
        self.load = load
        self.active = active
        self.sub = sub
        self.description = description
    }
}

public struct ProbeEnvEntry: Equatable, Sendable {
    public var file: String
    public var line: Int
    public var key: String
    public var value: String

    public init(file: String, line: Int, key: String, value: String) {
        self.file = file
        self.line = line
        self.key = key
        self.value = value
    }
}

public struct ProbeVM: Equatable, Sendable {
    public var provider: VMProvider
    public var id: String
    public var name: String
    public var state: String
    public var ip: String?

    public init(provider: VMProvider, id: String, name: String, state: String, ip: String? = nil) {
        self.provider = provider
        self.id = id
        self.name = name
        self.state = state
        self.ip = ip
    }
}

public struct ProjectProbe: Equatable, Sendable {
    public var protocolVersion: Int
    /// True when the frame ended without `@@pp-end` (cut off by a timeout or a dropped connection).
    public var partial: Bool
    /// Tool name to its path, or "-" when the host doesn't have it.
    public var tools: [String: String]
    public var host: ProbeHost?
    public var roots: [ProbeRoot]
    public var listeners: [ProbeListener]
    public var processes: [Int32: ProbeProcess]
    public var composeProjects: [ProbeComposeProject]
    public var containers: [ProbeContainer]
    public var units: [ProbeUnit]
    /// Project root to the interesting files found under it.
    public var files: [String: [String]]
    public var envEntries: [ProbeEnvEntry]
    public var vms: [ProbeVM]
    /// Section name to the stderr the script captured for it.
    public var errors: [String: String]
    /// Tools the script looked for and did not find (`@@absent`).
    public var absent: Set<String>

    public init(
        protocolVersion: Int = ProjectProbeScript.protocolVersion, partial: Bool = false,
        tools: [String: String] = [:], host: ProbeHost? = nil, roots: [ProbeRoot] = [],
        listeners: [ProbeListener] = [], processes: [Int32: ProbeProcess] = [:],
        composeProjects: [ProbeComposeProject] = [], containers: [ProbeContainer] = [],
        units: [ProbeUnit] = [], files: [String: [String]] = [:], envEntries: [ProbeEnvEntry] = [],
        vms: [ProbeVM] = [], errors: [String: String] = [:], absent: Set<String> = []
    ) {
        self.protocolVersion = protocolVersion
        self.partial = partial
        self.tools = tools
        self.host = host
        self.roots = roots
        self.listeners = listeners
        self.processes = processes
        self.composeProjects = composeProjects
        self.containers = containers
        self.units = units
        self.files = files
        self.envEntries = envEntries
        self.vms = vms
        self.errors = errors
        self.absent = absent
    }
}
