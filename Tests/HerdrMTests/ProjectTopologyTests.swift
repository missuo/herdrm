import HerdrKit
import XCTest
@testable import herdrm

final class ProjectTopologyTests: XCTestCase {
    private let devbox = Device(name: "devbox", kind: .ssh(target: "dev@devbox"))
    private let root = "/home/dev/acme-app"

    private func server(_ signature: String, framework: String, port: Int, hidden: Bool = false) -> DevServer {
        DevServer(
            signature: signature, role: .frontend, framework: framework, bind: "127.0.0.1", port: port,
            isPublicBind: false, pids: [4101], ownerPID: 4101, cwdRelative: "frontend", unit: nil, logPath: nil,
            hotReload: true, urls: [], isHidden: hidden)
    }

    private func fixture() -> ProjectSnapshot {
        let web = ContainerRow(
            id: "c1", name: "acme-web-1", image: "nginx:1.27", service: "web", state: "running",
            statusText: "Up 2 hours", health: "healthy", ports: [], urls: [])
        return ProjectSnapshot(
            identity: ProjectIdentity(deviceID: devbox.id, root: root, worktreeRoots: [root]),
            probedAt: Date(), partial: false,
            host: HostHealth(hostname: "devbox", dockerError: "daemon down"),
            devServers: [
                server("next-server@frontend", framework: "Next.js", port: 3100),
                server("vite@web", framework: "vite-hidden-fw", port: 5173, hidden: true),
            ],
            otherListeners: [],
            compose: [ComposeGroup(name: "acme", workingDir: root, configFiles: [], match: .name, running: 1, total: 1, containers: [web])],
            otherCompose: [], attachedContainers: [web], suggestedContainers: [],
            vms: [VMRow(provider: .lima, vmID: "acme-vm", name: "acme-vm", state: "running", ip: nil, match: .declared)],
            otherVMs: [], files: [], envEntries: [], warnings: [], staleOverrides: [])
    }

    func testRemoteSpaceHasMacNodeWithVMsAndHidesHiddenServers() {
        let topology = ProjectTopology.make(snapshot: fixture(), device: devbox, linked: [])
        XCTAssertTrue(topology.isRemote)
        XCTAssertEqual(topology.mac?.vms.map(\.name), ["acme-vm"])
        XCTAssertNil(topology.host.vms)
        XCTAssertEqual(topology.host.devServers.map(\.framework), ["Next.js"])
        XCTAssertEqual(topology.host.compose.map(\.name), ["acme"])
        XCTAssertEqual(topology.host.attachedCount, 1)
        XCTAssertEqual(topology.host.dockerError, "daemon down")
    }

    func testLocalSpaceHasNoMacNodeAndKeepsVMsOnTheHost() {
        let topology = ProjectTopology.make(snapshot: fixture(), device: .local, linked: [])
        XCTAssertFalse(topology.isRemote)
        XCTAssertNil(topology.mac)
        XCTAssertEqual(topology.host.vms?.count, 1)
    }

    func testLinkedHostsBecomeNodes() {
        let other = Device(name: "buildbox", kind: .ssh(target: "dev@buildbox"))
        let topology = ProjectTopology.make(snapshot: fixture(), device: devbox, linked: [(other, "/srv/acme")])
        XCTAssertEqual(topology.linked.map(\.root), ["/srv/acme"])
        XCTAssertEqual(topology.linked.first?.id, other.id)
    }
}
