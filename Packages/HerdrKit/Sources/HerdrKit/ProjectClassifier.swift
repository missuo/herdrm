import Foundation

/// Turns one raw `ProjectProbe` into the `ProjectSnapshot` the Project panel renders.
/// Pure: no I/O, no clock beyond the `now` it is given.
public enum ProjectClassifier {
    public static func classify(
        probe: ProjectProbe, localVMs: ProjectProbe?, identity: ProjectIdentity,
        device: Device, overrides: ProjectOverrides, now: Date
    ) -> ProjectSnapshot {
        let roots = ProjectPaths.roots(of: identity)

        let listeners = classifyListeners(
            probe: probe, roots: roots, identity: identity, device: device, overrides: overrides)
        let composeResult = classifyCompose(probe: probe, roots: roots, identity: identity, device: device, overrides: overrides)
        let containers = classifyContainers(
            probe: probe, matchedProjects: Set(composeResult.matched.map(\.name)),
            identity: identity, device: device, overrides: overrides)
        // The script scans per pane cwd; only roots inside this project count as its files.
        let scopedFiles = probe.files.filter { key, _ in
            ProjectPaths.longestRoot(containing: key, in: roots) != nil
        }
        let scopedEnv = probe.envEntries.filter {
            ProjectPaths.longestRoot(containing: $0.file, in: roots) != nil
        }
        let vms = classifyVMs(
            localVMs: localVMs, files: scopedFiles, identity: identity, overrides: overrides)

        // A `#<port>` suffix only disambiguates; an override on either spelling counts as live.
        let live = Set((listeners.devServers + listeners.other).flatMap { row -> [String] in
            let suffix = "#\(row.port)"
            if row.signature.hasSuffix(suffix) {
                return [row.signature, String(row.signature.dropLast(suffix.count))]
            }
            return [row.signature, row.signature + suffix]
        })
        let stale = overrides.services
            .filter { signature, value in
                !(value.url ?? "").isEmpty && !live.contains(signature)
            }
            .keys.sorted()

        return ProjectSnapshot(
            identity: identity,
            probedAt: now,
            partial: probe.partial,
            host: hostHealth(probe.host, devServers: listeners.devServers, compose: composeResult.matched),
            devServers: listeners.devServers,
            otherListeners: listeners.other,
            compose: composeResult.matched,
            otherCompose: composeResult.other,
            attachedContainers: containers.attached,
            suggestedContainers: containers.suggested,
            vms: vms.listed,
            otherVMs: vms.other,
            files: Array(Set(scopedFiles.values.flatMap { $0 })).sorted(),
            envEntries: scopedEnv,
            warnings: warnings(from: probe.errors),
            staleOverrides: stale)
    }

    // MARK: - Roles

    /// Classifies a listening process. `parentArgs` lets a bare child (a reload worker, a
    /// `node` under `npm run dev`) inherit the family of the command that started it.
    static func role(
        comm: String, args: String, parentArgs: String?, port: Int
    ) -> (ServiceRole, framework: String, hotReload: Bool) {
        let own = (comm + " " + args).lowercased()
        let parent = (parentArgs ?? "").lowercased()

        if let tool = toolingFamily(comm: comm, args: args, own: own) {
            return (.tooling, tool, hasReloadFlag(own))
        }
        // The process's own command line decides first; the parent's only fills in when
        // nothing matched, so a uvicorn child under `concurrently "next dev" "uvicorn"` stays uvicorn.
        for text in [own, parent] where !text.isEmpty {
            for family in RoleTable.families where matches(text, family.pattern) {
                return (family.role, family.framework, hasReloadFlag(text) || family.hotReload)
            }
        }
        let context = own + " " + parent
        let reload = hasReloadFlag(own) || hasReloadFlag(context)
        if RoleTable.isAir(comm: comm) { return (.backend, "air", true) }

        let name = comm.trimmingCharacters(in: .whitespaces)
        let framework = name.isEmpty ? "unknown" : name
        return (roleForPort(port), framework, reload)
    }

    private static func hasReloadFlag(_ text: String) -> Bool {
        text.contains("--reload") || matches(text, #"\bnodemon\b"#)
    }

    private static func toolingFamily(comm: String, args: String, own _: String) -> String? {
        let names = executableNames(comm: comm, args: args)
        // "mcp" as a word or executable-name prefix, not a substring of some path.
        if names.contains(where: { $0.hasPrefix("mcp") || matches($0, #"(^|[^a-z0-9])mcp([^a-z0-9]|$)"#) }) {
            return "mcp"
        }
        for tool in RoleTable.tooling {
            if names.contains(where: { $0 == tool || $0.hasPrefix(tool + "-") || $0.hasPrefix(tool + ".") }) {
                return tool
            }
        }
        for fragment in RoleTable.languageServers where names.contains(where: { $0.contains(fragment) }) {
            return "lsp"
        }
        return nil
    }

    /// Lowercased basenames of the command and its first argument ("node /usr/bin/gitnexus serve").
    private static func executableNames(comm: String, args: String) -> [String] {
        let tokens = args.split(separator: " ").prefix(2).map(String.init)
        return ([comm] + tokens).map { ($0 as NSString).lastPathComponent.lowercased() }
    }

    private static func roleForPort(_ port: Int) -> ServiceRole {
        if (3000...3999).contains(port) || [4200, 5173, 4321].contains(port) { return .frontend }
        if (8000...8999).contains(port) { return .backend }
        return .other
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private enum RoleTable {
        struct Family {
            var pattern: String
            var framework: String
            var role: ServiceRole
            var hotReload: Bool
        }

        /// First match wins. `hotReload` is the family's own default; `--reload` and
        /// `nodemon` in the command line add to it.
        static let families: [Family] = [
            Family(pattern: #"next-server|\bnext\s+dev\b"#, framework: "next", role: .frontend, hotReload: true),
            Family(pattern: #"\bnext\s+start\b"#, framework: "next", role: .frontend, hotReload: false),
            Family(pattern: #"\bvite\b"#, framework: "vite", role: .frontend, hotReload: true),
            Family(pattern: #"\bwebpack(-dev-server)?\b"#, framework: "webpack", role: .frontend, hotReload: false),
            Family(pattern: #"\breact-scripts\b"#, framework: "react-scripts", role: .frontend, hotReload: false),
            Family(pattern: #"\bnuxt\b"#, framework: "nuxt", role: .frontend, hotReload: false),
            Family(pattern: #"\bastro\b"#, framework: "astro", role: .frontend, hotReload: false),
            Family(pattern: #"\bremix\b"#, framework: "remix", role: .frontend, hotReload: false),
            Family(pattern: #"\bsvelte-kit\b"#, framework: "svelte-kit", role: .frontend, hotReload: false),
            Family(pattern: #"\bng\s+serve\b"#, framework: "angular", role: .frontend, hotReload: false),
            Family(pattern: #"\bparcel\b"#, framework: "parcel", role: .frontend, hotReload: false),
            Family(pattern: #"\buvicorn\b"#, framework: "uvicorn", role: .backend, hotReload: false),
            Family(pattern: #"\bgunicorn\b"#, framework: "gunicorn", role: .backend, hotReload: false),
            Family(pattern: #"\bhypercorn\b"#, framework: "hypercorn", role: .backend, hotReload: false),
            Family(pattern: #"\bflask\s+run\b"#, framework: "flask", role: .backend, hotReload: false),
            Family(pattern: #"manage\.py\s+runserver"#, framework: "django", role: .backend, hotReload: false),
            Family(pattern: #"\brails\b"#, framework: "rails", role: .backend, hotReload: false),
            Family(pattern: #"\bpuma\b"#, framework: "puma", role: .backend, hotReload: false),
            Family(pattern: #"\bgo\s+run\b"#, framework: "go", role: .backend, hotReload: false),
            Family(pattern: #"\bcargo\s+watch\b"#, framework: "cargo", role: .backend, hotReload: false),
        ]

        static let tooling = ["gitnexus", "dolt", "roamgate", "herdr", "claude", "codex"]
        static let languageServers = [
            "language-server", "languageserver", "pyright", "tsserver", "gopls",
            "rust-analyzer", "clangd", "sourcekit-lsp",
        ]

        static func isAir(comm: String) -> Bool {
            comm.trimmingCharacters(in: .whitespaces).lowercased() == "air"
        }
    }

    // MARK: - URLs and published ports

    /// The URL a browser on this Mac would use, or nil when the listener is only reachable
    /// from the remote host itself.
    static func detectedURL(bind: String, port: Int, device: Device) -> ProjectURL? {
        let loopback = isLoopback(bind)
        if loopback && !device.isLocal { return nil }
        let url = "http://\(urlHost(for: device)):\(port)"
        return ProjectURL(label: url, url: url, source: .detected, loopbackOnHost: loopback)
    }

    static func isLoopback(_ bind: String) -> Bool {
        let trimmed = bind.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed.hasPrefix("127.") || trimmed == "::1" || trimmed == "localhost"
    }

    private static func urlHost(for device: Device) -> String {
        if device.isLocal { return "localhost" }
        guard let target = device.sshTarget else { return device.name }
        let host = target.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? target
        return host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// Parses docker's ports column: "100.64.0.7:4000->3000/tcp, [::]:5432->5432/tcp".
    /// Exposed-only entries ("3000/tcp") have no host side and are skipped.
    static func publishedPorts(_ ports: String) -> [PublishedPort] {
        var result: [PublishedPort] = []
        for entry in ports.split(separator: ",") {
            let text = entry.trimmingCharacters(in: .whitespaces)
            let sides = text.components(separatedBy: "->")
            guard sides.count == 2, let colon = sides[0].lastIndex(of: ":") else { continue }
            let hostIP = String(sides[0][..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let hostRange = portRange(String(sides[0][sides[0].index(after: colon)...]))
            let target = sides[1].split(separator: "/", maxSplits: 1).map(String.init)
            guard let containerRange = target.first.flatMap(portRange),
                  let hostRange, hostRange.count == containerRange.count else { continue }
            let proto = target.count > 1 ? target[1] : "tcp"
            for (hostPort, containerPort) in zip(hostRange, containerRange) {
                result.append(PublishedPort(hostIP: hostIP, hostPort: hostPort, containerPort: containerPort, proto: proto))
            }
        }
        return result
    }

    private static func portRange(_ text: String) -> [Int]? {
        let bounds = text.split(separator: "-").map { Int($0) }
        if bounds.count == 1, let port = bounds[0] { return [port] }
        if bounds.count == 2, let low = bounds[0], let high = bounds[1], low <= high { return Array(low...high) }
        return nil
    }

    /// An override URL (first) followed by the detected one, without repeating a URL.
    private static func urls(
        override: ServiceOverride?, bind: String, port: Int, device: Device
    ) -> [ProjectURL] {
        var result: [ProjectURL] = []
        if let url = override?.url, !url.isEmpty {
            let label = override?.label.flatMap { $0.isEmpty ? nil : $0 } ?? url
            result.append(ProjectURL(label: label, url: url, source: .override, loopbackOnHost: false))
        }
        if let detected = detectedURL(bind: bind, port: port, device: device),
           !result.contains(where: { $0.url == detected.url }) {
            result.append(detected)
        }
        return result
    }

    // MARK: - Listeners

    /// One listening port after merging IPv4/IPv6 sockets and reload workers.
    private struct PortGroup {
        var port: Int
        var bind: String
        var pids: [Int32]
    }

    /// A listener that belongs to the project, before overrides and signature de-duplication.
    private struct Candidate {
        var baseSignature: String
        var role: ServiceRole
        var framework: String
        var bind: String
        var port: Int
        var pids: [Int32]
        var ownerPID: Int32?
        var cwdRelative: String
        var unit: String?
        var logPath: String?
        var hotReload: Bool
    }

    private static func classifyListeners(
        probe: ProjectProbe, roots: [String], identity: ProjectIdentity,
        device: Device, overrides: ProjectOverrides
    ) -> (devServers: [DevServer], other: [DevServer]) {
        let published = Set(probe.containers.flatMap { publishedPorts($0.ports).filter { $0.proto == "tcp" }.map(\.hostPort) })
        var candidates: [Candidate] = []
        for group in portGroups(probe.listeners) {
            if group.pids.isEmpty {
                if !published.contains(group.port) { candidates.append(unattributed(group)) }
            } else if let candidate = ownedCandidate(group, probe: probe, roots: roots, identity: identity) {
                candidates.append(candidate)
            }
        }

        let counts = Dictionary(grouping: candidates, by: \.baseSignature).mapValues(\.count)
        var devServers: [DevServer] = []
        var other: [DevServer] = []
        for candidate in candidates {
            let signature = counts[candidate.baseSignature, default: 0] > 1
                ? "\(candidate.baseSignature)#\(candidate.port)" : candidate.baseSignature
            let override = overrides.services[signature]
                ?? overrides.services[candidate.baseSignature]
                ?? overrides.services["\(candidate.baseSignature)#\(candidate.port)"]
            let role = override?.role.flatMap(ServiceRole.init(rawValue:)) ?? candidate.role
            let row = DevServer(
                signature: signature, role: role, framework: candidate.framework, bind: candidate.bind,
                port: candidate.port, isPublicBind: !isLoopback(candidate.bind), pids: candidate.pids,
                ownerPID: candidate.ownerPID, cwdRelative: candidate.cwdRelative, unit: candidate.unit,
                logPath: candidate.logPath, hotReload: candidate.hotReload,
                urls: urls(override: override, bind: candidate.bind, port: candidate.port, device: device),
                isHidden: override?.hidden ?? false)
            if role == .frontend || role == .backend { devServers.append(row) } else { other.append(row) }
        }
        return (devServers.sorted { $0.port < $1.port }, other.sorted { $0.port < $1.port })
    }

    /// Merges listeners on the same port (IPv4 and IPv6 sockets, parent and child processes).
    /// The merged bind is the first non-loopback one, so a public socket isn't hidden.
    private static func portGroups(_ listeners: [ProbeListener]) -> [PortGroup] {
        var groups: [PortGroup] = []
        for listener in listeners {
            if let index = groups.firstIndex(where: { $0.port == listener.port }) {
                for pid in listener.pids where !groups[index].pids.contains(pid) {
                    groups[index].pids.append(pid)
                }
                if isLoopback(groups[index].bind) && !isLoopback(listener.bind) {
                    groups[index].bind = listener.bind
                }
            } else {
                groups.append(PortGroup(port: listener.port, bind: listener.bind, pids: listener.pids))
            }
        }
        return groups
    }

    private static func unattributed(_ group: PortGroup) -> Candidate {
        Candidate(
            baseSignature: "unknown@", role: .other, framework: "unknown", bind: group.bind,
            port: group.port, pids: [], ownerPID: nil, cwdRelative: "", unit: nil, logPath: nil,
            hotReload: false)
    }

    private static func ownedCandidate(
        _ group: PortGroup, probe: ProjectProbe, roots: [String], identity: ProjectIdentity
    ) -> Candidate? {
        let processes = probe.processes
        func effectiveCwd(_ pid: Int32) -> String? {
            guard let process = processes[pid] else { return nil }
            return process.cwd ?? process.ppid.flatMap { processes[$0]?.cwd }
        }
        func insideProject(_ pid: Int32) -> Bool {
            effectiveCwd(pid).map { ProjectPaths.longestRoot(containing: $0, in: roots) != nil } ?? false
        }

        let inside = group.pids.filter(insideProject)
        guard !inside.isEmpty else { return nil }

        let topLevel = group.pids.filter { pid in
            guard let process = processes[pid] else { return false }
            return !(process.ppid.map(group.pids.contains) ?? false)
        }
        let owner = topLevel.min() ?? group.pids.min()
        let anchor = owner.flatMap { inside.contains($0) ? $0 : nil } ?? inside[0]
        let ownerProcess = owner.flatMap { processes[$0] }
        let details = ([ownerProcess] + group.pids.map { processes[$0] }).compactMap { $0 }

        let cwd = effectiveCwd(anchor) ?? ""
        let cwdRelative = ProjectPaths.relative(cwd, roots: roots, mainRoot: identity.root)
        let parentArgs = ownerProcess?.ppid.flatMap { processes[$0]?.args }
        let classified = role(
            comm: ownerProcess?.comm ?? "", args: ownerProcess?.args ?? "",
            parentArgs: parentArgs, port: group.port)

        return Candidate(
            baseSignature: "\(classified.framework)@\(cwdRelative)",
            role: classified.0, framework: classified.framework, bind: group.bind, port: group.port,
            pids: group.pids, ownerPID: owner, cwdRelative: cwdRelative,
            unit: details.compactMap(\.unit).first,
            logPath: details.compactMap(\.stdoutPath).first(where: isLogFile),
            hotReload: classified.hotReload)
    }

    /// Process stdout can be a socket, a pipe or the null device; only real files are logs.
    private static func isLogFile(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("/dev/")
    }

    // MARK: - Compose

    private static func classifyCompose(
        probe: ProjectProbe, roots: [String], identity: ProjectIdentity,
        device: Device, overrides: ProjectOverrides
    ) -> (matched: [ComposeGroup], other: [ComposeGroup]) {
        var names: [String] = []
        for name in probe.composeProjects.map(\.name) + probe.containers.compactMap(\.composeProject)
        where !names.contains(name) {
            names.append(name)
        }

        var matched: [ComposeGroup] = []
        var other: [ComposeGroup] = []
        for name in names.sorted() {
            let listed = probe.composeProjects.first { $0.name == name }
            let members = probe.containers.filter { $0.composeProject == name }
            let workingDir = members.compactMap(\.workingDir).first
            let configFiles = listed.map(\.configFiles).flatMap { $0.isEmpty ? nil : $0 }
                ?? members.first { !$0.configFiles.isEmpty }?.configFiles ?? []
            let counts = laneCounts(members: members, status: listed?.status)
            let rows = members.map { containerRow($0, device: device) }

            // A detached group stays visible with no match, so Attach brings it back.
            let match = overrides.detachedCompose.contains(name) ? nil : composeMatch(
                name: name, workingDir: workingDir, configFiles: configFiles, roots: roots,
                identity: identity, overrides: overrides)
            let group = ComposeGroup(
                name: name, workingDir: workingDir, configFiles: configFiles,
                match: match, running: counts.up, total: counts.total, containers: rows)
            if match != nil { matched.append(group) } else { other.append(group) }
        }
        return (matched, other)
    }

    /// Path first, then name, then an explicit attach. Nil when nothing ties it to the project.
    private static func composeMatch(
        name: String, workingDir: String?, configFiles: [String], roots: [String],
        identity: ProjectIdentity, overrides: ProjectOverrides
    ) -> ComposeMatch? {
        let paths = (workingDir.map { [$0] } ?? []) + configFiles
        if paths.contains(where: { ProjectPaths.longestRoot(containing: $0, in: roots) != nil }) {
            return .path
        }
        let project = identity.name.lowercased()
        let directory = workingDir.map { ($0 as NSString).lastPathComponent.lowercased() }
        if name.lowercased() == project || directory == project { return .name }
        if overrides.attachedCompose.contains(name) { return .attached }
        return nil
    }

    /// Running of total from the listed containers; the `compose ls` status string
    /// ("exited(4), running(24)") only when no containers were listed.
    private static func laneCounts(members: [ProbeContainer], status: String?) -> LaneCount {
        if !members.isEmpty {
            return LaneCount(up: members.filter { $0.state == "running" }.count, total: members.count)
        }
        var up = 0
        var total = 0
        for part in (status ?? "").split(separator: ",") {
            let pieces = part.split(whereSeparator: { "()".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2, let count = Int(pieces[1]) else { continue }
            total += count
            if pieces[0] == "running" { up += count }
        }
        return LaneCount(up: up, total: total)
    }

    // MARK: - Containers

    private static func classifyContainers(
        probe: ProjectProbe, matchedProjects: Set<String>, identity: ProjectIdentity,
        device: Device, overrides: ProjectOverrides
    ) -> (attached: [ContainerRow], suggested: [ContainerRow]) {
        var attached: [ContainerRow] = []
        var suggested: [ContainerRow] = []
        for container in probe.containers {
            if let project = container.composeProject, matchedProjects.contains(project) { continue }
            if overrides.attachedContainers.contains(container.name) {
                attached.append(containerRow(container, device: device))
            } else if container.composeProject == nil,
                      !overrides.dismissedSuggestions.contains(container.name),
                      let first = container.name.split(separator: "-").first,
                      identity.tokens.contains(first.lowercased()) {
                suggested.append(containerRow(container, device: device))
            }
        }
        return (attached, suggested)
    }

    private static func containerRow(_ container: ProbeContainer, device: Device) -> ContainerRow {
        let ports = publishedPorts(container.ports)
        var urls: [ProjectURL] = []
        for port in ports where port.proto == "tcp" {
            if let url = detectedURL(bind: port.hostIP, port: port.hostPort, device: device),
               !urls.contains(where: { $0.url == url.url }) {
                urls.append(url)
            }
        }
        return ContainerRow(
            id: container.id, name: container.name, image: container.image,
            service: container.composeService, state: container.state,
            statusText: container.status, health: health(of: container.status),
            ports: ports, urls: urls)
    }

    private static func health(of status: String) -> String? {
        if status.contains("(unhealthy)") { return "unhealthy" }
        if status.contains("(healthy)") { return "healthy" }
        if status.contains("(health: starting)") { return "starting" }
        return nil
    }

    // MARK: - VMs

    private static func classifyVMs(
        localVMs: ProjectProbe?, files: [String: [String]], identity: ProjectIdentity,
        overrides: ProjectOverrides
    ) -> (listed: [VMRow], other: [VMRow]) {
        guard let localVMs else { return ([], []) }
        let declaresLima = files.values.joined().contains { isLimaConfig($0) }
        let tokens = identity.tokens

        var listed: [VMRow] = []
        var other: [VMRow] = []
        for vm in localVMs.vms {
            let match: VMMatch?
            if overrides.attachedVMs.contains(where: { $0.provider == vm.provider && $0.id.lowercased() == vm.id.lowercased() }) {
                match = .attached
            } else if vm.provider == .lima && declaresLima {
                match = .declared
            } else if !Set(words(in: vm.name)).isDisjoint(with: tokens) {
                match = .suggested
            } else {
                match = nil
            }
            let row = VMRow(provider: vm.provider, vmID: vm.id, name: vm.name, state: vm.state, ip: vm.ip, match: match)
            if match == nil { other.append(row) } else { listed.append(row) }
        }
        return (listed, other)
    }

    /// Lowercased alphanumeric words, so the token "app" matches "app tests" but not "Happy".
    private static func words(in name: String) -> [String] {
        name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// M1 only checks that the project ships a lima config; it does not check which
    /// instance the config names, so every lima VM counts as declared.
    private static func isLimaConfig(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasPrefix("lima") && (name.hasSuffix(".yaml") || name.hasSuffix(".yml"))
    }

    // MARK: - Host and warnings

    private static func hostHealth(
        _ host: ProbeHost?, devServers: [DevServer], compose: [ComposeGroup]
    ) -> HostHealth {
        var memUsed: Double?
        if let total = host?.memTotalKB, let available = host?.memAvailableKB, total > 0 {
            memUsed = 1 - Double(available) / Double(total)
        }
        return HostHealth(
            hostname: host.flatMap { $0.hostname.isEmpty ? nil : $0.hostname },
            cpuCount: host?.cpuCount,
            load1: host?.load1,
            memUsedFraction: memUsed,
            dockerServerVersion: host?.dockerServerVersion,
            dockerError: host?.dockerError,
            systemdUserState: host?.systemdUserState,
            hotLanes: LaneCount(up: devServers.filter { !$0.pids.isEmpty }.count, total: devServers.count),
            dockerLanes: LaneCount(up: compose.map(\.running).reduce(0, +), total: compose.map(\.total).reduce(0, +)))
    }

    private static func warnings(from errors: [String: String]) -> [String] {
        errors.keys.sorted().map { key in
            let firstLine = (errors[key] ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return firstLine.isEmpty ? key : "\(key): \(firstLine)"
        }
    }
}

/// Component-wise path helpers: "/a/bc" is not under "/a/b", and trailing slashes don't matter.
private enum ProjectPaths {
    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// The main root plus every worktree root, deduplicated.
    static func roots(of identity: ProjectIdentity) -> [String] {
        var seen: [[String]] = []
        var result: [String] = []
        for root in [identity.root] + identity.worktreeRoots where !seen.contains(components(root)) {
            seen.append(components(root))
            result.append(root)
        }
        return result
    }

    /// The deepest root that `path` is at or under, so a worktree nested in the main
    /// checkout wins over the main root.
    static func longestRoot(containing path: String, in roots: [String]) -> String? {
        let target = components(path)
        return roots
            .filter { target.starts(with: components($0)) }
            .max { components($0).count < components($1).count }
    }

    /// `cwd` relative to its deepest root; prefixed `wt:` when that root is not the main one.
    /// Empty when the cwd is the root itself or outside every root.
    static func relative(_ cwd: String, roots: [String], mainRoot: String) -> String {
        guard let root = longestRoot(containing: cwd, in: roots) else { return "" }
        let rest = components(cwd).dropFirst(components(root).count).joined(separator: "/")
        return components(root) == components(mainRoot) ? rest : "wt:" + rest
    }
}
