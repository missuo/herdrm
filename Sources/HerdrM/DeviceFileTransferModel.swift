import Foundation
import HerdrKit
import SwiftUI

@MainActor
final class DeviceFileTransferModel: ObservableObject {
    @Published private(set) var isTransferring = false
    @Published private(set) var pendingBatch: DeviceFileTransferBatch?
    @Published private(set) var progress: DeviceFileBatchProgress?
    @Published private(set) var label = ""
    @Published var error: String?

    private var task: Task<Void, Never>?
    private var onFinished: (@MainActor () async -> Void)?

    func prepare(
        direction: DeviceFileTransferBatch.Direction,
        entries: [DeviceFileEntry],
        targetDevice: Device,
        localDirectory: String,
        targetDirectory: String,
        onFinished: @escaping @MainActor () async -> Void
    ) {
        guard !isTransferring, !entries.isEmpty else { return }
        isTransferring = true
        progress = nil
        error = nil
        label = String(localized: "Checking destination…")
        self.onFinished = onFinished
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let batch = try await DeviceFileTransferBatch.prepare(
                    direction: direction, entries: entries, device: targetDevice,
                    localDirectory: localDirectory, targetDirectory: targetDirectory)
                try Task.checkCancellation()
                if batch.conflictingNames.isEmpty {
                    start(batch, resolution: .skip)
                } else {
                    pendingBatch = batch
                    label = String(localized: "Choose how to handle existing files")
                    task = nil
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    label = String(localized: "Transfer cancelled")
                } else {
                    self.error = error.localizedDescription
                    label = String(localized: "Could not prepare transfer")
                }
                isTransferring = false
                self.onFinished = nil
                task = nil
            }
        }
    }

    func startPending(resolution: DeviceFileTransferBatch.ConflictResolution) {
        guard let batch = pendingBatch else { return }
        startPending(batch, resolution: resolution)
    }

    /// Starts the batch a conflict dialog presented. Takes it explicitly so the
    /// choice still applies if the dialog's binding is cleared before its action runs.
    func startPending(_ batch: DeviceFileTransferBatch, resolution: DeviceFileTransferBatch.ConflictResolution) {
        guard isTransferring else { return }
        pendingBatch = nil
        start(batch, resolution: resolution)
    }

    private func start(_ batch: DeviceFileTransferBatch, resolution: DeviceFileTransferBatch.ConflictResolution) {
        task = Task { [weak self] in
            guard let self else { return }
            let result = await batch.run(resolution: resolution) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.isTransferring,
                          value.processedFiles >= (self.progress?.processedFiles ?? 0) else { return }
                    self.progress = value
                    if let name = value.currentName {
                        self.label = batch.direction == .upload
                            ? String(localized: "Uploading \(name) (\(value.processedFiles + 1)/\(value.totalFiles))")
                            : String(localized: "Downloading \(name) (\(value.processedFiles + 1)/\(value.totalFiles))")
                    }
                }
            }
            // A cancelled transfer must still refresh files that did finish.
            // The refresh therefore runs outside the cancelled task.
            if let onFinished { await Task { @MainActor in await onFinished() }.value }
            isTransferring = false
            progress = nil
            let summary = String(localized: "Transferred \(result.transferred.count); skipped \(result.skipped.count); failed \(result.failures.count).")
            label = result.cancelled ? String(localized: "Transfer cancelled") + " — " + summary : summary
            if !result.failures.isEmpty {
                error = result.failures.prefix(5).map { "\($0.name): \($0.message)" }.joined(separator: "\n")
                if result.failures.count > 5 {
                    error! += "\n" + String(localized: "\(result.failures.count - 5) more files failed.")
                }
            }
            onFinished = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        if pendingBatch != nil {
            pendingBatch = nil
            isTransferring = false
            label = String(localized: "Transfer cancelled")
            onFinished = nil
        }
    }

    func dismiss() { label = "" }

    deinit { task?.cancel() }
}
