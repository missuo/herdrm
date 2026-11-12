import Foundation

/// Turns one `ProjectProbeScript` frame into a `ProjectProbe`. The frame is a
/// sequence of `@@name [arg]` headers, each followed by that section's raw lines;
/// unknown headers are ignored so the script can grow without breaking old apps.
/// Secrets are dropped here, not downstream: env keys that look sensitive never
/// leave the parser, and credentials embedded in URL values are stripped.
public enum ProjectProbeParser {
    /// Only these `@@` lines open or close a section. Anything else starting with `@@`
    /// (say, a file literally named `@@pp-end`) is data of the current section.
    private static let knownHeaders: Set<String> = [
        "pp-begin", "pp-end", "tools", "host", "roots", "listeners", "pids", "ps", "psc", "lsofp",
        "compose", "containers", "units", "files", "env", "vms", "absent", "error",
    ]

    public static func parse(_ text: String) -> ProjectProbe {
        var probe = ProjectProbe(partial: true)
        var section = ""
        var arg = ""
        var host: [String] = []
        var listenerKind = "ss"
        var listenerLines: [String] = []
        var pidLines: [String] = []
        var psLines: [String] = []
        var pscLines: [String] = []
        var lsofpLines: [String] = []
        var composeLines: [String] = []
        var containerLines: [String] = []
        var unitLines: [String] = []
        var vmText: [String: [String]] = [:]
        var sawBegin = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.hasPrefix("@@"), knownHeaders.contains(String(line.dropFirst(2).prefix { $0 != " " })) {
                let body = line.dropFirst(2)
                let name = String(body.prefix { $0 != " " })
                let rest = String(body.dropFirst(name.count).drop { $0 == " " })
                switch name {
                case "pp-begin":
                    // A new frame replaces whatever came before (ssh banners, earlier frames).
                    probe = ProjectProbe(protocolVersion: Int(rest) ?? 1, partial: true)
                    host = []; listenerLines = []; pidLines = []; psLines = []; pscLines = []; lsofpLines = []
                    composeLines = []; containerLines = []; unitLines = []; vmText = [:]
                    listenerKind = "ss"
                    sawBegin = true
                    section = ""
                    continue
                case "pp-end":
                    probe.partial = false
                    section = ""
                    continue
                case "absent":
                    probe.absent.insert(rest)
                    section = ""
                    continue
                default:
                    section = name
                    arg = rest
                    switch name {
                    case "listeners": listenerKind = rest.isEmpty ? "ss" : rest
                    case "files": probe.files[rest, default: []] += []
                    case "error": probe.errors[rest] = probe.errors[rest] ?? ""
                    default: break
                    }
                    continue
                }
            }
            guard sawBegin, !line.isEmpty else { continue }
            switch section {
            case "tools":
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 { probe.tools[parts[0]] = parts[1] }
            case "host": host.append(line)
            case "roots":
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if let cwd = f.first, !cwd.isEmpty {
                    probe.roots.append(ProbeRoot(cwd: cwd, toplevel: dashToNil(f[safe: 1]), commonDir: dashToNil(f[safe: 2])))
                }
            case "listeners": listenerLines.append(line)
            case "pids": pidLines.append(line)
            case "ps": psLines.append(line)
            case "psc": pscLines.append(line)
            case "lsofp": lsofpLines.append(line)
            case "compose": composeLines.append(line)
            case "containers": containerLines.append(line)
            case "units": unitLines.append(line)
            case "files": probe.files[arg, default: []].append(line)
            case "env":
                if let entry = parseEnvLine(line, file: arg) { probe.envEntries.append(entry) }
            case "vms": vmText[arg, default: []].append(line)
            case "error":
                let existing = probe.errors[arg] ?? ""
                probe.errors[arg] = existing.isEmpty ? line : existing + "\n" + line
            default: break
            }
        }

        probe.host = parseHost(host)
        probe.listeners = listenerKind == "lsof" ? parseLsofListeners(listenerLines) : parseSS(listenerLines)
        probe.processes = psLines.isEmpty ? parsePIDs(pidLines) : parsePS(psLines, lsofLines: lsofpLines, commLines: pscLines)
        probe.composeProjects = parseComposeList(composeLines.joined(separator: "\n"))
        probe.containers = parseContainers(containerLines)
        probe.units = parseUnits(unitLines)
        probe.vms = parseParallels((vmText["parallels"] ?? []).joined(separator: "\n"))
            + parseVmpal((vmText["vmpal"] ?? []).joined(separator: "\n"))
            + parseLima((vmText["lima"] ?? []).joined(separator: "\n"))
        return probe
    }

    // MARK: - Listeners

    /// `ss -ltnpH`: `LISTEN recv send local peer [users:(("comm",pid=N,fd=M),…)]`.
    static func parseSS(_ lines: [String]) -> [ProbeListener] {
        lines.compactMap { line in
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 4, let (bind, port) = splitBindPort(String(tokens[3])) else { return nil }
            return ProbeListener(bind: bind, port: port, pids: pidsInSSUsers(line))
        }
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`: `p<pid>`, `c<command>`, then `f<fd>` / `n<addr:port>` pairs.
    static func parseLsofListeners(_ lines: [String]) -> [ProbeListener] {
        var order: [String] = []
        var byKey: [String: ProbeListener] = [:]
        var pid: Int32?
        for line in lines {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "n":
                guard let pid, let (bind, port) = splitBindPort(value) else { continue }
                let key = "\(bind):\(port)"
                if byKey[key] == nil {
                    byKey[key] = ProbeListener(bind: bind, port: port, pids: [])
                    order.append(key)
                }
                if byKey[key]?.pids.contains(pid) == false { byKey[key]?.pids.append(pid) }
            default: break
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private static func splitBindPort(_ address: String) -> (String, Int)? {
        guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { return nil }
        var bind = String(address[..<colon])
        if bind.hasPrefix("["), bind.hasSuffix("]") { bind = String(bind.dropFirst().dropLast()) }
        return (bind, port)
    }

    private static func pidsInSSUsers(_ line: String) -> [Int32] {
        var pids: [Int32] = []
        var rest = line[...]
        while let range = rest.range(of: "pid=") {
            let digits = rest[range.upperBound...].prefix { $0.isNumber }
            if let pid = Int32(digits), !pids.contains(pid) { pids.append(pid) }
            rest = rest[range.upperBound...]
        }
        return pids
    }

    // MARK: - Processes

    /// Linux `@@pids`: `pid \t ppid \t comm \t cwd \t unit \t stdout \t args`.
    static func parsePIDs(_ lines: [String]) -> [Int32: ProbeProcess] {
        var result: [Int32: ProbeProcess] = [:]
        for line in lines {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let pid = Int32(f[0]) else { continue }
            result[pid] = ProbeProcess(
                pid: pid,
                ppid: Int32(f[1]),
                comm: f[2],
                cwd: dashToNil(f[safe: 3]),
                unit: dashToNil(f[safe: 4]),
                stdoutPath: dashToNil(f[safe: 5]),
                args: f.dropFirst(6).joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            )
        }
        return result
    }

    /// macOS: `ps -ww -o pid=,ppid=,args=` plus `ps -o pid=,comm=` (BSD ps truncates a
    /// non-final comm column, so it is listed on its own) and `lsof -a -d cwd,1 -Fpfn`.
    /// Without `commLines`, `psLines` may carry the command as `pid ppid comm args`; the
    /// path can contain spaces, so it is the shortest prefix the arguments repeat as `argv[0]`.
    static func parsePS(_ psLines: [String], lsofLines: [String], commLines: [String] = []) -> [Int32: ProbeProcess] {
        var comms: [Int32: String] = [:]
        for raw in commLines {
            var rest = raw.drop { $0 == " " || $0 == "\t" }
            if let token = takeToken(&rest), let pid = Int32(token) { comms[pid] = String(rest) }
        }
        var result: [Int32: ProbeProcess] = [:]
        for raw in psLines {
            var rest = raw.drop { $0 == " " || $0 == "\t" }
            guard let pidToken = takeToken(&rest), let pid = Int32(pidToken),
                  let ppidToken = takeToken(&rest) else { continue }
            var comm: String
            var args: String
            if let known = comms[pid] {
                comm = known
                args = String(rest).trimmingCharacters(in: .whitespaces)
            } else if !commLines.isEmpty {
                // No comm listing for this pid: name it after argv[0] and keep the args whole.
                args = String(rest).trimmingCharacters(in: .whitespaces)
                comm = args.split(separator: " ").first.map(String.init) ?? ""
            } else {
                (comm, args) = splitCommAndArgs(String(rest))
            }
            result[pid] = ProbeProcess(
                pid: pid,
                ppid: Int32(ppidToken),
                comm: comm.split(separator: "/").last.map(String.init) ?? comm,
                args: args
            )
        }
        var pid: Int32?
        var fd = ""
        for line in lsofLines {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); fd = ""
            case "f": fd = value
            case "n":
                guard let pid, result[pid] != nil else { continue }
                if fd == "cwd" { result[pid]?.cwd = value }
                if fd == "1" { result[pid]?.stdoutPath = value }
            default: break
            }
        }
        return result
    }

    private static func takeToken(_ s: inout Substring) -> String? {
        let token = s.prefix { $0 != " " && $0 != "\t" }
        guard !token.isEmpty else { return nil }
        s = s.dropFirst(token.count).drop { $0 == " " || $0 == "\t" }
        return String(token)
    }

    private static func splitCommAndArgs(_ rest: String) -> (String, String) {
        var index = rest.startIndex
        while let space = rest[index...].firstIndex(of: " ") {
            let comm = rest[..<space]
            let remainder = rest[rest.index(after: space)...]
            if remainder.hasPrefix(comm) { return (String(comm), String(remainder).trimmingCharacters(in: .whitespaces)) }
            index = rest.index(after: space)
        }
        if let space = rest.firstIndex(of: " ") {
            return (String(rest[..<space]), String(rest[rest.index(after: space)...]).trimmingCharacters(in: .whitespaces))
        }
        return (rest, rest)
    }

    // MARK: - Docker, systemd

    /// `id \t name \t image \t state \t status \t ports \t project \t service \t working_dir \t config_files`.
    static func parseContainers(_ lines: [String]) -> [ProbeContainer] {
        lines.compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].isEmpty else { return nil }
            return ProbeContainer(
                id: f[0], name: f[1], image: f[safe: 2] ?? "", state: f[safe: 3] ?? "",
                status: f[safe: 4] ?? "", ports: f[safe: 5] ?? "",
                composeProject: dashToNil(f[safe: 6]), composeService: dashToNil(f[safe: 7]),
                workingDir: dashToNil(f[safe: 8]), configFiles: commaList(f[safe: 9])
            )
        }
    }

    static func parseComposeList(_ json: String) -> [ProbeComposeProject] {
        guard let array = jsonValue(json) as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let name = item["Name"] as? String else { return nil }
            return ProbeComposeProject(
                name: name, status: item["Status"] as? String ?? "",
                configFiles: commaList(item["ConfigFiles"] as? String)
            )
        }
    }

    /// `systemctl --user list-units --no-legend --plain`: `unit load active sub description…`.
    static func parseUnits(_ lines: [String]) -> [ProbeUnit] {
        lines.compactMap { raw in
            var rest = raw.drop { $0 == " " || $0 == "●" || $0 == "*" }
            guard let id = takeToken(&rest), let load = takeToken(&rest),
                  let active = takeToken(&rest), let sub = takeToken(&rest) else { return nil }
            return ProbeUnit(id: id, load: load, active: active, sub: sub, description: String(rest).trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - VMs

    /// `prlctl list -a -j`: a JSON array. Parallels prints blank or `-` when it has no address.
    static func parseParallels(_ json: String) -> [ProbeVM] {
        guard let array = jsonValue(json) as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let id = item["uuid"] as? String, let name = item["name"] as? String else { return nil }
            return ProbeVM(provider: .parallels, id: id, name: name, state: item["status"] as? String ?? "", ip: address(item["ip_configured"]))
        }
    }

    /// `vmpal list --json`: `{"vms":[…]}`.
    static func parseVmpal(_ json: String) -> [ProbeVM] {
        guard let vms = (jsonValue(json) as? [String: Any])?["vms"] as? [[String: Any]] else { return [] }
        return vms.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return ProbeVM(provider: .vmpal, id: id, name: name, state: item["state"] as? String ?? "", ip: address(item["internetAddress"]))
        }
    }

    /// `limactl list --json`: one JSON object per line. Lima has no address in the listing.
    static func parseLima(_ ndjson: String) -> [ProbeVM] {
        ndjson.split(separator: "\n").compactMap { line in
            guard let item = jsonValue(String(line)) as? [String: Any], let name = item["name"] as? String else { return nil }
            return ProbeVM(provider: .lima, id: name, name: name, state: item["status"] as? String ?? "", ip: nil)
        }
    }

    // MARK: - Host

    private static func parseHost(_ lines: [String]) -> ProbeHost? {
        guard !lines.isEmpty else { return nil }
        var host = ProbeHost()
        var boottime: Double?
        var now: Double?
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "os": host.os = value
            case "hostname": host.hostname = value
            case "home": host.home = value.isEmpty ? nil : value
            case "ncpu": host.cpuCount = Int(value)
            case "load": host.load1 = value.split(separator: " ").first.flatMap { Double($0) }
            case "memtotal_kb": host.memTotalKB = UInt64(value)
            case "memavail_kb": host.memAvailableKB = UInt64(value)
            case "uptime": host.uptimeSeconds = Double(value)
            case "boottime": boottime = Double(value)
            case "now": now = Double(value)
            case "docker": host.dockerServerVersion = value.isEmpty ? nil : value
            case "docker_error": host.dockerError = value.isEmpty ? nil : value
            case "systemd": host.systemdUserState = value.isEmpty ? nil : value
            default: break
            }
        }
        if host.uptimeSeconds == nil, let boottime {
            host.uptimeSeconds = max(0, (now ?? Date().timeIntervalSince1970) - boottime)
        }
        return host
    }

    // MARK: - Env

    private static let secretMarkers = ["SECRET", "TOKEN", "KEY", "PASS", "CREDENTIAL"]

    /// `<lineno>:<KEY>`. The script sends key names only; a `=value` tail (an older script) is
    /// discarded, so `value` stays empty. Sensitive keys are dropped.
    private static func parseEnvLine(_ line: String, file: String) -> ProbeEnvEntry? {
        guard let colon = line.firstIndex(of: ":"), let number = Int(line[..<colon]) else { return nil }
        var key = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("export ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if let equals = key.firstIndex(of: "=") { key = String(key[..<equals]).trimmingCharacters(in: .whitespaces) }
        guard !key.isEmpty else { return nil }
        let upper = key.uppercased()
        if secretMarkers.contains(where: { upper.contains($0) }) { return nil }
        return ProbeEnvEntry(file: file, line: number, key: key, value: "")
    }

    /// Removes `user:password@` from a URL. No longer reached by the probe (env values are not
    /// sent), kept for when env-suggested URLs return.
    static func stripUserinfo(_ value: String) -> String {
        value.replacingOccurrences(of: #"://[^/\s]*@"#, with: "://", options: .regularExpression)
    }

    // MARK: - Helpers

    private static func dashToNil(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s != "-" else { return nil }
        return s
    }

    private static func commaList(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func address(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "-" else { return nil }
        return s
    }

    private static func jsonValue(_ text: String) -> Any? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
