import Foundation
import XCTest
@testable import HerdrKit

final class ProjectStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("projects.json") }

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        // Restore permissions first so the directory can be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    func testRoundTrip() {
        let store = ProjectStore(directory: dir)
        store.update(key: "proj-a") { $0.attachedCompose = ["docker-compose.yml"] }
        store.setSpaceRoot(deviceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                           workspaceLabel: "acme", root: "/home/dev/acme")

        let reloaded = ProjectStore(directory: dir).load()
        XCTAssertEqual(reloaded, store.load())
        XCTAssertEqual(reloaded.projects["proj-a"]?.attachedCompose, ["docker-compose.yml"])
        XCTAssertEqual(reloaded.spaceRoots.count, 1)
    }

    func testCorruptFileIsRenamedAndIgnored() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{".write(to: file, atomically: true, encoding: .utf8)

        let store = ProjectStore(directory: dir)
        XCTAssertEqual(store.load(), ProjectStoreFile())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("projects.json.corrupt").path))

        // A second corruption replaces the older .corrupt copy.
        try "[oops".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), ProjectStoreFile())
        let corrupt = try String(contentsOf: dir.appendingPathComponent("projects.json.corrupt"),
                                 encoding: .utf8)
        XCTAssertEqual(corrupt, "[oops")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnreadableFileIsNotRenamedOrOverwritten() throws {
        guard getuid() != 0 else { throw XCTSkip("root reads mode-000 files") }
        let store = ProjectStore(directory: dir)
        store.update(key: "keep") { $0.envFile = ".env" }
        let original = try Data(contentsOf: file)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        XCTAssertEqual(store.load(), ProjectStoreFile())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("projects.json.corrupt").path))

        store.update(key: "other") { $0.envFile = ".env.local" }
        store.save(ProjectStoreFile(projects: ["other": ProjectOverrides(envFile: ".env.local")]))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDecodesFileMissingOptionalKeys() throws {
        let decoded = try JSONDecoder().decode(ProjectStoreFile.self, from: Data(#"{"version":1}"#.utf8))
        XCTAssertEqual(decoded, ProjectStoreFile(version: 1))
    }

    func testSpaceRootKeyFormat() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let store = ProjectStore(directory: dir)
        store.setSpaceRoot(deviceID: id, workspaceLabel: "acme", root: "/home/dev/acme")

        XCTAssertEqual(store.load().spaceRoots["\(id.uuidString):acme"], "/home/dev/acme")
        XCTAssertEqual(store.spaceRoot(deviceID: id, workspaceLabel: "acme"), "/home/dev/acme")

        store.setSpaceRoot(deviceID: id, workspaceLabel: "acme", root: nil)
        XCTAssertNil(store.load().spaceRoots["\(id.uuidString):acme"])
        XCTAssertNil(store.spaceRoot(deviceID: id, workspaceLabel: "acme"))
    }

    func testUpdateCreatesMissingEntry() {
        let store = ProjectStore(directory: dir)
        XCTAssertEqual(store.overrides(for: "missing"), ProjectOverrides())

        store.update(key: "fresh") { $0.envFile = ".env.local" }

        XCTAssertEqual(store.overrides(for: "fresh").envFile, ".env.local")
        XCTAssertEqual(store.overrides(for: "fresh").services, [:])
    }

    func testSaveIsAtomic() throws {
        let store = ProjectStore(directory: dir)
        store.save(ProjectStoreFile(projects: ["p": ProjectOverrides(envFile: ".env")]))
        store.save(ProjectStoreFile(projects: ["p": ProjectOverrides(envFile: ".env.local")]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["projects.json"])
    }
}
