import Foundation

// Host health for the device a pane runs on: totals plus who uses them.
// `MachineStatsScript` prints one frame per tick, `MachineStatsParser` turns a
// frame into a cumulative `MachineSample`, and `MachineStatsComputer` diffs two
// samples into the `MachineSnapshot` the status strip renders. Pure, no I/O.

/// One process as the sampler saw it; `cpuTime` is cumulative seconds.
public struct MachineProcess: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var cpuTime: Double
    /// Linux start time in clock ticks; tells a reused pid apart. Nil on macOS.
    public var start: UInt64?
    public var rssBytes: UInt64
    /// Executable basename (Linux `comm`, macOS basename of `comm`).
    public var name: String

    public init(pid: Int32, ppid: Int32, cpuTime: Double, start: UInt64? = nil, rssBytes: UInt64, name: String) {
        self.pid = pid
        self.ppid = ppid
        self.cpuTime = cpuTime
        self.start = start
        self.rssBytes = rssBytes
        self.name = name
    }
}

public struct MachineDisk: Sendable, Equatable, Identifiable {
    public var mount: String
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var id: String { mount }

    /// `df`'s Capacity: used / (used + available), so root-reserved blocks count as full.
    public var fraction: Double {
        totalBytes == 0 ? 0 : min(1, Double(usedBytes) / Double(totalBytes))
    }
}

/// Raw, cumulative readings from one sampler frame.
public struct MachineSample: Sendable {
    public var os: String = ""
    public var host: String = ""
    public var samplerPID: Int32 = 0
    public var cpuCount: Int = 1
    public var uptime: TimeInterval?
    /// Linux `/proc/uptime`: a host-side clock with centisecond resolution.
    public var clock: Double?
    public var load: [Double] = []
    /// Linux `/proc/stat` aggregate jiffies.
    public var cpuBusyTicks: UInt64?
    public var cpuTotalTicks: UInt64?
    public var memTotalBytes: UInt64 = 0
    public var memUsedBytes: UInt64 = 0
    public var swapTotalBytes: UInt64 = 0
    public var swapUsedBytes: UInt64 = 0
    public var processes: [Int32: MachineProcess] = [:]
    /// Command lines of interpreter processes (node, bun, python…), so the
    /// script they run can name the agent.
    public var arguments: [Int32: String] = [:]
    public var disks: [MachineDisk] = []
    /// Monotonic time the frame arrived; the interval fallback when `clock` is nil.
    public var receivedAt: TimeInterval = 0

    public init() {}

    public var isLinux: Bool { os == "Linux" }
}

public enum ProcessGroupKind: Hashable, Sendable {
    case herdr
    case agent(String)
    case other
}

/// Usage summed over a set of processes. `cpuPercent` is % of one core, like `top`.
public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var cpuPercent: Double
    public var rssBytes: UInt64
    public var processCount: Int
}

/// One running agent: its outermost agent process plus every descendant.
public struct AgentInstance: Sendable, Equatable, Identifiable {
    public var rootPID: Int32
    public var kind: String
    /// Root first, then its parents up to (not including) pid 1. Lets a pane's
    /// shell pid find the agent it launched.
    public var lineage: [Int32]
    public var usage: ProcessUsage
    public var id: Int32 { rootPID }
}

public struct ProcessGroup: Sendable, Equatable, Identifiable {
    public var kind: ProcessGroupKind
    public var usage: ProcessUsage
    public var instances: [AgentInstance]
    public var id: String { usage.id }
}

/// Every running copy of one MCP server, summed: each copy is the server's
/// outermost process (a launcher such as npx or mcp-proxy, or the server
/// itself) plus every descendant.
public struct MCPServerUsage: Sendable, Equatable, Identifiable {
    /// The server (`graft`, `playwright`), or for a bridge, what it connects to.
    public var name: String
    /// Runs on its own (a systemd service, a shared HTTP server) rather than as
    /// a child of an agent session.
    public var isService: Bool
    public var instances: Int
    public var usage: ProcessUsage
    public var id: String { usage.id }
}

public struct MachineSnapshot: Sendable, Equatable {
    public var os: String
    public var host: String
    public var cpuCount: Int
    public var uptime: TimeInterval?
    public var load: [Double]
    /// Whole-machine CPU, 0–100. Nil until a second frame gives a delta.
    public var cpuPercent: Double?
    public var memUsedBytes: UInt64
    public var memTotalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    public var disks: [MachineDisk]
    /// herdr first, then agent kinds by CPU then RSS.
    public var groups: [ProcessGroup]
    /// MCP servers by CPU then RSS; not counted in `groups` or `other`.
    public var mcpServers: [MCPServerUsage]
    public var other: ProcessUsage
    /// Heaviest non-agent processes, merged by name.
    public var topOther: [ProcessUsage]

    /// All MCP servers together.
    public var mcpUsage: ProcessUsage {
        mcpServers.reduce(into: ProcessUsage(id: "mcp", name: "mcp", cpuPercent: 0, rssBytes: 0, processCount: 0)) {
            $0.cpuPercent += $1.usage.cpuPercent
            $0.rssBytes += $1.usage.rssBytes
            $0.processCount += $1.usage.processCount
        }
    }

    public var memFraction: Double {
        memTotalBytes == 0 ? 0 : min(1, Double(memUsedBytes) / Double(memTotalBytes))
    }

    /// The fullest filesystem — the one that runs out first.
    public var fullestDisk: MachineDisk? { disks.max { $0.fraction < $1.fraction } }
}

// MARK: - Parsing

public enum MachineStatsParser {
    public static let frameEnd = "@@hm-end"

    /// Parses one frame (the text between `@@hm-begin` and `@@hm-end`).
    public static func parse(_ frame: String, receivedAt: TimeInterval = 0) -> MachineSample? {
        var sample = MachineSample()
        sample.receivedAt = receivedAt
        var section = "header"
        var tck = 100.0
        var page: UInt64 = 4096
        var vm: [String: UInt64] = [:]
        var vmPage: UInt64 = 4096
        var now: Double?
        var bootTime: Double?
        var sawBegin = false

        for raw in frame.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if line == "@@hm-begin" { sawBegin = true }
                section = String(line.dropFirst(2))
                continue
            }
            switch section {
            case "hm-begin", "header":
                let (key, value) = splitKey(line)
                switch key {
                case "os": sample.os = value
                case "host": sample.host = value
                case "self": sample.samplerPID = Int32(value) ?? 0
                case "tck": tck = Double(value) ?? 100
                case "page": page = UInt64(value) ?? 4096
                case "ncpu": sample.cpuCount = max(1, Int(value) ?? 1)
                case "uptime":
                    sample.clock = Double(value)
                    sample.uptime = sample.clock
                case "now": now = Double(value)
                case "boottime": bootTime = braceNumber(value, key: "sec")
                case "load":
                    sample.load = value
                        .replacingOccurrences(of: "{", with: "")
                        .replacingOccurrences(of: "}", with: "")
                        .split(separator: " ")
                        .compactMap { Double($0) }
                case "cpu":
                    let ticks = value.split(separator: " ").compactMap { UInt64($0) }
                    if ticks.count >= 4 {
                        // user nice system idle iowait irq softirq steal; guest is already in user.
                        let total = ticks.prefix(8).reduce(0, +)
                        let idle = ticks[3] + (ticks.count > 4 ? ticks[4] : 0)
                        sample.cpuTotalTicks = total
                        sample.cpuBusyTicks = total - idle
                    }
                case "mem":
                    let (name, number) = splitKey(value)
                    vm[name] = UInt64(number.split(separator: " ").first ?? "")
                case "memsize": sample.memTotalBytes = UInt64(value) ?? 0
                case "swap":
                    sample.swapTotalBytes = swapField(value, "total")
                    sample.swapUsedBytes = swapField(value, "used")
                default: break
                }
            case "vm":
                if line.hasPrefix("Mach Virtual Memory Statistics"),
                   let size = line.range(of: "page size of ").map({ line[$0.upperBound...] }),
                   let bytes = UInt64(size.prefix { $0.isNumber }) {
                    vmPage = bytes
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                let number = line[line.index(after: colon)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                if let pages = UInt64(number) { vm[key] = pages }
            case "procs":
                if let process = sample.isLinux
                    ? parseLinuxProcess(line, tck: tck, page: page)
                    : parseDarwinProcess(line) {
                    sample.processes[process.pid] = process
                }
            case "args":
                let trimmed = line.drop { $0 == " " }
                guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
                sample.arguments[pid] = String(trimmed[trimmed.index(after: space)...])
            case "df":
                if let disk = parseDisk(line), !sample.disks.contains(where: { $0.mount == disk.mount }) {
                    sample.disks.append(disk)
                }
            default:
                break
            }
        }
        guard sawBegin, !sample.os.isEmpty else { return nil }

        if sample.isLinux {
            // /proc/meminfo reports kB.
            let kib: (String) -> UInt64 = { (vm[$0] ?? 0) * 1024 }
            sample.memTotalBytes = kib("MemTotal")
            sample.memUsedBytes = sample.memTotalBytes - min(sample.memTotalBytes, kib("MemAvailable"))
            sample.swapTotalBytes = kib("SwapTotal")
            sample.swapUsedBytes = sample.swapTotalBytes - min(sample.swapTotalBytes, kib("SwapFree"))
        } else {
            // Activity Monitor's "Memory Used": app memory + wired + compressed.
            let wired = vm["Pages wired down"] ?? 0
            let compressed = vm["Pages occupied by compressor"] ?? 0
            let app: UInt64
            if let anonymous = vm["Anonymous pages"] {
                app = anonymous - min(anonymous, vm["Pages purgeable"] ?? 0)
            } else {
                app = vm["Pages active"] ?? 0
            }
            sample.memUsedBytes = min(sample.memTotalBytes, (app + wired + compressed) * vmPage)
            if let now, let bootTime { sample.uptime = max(0, now - bootTime) }
        }
        return sample
    }

    /// `[[dd-]hh:]mm:ss[.ss]` → seconds (macOS `ps -o time`).
    public static func cpuSeconds(_ text: String) -> Double? {
        var rest = Substring(text)
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }

    private static func splitKey(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    /// `pid ppid ticks start rssPages comm…` (awk over `/proc/[0-9]*/stat`).
    private static func parseLinuxProcess(_ line: String, tck: Double, page: UInt64) -> MachineProcess? {
        let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard fields.count >= 5,
              let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
              let ticks = Double(fields[2]), let start = UInt64(fields[3]), let rss = UInt64(fields[4])
        else { return nil }
        return MachineProcess(
            pid: pid, ppid: ppid, cpuTime: ticks / max(1, tck), start: start,
            rssBytes: rss * page, name: fields.count > 5 ? String(fields[5]) : ""
        )
    }

    /// `pid ppid rssKiB time name` (`ps -Ao pid=,ppid=,rss=,time=,comm=`, comm basenamed).
    private static func parseDarwinProcess(_ line: String) -> MachineProcess? {
        let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard fields.count >= 4,
              let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
              let rss = UInt64(fields[2]), let time = cpuSeconds(String(fields[3]))
        else { return nil }
        return MachineProcess(
            pid: pid, ppid: ppid, cpuTime: time,
            rssBytes: rss * 1024, name: fields.count > 4 ? String(fields[4]) : ""
        )
    }

    /// POSIX `df -Pk` row: filesystem, 1024-blocks, used, available, capacity, mount (may hold spaces).
    private static func parseDisk(_ line: String) -> MachineDisk? {
        let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard fields.count == 6, let used = UInt64(fields[2]), let available = UInt64(fields[3]) else { return nil }
        return MachineDisk(mount: String(fields[5].drop { $0 == " " }), usedBytes: used * 1024, totalBytes: (used + available) * 1024)
    }

    /// `{ sec = 1790953309, usec = 721435 } …` → 1790953309.
    private static func braceNumber(_ text: String, key: String) -> Double? {
        guard let range = text.range(of: "\(key) = ") else { return nil }
        return Double(text[range.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    /// `total = 2048.00M  used = 1024.00M  free = …` → bytes.
    private static func swapField(_ text: String, _ key: String) -> UInt64 {
        guard let range = text.range(of: "\(key) = ") else { return 0 }
        let token = text[range.upperBound...].prefix { !$0.isWhitespace }
        guard let unit = token.last, let value = Double(token.dropLast()) else { return 0 }
        let scale: Double
        switch unit {
        case "K": scale = 1024
        case "M": scale = 1024 * 1024
        case "G": scale = 1024 * 1024 * 1024
        case "T": scale = 1024 * 1024 * 1024 * 1024
        default: return UInt64(Double(token) ?? 0)
        }
        return UInt64(value * scale)
    }
}

// MARK: - Agent detection

public enum AgentProcessMatcher {
    /// Executable basename → agent kind. Kinds match herdr's and `BrandIconLoader.agentIcon`.
    static let binaries: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "gemini": "gemini",
        "opencode": "opencode",
        "cursor-agent": "cursor-agent",
        "grok": "grok",
        "qwen": "qwen",
        "kimi": "kimi",
        "copilot": "copilot",
        "aider": "aider",
        "amp": "amp",
        "goose": "goose",
        "crush": "crush",
        "droid": "droid",
        "pi": "pi",
    ]

    /// npm package directories of agents that ship as a script run by node.
    static let packages: [String: String] = [
        "claude-code": "claude",
        "codex": "codex",
        "gemini-cli": "gemini",
        "qwen-code": "qwen",
        "opencode-ai": "opencode",
        "copilot": "copilot",
        "amp": "amp",
        "pi-coding-agent": "pi",
    ]

    static let interpreters: Set<String> = ["node", "bun", "deno"]

    /// The agent kind a process is, or nil. `arguments` is its full command
    /// line, known only for interpreter processes.
    public static func kind(name: String, arguments: String?) -> String? {
        let base = basename(name)
        if let kind = binaries[base] { return kind }
        // Codex's npm launcher execs a vendored `codex-<target-triple>` binary
        // (Linux truncates comm to 15 chars: "codex-x86_64-un").
        if base.hasPrefix("codex-") { return "codex" }
        // Claude Code's native installer runs `~/.local/share/claude/versions/<version>`
        // directly for teammates, resumed and background sessions, so the process is
        // named after the version. The sampler sends the command line when argv0 is
        // that path; without one (argv0 rewritten to "claude") the name alone decides.
        if isVersionName(base) {
            guard let arguments else { return "claude" }
            return arguments.contains("/claude/") || arguments.hasPrefix("claude ") ? "claude" : nil
        }
        guard isInterpreter(base), let arguments else { return nil }
        // The first non-flag argument after argv0 is the script being run.
        let script = arguments
            .split(separator: " ")
            .dropFirst()
            .first { !$0.hasPrefix("-") }
            .map(String.init)
        guard let script else { return nil }
        var scriptName = basename(script)
        for ext in [".js", ".mjs", ".cjs", ".py"] where scriptName.hasSuffix(ext) {
            scriptName.removeLast(ext.count)
        }
        if let kind = binaries[scriptName] { return kind }
        // `…/node_modules/@anthropic-ai/claude-code/cli.js`: match whole path
        // components, so `claude-coder-mac-mcp` is not Claude.
        for component in script.split(separator: "/").reversed() {
            if let kind = packages[String(component)] { return kind }
        }
        return nil
    }

    /// `2.1.289`, `2.1.290-beta.1`: three dot-separated numbers, then anything.
    static func isVersionName(_ base: String) -> Bool {
        let parts = base.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
        else { return false }
        return parts[2].prefix { $0.isNumber }.count > 0
    }

    /// Lead pid of a Claude agent-team tmux server (`tmux -L claude-swarm-48336 …`).
    static func swarmLeadPID(name: String, arguments: String?) -> Int32? {
        guard name.hasPrefix("tmux"), let arguments,
              let range = arguments.range(of: "claude-swarm-")
        else { return nil }
        return Int32(arguments[range.upperBound...].prefix { $0.isNumber })
    }

    static func isInterpreter(_ base: String) -> Bool {
        if interpreters.contains(base) { return true }
        guard base.hasPrefix("python") else { return false }
        return base.dropFirst("python".count).allSatisfy { $0.isNumber || $0 == "." }
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - MCP server detection

/// Picks MCP servers out of the process table, so each server's cost shows on
/// its own instead of inside the agent that started it (or, for a server run
/// as a service, inside "Everything else"). Command lines are known only for
/// what the sampler sends: interpreters and anything mentioning MCP.
public enum MCPServerMatcher {
    public struct Match: Sendable, Equatable {
        public var name: String
        /// The name came from a launcher's arguments (npx, uvx, mcp-proxy…);
        /// a server process further down the tree names the row better.
        public var isLauncher: Bool

        public init(name: String, isLauncher: Bool) {
            self.name = name
            self.isLauncher = isLauncher
        }
    }

    /// Programs that start or bridge a server; what they run names the row.
    static let launchers: Set<String> = [
        "npx", "npm", "pnpm", "bunx", "uvx", "uv", "pipx", "xcrun", "env",
        "sh", "bash", "zsh", "dash", "mcp-proxy", "mcp-remote", "supergateway",
    ]
    /// Launcher subcommands, never the server itself.
    static let launcherWords: Set<String> = ["exec", "run", "dlx", "x", "tool", "--"]
    /// Launcher flags whose next argument is their value.
    static let valueFlags: Set<String> = [
        "--transport", "--log-level", "--host", "--port", "--cwd", "-e", "--env",
        "-H", "--headers", "-p", "--package", "--from", "--with", "--python",
    ]
    /// Servers whose command line never says "mcp": program → serving subcommands.
    static let knownServers: [String: Set<String>] = ["gitnexus": ["serve", "mcp"]]
    /// Path components that name nothing: `…/@playwright/mcp/dist/cli.js` is playwright.
    static let genericComponents: Set<String> = [
        "cli", "index", "main", "server", "dist", "build", "bin", "lib", "src", "out", "mcp",
    ]
    static let codeExtensions = [".js", ".mjs", ".cjs", ".ts", ".py"]
    /// `--mcp-config ~/.claude/mcp.json` points at a config, not a server.
    static let configExtensions = [".json", ".jsonc", ".toml", ".yaml", ".yml", ".env", ".conf"]

    /// The MCP server a process is, or nil. `arguments` is its full command line,
    /// when the sampler sent one.
    public static func match(name: String, arguments: String?) -> Match? {
        let comm = AgentProcessMatcher.basename(name)
        guard let arguments else {
            return mentionsMCP(comm) ? Match(name: comm, isLauncher: false) : nil
        }
        var tokens = arguments.split(separator: " ").map(String.init)[...]
        guard var programPath = tokens.popFirst() else { return nil }
        if AgentProcessMatcher.isInterpreter(AgentProcessMatcher.basename(programPath)) {
            // The script (or `-m module`) an interpreter runs is the program.
            while let next = tokens.first, next.hasPrefix("-"), next != "-m" { tokens.removeFirst() }
            if tokens.first == "-m" { tokens.removeFirst() }
            guard let script = tokens.popFirst() else { return nil }
            programPath = script
        }
        let program = displayName(programPath)
        let positionals = positionalArguments(tokens)

        if launchers.contains(program) {
            let target = positionals.first { !$0.contains("://") }
            let url = positionals.first { $0.contains("://") }.flatMap(URL.init(string:))
            let servesMCP = mentionsMCP(program)
                || target.map(mentionsMCP) == true
                || url.map { ["mcp", "sse"].contains($0.lastPathComponent) } == true
            guard servesMCP else { return nil }
            if let target {
                return Match(name: displayName(withoutVersion(target)), isLauncher: true)
            }
            if let url, let host = url.host {
                return Match(name: "\(program) → \(host)\(url.port.map { ":\($0)" } ?? "")", isLauncher: true)
            }
            return Match(name: program, isLauncher: true)
        }

        let servesMCP = mentionsMCP(programPath)
            || positionals.prefix(2).contains(where: mentionsMCP)
            || positionals.first.map { knownServers[program]?.contains($0) == true } == true
        return servesMCP ? Match(name: program, isLauncher: false) : nil
    }

    /// Whether a word, path or package names MCP: a component that is `mcp`,
    /// starts with it (`mcp-proxy`, `mcp_server_fetch`, `mcpbridge`) or ends with
    /// it (`unpeel-mcp`), or the protocol's own npm scope.
    static func mentionsMCP(_ token: String) -> Bool {
        let lowered = token.lowercased()
        if configExtensions.contains(where: lowered.hasSuffix) { return false }
        if lowered.contains("modelcontextprotocol") { return true }
        return lowered.split(separator: "/").contains { component in
            let words = component.split { "-_.@".contains($0) }
            return words.contains { $0 == "mcp" } || component.hasPrefix("mcp") || component.hasSuffix("-mcp")
        }
    }

    /// Arguments that are not flags, flag values or launcher subcommands.
    static func positionalArguments(_ tokens: ArraySlice<String>) -> [String] {
        var result: [String] = []
        var skipNext = false
        for token in tokens {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(token) { skipNext = true; continue }
            if token.hasPrefix("-") || launcherWords.contains(token) { continue }
            result.append(token)
        }
        return result
    }

    /// `@playwright/mcp@latest` → `@playwright/mcp`.
    static func withoutVersion(_ package: String) -> String {
        guard let at = package.dropFirst().lastIndex(of: "@") else { return package }
        return String(package[..<at])
    }

    /// The meaningful name in a path: its last component that isn't generic,
    /// without a code extension or an npm scope's `@`.
    static func displayName(_ path: String) -> String {
        var components = path.split(separator: "/").map(String.init)
        guard var last = components.popLast() else { return path }
        for ext in codeExtensions where last.hasSuffix(ext) {
            last.removeLast(ext.count)
        }
        let name = ([last] + components.reversed()).first { !genericComponents.contains($0.lowercased()) } ?? last
        return name.hasPrefix("@") ? String(name.dropFirst()) : name
    }
}

// MARK: - Snapshot

public enum MachineStatsComputer {
    /// How many merged-by-name processes `topOther` keeps.
    static let topOtherLimit = 5

    public static func snapshot(previous: MachineSample?, current: MachineSample) -> MachineSnapshot {
        let interval = interval(previous: previous, current: current)
        let processes = current.processes

        // Per-process CPU % of one core over the interval. Nil before a delta exists.
        var cpu: [Int32: Double] = [:]
        if let previous, let interval {
            let cap = Double(current.cpuCount) * 100
            for (pid, process) in processes {
                let delta: Double
                if let before = previous.processes[pid], isSameProcess(before, process) {
                    delta = max(0, process.cpuTime - before.cpuTime)
                } else {
                    // Started after the previous frame: all its time falls in this interval.
                    delta = process.cpuTime
                }
                cpu[pid] = min(cap, delta / interval * 100)
            }
        }

        let kinds = processes.compactMapValues { process in
            AgentProcessMatcher.kind(name: process.name, arguments: current.arguments[process.pid])
        }
        // Agent-team teammates run in a tmux server that daemonizes (parent pid 1);
        // hang the server back under the lead whose pid names its socket.
        var parents: [Int32: Int32] = [:]
        for (pid, process) in processes {
            if let lead = AgentProcessMatcher.swarmLeadPID(name: process.name, arguments: current.arguments[pid]),
               lead != pid, processes[lead] != nil {
                parents[pid] = lead
            }
        }

        var mcpMatches: [Int32: MCPServerMatcher.Match] = [:]
        for (pid, process) in processes where kinds[pid] == nil {
            mcpMatches[pid] = MCPServerMatcher.match(name: process.name, arguments: current.arguments[pid])
        }

        // Walk each process up its parents: the outermost MCP server below its
        // agent owns it, else the outermost agent above it does; anything under
        // the sampler's own shell is left out.
        var instanceUsage: [Int32: ProcessUsage] = [:]
        var lineages: [Int32: [Int32]] = [:]
        var mcpInstances: [Int32: (usage: ProcessUsage, isService: Bool)] = [:]
        // The server process closest to each MCP root that names itself, rather
        // than being named by a launcher's arguments: (distance, name).
        var mcpNames: [Int32: (depth: Int, name: String)] = [:]
        var herdr = ProcessUsage(id: "herdr", name: "herdr", cpuPercent: 0, rssBytes: 0, processCount: 0)
        var other = ProcessUsage(id: "other", name: "other", cpuPercent: 0, rssBytes: 0, processCount: 0)
        var otherByName: [String: ProcessUsage] = [:]

        for (pid, process) in processes {
            var chain: [Int32] = []
            var visited: Set<Int32> = []
            var cursor: Int32? = pid
            var owner: Int32?
            var mcpRoot: Int32?
            var isSampler = false
            while let id = cursor, let node = processes[id], visited.insert(id).inserted, chain.count < 256 {
                chain.append(id)
                if id == current.samplerPID { isSampler = true; break }
                if kinds[id] != nil {
                    owner = id
                } else if owner == nil, mcpMatches[id] != nil {
                    mcpRoot = id
                }
                let parent = parents[id] ?? node.ppid
                cursor = parent == id || parent <= 0 ? nil : parent
            }
            if isSampler { continue }

            let usageCPU = cpu[pid] ?? 0
            if let root = mcpRoot {
                mcpInstances[root, default: (
                    ProcessUsage(id: "mcp-\(root)", name: "", cpuPercent: 0, rssBytes: 0, processCount: 0),
                    owner == nil
                )].usage.add(cpu: usageCPU, rss: process.rssBytes)
                if let match = mcpMatches[pid], !match.isLauncher, let depth = chain.firstIndex(of: root),
                   mcpNames[root].map({ depth < $0.depth }) ?? true {
                    mcpNames[root] = (depth, match.name)
                }
            } else if let owner {
                if lineages[owner] == nil, let index = chain.firstIndex(of: owner) {
                    lineages[owner] = chain[index...].filter { $0 > 1 }
                }
                instanceUsage[owner, default: ProcessUsage(
                    id: "agent-\(owner)", name: kinds[owner] ?? "", cpuPercent: 0, rssBytes: 0, processCount: 0
                )].add(cpu: usageCPU, rss: process.rssBytes)
            } else if AgentProcessMatcher.basename(process.name) == "herdr" {
                herdr.add(cpu: usageCPU, rss: process.rssBytes)
            } else {
                other.add(cpu: usageCPU, rss: process.rssBytes)
                let name = process.name.isEmpty ? "pid \(pid)" : process.name
                otherByName[name, default: ProcessUsage(
                    id: "other-\(name)", name: name, cpuPercent: 0, rssBytes: 0, processCount: 0
                )].add(cpu: usageCPU, rss: process.rssBytes)
            }
        }

        var byKind: [String: [AgentInstance]] = [:]
        for (root, usage) in instanceUsage {
            let kind = kinds[root] ?? usage.name
            byKind[kind, default: []].append(
                AgentInstance(rootPID: root, kind: kind, lineage: lineages[root] ?? [root], usage: usage)
            )
        }
        var agentGroups: [ProcessGroup] = byKind.map { kind, instances in
            var total = ProcessUsage(id: "kind-\(kind)", name: kind, cpuPercent: 0, rssBytes: 0, processCount: 0)
            for instance in instances {
                total.cpuPercent += instance.usage.cpuPercent
                total.rssBytes += instance.usage.rssBytes
                total.processCount += instance.usage.processCount
            }
            return ProcessGroup(kind: .agent(kind), usage: total, instances: instances.sorted(by: heavierFirst))
        }
        agentGroups.sort { heavier($0.usage, $1.usage) }

        var groups: [ProcessGroup] = []
        if herdr.processCount > 0 {
            groups.append(ProcessGroup(kind: .herdr, usage: herdr, instances: []))
        }
        groups += agentGroups

        // One row per server name, services apart from the copies agents start.
        var mcpByName: [String: MCPServerUsage] = [:]
        for (root, instance) in mcpInstances {
            let name = mcpNames[root]?.name ?? mcpMatches[root]?.name ?? "mcp"
            let key = "\(name)|\(instance.isService)"
            var server = mcpByName[key] ?? MCPServerUsage(
                name: name, isService: instance.isService, instances: 0,
                usage: ProcessUsage(
                    id: "mcp-\(instance.isService ? "service" : "agent")-\(name)",
                    name: name, cpuPercent: 0, rssBytes: 0, processCount: 0
                )
            )
            server.instances += 1
            server.usage.cpuPercent += instance.usage.cpuPercent
            server.usage.rssBytes += instance.usage.rssBytes
            server.usage.processCount += instance.usage.processCount
            mcpByName[key] = server
        }

        return MachineSnapshot(
            os: current.os,
            host: current.host,
            cpuCount: current.cpuCount,
            uptime: current.uptime,
            load: current.load,
            cpuPercent: totalCPU(previous: previous, current: current, interval: interval, perProcess: cpu),
            memUsedBytes: current.memUsedBytes,
            memTotalBytes: current.memTotalBytes,
            swapUsedBytes: current.swapUsedBytes,
            swapTotalBytes: current.swapTotalBytes,
            disks: current.disks,
            groups: groups,
            mcpServers: mcpByName.values.sorted { heavier($0.usage, $1.usage) },
            other: other,
            topOther: Array(otherByName.values.sorted(by: heavier).prefix(topOtherLimit))
        )
    }

    /// Seconds between frames: the host clock on Linux, arrival time otherwise.
    static func interval(previous: MachineSample?, current: MachineSample) -> Double? {
        guard let previous else { return nil }
        let seconds: Double
        if let now = current.clock, let before = previous.clock {
            seconds = now - before
        } else {
            seconds = current.receivedAt - previous.receivedAt
        }
        return seconds > 0.05 ? seconds : nil
    }

    static func isSameProcess(_ a: MachineProcess, _ b: MachineProcess) -> Bool {
        if let startA = a.start, let startB = b.start { return startA == startB }
        return a.name == b.name && b.cpuTime >= a.cpuTime
    }

    static func totalCPU(
        previous: MachineSample?, current: MachineSample, interval: Double?, perProcess: [Int32: Double]
    ) -> Double? {
        if let busy = current.cpuBusyTicks, let total = current.cpuTotalTicks,
           let busyBefore = previous?.cpuBusyTicks, let totalBefore = previous?.cpuTotalTicks,
           total > totalBefore {
            let busyDelta = Double(busy &- busyBefore)
            return min(100, max(0, busyDelta / Double(total - totalBefore) * 100))
        }
        guard interval != nil, !perProcess.isEmpty else { return nil }
        let sum = perProcess.values.reduce(0, +)
        return min(100, max(0, sum / Double(current.cpuCount)))
    }

    static func heavier(_ a: ProcessUsage, _ b: ProcessUsage) -> Bool {
        // Whole-percent CPU first, so jitter in idle processes doesn't reshuffle rows.
        let cpuA = a.cpuPercent.rounded(), cpuB = b.cpuPercent.rounded()
        if cpuA != cpuB { return cpuA > cpuB }
        if a.rssBytes != b.rssBytes { return a.rssBytes > b.rssBytes }
        return a.id < b.id
    }

    static func heavierFirst(_ a: AgentInstance, _ b: AgentInstance) -> Bool {
        heavier(a.usage, b.usage)
    }
}

extension ProcessUsage {
    mutating func add(cpu: Double, rss: UInt64) {
        cpuPercent += cpu
        rssBytes += rss
        processCount += 1
    }
}
