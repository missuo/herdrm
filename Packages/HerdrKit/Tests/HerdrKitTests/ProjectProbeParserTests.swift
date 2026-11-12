import XCTest
@testable import HerdrKit

final class ProjectProbeParserTests: XCTestCase {
    func testParsesSSWithTwoPIDsOnOneSocketAndNoUsersField() {
        let lines = [
            #"LISTEN 0      511                      127.0.0.1:3100  0.0.0.0:* users:(("next-server (v1",pid=3678507,fd=22))"#,
            #"LISTEN 0      2048                     127.0.0.1:8100  0.0.0.0:* users:(("python3",pid=3995699,fd=3),("python3",pid=3672770,fd=3))"#,
            "LISTEN 0      4096                   100.64.0.7:4000  0.0.0.0:*",
        ]
        XCTAssertEqual(ProjectProbeParser.parseSS(lines), [
            ProbeListener(bind: "127.0.0.1", port: 3100, pids: [3678507]),
            ProbeListener(bind: "127.0.0.1", port: 8100, pids: [3995699, 3672770]),
            ProbeListener(bind: "100.64.0.7", port: 4000, pids: []),
        ])
    }

    func testParsesIPv6AndWildcardBinds() {
        let lines = [
            "LISTEN 0      4096                          [::]:9200     [::]:*",
            "LISTEN 0      511                              *:3000        *:*",
        ]
        let parsed = ProjectProbeParser.parseSS(lines)
        XCTAssertEqual(parsed.map(\.bind), ["::", "*"])
        XCTAssertEqual(parsed.map(\.port), [9200, 3000])
    }

    func testParsesPIDLines() {
        let lines = [
            "3678507\t3678404\tnext-server (v1\t/home/dev/acme-app/frontend\tacme-dev-fe.service\t/tmp/acme-frontend-3100.log\tnext-server (v14.2.35)   ",
            "3196354\t982\tnode\t/home/dev\tgitnexus.service\tsocket:[406372956]\tnode /usr/bin/gitnexus serve --host 127.0.0.1 --port 4747 ",
        ]
        let pids = ProjectProbeParser.parsePIDs(lines)
        let next = pids[3678507]
        XCTAssertEqual(next?.ppid, 3678404)
        XCTAssertEqual(next?.comm, "next-server (v1")
        XCTAssertEqual(next?.cwd, "/home/dev/acme-app/frontend")
        XCTAssertEqual(next?.unit, "acme-dev-fe.service")
        XCTAssertEqual(next?.stdoutPath, "/tmp/acme-frontend-3100.log")
        XCTAssertEqual(next?.args, "next-server (v14.2.35)")
        XCTAssertEqual(pids[3196354]?.stdoutPath, "socket:[406372956]")
        XCTAssertEqual(pids[3196354]?.args, "node /usr/bin/gitnexus serve --host 127.0.0.1 --port 4747")
    }

    func testParsesLsofListenersAndPSOnMac() {
        let lsof = ["p518", "ccrapportd", "f12", "n*:56684", "f15", "n*:56684", "p802", "caw-server", "f11", "n127.0.0.1:5600", "p876", "cGoogle Drive", "f29", "n[::1]:7679"]
        XCTAssertEqual(ProjectProbeParser.parseLsofListeners(lsof), [
            ProbeListener(bind: "*", port: 56684, pids: [518]),
            ProbeListener(bind: "127.0.0.1", port: 5600, pids: [802]),
            ProbeListener(bind: "::1", port: 7679, pids: [876]),
        ])
        let ps = [
            "  802     1 /Users/dev/bin/aw-server /Users/dev/bin/aw-server --port 5600",
            "  876   501 /Applications/Google Drive.app/Contents/MacOS/Google Drive /Applications/Google Drive.app/Contents/MacOS/Google Drive --flag",
        ]
        let lsofp = ["p802", "fcwd", "n/Users/dev/proj", "f1", "n/tmp/aw.log", "p876", "fcwd", "n/"]
        let procs = ProjectProbeParser.parsePS(ps, lsofLines: lsofp)
        XCTAssertEqual(procs[802]?.ppid, 1)
        XCTAssertEqual(procs[802]?.comm, "aw-server")
        XCTAssertEqual(procs[802]?.cwd, "/Users/dev/proj")
        XCTAssertEqual(procs[802]?.stdoutPath, "/tmp/aw.log")
        XCTAssertEqual(procs[802]?.args, "/Users/dev/bin/aw-server --port 5600")
        XCTAssertEqual(procs[876]?.comm, "Google Drive")
        XCTAssertEqual(procs[876]?.cwd, "/")
        XCTAssertNil(procs[876]?.stdoutPath)
    }

    func testParsesMacPSWithSeparateCommListing() {
        let ps = ["  855     1 /Applications/Google Drive.app/Contents/MacOS/Google Drive --auto_restart_count=1"]
        let comm = ["  855 /Applications/Google Drive.app/Contents/MacOS/Google Drive"]
        let procs = ProjectProbeParser.parsePS(ps, lsofLines: [], commLines: comm)
        XCTAssertEqual(procs[855]?.comm, "Google Drive")
        XCTAssertEqual(procs[855]?.args, "/Applications/Google Drive.app/Contents/MacOS/Google Drive --auto_restart_count=1")
    }

    func testParsesContainersIncludingUnlabeled() {
        let id = String(repeating: "5d", count: 32)
        let lines = [
            "\(id)\tacme-frontend\tacme/frontend:1.0.0\trunning\tUp 26 seconds (healthy)\t100.64.0.7:4000->3000/tcp\tacme\tfrontend\t/home/dev/acme-app\t/home/dev/acme-app/docker-compose.yml,/home/dev/acme-app/docker-compose.override.yml",
            "f2a8bde9b3bc\tacme-dev-proxy\tcaddy:2-alpine\trunning\tUp 7 days\t\t\t\t\t",
        ]
        let containers = ProjectProbeParser.parseContainers(lines)
        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].name, "acme-frontend")
        XCTAssertEqual(containers[0].composeProject, "acme")
        XCTAssertEqual(containers[0].composeService, "frontend")
        XCTAssertEqual(containers[0].workingDir, "/home/dev/acme-app")
        XCTAssertEqual(containers[0].configFiles.count, 2)
        XCTAssertTrue(containers[0].status.contains("(healthy)"))
        XCTAssertEqual(containers[0].ports, "100.64.0.7:4000->3000/tcp")
        XCTAssertEqual(containers[1].name, "acme-dev-proxy")
        XCTAssertEqual(containers[1].ports, "")
        XCTAssertNil(containers[1].composeProject)
        XCTAssertNil(containers[1].composeService)
        XCTAssertNil(containers[1].workingDir)
        XCTAssertEqual(containers[1].configFiles, [])
    }

    func testParsesComposeList() {
        let json = #"[{"Name":"acme","Status":"exited(4), running(24)","ConfigFiles":"/home/dev/acme-app/a.yml,/home/dev/acme-app/b.yml"}]"#
        let projects = ProjectProbeParser.parseComposeList(json)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "acme")
        XCTAssertEqual(projects[0].status, "exited(4), running(24)")
        XCTAssertEqual(projects[0].configFiles, ["/home/dev/acme-app/a.yml", "/home/dev/acme-app/b.yml"])
    }

    func testParsesParallelsVmpalLima() {
        let prl = """
        [
        \t{
        \t\t"uuid": "aaaaaaaa-1111-4222-8333-444444444444",
        \t\t"name": "Win 11 Pro",
        \t\t"status": "suspended",
        \t\t"ip_configured": "   "
        \t}
        ]
        """
        XCTAssertEqual(ProjectProbeParser.parseParallels(prl), [
            ProbeVM(provider: .parallels, id: "aaaaaaaa-1111-4222-8333-444444444444", name: "Win 11 Pro", state: "suspended", ip: nil),
        ])
        let vmpal = #"{"vms":[{"activity":null,"guest":"linux","id":"0A0B0C0D-1111-4222-8333-444455556666","internetAddress":"192.168.64.6","name":"Ubuntu VM","state":"running"}]}"#
        XCTAssertEqual(ProjectProbeParser.parseVmpal(vmpal), [
            ProbeVM(provider: .vmpal, id: "0A0B0C0D-1111-4222-8333-444455556666", name: "Ubuntu VM", state: "running", ip: "192.168.64.6"),
        ])
        let lima = #"{"name":"default","hostname":"lima-default","status":"Stopped","vmType":"vz","cpus":4}"#
        XCTAssertEqual(ProjectProbeParser.parseLima(lima), [
            ProbeVM(provider: .lima, id: "default", name: "default", state: "Stopped", ip: nil),
        ])
    }

    func testHostSectionLinuxAndDarwin() {
        let linux = """
        @@pp-begin 1
        @@host
        os Linux
        hostname devbox
        home /home/dev
        ncpu 8
        load 17.59 17.00 16.36
        memtotal_kb 65786260
        memavail_kb 30722896
        uptime 680936.53
        docker 29.8.1
        systemd degraded
        @@pp-end
        """
        let host = ProjectProbeParser.parse(linux).host
        XCTAssertEqual(host?.home, "/home/dev")
        XCTAssertEqual(host?.os, "Linux")
        XCTAssertEqual(host?.hostname, "devbox")
        XCTAssertEqual(host?.cpuCount, 8)
        XCTAssertEqual(host?.load1, 17.59)
        XCTAssertEqual(host?.memTotalKB, 65786260)
        XCTAssertEqual(host?.memAvailableKB, 30722896)
        XCTAssertEqual(host?.uptimeSeconds, 680936.53)
        XCTAssertEqual(host?.dockerServerVersion, "29.8.1")
        XCTAssertEqual(host?.systemdUserState, "degraded")

        let darwin = """
        @@pp-begin 1
        @@host
        os Darwin
        hostname mac
        ncpu 18
        load 48.87 25.14 19.66
        memtotal_kb 134217728
        boottime 1792102918
        docker_error Cannot connect to the Docker daemon at unix:///Users/dev/.docker/run/docker.sock. Is the docker daemon running?
        @@pp-end
        """
        let mac = ProjectProbeParser.parse(darwin).host
        XCTAssertEqual(mac?.os, "Darwin")
        XCTAssertNotNil(mac?.dockerError)
        XCTAssertNil(mac?.dockerServerVersion)
        XCTAssertNil(mac?.memAvailableKB)
        XCTAssertNil(mac?.systemdUserState)
        XCTAssertNotNil(mac?.uptimeSeconds)
    }

    func testEnvEntriesAreKeysOnlyAndDropSecretKeys() {
        let text = """
        @@pp-begin 1
        @@env /home/dev/acme-app/.env
        3:API_PORT
        4:DB_PASSWORD
        5:PUBLIC_URL
        6:DB_URL=https://u:p@ss@db/
        7:API_TOKEN=x
        @@pp-end
        """
        let probe = ProjectProbeParser.parse(text)
        // An older script's `=value` tail is discarded rather than kept.
        XCTAssertEqual(probe.envEntries, [
            ProbeEnvEntry(file: "/home/dev/acme-app/.env", line: 3, key: "API_PORT", value: ""),
            ProbeEnvEntry(file: "/home/dev/acme-app/.env", line: 5, key: "PUBLIC_URL", value: ""),
            ProbeEnvEntry(file: "/home/dev/acme-app/.env", line: 6, key: "DB_URL", value: ""),
        ])
    }

    func testStripUserinfoRemovesCredentials() {
        XCTAssertEqual(ProjectProbeParser.stripUserinfo("https://u:p@host/"), "https://host/")
        XCTAssertEqual(ProjectProbeParser.stripUserinfo("https://u:p@ss@db/"), "https://db/")
        XCTAssertEqual(ProjectProbeParser.stripUserinfo("http://localhost:3000/a@b"), "http://localhost:3000/a@b")
    }

    func testListenerWithoutProcessParses() {
        let probe = ProjectProbeParser.parse("""
        @@pp-begin 1
        @@listeners ss
        LISTEN 0      4096                       0.0.0.0:80    0.0.0.0:*
        @@pp-end
        """)
        XCTAssertEqual(probe.listeners, [ProbeListener(bind: "0.0.0.0", port: 80, pids: [])])
    }

    func testTruncatedFrameIsPartial() {
        let probe = ProjectProbeParser.parse("""
        @@pp-begin 1
        @@host
        os Linux
        hostname devbox
        @@listeners ss
        LISTEN 0      4096                       0.0.0.0:80
        """)
        XCTAssertTrue(probe.partial)
        XCTAssertEqual(probe.host?.hostname, "devbox")
    }

    func testErrorSectionIsRecorded() {
        let probe = ProjectProbeParser.parse("""
        @@pp-begin 1
        @@containers
        @@error docker
        Cannot connect to the Docker daemon at unix:///var/run/docker.sock.
        @@pp-end
        """)
        XCTAssertFalse(probe.partial)
        XCTAssertTrue(probe.errors["docker"]?.contains("Cannot connect") == true)
    }

    func testFilesToolsAndAbsentSections() {
        let probe = ProjectProbeParser.parse("""
        @@pp-begin 1
        @@tools
        git /usr/bin/git
        docker -
        @@files /home/dev/acme-app
        /home/dev/acme-app/package.json
        /home/dev/acme-app/frontend/package.json
        @@vms parallels
        @@absent prlctl
        @@pp-end
        """)
        XCTAssertEqual(probe.tools, ["git": "/usr/bin/git", "docker": "-"])
        XCTAssertEqual(probe.files["/home/dev/acme-app"]?.count, 2)
        XCTAssertEqual(probe.absent, ["prlctl"])
        XCTAssertEqual(probe.vms, [])
    }

    func testUnknownAtAtLineIsDataNotAHeader() {
        let probe = ProjectProbeParser.parse("""
        @@pp-begin 1
        @@files /home/dev/acme-app
        /home/dev/acme-app/package.json
        @@pp-end-fake
        @@pp-end
        @@files /x
        @@pp-end
        """)
        // `@@pp-end` is a real header, so the frame ends at the first one; `@@pp-end-fake` is a file line.
        XCTAssertFalse(probe.partial)
        XCTAssertEqual(probe.files["/home/dev/acme-app"], ["/home/dev/acme-app/package.json", "@@pp-end-fake"])
    }

    func testTruncatedFrameWithBogusFileLineStaysPartial() {
        let probe = ProjectProbeParser.parse("@@pp-begin 1\n@@files /r\n@@bogus\n/r/a\n")
        XCTAssertTrue(probe.partial)
        XCTAssertEqual(probe.files["/r"], ["@@bogus", "/r/a"])
    }

    func testGarbageJSONSectionsParseToNothing() {
        let probe = ProjectProbeParser.parse("""
        @@pp-begin 1
        @@compose
        not json at all
        @@vms parallels
        <html>
        @@vms vmpal
        {"vms": 3}
        @@vms lima
        nope
        @@pp-end
        """)
        XCTAssertEqual(probe.composeProjects, [])
        XCTAssertEqual(probe.vms, [])
    }

    func testDarwinBoottimeRawLineGivesUptime() {
        let probe = ProjectProbeParser.parse("@@pp-begin 1\n@@host\nos Darwin\nnow 1792110000\nboottime 1792102918\n@@pp-end\n")
        XCTAssertEqual(probe.host?.uptimeSeconds, 7082)
    }

    func testPSWithoutCommEntryKeepsArgv0() {
        let procs = ProjectProbeParser.parsePS(["  9 1 /usr/bin/foo --x", " 10 1 /bin/bar"], lsofLines: [], commLines: ["10 /bin/bar"])
        XCTAssertEqual(procs[9]?.comm, "foo")
        XCTAssertEqual(procs[9]?.args, "/usr/bin/foo --x")
    }
}
