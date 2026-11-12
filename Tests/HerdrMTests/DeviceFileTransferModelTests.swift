import Foundation
import HerdrKit
import Testing
@testable import herdrm

@Suite(.serialized) @MainActor
struct DeviceFileTransferModelTests {
    @Test func existingFilesWaitForAChoiceAndTheQueueRefreshesAfterFinishing() async throws {
        let fixture = try TransferModelFixture()
        defer { fixture.remove() }
        let model = DeviceFileTransferModel()
        var refreshes = 0
        model.prepare(
            direction: .upload, entries: try await fixture.entries(), targetDevice: .local,
            localDirectory: fixture.source.path, targetDirectory: fixture.destination.path
        ) { refreshes += 1 }
        try await waitUntil { model.pendingBatch != nil }
        #expect(model.isTransferring)
        #expect(model.pendingBatch?.conflictingNames == ["test1.txt"])
        model.startPending(resolution: .skip)
        try await waitUntil { !model.isTransferring }
        #expect(model.pendingBatch == nil)
        #expect(model.error == nil)
        #expect(refreshes == 1)
        #expect(model.label == String(localized: "Transferred \(1); skipped \(1); failed \(0)."))
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("test1.txt")) == Data("old".utf8))
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("test2.txt")) == Data("test2".utf8))
    }

    @Test func cancellingTheConflictPromptDoesNotStartAnyCopies() async throws {
        let fixture = try TransferModelFixture()
        defer { fixture.remove() }
        let model = DeviceFileTransferModel()
        model.prepare(
            direction: .upload, entries: try await fixture.entries(), targetDevice: .local,
            localDirectory: fixture.source.path, targetDirectory: fixture.destination.path
        ) {}
        try await waitUntil { model.pendingBatch != nil }
        model.cancel()
        #expect(!model.isTransferring)
        #expect(model.pendingBatch == nil)
        #expect(model.error == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path) == ["test1.txt"])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}

private struct TransferModelFixture {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("herdrm-transfer-\(UUID().uuidString)")
        source = root.appendingPathComponent("test1")
        destination = root.appendingPathComponent("test2")
        for folder in [source, destination] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for name in ["test1", "test2"] {
            try Data(name.utf8).write(to: source.appendingPathComponent("\(name).txt"))
        }
        try Data("old".utf8).write(to: destination.appendingPathComponent("test1.txt"))
    }

    func entries() async throws -> [DeviceFileEntry] {
        try await DeviceFileService(device: .local).listDirectory(at: source.path).entries
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
