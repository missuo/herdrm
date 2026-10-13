import Foundation
import XCTest
@testable import HerdrKit

/// Title-bar machine stats: sampler frame parsing, CPU deltas, and which agent
/// owns which process.
final class MachineStatsTests: XCTestCase {
    // MARK: Parsing

    /// Shape recorded from cloud-dev (Ubuntu, herdr 0.9.1), trimmed.
    private func linuxFrame(
        uptime: String = "3369422.72",
        cpu: String = "871568343 8347356 167532790 1498856784 100368636 0 9836772 0 0 0",
        procs: [String] = [],
        args: [String] = []
    ) -> String {
        """
        @@hm-begin
        os Linux
        host cloud-dev
        self 177389
        tck 100
        page 4096
        ncpu 8
        uptime \(uptime)
        load 12.70 15.27 15.60
        cpu \(cpu)
        mem MemTotal 65792224
        mem MemAvailable 23923008
        mem SwapTotal 16777212
        mem SwapFree 3963680
        @@procs
        \(procs.joined(separator: "\n"))
        @@args
        \(args.joined(separator: "\n"))
        @@df
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        /dev/root        518960100 466051928  52891788      90% /
        /dev/root        518960100 466051928  52891788      90% /
        """
    }

    /// Shape recorded from a local Mac (macOS 27), trimmed.
    private func darwinFrame(procs: [String], args: [String] = []) -> String {
        """
        @@hm-begin
        os Darwin
        host deepdark79.local
        self 60084
        ncpu 18
        memsize 137438953472
        now 1791000000
        boottime { sec = 1790953309, usec = 721435 } Fri Oct  2 17:01:49 2026
        load { 10.34 10.80 8.99 }
        swap total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)
        @@vm
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                    90983.
        Pages active:                                3044123.
        Pages wired down:                            1679498.
        Pages purgeable:                              116719.
        "Translation faults":                     2372711040.
        Anonymous pages:                             3703019.
        Pages occupied by compressor:                 465666.
        @@procs
        \(procs.joined(separator: "\n"))
        @@args
        \(args.joined(separator: "\n"))
        @@df
        Filesystem     1024-blocks       Used Available Capacity  Mounted on
        /dev/disk3s1s1  1948404040   13339556 406819060     4%    /
        /dev/disk3s5    1948404040 1513775600 406819060    79%    /System/Volumes/Data
        """
    }

    func testParsesLinuxFrame() throws {
        let sample = try XCTUnwrap(MachineStatsParser.parse(linuxFrame(procs: [
            "1 0 510868 67 2970 systemd",
            "1505544 1 12147843 218622007 6226 herdr",
            "2154624 2154609 1274 321300832 3585 codex-x86_64-un",
            "4242 1 10 500 100 Web Content (x)",
        ])))
        XCTAssertEqual(sample.os, "Linux")
        XCTAssertEqual(sample.host, "cloud-dev")
        XCTAssertEqual(sample.samplerPID, 177389)
        XCTAssertEqual(sample.cpuCount, 8)
        XCTAssertEqual(sample.load, [12.70, 15.27, 15.60])
        XCTAssertEqual(sample.clock, 3369422.72)
        XCTAssertEqual(sample.memTotalBytes, 65792224 * 1024)
        XCTAssertEqual(sample.memUsedBytes, (65792224 - 23923008) * 1024)
        XCTAssertEqual(sample.swapUsedBytes, (16777212 - 3963680) * 1024)
        XCTAssertEqual(sample.cpuTotalTicks, 871568343 + 8347356 + 167532790 + 1498856784 + 100368636 + 9836772)
        XCTAssertEqual(sample.cpuBusyTicks, 871568343 + 8347356 + 167532790 + 9836772)
        let herdr = try XCTUnwrap(sample.processes[1505544])
        XCTAssertEqual(herdr.ppid, 1)
        XCTAssertEqual(herdr.cpuTime, 121478.43, accuracy: 0.001)
        XCTAssertEqual(herdr.start, 218622007)
        XCTAssertEqual(herdr.rssBytes, 6226 * 4096)
        XCTAssertEqual(herdr.name, "herdr")
        XCTAssertEqual(sample.processes[4242]?.name, "Web Content (x)")
        // Same filesystem listed for / and $HOME: one disk.
        XCTAssertEqual(sample.disks.count, 1)
        XCTAssertEqual(sample.disks.first?.mount, "/")
        XCTAssertEqual(try XCTUnwrap(sample.disks.first).fraction, 0.898, accuracy: 0.001)
    }

    func testParsesDarwinFrame() throws {
        let sample = try XCTUnwrap(MachineStatsParser.parse(darwinFrame(
            procs: ["1 0 38896 59:10.74 launchd", "10550 54404 947264 1-02:03:04.50 claude"],
            args: [" 1671 /opt/homebrew/bin/node /x/agent-state.js --animate"]
        )))
        XCTAssertEqual(sample.os, "Darwin")
        XCTAssertEqual(sample.cpuCount, 18)
        XCTAssertEqual(sample.memTotalBytes, 137438953472)
        XCTAssertEqual(sample.memUsedBytes, (3703019 - 116719 + 1679498 + 465666) * 16384)
        XCTAssertEqual(sample.swapTotalBytes, 2048 * 1024 * 1024)
        XCTAssertEqual(sample.swapUsedBytes, 512 * 1024 * 1024)
        XCTAssertEqual(sample.uptime, 1791000000 - 1790953309)
        XCTAssertEqual(sample.load, [10.34, 10.80, 8.99])
        XCTAssertNil(sample.clock)
        XCTAssertEqual(sample.processes[1]?.cpuTime ?? 0, 3550.74, accuracy: 0.001)
        XCTAssertEqual(sample.processes[10550]?.cpuTime ?? 0, 86_400 + 7384.5, accuracy: 0.001)
        XCTAssertEqual(sample.processes[10550]?.rssBytes, 947264 * 1024)
        XCTAssertEqual(sample.arguments[1671], "/opt/homebrew/bin/node /x/agent-state.js --animate")
        XCTAssertEqual(sample.disks.map(\.mount), ["/", "/System/Volumes/Data"])
    }

    func testRejectsGarbage() {
        XCTAssertNil(MachineStatsParser.parse("Welcome to Ubuntu\nlast login: never"))
    }

    func testCPUSecondsFormats() {
        XCTAssertEqual(MachineStatsParser.cpuSeconds("0:00.04"), 0.04)
        XCTAssertEqual(MachineStatsParser.cpuSeconds("123:45.67") ?? 0, 7425.67, accuracy: 0.001)
        XCTAssertEqual(MachineStatsParser.cpuSeconds("01:02:03"), 3723)
        XCTAssertEqual(MachineStatsParser.cpuSeconds("2-00:00:01"), 172_801)
        XCTAssertNil(MachineStatsParser.cpuSeconds("abc"))
    }

    // MARK: Agent detection

    func testMatcherKnowsNativeAndScriptAgents() {
        XCTAssertEqual(AgentProcessMatcher.kind(name: "claude", arguments: nil), "claude")
        XCTAssertEqual(AgentProcessMatcher.kind(name: "codex-x86_64-un", arguments: nil), "codex")
        XCTAssertEqual(AgentProcessMatcher.kind(
            name: "node",
            arguments: "node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume"
        ), "claude")
        XCTAssertEqual(AgentProcessMatcher.kind(
            name: "node", arguments: "/opt/homebrew/bin/node --no-warnings /opt/homebrew/bin/codex"
        ), "codex")
        XCTAssertEqual(AgentProcessMatcher.kind(
            name: "bun", arguments: "bun /home/u/.bun/install/global/node_modules/@google/gemini-cli/dist/index.js"
        ), "gemini")
        XCTAssertEqual(AgentProcessMatcher.kind(name: "python3.12", arguments: "python3.12 /usr/local/bin/aider"), "aider")
    }

    func testMatcherKnowsClaudesVersionedBinary() {
        // Teammates and resumed sessions exec `~/.local/share/claude/versions/<v>`.
        XCTAssertEqual(AgentProcessMatcher.kind(
            name: "2.1.289",
            arguments: "/home/u/.local/share/claude/versions/2.1.289 --agent-id lane-A@session-e5 --agent-name lane-A"
        ), "claude")
        // bg-pty-host rewrites argv0 to "claude"; the sampler then sends no command line.
        XCTAssertEqual(AgentProcessMatcher.kind(name: "2.1.288", arguments: nil), "claude")
        XCTAssertNil(AgentProcessMatcher.kind(name: "1.4.2", arguments: "/opt/tool/1.4.2 --serve"))
        XCTAssertNil(AgentProcessMatcher.kind(name: "v2.1", arguments: nil))
    }

    func testMatcherIgnoresLookalikes() {
        // Component match, not substring: an MCP server named after Claude is not Claude.
        XCTAssertNil(AgentProcessMatcher.kind(
            name: "node", arguments: "/opt/homebrew/bin/node /Users/u/claude-coder-mac-mcp/dist/index.js mcp"
        ))
        XCTAssertNil(AgentProcessMatcher.kind(name: "node", arguments: "node /usr/bin/gitnexus mcp"))
        XCTAssertNil(AgentProcessMatcher.kind(name: "node", arguments: nil))
        XCTAssertNil(AgentProcessMatcher.kind(name: "pilot", arguments: nil))
        XCTAssertNil(AgentProcessMatcher.kind(name: "pythonista", arguments: "pythonista /x/claude"))
    }

    // MARK: MCP server detection

    /// Command lines recorded on cloud-dev (Ubuntu, Claude Code 2.1.296).
    func testMCPMatcherNamesServers() {
        func match(_ name: String, _ arguments: String?) -> MCPServerMatcher.Match? {
            MCPServerMatcher.match(name: name, arguments: arguments)
        }
        XCTAssertEqual(match("node", "node /usr/bin/graft mcp"), .init(name: "graft", isLauncher: false))
        XCTAssertEqual(match("node", "node /usr/bin/gitnexus serve --host 127.0.0.1 --port 4747")?.name, "gitnexus")
        XCTAssertEqual(match("node", "node /usr/bin/gitnexus mcp")?.name, "gitnexus")
        XCTAssertEqual(match("unpeel-mcp", "/home/u/.unpeel/bin/unpeel-mcp")?.name, "unpeel-mcp")
        XCTAssertEqual(
            match("node", "node /home/u/.npm/_npx/9a1b/node_modules/@playwright/mcp/cli.js"),
            .init(name: "playwright", isLauncher: false)
        )
        XCTAssertEqual(match("npm exec @playw", "npm exec @playwright/mcp@latest"), .init(name: "playwright", isLauncher: true))
        XCTAssertEqual(match("node", "node /opt/homebrew/bin/npx -y @modelcontextprotocol/server-filesystem /tmp")?.name, "server-filesystem")
        XCTAssertEqual(match("python3", "/usr/bin/python3 -m mcp_server_fetch")?.name, "mcp_server_fetch")
        XCTAssertEqual(match("xcrun", "xcrun mcpbridge")?.name, "mcpbridge")
        // npx's chain for kapture: npm exec → sh -c → node; shells are launchers too.
        XCTAssertEqual(match("npm exec kaptur", "npm exec kapture-mcp@latest bridge"), .init(name: "kapture-mcp", isLauncher: true))
        XCTAssertEqual(match("sh", "sh -c kapture-mcp bridge"), .init(name: "kapture-mcp", isLauncher: true))
        XCTAssertEqual(
            match("node", "node /h/.npm/_npx/937d/node_modules/.bin/kapture-mcp bridge"),
            .init(name: "kapture-mcp", isLauncher: false)
        )
        XCTAssertEqual(match("unpeel-host", "/h/.local/bin/unpeel-host __mcp_gate__ unified")?.name, "unpeel-host")
        // mcp-proxy as a stdio bridge to a shared HTTP server: named after its target.
        XCTAssertEqual(
            match("mcp-proxy", "/h/.local/share/uv/tools/mcp-proxy/bin/python /h/.local/bin/mcp-proxy --transport streamablehttp --log-level WARNING http://127.0.0.1:4748/mcp"),
            .init(name: "mcp-proxy → 127.0.0.1:4748", isLauncher: true)
        )
    }

    func testMCPMatcherIgnoresNonServers() {
        XCTAssertNil(MCPServerMatcher.match(name: "node", arguments: "node /usr/bin/graft build ."))
        XCTAssertNil(MCPServerMatcher.match(name: "node", arguments: "node /usr/bin/gitnexus analyze"))
        XCTAssertNil(MCPServerMatcher.match(name: "claude", arguments: "claude --mcp-config /h/.claude/mcp.json"))
        XCTAssertNil(MCPServerMatcher.match(name: "node", arguments: "node /x/vite.js --config mcp.json"))
        XCTAssertNil(MCPServerMatcher.match(name: "node", arguments: nil))
        XCTAssertNil(MCPServerMatcher.match(name: "vim", arguments: nil))
    }

    /// herdr (100) → bash (200) → claude (300) → graft mcp (310), mcp-proxy bridge (320);
    /// bash → claude (400) → graft mcp (410). Services under pid 1: mcp-proxy (800) →
    /// graft mcp (810), and gitnexus serve (900).
    func testMCPServersLeaveTheirAgentAndOther() throws {
        func processes(_ graftCPU: Double) -> [MachineProcess] {
            [
                proc(1, 0, "systemd", cpu: 0),
                proc(100, 1, "herdr", cpu: 0),
                proc(200, 100, "bash", cpu: 0),
                proc(300, 200, "claude", cpu: 0, rss: 500),
                proc(310, 300, "node", cpu: graftCPU, rss: 9_000),
                proc(320, 300, "mcp-proxy", cpu: 0, rss: 50),
                proc(400, 200, "claude", cpu: 0, rss: 400),
                proc(410, 400, "node", cpu: 0, rss: 3_000),
                proc(800, 1, "mcp-proxy", cpu: 0, rss: 60),
                proc(810, 800, "node", cpu: 0, rss: 1_100),
                proc(900, 1, "node", cpu: 0, rss: 500),
            ]
        }
        let arguments: [Int32: String] = [
            310: "node /usr/bin/graft mcp",
            320: "/h/.local/share/uv/tools/mcp-proxy/bin/python /h/.local/bin/mcp-proxy --transport streamablehttp http://127.0.0.1:4748/mcp",
            410: "node /usr/bin/graft mcp",
            800: "/h/.local/share/uv/tools/mcp-proxy/bin/python /h/.local/bin/mcp-proxy --host 127.0.0.1 --port 4748 --stateless --cwd /h/dev/repo /usr/bin/graft mcp",
            810: "/usr/bin/graft mcp",
            900: "node /usr/bin/gitnexus serve --host 127.0.0.1 --port 4747",
        ]
        let snapshot = MachineStatsComputer.snapshot(
            previous: sample(clock: 10, processes(0), arguments: arguments),
            current: sample(clock: 12, processes(1), arguments: arguments)
        )

        let claude = try XCTUnwrap(snapshot.groups.first { $0.kind == .agent("claude") })
        XCTAssertEqual(claude.usage.rssBytes, 500 + 400, "an agent's MCP servers are listed on their own")
        XCTAssertEqual(Set(claude.instances.map(\.rootPID)), [300, 400])
        XCTAssertEqual(snapshot.other.processCount, 2) // systemd, bash

        let servers = Dictionary(uniqueKeysWithValues: snapshot.mcpServers.map { ("\($0.name)|\($0.isService)", $0) })
        XCTAssertEqual(servers.count, 4)
        let perAgent = try XCTUnwrap(servers["graft|false"])
        XCTAssertEqual(perAgent.instances, 2)
        XCTAssertEqual(perAgent.usage.rssBytes, 9_000 + 3_000)
        XCTAssertEqual(perAgent.usage.cpuPercent, 50, accuracy: 0.001) // 1 s over 2 s
        let shared = try XCTUnwrap(servers["graft|true"], "the proxy service is named after the graft it runs")
        XCTAssertEqual(shared.instances, 1)
        XCTAssertEqual(shared.usage.rssBytes, 60 + 1_100)
        XCTAssertEqual(shared.usage.processCount, 2)
        XCTAssertEqual(servers["gitnexus|true"]?.usage.rssBytes, 500)
        XCTAssertEqual(servers["mcp-proxy → 127.0.0.1:4748|false"]?.usage.rssBytes, 50)
        XCTAssertEqual(snapshot.mcpServers.first?.name, "graft", "heaviest first")
        XCTAssertEqual(snapshot.mcpUsage.rssBytes, 9_000 + 3_000 + 60 + 1_100 + 500 + 50)
    }

    // MARK: Snapshot

    private func sample(
        clock: Double,
        busy: UInt64 = 0, total: UInt64 = 0,
        _ processes: [MachineProcess],
        arguments: [Int32: String] = [:],
        samplerPID: Int32 = 9000
    ) -> MachineSample {
        var sample = MachineSample()
        sample.os = "Linux"
        sample.cpuCount = 4
        sample.clock = clock
        sample.samplerPID = samplerPID
        sample.cpuBusyTicks = busy
        sample.cpuTotalTicks = total
        sample.processes = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        sample.arguments = arguments
        return sample
    }

    private func proc(_ pid: Int32, _ ppid: Int32, _ name: String, cpu: Double, rss: UInt64 = 1000, start: UInt64 = 1) -> MachineProcess {
        MachineProcess(pid: pid, ppid: ppid, cpuTime: cpu, start: start, rssBytes: rss, name: name)
    }

    /// herdr server (100) → shell (200) → claude (300) → node MCP (400), claude -p (500) → bash (600);
    /// herdr → bare shell (210) → vim (220); sampler sh (9000) → ps (9001).
    private func tree(cpuScale: Double) -> [MachineProcess] {
        [
            proc(1, 0, "systemd", cpu: 1),
            proc(100, 1, "herdr", cpu: 10 + 0.5 * cpuScale),
            proc(200, 100, "zsh", cpu: 1),
            proc(300, 200, "claude", cpu: 50 + 1 * cpuScale, rss: 500_000),
            proc(400, 300, "node", cpu: 3 + 0.2 * cpuScale, rss: 80_000),
            proc(500, 300, "claude", cpu: 4 + 0.3 * cpuScale, rss: 200_000),
            proc(600, 500, "bash", cpu: 0),
            proc(210, 100, "zsh", cpu: 1),
            proc(220, 210, "vim", cpu: 2 + 0.1 * cpuScale, rss: 7_000),
            proc(700, 1, "herdr", cpu: 1, rss: 3_000),
            proc(9000, 1, "sh", cpu: 0),
            proc(9001, 9000, "ps", cpu: 5 * cpuScale),
        ]
    }

    func testFirstSampleHasNoCPUButHasMemory() {
        let snapshot = MachineStatsComputer.snapshot(previous: nil, current: sample(clock: 10, tree(cpuScale: 0)))
        XCTAssertNil(snapshot.cpuPercent)
        let claude = snapshot.groups.first { $0.kind == .agent("claude") }
        XCTAssertEqual(claude?.usage.rssBytes, 500_000 + 80_000 + 200_000 + 1000)
        XCTAssertEqual(claude?.usage.cpuPercent, 0)
    }

    func testAgentOwnsItsDescendantsAndNestedAgents() throws {
        let before = sample(clock: 10, busy: 1000, total: 4000, tree(cpuScale: 0))
        let after = sample(clock: 12, busy: 1400, total: 4800, tree(cpuScale: 1))
        let snapshot = MachineStatsComputer.snapshot(previous: before, current: after)

        // /proc/stat: 400 busy of 800 ticks.
        XCTAssertEqual(try XCTUnwrap(snapshot.cpuPercent), 50, accuracy: 0.001)

        XCTAssertEqual(snapshot.groups.map(\.kind), [.herdr, .agent("claude")])
        let claude = try XCTUnwrap(snapshot.groups.last)
        // One instance: the nested `claude -p` (500) folds into 300.
        XCTAssertEqual(claude.instances.map(\.rootPID), [300])
        XCTAssertEqual(claude.instances.first?.lineage, [300, 200, 100])
        XCTAssertEqual(claude.usage.processCount, 4)
        // (1 + 0.2 + 0.3) s over 2 s = 75% of one core.
        XCTAssertEqual(claude.usage.cpuPercent, 75, accuracy: 0.001)

        let herdr = try XCTUnwrap(snapshot.groups.first { $0.kind == .herdr })
        XCTAssertEqual(herdr.usage.processCount, 2, "server + attach client; not the pane shells")
        XCTAssertEqual(herdr.usage.cpuPercent, 25, accuracy: 0.001)

        // Shells under herdr are "other"; the sampler's own ps is left out entirely.
        XCTAssertEqual(snapshot.other.processCount, 4) // systemd, zsh ×2, vim
        XCTAssertFalse(snapshot.topOther.contains { $0.name == "ps" || $0.name == "sh" })
        XCTAssertEqual(snapshot.topOther.first?.name, "vim")
    }

    func testSwarmTeammatesBelongToTheirLead() throws {
        // herdr (100) → bash (200) → lead claude (300). Claude's agent-team tmux
        // server (400) daemonized to pid 1; its teammates (410, 420) run under it.
        // A detached session (500, ppid 1) keeps its own swarm (600 → 610).
        let processes = [
            proc(1, 0, "systemd", cpu: 0),
            proc(100, 1, "herdr", cpu: 0),
            proc(200, 100, "bash", cpu: 0),
            proc(300, 200, "claude", cpu: 0, rss: 500),
            proc(400, 1, "tmux: server", cpu: 0, rss: 10),
            proc(410, 400, "2.1.289", cpu: 0, rss: 300),
            proc(420, 400, "2.1.289", cpu: 0, rss: 400),
            proc(500, 1, "2.1.288", cpu: 0, rss: 50),
            proc(600, 1, "tmux: server", cpu: 0, rss: 10),
            proc(610, 600, "2.1.288", cpu: 0, rss: 200),
        ]
        let arguments: [Int32: String] = [
            400: "tmux -L claude-swarm-300 new-session -d -s claude-swarm -n swarm-view",
            410: "/h/.local/share/claude/versions/2.1.289 --agent-id lane-A@s",
            420: "/h/.local/share/claude/versions/2.1.289 --agent-id lane-B@s",
            600: "tmux -L claude-swarm-500 new-session -d -s claude-swarm",
            610: "/h/.local/share/claude/versions/2.1.288 --agent-id lane-H29@t",
        ]
        let snapshot = MachineStatsComputer.snapshot(
            previous: nil, current: sample(clock: 1, processes, arguments: arguments)
        )
        let claude = try XCTUnwrap(snapshot.groups.first { $0.kind == .agent("claude") })
        XCTAssertEqual(Set(claude.instances.map(\.rootPID)), [300, 500])
        let lead = try XCTUnwrap(claude.instances.first { $0.rootPID == 300 })
        XCTAssertEqual(lead.usage.rssBytes, 500 + 10 + 300 + 400)
        XCTAssertEqual(lead.lineage, [300, 200, 100])
        let detached = try XCTUnwrap(claude.instances.first { $0.rootPID == 500 })
        XCTAssertEqual(detached.usage.rssBytes, 50 + 10 + 200)
        XCTAssertEqual(snapshot.other.processCount, 2) // systemd, bash
    }

    func testReusedPIDCountsFromZero() throws {
        let before = sample(clock: 10, [proc(42, 1, "claude", cpu: 500, start: 1)])
        let after = sample(clock: 12, [proc(42, 1, "claude", cpu: 1, start: 99)])
        let snapshot = MachineStatsComputer.snapshot(previous: before, current: after)
        XCTAssertEqual(try XCTUnwrap(snapshot.groups.first).usage.cpuPercent, 50, accuracy: 0.001)
    }

    func testParentCycleTerminates() {
        let looped = [proc(10, 11, "claude", cpu: 1), proc(11, 10, "node", cpu: 1)]
        let snapshot = MachineStatsComputer.snapshot(previous: nil, current: sample(clock: 1, looped))
        XCTAssertEqual(snapshot.groups.first?.usage.processCount, 2)
    }

    func testDarwinTotalCPUFallsBackToProcessSum() throws {
        var before = sample(clock: 0, [proc(5, 1, "a", cpu: 10), proc(6, 1, "b", cpu: 10)])
        var after = sample(clock: 0, [proc(5, 1, "a", cpu: 12), proc(6, 1, "b", cpu: 14)])
        for index in [0, 1] {
            var s = index == 0 ? before : after
            s.os = "Darwin"
            s.clock = nil
            s.cpuBusyTicks = nil
            s.cpuTotalTicks = nil
            s.receivedAt = index == 0 ? 100 : 102
            if index == 0 { before = s } else { after = s }
        }
        let snapshot = MachineStatsComputer.snapshot(previous: before, current: after)
        // (2 + 4) s over 2 s on 4 cores = 75%.
        XCTAssertEqual(try XCTUnwrap(snapshot.cpuPercent), 75, accuracy: 0.001)
    }

    func testProcessInfoPIDs() {
        let info: JSONValue = .object([
            "pane_id": .string("w1:p1"),
            "shell_pid": .number(200),
            "foreground_processes": .array([
                .object(["pid": .number(300), "name": .string("claude")]),
                .object(["pid": .number(301), "name": .string("claude")]),
            ]),
        ])
        XCTAssertEqual(HerdrService.processInfoPIDs(info), [200, 300, 301])
    }

    // MARK: Live sampler

    func testLocalSamplerProducesTwoFrames() async throws {
        var samples: [MachineSample] = []
        for try await sample in MachineStatsStream.samples(device: .local, interval: 1, frames: 2) {
            samples.append(sample)
        }
        XCTAssertEqual(samples.count, 2)
        let last = try XCTUnwrap(samples.last)
        XCTAssertGreaterThan(last.memTotalBytes, 0)
        XCTAssertGreaterThan(last.processes.count, 10)
        XCTAssertFalse(last.disks.isEmpty)
        let snapshot = MachineStatsComputer.snapshot(previous: samples.first, current: last)
        XCTAssertNotNil(snapshot.cpuPercent)
    }

    func testRemoteSamplerProducesFrames() async throws {
        guard let target = ProcessInfo.processInfo.environment["HERDRM_E2E_SSH_TARGET"] else {
            throw XCTSkip("HERDRM_E2E_SSH_TARGET not set")
        }
        let device = Device(name: "e2e-remote", kind: .ssh(target: target))
        var samples: [MachineSample] = []
        for try await sample in MachineStatsStream.samples(device: device, interval: 1, frames: 2) {
            samples.append(sample)
        }
        XCTAssertEqual(samples.count, 2)
        let snapshot = MachineStatsComputer.snapshot(previous: samples.first, current: samples[1])
        XCTAssertNotNil(snapshot.cpuPercent)
        XCTAssertGreaterThan(snapshot.memTotalBytes, 0)
        XCTAssertFalse(snapshot.disks.isEmpty)
    }

    func testCancellingStopsTheSampler() async throws {
        let task = Task {
            var count = 0
            for try await _ in MachineStatsStream.samples(device: .local, interval: 1) {
                count += 1
                if count == 1 { break }
            }
            return count
        }
        let count = try await task.value
        XCTAssertEqual(count, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "herdrm-stats 1 0"]
        let output = Pipe()
        pgrep.standardOutput = output
        try pgrep.run()
        pgrep.waitUntilExit()
        let pids = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(pids.trimmingCharacters(in: .whitespacesAndNewlines), "", "sampler still running")
    }
}
