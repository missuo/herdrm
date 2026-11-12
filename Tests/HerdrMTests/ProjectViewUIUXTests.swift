import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `ProjectView` with an injected snapshot and reads it back the way VoiceOver does.
@MainActor
final class ProjectViewUIUXTests: XCTestCase {
    private let devbox = Device(name: "devbox", kind: .ssh(target: "dev@devbox"))
    private let root = "/home/dev/acme-app"

    private func server(
        _ signature: String, framework: String, port: Int, role: ServiceRole = .frontend, hot: Bool = true,
        publicBind: Bool = false, hidden: Bool = false
    ) -> DevServer {
        DevServer(
            signature: signature, role: role, framework: framework, bind: publicBind ? "0.0.0.0" : "127.0.0.1",
            port: port, isPublicBind: publicBind, pids: [4101], ownerPID: 4101, cwdRelative: "frontend",
            unit: hot ? "acme-dev-fe.service" : nil, logPath: hot ? "/tmp/acme-frontend-3100.log" : nil,
            hotReload: hot,
            urls: [ProjectURL(label: "http://localhost:\(port)", url: "http://localhost:\(port)", source: .detected, loopbackOnHost: !publicBind)],
            isHidden: hidden)
    }

    private func container(
        _ id: String, name: String, service: String?, state: String = "running", health: String? = "healthy",
        image: String = "nginx:1.27",
        ports: [PublishedPort] = [PublishedPort(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")],
        statusText: String = "Up 2 hours"
    ) -> ContainerRow {
        ContainerRow(
            id: id, name: name, image: image, service: service, state: state, statusText: statusText,
            health: health, ports: ports, urls: [])
    }

    private func snapshot(
        extraServers: [DevServer] = [], compose: [ComposeGroup]? = nil, attached: [ContainerRow] = [],
        suggested: [ContainerRow] = []
    ) -> ProjectSnapshot {
        let web = container("c1", name: "acme-web-1", service: "web")
        let groups = compose ?? [
            ComposeGroup(name: "acme", workingDir: root, configFiles: ["\(root)/compose.yaml"], match: .name, running: 1, total: 1, containers: [web])
        ]
        return ProjectSnapshot(
            identity: ProjectIdentity(deviceID: devbox.id, root: root, worktreeRoots: [root]),
            probedAt: Date(), partial: false,
            host: HostHealth(
                hostname: "devbox", cpuCount: 8, load1: 0.7, memUsedFraction: 0.42,
                dockerServerVersion: "27.3.1", hotLanes: LaneCount(up: 1, total: 1), dockerLanes: LaneCount(up: 1, total: 1)),
            devServers: [server("next-server@frontend", framework: "Next.js", port: 3100)] + extraServers,
            otherListeners: [server("python3@scratch", framework: "python3", port: 9000, role: .other, hot: false)],
            compose: groups,
            otherCompose: [], attachedContainers: attached, suggestedContainers: suggested,
            vms: [VMRow(provider: .lima, vmID: "acme-vm", name: "acme-vm", state: "running", ip: "192.168.5.15", match: .declared)],
            otherVMs: [], files: ["compose.yaml"], envEntries: [], warnings: [], staleOverrides: [])
    }

    private func host(_ model: AppModel, width: CGFloat = 760, height: CGFloat = 900) -> (NSWindow, NSHostingView<AnyView>) {
        let view = NSHostingView(rootView: AnyView(ProjectView(model: model, polling: false).frame(width: width, height: height)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ProjectViewHarness \(UUID().uuidString)"
        window.contentView = view
        window.orderFrontRegardless()
        return (window, view)
    }

    /// Settles until `id` is in the accessibility tree or `timeout` elapses; returns the elements either way.
    private func waitFor(_ window: NSWindow, id: String, timeout: TimeInterval = 3) -> [AccessibilityProbe.Element] {
        let end = Date().addingTimeInterval(timeout)
        var all = elements(in: window)
        while element(all, id: id) == nil, Date() < end {
            settle(0.2)
            all = elements(in: window)
        }
        return all
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }

    private func elements(in window: NSWindow) -> [AccessibilityProbe.Element] {
        AccessibilityProbe.elements(in: window)
    }

    private func texts(_ elements: [AccessibilityProbe.Element]) -> Set<String> {
        Set(elements.flatMap { [$0.value, $0.name].compactMap { $0 } })
    }

    private func element(_ elements: [AccessibilityProbe.Element], id: String) -> AccessibilityProbe.Element? {
        elements.first { $0.identifier == id }
    }

    private func model(entry: ProjectInspectorModel.Entry?, device: Device? = nil) throws -> (AppModel, SpaceRef) {
        let device = device ?? devbox
        let model = AppModel()
        model.devices = [device]
        var state = DeviceSessionState()
        state.workspaces = [try JSONDecoder().decode(
            WorkspaceInfo.self,
            from: JSONSerialization.data(withJSONObject: ["workspace_id": "w1", "number": 1, "label": "acme"]))]
        model.sessions[device.id] = state
        let space = SpaceRef(deviceID: device.id, workspaceID: "w1")
        model.selectedSpace = space
        model.detailMode = .project
        if let entry {
            model.projects._setEntryForTesting(space: space, key: "\(device.id.uuidString):\(root)", entry: entry)
        }
        return (model, space)
    }

    func testRendersSectionsBadgesAndRefresh() throws {
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()

        let elements = AccessibilityProbe.elements(in: window)
        let texts = Set(elements.flatMap { [$0.value, $0.name].compactMap { $0 } })
        for expected in ["Hot reload", "Docker", "Hosts & VMs", "Other listeners", "loopback only", "matched by name"] {
            XCTAssertTrue(texts.contains(expected), "missing \(expected) in \(texts.sorted())")
        }
        let refresh = try XCTUnwrap(elements.first { $0.role == "AXButton" && $0.name == "Refresh" }, "no Refresh button")
        XCTAssertEqual(refresh.isEnabled, true)
    }

    func testNoSpaceShowsEmptyState() throws {
        let (model, _) = try model(entry: nil)
        model.selectedSpace = nil
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let texts = texts(elements(in: window))
        XCTAssertTrue(texts.contains("No Space selected"), "\(texts.sorted())")
        XCTAssertFalse(texts.contains("Hot reload"))
    }

    func testFailedProbeKeepsStaleSnapshotUnderBanner() throws {
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(), state: .failed("ssh timed out"), lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let texts = texts(elements(in: window))
        XCTAssertTrue(texts.contains("ssh timed out"), "\(texts.sorted())")
        XCTAssertTrue(texts.contains("Hot reload"), "stale snapshot must stay visible")
    }

    func testHiddenRowsLeaveTheListsAndSitInACollapsedDisclosure() throws {
        var snap = snapshot()
        var hiddenDev = server("vite@web", framework: "vite-hidden-fw", port: 5173)
        hiddenDev.isHidden = true
        var hiddenOther = server("redis@", framework: "redis-hidden-fw", port: 6379, role: .other, hot: false)
        hiddenOther.isHidden = true
        snap.devServers.append(hiddenDev)
        snap.otherListeners.append(hiddenOther)
        let entry = ProjectInspectorModel.Entry(snapshot: snap, state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()

        let texts = texts(elements(in: window))
        XCTAssertTrue(texts.contains("Hidden (2)"), "no Hidden disclosure in \(texts.sorted())")
        XCTAssertFalse(texts.contains("vite-hidden-fw"), "hidden dev server is still listed")
        XCTAssertFalse(texts.contains("redis-hidden-fw"), "hidden listener is still listed")
        XCTAssertTrue(texts.contains("Next.js"), "visible server must stay")
        XCTAssertTrue(texts.contains("Other listeners"), "the visible listener keeps its section")
    }

    func testSummaryStripCounts() throws {
        let hidden = server("vite@web", framework: "vite-hidden-fw", port: 5173, hidden: true)
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(extraServers: [hidden]), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        let strip = try XCTUnwrap(element(all, id: "project.summary"), "no summary strip")
        let label = try XCTUnwrap(strip.name)
        for part in ["Dev servers 1", "Containers 1/1", "VMs 1", "Hosts 1"] {
            XCTAssertTrue(label.contains(part), "\(part) missing in \(label)")
        }
        XCTAssertFalse(label.contains("2"), "hidden server leaked into the count: \(label)")
    }

    func testDevServerRowShowsTagsAndMoreMenu() throws {
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        let shown = texts(all)
        for expected in ["hot reload", "acme-dev-fe.service", "acme-frontend-3100.log", "Frontend"] {
            XCTAssertTrue(shown.contains(expected), "missing \(expected) in \(shown.sorted())")
        }
        XCTAssertNotNil(all.first { $0.name == "More" }, "no More menu on the dev server row")
        XCTAssertNil(all.first { $0.role == "AXButton" && $0.name == "Hide" }, "Hide must live in the menu, not inline")
    }

    func testContainerTileClickRevealsDetailStrip() throws {
        let long = container("c2", name: "acme-very-long-container-name-for-truncation-1", service: nil, state: "exited", health: nil, statusText: "Exited (0) 2 days ago")
        let web = container("c1", name: "acme-web-1", service: "web")
        let groups = [
            ComposeGroup(name: "acme", workingDir: root, configFiles: [], match: .name, running: 1, total: 2, containers: [web, long]),
            ComposeGroup(name: "acme-lake", workingDir: root, configFiles: [], match: .name, running: 0, total: 0, containers: []),
        ]
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(compose: groups), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        var all = elements(in: window)
        XCTAssertNil(element(all, id: "project.containerDetail"))
        XCTAssertNil(all.first { $0.role == "AXButton" && $0.name == "Close" }, "tiles carry no buttons; the strip is the only action surface")
        let tile = try XCTUnwrap(element(all, id: "project.container.c1"))
        AccessibilityProbe.press(tile)
        settle()
        all = elements(in: window)
        XCTAssertNotNil(element(all, id: "project.containerDetail"))
        let texts = texts(all)
        XCTAssertTrue(texts.contains("nginx:1.27"), "\(texts.sorted())")
        XCTAssertTrue(texts.contains("0.0.0.0:8080 → 80/tcp"), "\(texts.sorted())")
        AccessibilityProbe.press(try XCTUnwrap(element(all, id: "project.container.c1")))
        settle()
        XCTAssertNil(element(elements(in: window), id: "project.containerDetail"), "second click must close the strip")
    }

    func testUnhealthyTileIsLabelled() throws {
        let sick = container("c1", name: "acme-web-1", service: "web", health: "unhealthy")
        let groups = [ComposeGroup(name: "acme", workingDir: root, configFiles: [], match: .name, running: 1, total: 1, containers: [sick])]
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(compose: groups), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let tile = try XCTUnwrap(element(elements(in: window), id: "project.container.c1"))
        XCTAssertEqual(tile.name, "web, running, unhealthy")
    }

    func testSelectionIsPrunedWhenTheContainerDisappears() throws {
        let web = container("c1", name: "acme-web-1", service: "web")
        let groups = [ComposeGroup(name: "acme", workingDir: root, configFiles: [], match: .name, running: 1, total: 1, containers: [web])]
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(compose: groups), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, space) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        AccessibilityProbe.press(try XCTUnwrap(element(elements(in: window), id: "project.container.c1")))
        settle()
        XCTAssertNotNil(element(elements(in: window), id: "project.containerDetail"))
        let replaced = container("c9", name: "acme-web-1", service: "web")
        var next = snapshot(compose: [ComposeGroup(name: "acme", workingDir: root, configFiles: [], match: .name, running: 1, total: 1, containers: [replaced])])
        next.probedAt = Date().addingTimeInterval(5)
        model.projects._setEntryForTesting(space: space, key: "\(devbox.id.uuidString):\(root)", entry: ProjectInspectorModel.Entry(snapshot: next, state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil))
        settle()
        XCTAssertNil(element(elements(in: window), id: "project.containerDetail"), "stale selection must be pruned")
        XCTAssertNotNil(element(elements(in: window), id: "project.container.c9"))
    }

    func testHostCardShowsMetersAndProviderTag() throws {
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        let texts = texts(all)
        for expected in ["Lima", "Load", "Memory", "acme-vm", "devbox"] {
            XCTAssertTrue(texts.contains(expected), "missing \(expected) in \(texts.sorted())")
        }
        XCTAssertNotNil(element(all, id: "project.host.meter.load"))
        XCTAssertNotNil(element(all, id: "project.host.meter.memory"))
    }

    func testLinksCardPaginatesPastTwelveChips() throws {
        // Fourteen public URLs on one container, nothing else: 14 links make two pages, and the
        // short page keeps the Links card inside the 900 pt window the probe can read.
        let urls = (0..<14).map { ProjectURL(label: "http://localhost:\(3200 + $0)", url: "http://localhost:\(3200 + $0)", source: .detected, loopbackOnHost: false) }
        var web = container("c1", name: "acme-web-1", service: "web")
        web.urls = urls
        var snap = snapshot(compose: [ComposeGroup(name: "acme", workingDir: root, configFiles: [], match: .name, running: 1, total: 1, containers: [web])])
        snap.devServers = []
        snap.otherListeners = []
        snap.vms = []
        let entry = ProjectInspectorModel.Entry(snapshot: snap, state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        var all = waitFor(window, id: "project.link.http://localhost:3200")
        XCTAssertTrue(texts(all).contains("1/2"), "page indicator missing; ids: \(all.compactMap(\.identifier).filter { $0.hasPrefix("project.link") })")
        XCTAssertNotNil(element(all, id: "project.link.http://localhost:3200"), "first page shows the first chips")
        XCTAssertNil(element(all, id: "project.link.http://localhost:3213"), "page 2 chip must not be on page 1")
        AccessibilityProbe.press(try XCTUnwrap(all.first { $0.role == "AXButton" && $0.name == "Next page" }))
        settle()
        all = waitFor(window, id: "project.link.http://localhost:3213")
        XCTAssertTrue(texts(all).contains("2/2"), "page indicator did not advance; ids: \(all.compactMap(\.identifier).filter { $0.hasPrefix("project.link") })")
        XCTAssertNotNil(element(all, id: "project.link.http://localhost:3213"))
        XCTAssertNil(element(all, id: "project.link.http://localhost:3200"))
    }

    func testFilesCardPaginatesPastTwelveRows() throws {
        var snap = snapshot()
        snap.files = (0..<20).map { "file-\($0).yaml" }
        snap.devServers = []
        snap.otherListeners = []
        snap.vms = []
        let entry = ProjectInspectorModel.Entry(snapshot: snap, state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        var all = waitFor(window, id: "project.files.page")
        var shown = texts(all)
        XCTAssertTrue(shown.contains("1/2"), "page indicator missing: \(shown.sorted())")
        XCTAssertTrue(shown.contains("file-0.yaml"))
        XCTAssertFalse(shown.contains("file-19.yaml"), "page 2 row must not be on page 1")
        AccessibilityProbe.press(try XCTUnwrap(all.first { $0.role == "AXButton" && $0.name == "Next page" }))
        settle()
        all = elements(in: window)
        shown = texts(all)
        XCTAssertTrue(shown.contains("2/2"))
        XCTAssertTrue(shown.contains("file-19.yaml"))
        XCTAssertFalse(shown.contains("file-0.yaml"))
    }

    func testLinksCardShowsChips() throws {
        let open = server("vite@web2", framework: "vite", port: 3200, publicBind: true)
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(extraServers: [open]), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        XCTAssertTrue(texts(all).contains("Links"))
        XCTAssertNotNil(element(all, id: "project.section.links"))
        let chips = all.filter { $0.role == "AXButton" && $0.name == "http://localhost:3200" }
        XCTAssertFalse(chips.isEmpty, "public URL must be a clickable chip")
        XCTAssertTrue(all.filter { $0.role == "AXButton" && $0.name == "http://localhost:3100" }.isEmpty, "remote loopback URL must not be a button anywhere")
        XCTAssertTrue(texts(all).contains("http://localhost:3100"), "remote loopback URL stays visible as plain text")
    }

    func testEnvKeysAreUniquePerFileInFirstSeenOrder() {
        var snap = snapshot()
        snap.envEntries = [
            ProbeEnvEntry(file: ".env", line: 1, key: "DB_URL", value: "a"),
            ProbeEnvEntry(file: ".env", line: 2, key: "API_KEY", value: "b"),
            ProbeEnvEntry(file: ".env", line: 3, key: "DB_URL", value: "c"),
            ProbeEnvEntry(file: ".env.local", line: 1, key: "DB_URL", value: "d"),
        ]
        XCTAssertEqual(projectEnvKeys(snap), [".env": ["DB_URL", "API_KEY"], ".env.local": ["DB_URL"]])
    }

    func testOverviewShowsLanesForRemoteSpace() throws {
        let hidden = server("vite@web", framework: "vite-hidden-fw", port: 5173, hidden: true)
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(extraServers: [hidden]), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        for id in ["project.overview.node.mac", "project.overview.node.host", "project.overview.lane.hot", "project.overview.lane.docker", "project.overview.lane.vms"] {
            XCTAssertNotNil(element(all, id: id), "missing \(id)")
        }
        let texts = texts(all)
        for expected in ["Architecture", "Mac", "devbox", "ssh"] { XCTAssertTrue(texts.contains(expected), "missing \(expected)") }
        XCTAssertFalse(texts.contains("vite-hidden-fw"), "hidden server leaked into the overview")
        let hotValue = try XCTUnwrap(element(all, id: "project.overview.lane.hot")?.value)
        XCTAssertTrue(hotValue.contains("Next.js"), hotValue)
        XCTAssertFalse(hotValue.contains("vite-hidden-fw"), hotValue)
    }

    func testOverviewCollapsesToThisMacForLocalSpace() throws {
        var snap = snapshot()
        snap.identity = ProjectIdentity(deviceID: Device.local.id, root: root, worktreeRoots: [root])
        let entry = ProjectInspectorModel.Entry(snapshot: snap, state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry, device: .local)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        XCTAssertNil(element(all, id: "project.overview.node.mac"))
        XCTAssertNotNil(element(all, id: "project.overview.node.host"))
        let texts = texts(all)
        XCTAssertTrue(texts.contains("This Mac"))
        XCTAssertFalse(texts.contains("ssh"))
    }

    func testNarrowPaneKeepsEveryCardInsideTheWindow() throws {
        let long = container("c2", name: "acme-very-long-container-name-for-truncation-1", service: nil)
        let twins = [9092, 9093, 9094].flatMap { p in
            ["0.0.0.0", "::"].map { PublishedPort(hostIP: $0, hostPort: p, containerPort: p, proto: "tcp") }
        }
        let groups = [ComposeGroup(name: "acme", workingDir: root, configFiles: [], match: .name, running: 2, total: 2, containers: [container("c1", name: "acme-web-1", service: "web", ports: twins), long])]
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(compose: groups), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model, width: 500)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        let bounds = try XCTUnwrap(all.first { $0.role == "AXWindow" }?.frame)
        var checked = 0
        for element in all where element.identifier?.hasPrefix("project.") == true {
            // A hidden element legitimately has no frame.
            guard let frame = element.frame else { continue }
            checked += 1
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 0.5, "\(element.identifier!) clips left")
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.5, "\(element.identifier!) clips right")
        }
        XCTAssertGreaterThan(checked, 5, "the clipping check must actually see framed project elements")
        XCTAssertNotNil(element(all, id: "project.overview.lane.docker"))

        AccessibilityProbe.press(try XCTUnwrap(element(all, id: "project.container.c1")))
        settle()
        let strip = elements(in: window)
        XCTAssertNotNil(element(strip, id: "project.containerDetail"), "pressing the tile opens the detail strip")
        let stripBounds = try XCTUnwrap(strip.first { $0.role == "AXWindow" }?.frame)
        for element in strip where element.identifier?.hasPrefix("project.") == true {
            guard let frame = element.frame else { continue }
            XCTAssertGreaterThanOrEqual(frame.minX, stripBounds.minX - 0.5, "\(element.identifier!) clips left with the strip open")
            XCTAssertLessThanOrEqual(frame.maxX, stripBounds.maxX + 0.5, "\(element.identifier!) clips right with the strip open")
        }
    }

    func testDisplayPortsCollapsesDualStackTwins() {
        func p(_ ip: String, _ h: Int, _ c: Int, _ proto: String = "tcp") -> PublishedPort {
            PublishedPort(hostIP: ip, hostPort: h, containerPort: c, proto: proto)
        }
        let out = ContainerPorts.displayPorts([
            p("0.0.0.0", 9092, 9092), p("::", 9092, 9092), p("127.0.0.1", 5432, 5432),
            p("0.0.0.0", 53, 53, "udp"), p("::", 53, 53, "udp"), p("0.0.0.0", 53, 53, "tcp"),
        ])
        XCTAssertEqual(out, [p("0.0.0.0", 9092, 9092), p("127.0.0.1", 5432, 5432), p("0.0.0.0", 53, 53, "udp"), p("0.0.0.0", 53, 53, "tcp")])
        XCTAssertEqual(ContainerPorts.displayPorts([p("::", 80, 80)]), [p("0.0.0.0", 80, 80)])
    }
}
