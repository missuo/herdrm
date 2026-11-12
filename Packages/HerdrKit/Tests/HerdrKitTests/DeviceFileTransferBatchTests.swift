import Foundation
import Testing
@testable import HerdrKit

struct DeviceFileTransferBatchTests {
    @Test func transfersEveryFileInBothDirectionsAndContinuesAfterAFailure() async throws {
        let fixture = try BatchFixture()
        defer { fixture.remove() }
        let batch = try await fixture.prepare()
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("test2.txt"))
        let result = await batch.run(resolution: .skip)
        #expect(result.transferred == ["test1.txt", "test10.txt"])
        #expect(result.failures.map(\.name) == ["test2.txt"])
        #expect(!result.cancelled)
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("test10.txt")) == Data("test10".utf8))

        let local = fixture.root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let listing = try await DeviceFileService(device: .local).listDirectory(at: fixture.destination.path)
        let download = try await DeviceFileTransferBatch.prepare(
            direction: .download, entries: listing.entries, device: .local,
            localDirectory: local.path, targetDirectory: fixture.destination.path)
        let downloaded = await download.run(resolution: .skip)
        #expect(downloaded.transferred == ["test1.txt", "test10.txt"])
        #expect(try Data(contentsOf: local.appendingPathComponent("test1.txt")) == Data("test1".utf8))
    }

    @Test func conflictsCanBeSkippedReplacedOrKeptAndHiddenFilesAreDetected() async throws {
        for resolution in [DeviceFileTransferBatch.ConflictResolution.skip, .replace, .keepBoth] {
            let fixture = try BatchFixture()
            defer { fixture.remove() }
            try Data("old".utf8).write(to: fixture.destination.appendingPathComponent("test1.txt"))
            try Data("hidden-new".utf8).write(to: fixture.source.appendingPathComponent(".test"))
            try Data("hidden-old".utf8).write(to: fixture.destination.appendingPathComponent(".test"))
            let batch = try await fixture.prepare()
            #expect(Set(batch.conflictingNames) == [".test", "test1.txt"])
            let result = await batch.run(resolution: resolution)
            #expect(result.failures.isEmpty)
            let original = try Data(contentsOf: fixture.destination.appendingPathComponent("test1.txt"))
            switch resolution {
            case .skip:
                #expect(Set(result.skipped) == [".test", "test1.txt"])
                #expect(original == Data("old".utf8))
            case .replace:
                #expect(original == Data("test1".utf8))
            case .keepBoth:
                #expect(original == Data("old".utf8))
                #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("test1 2.txt")) == Data("test1".utf8))
            }
        }
    }

    @Test func replaceDoesNotOverwriteADirectoryAndCancellationStopsTheRemainingQueue() async throws {
        let fixture = try BatchFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.destination.appendingPathComponent("test1.txt"), withIntermediateDirectories: true)
        let batch = try await fixture.prepare()
        let result = await batch.run(resolution: .replace)
        #expect(result.failures.map(\.name) == ["test1.txt"])
        #expect(result.transferred == ["test2.txt", "test10.txt"])

        let another = try BatchFixture()
        defer { another.remove() }
        let cancelBatch = try await another.prepare()
        let task = Task {
            await cancelBatch.run(resolution: .skip) { progress in
                if progress.processedFiles == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let cancelled = await task.value
        #expect(cancelled.cancelled)
        #expect(cancelled.transferred == ["test1.txt"])
        #expect(cancelled.failures.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: another.destination.path) == ["test1.txt"])
    }
}

private struct BatchFixture {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("herdrm-batch-\(UUID().uuidString)")
        source = root.appendingPathComponent("test1")
        destination = root.appendingPathComponent("test2")
        for directory in [source, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in ["test1", "test2", "test10"] {
            try Data(name.utf8).write(to: source.appendingPathComponent("\(name).txt"))
        }
    }

    func prepare() async throws -> DeviceFileTransferBatch {
        let listing = try await DeviceFileService(device: .local).listDirectory(at: source.path, includingHidden: true)
        return try await DeviceFileTransferBatch.prepare(
            direction: .upload, entries: listing.entries, device: .local,
            localDirectory: source.path, targetDirectory: destination.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
