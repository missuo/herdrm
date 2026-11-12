import XCTest
@testable import HerdrKit

final class ProjectClassifierTests: XCTestCase {
    private let root = "/home/dev/acme-app"
    private let worktree = "/home/dev/acme-app/.claude/worktrees/conntest"
    private let devbox = Device(name: "devbox", kind: .ssh(target: "dev@devbox"))
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func identity(root: String? = nil, worktrees: [String]? = nil) -> ProjectIdentity {
        let main = root ?? self.root
        return ProjectIdentity(
            deviceID: devbox.id, root: main,
            worktreeRoots: worktrees ?? [main, main + "/.claude/worktrees/conntest"])
    }

    private let ssLines = [
        #"LISTEN 0      511                      127.0.0.1:3100  0.0.0.0:* users:(("next-server (v1",pid=3678507,fd=22))"#,
        #"LISTEN 0      2048                     127.0.0.1:8100  0.0.0.0:* users:(("python3",pid=3995699,fd=3),("python3",pid=3672770,fd=3))"#,
        #"LISTEN 0      511                      127.0.0.1:4747  0.0.0.0:* users:(("node",pid=3196354,fd=22))"#,
        #"LISTEN 0      511                      127.0.0.1:38885 0.0.0.0:* users:(("dolt",pid=4100100,fd=9))"#,
        "LISTEN 0      4096                   100.64.0.7:4000  0.0.0.0:*",
    ]

    private let pidLines = [
        "3678507\t3678404\tnext-server (v1\t/home/dev/acme-app/frontend\tacme-dev-fe.service\t/tmp/acme-frontend-3100.log\tnext-server (v14.2.35)",
        "3678404\t1\tnode\t/home/dev/acme-app/frontend\tacme-dev-fe.service\t/tmp/acme-frontend-3100.log\tnpm run dev",
        "3995699\t982\tpython3\t/home/dev/acme-app/packages/api\tacme-dev-api.service\t/tmp/acme-api-8100.log\tpython3 -m uvicorn acme_api.main_simple:app --host 127.0.0.1 --port 8100 --reload --reload-dir acme_api",
        "3672770\t3995699\tpython3\t/home/dev/acme-app/packages/api\tacme-dev-api.service\t/tmp/acme-api-8100.log\tpython3 -c from multiprocessing.spawn import spawn_main; spawn_main",
        "3196354\t982\tnode\t/home/dev\tgitnexus.service\tsocket:[406372956]\tnode /usr/bin/gitnexus serve --host 127.0.0.1 --port 4747",
        "4100100\t1\tdolt\t/home/dev/acme-app/_dev/beads\t\t\tdolt sql-server --port 38885",
    ]

    private let frontendContainerLine =
        "5d5d5d5d5d5d\tacme-frontend\tacme/frontend:1.0.0\trunning\tUp 26 seconds (healthy)\t100.64.0.7:4000->3000/tcp\tacme\tfrontend\t/home/dev/acme-app\t/home/dev/acme-app/docker-compose.yml,/home/dev/acme-app/docker-compose.override.yml"
    private let proxyContainerLine =
        "f2a8bde9b3bc\tacme-dev-proxy\tcaddy:2-alpine\trunning\tUp 7 days\t\t\t\t\t"

    private let hostFrame = """
    @@pp-begin 1
    @@host
    os Linux
    hostname devbox
    ncpu 8
    load 17.59 17.00 16.36
    memtotal_kb 65786260
    memavail_kb 30722896
    uptime 680936.53
    docker 29.8.1
    systemd degraded
    @@pp-end
    """

    private func filler(_ project: String, count: Int, running: Int, workingDir: String = "/home/dev/acme-app") -> [ProbeContainer] {
        (0..<count).map { index in
            ProbeContainer(
                id: "\(project)-id-\(index)", name: "\(project)-svc\(index)-1", image: "img",
                state: index < running ? "running" : "exited", status: "Up",
                composeProject: project, composeService: "svc\(index)", workingDir: workingDir,
                configFiles: [workingDir + "/docker-compose.yml"])
        }
    }

    /// The devbox fixture: two dev servers, tooling, an unattributed docker-published port,
    /// compose groups `acme` (24/28) and `acme-lake` (2/5), and one unlabeled proxy container.
    private func devboxProbe() -> ProjectProbe {
        var containers = ProjectProbeParser.parseContainers([frontendContainerLine])
        containers += filler("acme", count: 27, running: 23)
        containers += filler("acme-lake", count: 5, running: 2)
        containers += ProjectProbeParser.parseContainers([proxyContainerLine])
        var probe = ProjectProbe()
        probe.host = ProjectProbeParser.parse(hostFrame).host
        probe.listeners = ProjectProbeParser.parseSS(ssLines)
        probe.processes = ProjectProbeParser.parsePIDs(pidLines)
        probe.composeProjects = [
            ProbeComposeProject(name: "acme", status: "exited(4), running(24)", configFiles: ["/home/dev/acme-app/docker-compose.yml"]),
            ProbeComposeProject(name: "acme-lake", status: "running(2), exited(3)", configFiles: ["/home/dev/acme-app/docker-compose.yml"]),
        ]
        probe.containers = containers
        return probe
    }

    private func classify(
        _ probe: ProjectProbe, localVMs: ProjectProbe? = nil, identity: ProjectIdentity? = nil,
        device: Device? = nil, overrides: ProjectOverrides = ProjectOverrides()
    ) -> ProjectSnapshot {
        ProjectClassifier.classify(
            probe: probe, localVMs: localVMs, identity: identity ?? self.identity(),
            device: device ?? devbox, overrides: overrides, now: now)
    }

    // MARK: - Dev servers

    func testDevboxHotReloadRows() {
        let snapshot = classify(devboxProbe())
        XCTAssertEqual(snapshot.devServers.count, 2)
        let next = snapshot.devServers[0]
        XCTAssertEqual(next.signature, "next@frontend")
        XCTAssertEqual(next.role, .frontend)
        XCTAssertEqual(next.framework, "next")
        XCTAssertEqual(next.port, 3100)
        XCTAssertEqual(next.bind, "127.0.0.1")
        XCTAssertFalse(next.isPublicBind)
        XCTAssertEqual(next.pids, [3678507])
        XCTAssertEqual(next.ownerPID, 3678507)
        XCTAssertEqual(next.cwdRelative, "frontend")
        XCTAssertEqual(next.unit, "acme-dev-fe.service")
        XCTAssertEqual(next.logPath, "/tmp/acme-frontend-3100.log")
        XCTAssertTrue(next.hotReload)
        XCTAssertEqual(next.urls, [])

        let api = snapshot.devServers[1]
        XCTAssertEqual(api.signature, "uvicorn@packages/api")
        XCTAssertEqual(api.role, .backend)
        XCTAssertEqual(api.framework, "uvicorn")
        XCTAssertEqual(api.port, 8100)
        XCTAssertEqual(api.pids, [3995699, 3672770])
        XCTAssertEqual(api.ownerPID, 3995699)
        XCTAssertEqual(api.cwdRelative, "packages/api")
        XCTAssertEqual(api.unit, "acme-dev-api.service")
        XCTAssertEqual(api.logPath, "/tmp/acme-api-8100.log")
        XCTAssertTrue(api.hotReload)
        XCTAssertEqual(api.urls, [])
    }

    func testUvicornParentAndChildCollapseToOneRow() {
        let snapshot = classify(devboxProbe())
        XCTAssertEqual(snapshot.devServers.filter { $0.port == 8100 }.count, 1)
    }

    func testToolingGoesToOtherListeners() {
        let snapshot = classify(devboxProbe())
        let all = snapshot.devServers + snapshot.otherListeners
        XCTAssertFalse(all.contains { $0.port == 4747 })
        XCTAssertFalse(snapshot.devServers.contains { $0.port == 38885 })
        let dolt = snapshot.otherListeners.first { $0.port == 38885 }
        XCTAssertEqual(dolt?.role, .tooling)
        XCTAssertEqual(dolt?.framework, "dolt")
        XCTAssertEqual(dolt?.signature, "dolt@_dev/beads")
    }

    func testListenerWithoutPidAttributesToPublishedContainerPort() {
        let snapshot = classify(devboxProbe())
        XCTAssertFalse(snapshot.otherListeners.contains { $0.port == 4000 })
        let frontend = snapshot.compose.flatMap(\.containers).first { $0.name == "acme-frontend" }
        XCTAssertTrue(frontend?.ports.contains { $0.hostPort == 4000 } == true)

        var orphan = devboxProbe()
        orphan.containers = []
        let unattributed = classify(orphan).otherListeners.first { $0.port == 4000 }
        XCTAssertEqual(unattributed?.role, .other)
        XCTAssertEqual(unattributed?.framework, "unknown")
        XCTAssertEqual(unattributed?.cwdRelative, "")
    }

    func testWorktreeListenerGetsWtPrefixedSignature() {
        var probe = ProjectProbe()
        probe.listeners = [ProbeListener(bind: "127.0.0.1", port: 3200, pids: [50])]
        probe.processes = [50: ProbeProcess(pid: 50, ppid: 1, comm: "node", cwd: worktree + "/frontend", args: "vite --port 3200")]
        let row = classify(probe).devServers.first
        XCTAssertEqual(row?.signature, "vite@wt:frontend")
        XCTAssertEqual(row?.cwdRelative, "wt:frontend")
    }

    func testPidWithoutCwdUsesParentCwd() {
        var probe = ProjectProbe()
        probe.listeners = [ProbeListener(bind: "127.0.0.1", port: 3200, pids: [51])]
        probe.processes = [
            50: ProbeProcess(pid: 50, ppid: 1, comm: "bash", cwd: root + "/web", args: "bash"),
            51: ProbeProcess(pid: 51, ppid: 50, comm: "node", cwd: nil, args: "vite --port 3200"),
        ]
        XCTAssertEqual(classify(probe).devServers.first?.cwdRelative, "web")
    }

    // MARK: - Role, URLs, ports

    func testRoleRules() {
        XCTAssertTrue(ProjectClassifier.role(comm: "next-server (v1", args: "next-server (v14.2.35)", parentArgs: "npm run dev", port: 3100) == (.frontend, "next", true))
        XCTAssertTrue(ProjectClassifier.role(comm: "python3", args: "python3 -m uvicorn a:app --reload", parentArgs: nil, port: 8100) == (.backend, "uvicorn", true))
        XCTAssertTrue(ProjectClassifier.role(comm: "python3", args: "python3 -m uvicorn a:app", parentArgs: nil, port: 8100) == (.backend, "uvicorn", false))
        XCTAssertEqual(ProjectClassifier.role(comm: "node", args: "node /usr/bin/gitnexus serve", parentArgs: nil, port: 4747).0, .tooling)
        XCTAssertEqual(ProjectClassifier.role(comm: "node", args: "mcp-proxy --port 9000", parentArgs: nil, port: 9000).0, .tooling)
        XCTAssertEqual(ProjectClassifier.role(comm: "foo", args: "foo", parentArgs: nil, port: 3999).0, .frontend)
        XCTAssertEqual(ProjectClassifier.role(comm: "foo", args: "foo", parentArgs: nil, port: 8999).0, .backend)
        XCTAssertEqual(ProjectClassifier.role(comm: "foo", args: "foo", parentArgs: nil, port: 5432).0, .other)
        XCTAssertEqual(ProjectClassifier.role(comm: "foo", args: "foo", parentArgs: nil, port: 5432).framework, "foo")
    }

    func testPublishedPortsParsing() {
        XCTAssertEqual(ProjectClassifier.publishedPorts("100.64.0.7:4000->3000/tcp, [::]:5432->5432/tcp"), [
            PublishedPort(hostIP: "100.64.0.7", hostPort: 4000, containerPort: 3000, proto: "tcp"),
            PublishedPort(hostIP: "::", hostPort: 5432, containerPort: 5432, proto: "tcp"),
        ])
        XCTAssertEqual(ProjectClassifier.publishedPorts("0.0.0.0:8000-8001->8000-8001/tcp"), [
            PublishedPort(hostIP: "0.0.0.0", hostPort: 8000, containerPort: 8000, proto: "tcp"),
            PublishedPort(hostIP: "0.0.0.0", hostPort: 8001, containerPort: 8001, proto: "tcp"),
        ])
        XCTAssertEqual(ProjectClassifier.publishedPorts("0.0.0.0:8000-8002->8000-8001/tcp"), [])
        XCTAssertEqual(ProjectClassifier.publishedPorts("3000/tcp"), [])
        XCTAssertEqual(ProjectClassifier.publishedPorts(""), [])
    }

    func testPublicBindGetsDerivedURL() {
        let devbox2 = Device(name: "devbox2", kind: .ssh(target: "dev@devbox2"))
        let tree = "/home/dev/dev/acme-app"
        var probe = ProjectProbe()
        probe.listeners = [ProbeListener(bind: "0.0.0.0", port: 3000, pids: [70])]
        probe.processes = [70: ProbeProcess(pid: 70, ppid: 1, comm: "next-server (v1", cwd: tree + "/frontend", args: "next-server (v14.2.35)")]
        let id = identity(root: tree)
        let remote = classify(probe, identity: id, device: devbox2).devServers.first
        XCTAssertEqual(remote?.isPublicBind, true)
        XCTAssertEqual(remote?.urls, [ProjectURL(label: "http://devbox2:3000", url: "http://devbox2:3000", source: .detected, loopbackOnHost: false)])

        let local = classify(probe, identity: id, device: .local).devServers.first
        XCTAssertEqual(local?.urls.first?.url, "http://localhost:3000")

        probe.listeners = [ProbeListener(bind: "127.0.0.1", port: 3000, pids: [70])]
        XCTAssertEqual(classify(probe, identity: id, device: .local).devServers.first?.urls.first?.url, "http://localhost:3000")
        XCTAssertNil(ProjectClassifier.detectedURL(bind: "127.0.0.1", port: 3000, device: devbox2))
        XCTAssertNil(ProjectClassifier.detectedURL(bind: "::1", port: 3000, device: devbox2))
        XCTAssertEqual(ProjectClassifier.detectedURL(bind: "::", port: 3000, device: devbox2)?.url, "http://devbox2:3000")
    }

    func testOverrideURLComesFirstAndMarksStaleWhenPortGone() {
        var overrides = ProjectOverrides()
        overrides.services["next@frontend"] = .init(url: "https://hot.devbox.example")
        let live = classify(devboxProbe(), overrides: overrides)
        XCTAssertEqual(
            live.devServers.first?.urls.first,
            ProjectURL(label: "https://hot.devbox.example", url: "https://hot.devbox.example", source: .override, loopbackOnHost: false))
        XCTAssertEqual(live.staleOverrides, [])

        var gone = devboxProbe()
        gone.listeners.removeAll { $0.port == 3100 }
        let stale = classify(gone, overrides: overrides)
        XCTAssertFalse(stale.devServers.contains { $0.signature == "next@frontend" })
        XCTAssertEqual(stale.staleOverrides, ["next@frontend"])
    }

    func testOverrideLabelIsUsedWhenSet() {
        var overrides = ProjectOverrides()
        overrides.services["next@frontend"] = .init(url: "https://hot.devbox.example", label: "Hot")
        XCTAssertEqual(classify(devboxProbe(), overrides: overrides).devServers.first?.urls.first?.label, "Hot")
    }

    func testHiddenServiceIsFlagged() {
        var overrides = ProjectOverrides()
        overrides.services["dolt@_dev/beads"] = .init(hidden: true)
        let snapshot = classify(devboxProbe(), overrides: overrides)
        XCTAssertEqual(snapshot.otherListeners.first { $0.port == 38885 }?.isHidden, true)
        XCTAssertEqual(snapshot.devServers.first?.isHidden, false)
    }

    // MARK: - Compose and containers

    func testComposeMatchedByNameWhenWorkingDirBasenameEqualsRoot() {
        let id = identity(root: "/home/dev/dev/acme-app")
        let snapshot = classify(devboxProbe(), identity: id)
        let acme = snapshot.compose.first { $0.name == "acme" }
        XCTAssertEqual(acme?.match, .name)
        XCTAssertEqual(acme?.running, 24)
        XCTAssertEqual(acme?.total, 28)
        XCTAssertEqual(snapshot.compose.first { $0.name == "acme-lake" }?.match, .name)
        XCTAssertEqual(snapshot.otherCompose, [])
    }

    func testComposeMatchedByPathOnDevbox2() {
        let tree = "/home/dev/dev/acme-app"
        var probe = ProjectProbe()
        probe.composeProjects = [ProbeComposeProject(name: "acme-app", status: "running(1)", configFiles: [tree + "/docker-compose.yml"])]
        probe.containers = filler("acme-app", count: 1, running: 1, workingDir: tree)
        let snapshot = classify(probe, identity: identity(root: tree))
        XCTAssertEqual(snapshot.compose.map(\.match), [.path])
        XCTAssertEqual(snapshot.compose.first?.workingDir, tree)
    }

    func testUnrelatedComposeIsOtherAndAttachedPromotesIt() {
        var probe = ProjectProbe()
        probe.composeProjects = [ProbeComposeProject(name: "billing", status: "running(2), exited(1)", configFiles: ["/srv/billing/compose.yml"])]
        let plain = classify(probe)
        XCTAssertEqual(plain.compose, [])
        XCTAssertEqual(plain.otherCompose.first?.name, "billing")
        // No containers listed: the compose ls status string is the fallback.
        XCTAssertEqual(plain.otherCompose.first?.running, 2)
        XCTAssertEqual(plain.otherCompose.first?.total, 3)

        var overrides = ProjectOverrides()
        overrides.attachedCompose = ["billing"]
        let attached = classify(probe, overrides: overrides)
        XCTAssertEqual(attached.compose.map(\.match), [.attached])
        XCTAssertEqual(attached.otherCompose, [])
    }

    func testDetachedComposeMovesToOtherSoAttachBringsItBack() {
        var overrides = ProjectOverrides()
        overrides.detachedCompose = ["acme-lake"]
        let snapshot = classify(devboxProbe(), overrides: overrides)
        XCTAssertFalse(snapshot.compose.contains { $0.name == "acme-lake" })
        XCTAssertEqual(snapshot.otherCompose.first { $0.name == "acme-lake" }?.match, nil)
        XCTAssertTrue(snapshot.compose.contains { $0.name == "acme" })

        // A group matched by name can be detached and is offered back, never lost.
        overrides.detachedCompose = ["acme"]
        let byName = classify(devboxProbe(), overrides: overrides)
        XCTAssertNotNil(byName.otherCompose.first { $0.name == "acme" })
        XCTAssertFalse(byName.compose.contains { $0.name == "acme" })

        // Attaching clears the detach (the model does this) and the group is matched again.
        overrides.detachedCompose = []
        overrides.attachedCompose = ["acme-lake"]
        XCTAssertEqual(classify(devboxProbe(), overrides: overrides).compose.first { $0.name == "acme-lake" }?.match, .path)
    }

    func testDetachingAnAttachedGroupOnlyDropsTheAttachment() {
        var probe = ProjectProbe()
        probe.composeProjects = [ProbeComposeProject(name: "billing", status: "running(1)", configFiles: ["/srv/billing/compose.yml"])]
        var overrides = ProjectOverrides()
        overrides.attachedCompose = ["billing"]
        XCTAssertEqual(classify(probe, overrides: overrides).compose.map(\.match), [.attached])
        overrides.attachedCompose = []
        let detached = classify(probe, overrides: overrides)
        XCTAssertEqual(detached.compose, [])
        XCTAssertEqual(detached.otherCompose.map(\.name), ["billing"])
    }

    func testFilesAndEnvFromUnrelatedRootsAreDropped() {
        var probe = devboxProbe()
        probe.files = [
            "/home/dev": ["/home/dev/Desktop/package.json", "/home/dev/lima.yaml"],
            root: [root + "/package.json"],
            worktree: [worktree + "/Makefile"],
            root + "-old": [root + "-old/package.json"],
        ]
        probe.envEntries = [
            ProbeEnvEntry(file: "/home/dev/.env", line: 1, key: "HOME_PORT", value: ""),
            ProbeEnvEntry(file: root + "/.env", line: 2, key: "API_PORT", value: ""),
            ProbeEnvEntry(file: root + "-old/.env", line: 3, key: "OLD_PORT", value: ""),
        ]
        let snapshot = classify(probe)
        XCTAssertEqual(snapshot.files, [root + "/package.json", worktree + "/Makefile"].sorted())
        XCTAssertEqual(snapshot.envEntries.map(\.key), ["API_PORT"])
    }

    func testLimaConfigOutsideTheProjectDoesNotDeclareVMs() {
        var local = ProjectProbe()
        local.vms = [ProbeVM(provider: .lima, id: "default", name: "default", state: "Running", ip: nil)]
        var probe = devboxProbe()
        probe.files = ["/home/dev": ["/home/dev/other/lima.yaml"]]
        XCTAssertEqual(classify(probe, localVMs: local).vms, [])
        probe.files = [root: [root + "/lima.yaml"]]
        XCTAssertEqual(classify(probe, localVMs: local).vms.map(\.match), [.declared])
    }

    func testUnlabeledContainerIsSuggestedByProjectToken() {
        let snapshot = classify(devboxProbe())
        XCTAssertEqual(snapshot.suggestedContainers.map(\.name), ["acme-dev-proxy"])
        XCTAssertEqual(snapshot.attachedContainers, [])

        var attach = ProjectOverrides()
        attach.attachedContainers = ["acme-dev-proxy"]
        let attached = classify(devboxProbe(), overrides: attach)
        XCTAssertEqual(attached.attachedContainers.map(\.name), ["acme-dev-proxy"])
        XCTAssertEqual(attached.suggestedContainers, [])

        var dismiss = ProjectOverrides()
        dismiss.dismissedSuggestions = ["acme-dev-proxy"]
        let dismissed = classify(devboxProbe(), overrides: dismiss)
        XCTAssertEqual(dismissed.attachedContainers, [])
        XCTAssertEqual(dismissed.suggestedContainers, [])
    }

    func testContainerHealthAndURLs() {
        let snapshot = classify(devboxProbe())
        let frontend = snapshot.compose.flatMap(\.containers).first { $0.name == "acme-frontend" }
        XCTAssertEqual(frontend?.health, "healthy")
        XCTAssertEqual(frontend?.service, "frontend")
        XCTAssertEqual(frontend?.urls.first?.url, "http://devbox:4000")
        XCTAssertNil(snapshot.suggestedContainers.first?.health)
    }

    // MARK: - VMs

    func testVMsAttachedDeclaredSuggested() {
        let ubuntu = ProbeVM(provider: .vmpal, id: "0A0B0C0D-1111-4222-8333-444455556666", name: "Ubuntu VM", state: "running", ip: "192.168.64.6")
        let debian = ProbeVM(provider: .vmpal, id: "11111111-0000-0000-0000-000000000001", name: "Debian VM", state: "stopped")
        let fedora = ProbeVM(provider: .vmpal, id: "11111111-0000-0000-0000-000000000002", name: "Fedora VM", state: "stopped")
        let win = ProbeVM(provider: .parallels, id: "aaaaaaaa-1111-4222-8333-444444444444", name: "Win 11 Pro", state: "suspended")
        let tests = ProbeVM(provider: .parallels, id: "bbbbbbbb-1111-4222-8333-555555555555", name: "acme tests", state: "stopped")
        let lima = ProbeVM(provider: .lima, id: "default", name: "default", state: "Stopped")
        var local = ProjectProbe()
        local.vms = [ubuntu, debian, fedora, win, tests, lima]

        var probe = devboxProbe()
        probe.files = [root: [root + "/package.json", root + "/lima.yaml"]]
        var overrides = ProjectOverrides()
        overrides.attachedVMs = [AttachedVM(provider: .vmpal, id: ubuntu.id, name: ubuntu.name)]

        let snapshot = classify(probe, localVMs: local, overrides: overrides)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.vms.map { ($0.id, $0.match) })
        XCTAssertEqual(byID["vmpal:\(ubuntu.id)"], .attached)
        XCTAssertEqual(byID["parallels:\(tests.id)"], .suggested)
        XCTAssertEqual(byID["lima:default"], .declared)
        XCTAssertEqual(snapshot.vms.count, 3)
        XCTAssertEqual(Set(snapshot.otherVMs.map(\.name)), ["Debian VM", "Fedora VM", "Win 11 Pro"])
        XCTAssertFalse(snapshot.vms.contains { $0.match == nil })

        let noLocal = classify(probe, localVMs: nil, overrides: overrides)
        XCTAssertEqual(noLocal.vms, [])
        XCTAssertEqual(noLocal.otherVMs, [])
    }

    func testParallelsAndVmpalAreNeverDeclared() {
        var local = ProjectProbe()
        local.vms = [
            ProbeVM(provider: .parallels, id: "p", name: "Win 11 Pro", state: "stopped"),
            ProbeVM(provider: .vmpal, id: "v", name: "Ubuntu VM", state: "stopped"),
        ]
        var probe = ProjectProbe()
        probe.files = [root: [root + "/lima.yaml"]]
        let snapshot = classify(probe, localVMs: local)
        XCTAssertEqual(snapshot.vms, [])
        XCTAssertEqual(snapshot.otherVMs.map(\.name), ["Win 11 Pro", "Ubuntu VM"])
    }

    // MARK: - Host and secrets

    func testHostHealthLanes() {
        let snapshot = classify(devboxProbe())
        XCTAssertEqual(snapshot.host.hostname, "devbox")
        XCTAssertEqual(snapshot.host.cpuCount, 8)
        XCTAssertEqual(snapshot.host.load1, 17.59)
        XCTAssertEqual(try XCTUnwrap(snapshot.host.memUsedFraction), 0.533, accuracy: 0.01)
        XCTAssertEqual(snapshot.host.dockerServerVersion, "29.8.1")
        XCTAssertEqual(snapshot.host.systemdUserState, "degraded")
        XCTAssertEqual(snapshot.host.hotLanes, LaneCount(up: 2, total: 2))
        XCTAssertEqual(snapshot.host.dockerLanes, LaneCount(up: 26, total: 33))
        XCTAssertEqual(snapshot.probedAt, now)
        XCTAssertFalse(snapshot.partial)
    }

    func testHostHealthWithoutHostBlockHasNoMemFraction() {
        var probe = ProjectProbe()
        probe.host = ProbeHost(hostname: "mac", memTotalKB: 100)
        XCTAssertNil(classify(probe).host.memUsedFraction)
        XCTAssertNil(classify(ProjectProbe()).host.hostname)
    }

    func testSecretsNeverReachSnapshot() {
        var probe = devboxProbe()
        probe.envEntries = ProjectProbeParser.parse("""
        @@pp-begin 1
        @@env /home/dev/acme-app/.env
        3:API_PORT
        4:DB_PASSWORD
        @@pp-end
        """).envEntries
        let snapshot = classify(probe)
        XCTAssertEqual(snapshot.envEntries.map(\.key), ["API_PORT"])
        XCTAssertFalse(snapshot.envEntries.contains { $0.key.uppercased().contains("PASSWORD") })
    }

    func testServiceOverrideDecodesMinimalJSONAndRoundTrips() throws {
        let decoder = JSONDecoder()
        let minimal = try decoder.decode(ServiceOverride.self, from: Data(#"{"url":"x"}"#.utf8))
        XCTAssertEqual(minimal, ServiceOverride(url: "x"))
        let empty = try decoder.decode(ProjectOverrides.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, ProjectOverrides())
        var full = ProjectOverrides()
        full.services["a@b"] = .init(url: "x", hidden: true)
        full.attachedCompose = ["acme"]
        full.envFile = ".env"
        let again = try decoder.decode(ProjectOverrides.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(again, full)
        let partial = try decoder.decode(ProjectOverrides.self, from: Data(#"{"services":{"a@b":{"hidden":true}}}"#.utf8))
        XCTAssertEqual(partial.services["a@b"]?.hidden, true)
        XCTAssertEqual(partial.attachedCompose, [])
    }

    func testChildUsesOwnCommandLineBeforeParent() {
        let result = ProjectClassifier.role(
            comm: "python3", args: "python3 -m uvicorn app:app --port 8100",
            parentArgs: #"concurrently "next dev" "uvicorn app:app --reload""#, port: 8100)
        XCTAssertEqual(result.0, .backend)
        XCTAssertEqual(result.framework, "uvicorn")
        XCTAssertFalse(result.hotReload)
        // Nothing in its own command line: the parent decides.
        XCTAssertEqual(ProjectClassifier.role(comm: "node", args: "node server.js", parentArgs: "npm run vite", port: 5000).framework, "vite")
    }

    func testMcpIsMatchedAsWordNotPathSubstring() {
        XCTAssertEqual(ProjectClassifier.role(comm: "node", args: "node /srv/mcpanel/server.js", parentArgs: nil, port: 3001).0, .frontend)
        XCTAssertEqual(ProjectClassifier.role(comm: "node", args: "node /usr/bin/mcp-proxy", parentArgs: nil, port: 3001).0, .tooling)
    }

    func testVMSuggestionMatchesWholeWordsOnly() {
        var local = ProjectProbe()
        local.vms = [
            ProbeVM(provider: .parallels, id: "h", name: "Happy VM", state: "stopped"),
            ProbeVM(provider: .parallels, id: "t", name: "acme tests", state: "stopped"),
        ]
        let snapshot = classify(ProjectProbe(), localVMs: local)
        XCTAssertEqual(snapshot.vms.map(\.name), ["acme tests"])
        XCTAssertEqual(snapshot.otherVMs.map(\.name), ["Happy VM"])
    }

    func testSecondSameFamilyListenerGetsPortSuffixAndKeepsOverride() {
        var probe = ProjectProbe()
        probe.listeners = [
            ProbeListener(bind: "0.0.0.0", port: 3100, pids: [60]),
            ProbeListener(bind: "0.0.0.0", port: 3101, pids: [61]),
        ]
        probe.processes = [
            60: ProbeProcess(pid: 60, ppid: 1, comm: "next-server (v1", cwd: root + "/frontend", args: "next-server"),
            61: ProbeProcess(pid: 61, ppid: 1, comm: "next-server (v1", cwd: root + "/frontend", args: "next-server"),
        ]
        var overrides = ProjectOverrides()
        overrides.services["next@frontend"] = .init(url: "https://hot.devbox.example")
        let snapshot = classify(probe, overrides: overrides)
        XCTAssertEqual(snapshot.devServers.map(\.signature), ["next@frontend#3100", "next@frontend#3101"])
        XCTAssertEqual(snapshot.devServers.map { $0.urls.first?.url }, ["https://hot.devbox.example", "https://hot.devbox.example"])
        XCTAssertEqual(snapshot.staleOverrides, [])
    }

    func testPortSuffixedOverrideSurvivesWhenSiblingStops() {
        var probe = ProjectProbe()
        probe.listeners = [ProbeListener(bind: "0.0.0.0", port: 3101, pids: [61])]
        probe.processes = [
            61: ProbeProcess(pid: 61, ppid: 1, comm: "next-server (v1", cwd: root + "/frontend", args: "next-server"),
        ]
        var overrides = ProjectOverrides()
        overrides.services["next@frontend#3101"] = .init(url: "https://hot.devbox.example", hidden: true)
        let snapshot = classify(probe, overrides: overrides)
        XCTAssertEqual(snapshot.devServers.map(\.signature), ["next@frontend"])
        XCTAssertEqual(snapshot.devServers.first?.urls.first?.url, "https://hot.devbox.example")
        XCTAssertEqual(snapshot.devServers.first?.isHidden, true)
        XCTAssertEqual(snapshot.staleOverrides, [])
    }

    func testSiblingDirectoryWithSharedPrefixIsNotOwned() {
        var probe = ProjectProbe()
        probe.listeners = [ProbeListener(bind: "0.0.0.0", port: 3300, pids: [80])]
        probe.processes = [80: ProbeProcess(pid: 80, ppid: 1, comm: "node", cwd: "/home/dev/acme-app2/x", args: "vite")]
        let snapshot = classify(probe)
        XCTAssertEqual(snapshot.devServers, [])
        XCTAssertEqual(snapshot.otherListeners, [])
    }

    func testLocalLoopbackURLIsFlaggedLoopbackAndIPv6TargetIsBracketed() {
        XCTAssertEqual(ProjectClassifier.detectedURL(bind: "127.0.0.1", port: 3000, device: .local)?.loopbackOnHost, true)
        XCTAssertEqual(ProjectClassifier.detectedURL(bind: "0.0.0.0", port: 3000, device: .local)?.loopbackOnHost, false)
        let v6 = Device(name: "v6", kind: .ssh(target: "dev@fd00::7"))
        XCTAssertEqual(ProjectClassifier.detectedURL(bind: "::", port: 3000, device: v6)?.url, "http://[fd00::7]:3000")
    }

    func testPartialAndErrorsSurfaceAsWarnings() {
        var probe = ProjectProbe(partial: true)
        probe.errors = ["docker": "Cannot connect to the Docker daemon\nsecond line"]
        let snapshot = classify(probe)
        XCTAssertTrue(snapshot.partial)
        XCTAssertEqual(snapshot.warnings, ["docker: Cannot connect to the Docker daemon"])
    }
}
