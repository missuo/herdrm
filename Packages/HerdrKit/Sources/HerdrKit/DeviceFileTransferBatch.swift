#if os(macOS)
import Foundation

public struct DeviceFileBatchProgress: Sendable {
    public let processedFiles: Int
    public let totalFiles: Int
    public let currentName: String?
    public let currentFile: FileTransferProgress?

    /// Queue progress, weighted equally per file. Failed and skipped files
    /// finish their queue slots; the final result reports them separately.
    public var fractionCompleted: Double {
        guard totalFiles > 0 else { return 0 }
        return (Double(processedFiles) + (currentFile?.fractionCompleted ?? 0)) / Double(totalFiles)
    }
}

public struct DeviceFileBatchResult: Sendable {
    public struct Failure: Sendable {
        public let name: String
        public let message: String
    }

    public fileprivate(set) var transferred: [String] = []
    public fileprivate(set) var skipped: [String] = []
    public fileprivate(set) var failures: [Failure] = []
    public fileprivate(set) var cancelled = false


}

/// A snapshot of the selected files and destination. Browsing elsewhere while
/// the queue runs does not change where any of its files will be copied.
public struct DeviceFileTransferBatch: Sendable {
    public enum Direction: Sendable { case upload, download }
    public enum ConflictResolution: Sendable { case skip, replace, keepBoth }

    public let entries: [DeviceFileEntry]
    public let direction: Direction
    private let service: DeviceFileService
    private let localDirectory: String
    private let targetDirectory: String
    private let existingKinds: [String: DeviceFileEntry.Kind]

    public var conflictingNames: [String] {
        entries.filter { existingKinds[$0.name] != nil }.map(\.name)
    }

    public static func prepare(
        direction: Direction,
        entries: [DeviceFileEntry],
        device: Device,
        localDirectory: String,
        targetDirectory: String
    ) async throws -> Self {
        guard !entries.isEmpty, entries.allSatisfy({ $0.kind == .regularFile }) else {
            throw HerdrError.fileTransferFailed("select at least one regular file")
        }
        let service = DeviceFileService(device: device)
        let destination = direction == .upload ? service : DeviceFileService(device: .local)
        let listing = try await destination.listDirectory(
            at: direction == .upload ? targetDirectory : localDirectory,
            includingHidden: true)
        try Task.checkCancellation()
        return Self(
            entries: entries, direction: direction, service: service,
            localDirectory: direction == .download ? listing.path : localDirectory,
            targetDirectory: direction == .upload ? listing.path : targetDirectory,
            // Swift String equality is canonical, so a remote directory holding both
            // the precomposed and decomposed spelling of a name yields duplicate
            // keys; keep the first instead of trapping.
            existingKinds: Dictionary(listing.entries.map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first }))
    }

    public func run(
        resolution: ConflictResolution,
        progress: @escaping @Sendable (DeviceFileBatchProgress) -> Void = { _ in }
    ) async -> DeviceFileBatchResult {
        var result = DeviceFileBatchResult()
        for (index, entry) in entries.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            progress(DeviceFileBatchProgress(
                processedFiles: index, totalFiles: entries.count, currentName: entry.name, currentFile: nil))
            let policy: FileConflictPolicy
            if let kind = existingKinds[entry.name] {
                switch resolution {
                case .skip:
                    result.skipped.append(entry.name)
                    progress(DeviceFileBatchProgress(
                        processedFiles: index + 1, totalFiles: entries.count, currentName: nil, currentFile: nil))
                    continue
                case .replace:
                    // In particular, remote `mv` must not put a file *inside*
                    // a same-named destination folder and report success.
                    guard kind == .regularFile else {
                        result.failures.append(.init(name: entry.name, message: "the destination is not a regular file; use Keep Both or Skip Existing"))
                        progress(DeviceFileBatchProgress(
                            processedFiles: index + 1, totalFiles: entries.count, currentName: nil, currentFile: nil))
                        continue
                    }
                    policy = .replace
                case .keepBoth:
                    policy = .keepBoth
                }
            } else {
                policy = .fail
            }
            do {
                let onProgress: DeviceFileService.ProgressHandler = { value in
                    progress(DeviceFileBatchProgress(
                        processedFiles: index, totalFiles: entries.count,
                        currentName: entry.name, currentFile: value))
                }
                switch direction {
                case .upload:
                    _ = try await service.uploadFile(
                        from: URL(fileURLWithPath: entry.path), toDirectory: targetDirectory,
                        conflictPolicy: policy, progress: onProgress)
                case .download:
                    _ = try await service.downloadFile(
                        at: entry.path, toLocalDirectory: URL(fileURLWithPath: localDirectory, isDirectory: true),
                        conflictPolicy: policy, progress: onProgress)
                }
                result.transferred.append(entry.name)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    result.cancelled = true
                    break
                }
                result.failures.append(.init(name: entry.name, message: error.localizedDescription))
            }
            progress(DeviceFileBatchProgress(
                processedFiles: index + 1, totalFiles: entries.count, currentName: nil, currentFile: nil))
        }
        return result
    }
}
#endif
