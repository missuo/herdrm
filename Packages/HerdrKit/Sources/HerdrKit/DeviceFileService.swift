#if os(macOS)
import Foundation

public struct DeviceFileEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    public let name: String
    public let path: String
    public let kind: Kind
    public let size: Int64?
    public let modificationDate: Date?
    public let isHidden: Bool
    public let isPackage: Bool

    public var id: String { path }

    public init(
        name: String,
        path: String,
        kind: Kind,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        isHidden: Bool = false,
        isPackage: Bool = false
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.isHidden = isHidden
        self.isPackage = isPackage
    }
}

public struct DeviceDirectoryListing: Sendable {
    public let path: String
    public let entries: [DeviceFileEntry]

    public init(path: String, entries: [DeviceFileEntry]) {
        self.path = path
        self.entries = entries
    }
}

public enum FileConflictPolicy: Sendable {
    case fail
    case replace
    case keepBoth
}

public struct FileTransferProgress: Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// Filesystem operations for one configured device. Remote operations use the
/// same system OpenSSH, known_hosts, config, agent, and Keychain askpass path as
/// terminal attach and socket forwarding.
public actor DeviceFileService {
    public typealias ProgressHandler = @Sendable (FileTransferProgress) -> Void

    public let device: Device
    private let sshExecutableURL: URL
    private var cachedRemoteHome: String?

    public init(device: Device) {
        self.device = device
        self.sshExecutableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    }

    init(device: Device, sshExecutableURL: URL) {
        self.device = device
        self.sshExecutableURL = sshExecutableURL
    }

    public func listDirectory(
        at requestedPath: String,
        includingHidden: Bool = false
    ) async throws -> DeviceDirectoryListing {
        let path = try await absolutePath(requestedPath)
        let entries: [DeviceFileEntry]
        switch device.kind {
        case .tailcat:
            throw HerdrError.fileOperationFailed(
                "the Files workspace is not supported over a tailcat tunnel"
            )
        case .local:
            entries = try Self.listLocalDirectory(at: path)
        case .ssh:
            let output = try await runSSHData(
                command: Self.remoteListingCommand(path: path),
                timeout: 30
            )
            entries = try Self.parseRemoteListing(output, directory: path)
        }
        return DeviceDirectoryListing(
            path: path,
            entries: Self.sorted(
                includingHidden ? entries : entries.filter { !$0.isHidden }
            )
        )
    }

    public func uploadFile(
        from localURL: URL,
        toDirectory requestedDirectory: String,
        conflictPolicy: FileConflictPolicy = .fail,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> String {
        let values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard localURL.isFileURL, values.isRegularFile == true else {
            throw HerdrError.fileTransferFailed("only regular local files can be uploaded")
        }
        let directory = try await absolutePath(requestedDirectory)
        let destination = try await resolvedDestination(
            name: localURL.lastPathComponent,
            directory: directory,
            conflictPolicy: conflictPolicy
        )

        switch device.kind {
        case .tailcat:
            throw HerdrError.fileOperationFailed(
                "the Files workspace is not supported over a tailcat tunnel"
            )
        case .local:
            let result = try await Self.copyLocalFile(
                from: localURL,
                to: URL(fileURLWithPath: destination),
                replace: conflictPolicy == .replace,
                progress: progress
            )
            return result.path
        case .ssh:
            let totalBytes = Int64(values.fileSize ?? 0)
            let temporary = destination + ".herdrm-\(UUID().uuidString.lowercased()).part"
            let installCommand = conflictPolicy == .replace
                ? "mv -f \"$tmp\" \"$dest\""
                : "ln \"$tmp\" \"$dest\" && rm -f \"$tmp\""
            let command = """
            umask 077
            tmp=\(HerdrService.shellQuoted(temporary))
            dest=\(HerdrService.shellQuoted(destination))
            trap 'rm -f "$tmp"' EXIT HUP INT TERM
            cat > "$tmp" && chmod 600 "$tmp" && \(installCommand)
            status=$?
            [ "$status" -eq 0 ] && trap - EXIT HUP INT TERM
            exit "$status"
            """
            try await runSSHUpload(
                localURL: localURL,
                command: command,
                totalBytes: totalBytes,
                progress: progress
            )
            return destination
        }
    }

    public func downloadFile(
        at sourcePath: String,
        toLocalDirectory localDirectory: URL,
        conflictPolicy: FileConflictPolicy = .fail,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> URL {
        guard localDirectory.isFileURL else {
            throw HerdrError.fileTransferFailed("a local destination directory is required")
        }
        let source = try await absolutePath(sourcePath)
        let name = (source as NSString).lastPathComponent
        let destination = try Self.resolvedLocalDestination(
            name: name,
            directory: localDirectory,
            conflictPolicy: conflictPolicy
        )

        switch device.kind {
        case .tailcat:
            throw HerdrError.fileOperationFailed(
                "the Files workspace is not supported over a tailcat tunnel"
            )
        case .local:
            return try await Self.copyLocalFile(
                from: URL(fileURLWithPath: source),
                to: destination,
                replace: conflictPolicy == .replace,
                progress: progress
            )
        case .ssh:
            let totalOutput = try await runSSHData(
                command: "wc -c < \(HerdrService.shellQuoted(source))",
                timeout: 15
            )
            guard let totalBytes = Int64(
                String(decoding: totalOutput, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw HerdrError.fileTransferFailed("the remote host returned an invalid file size")
            }
            let temporary = destination
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(destination.lastPathComponent).herdrm-\(UUID().uuidString.lowercased()).part"
                )
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await runSSHDownload(
                command: "cat \(HerdrService.shellQuoted(source))",
                temporaryURL: temporary,
                totalBytes: totalBytes,
                progress: progress
            )
            try Self.installDownloadedFile(
                temporary,
                at: destination,
                replace: conflictPolicy == .replace
            )
            return destination
        }
    }

    private func absolutePath(_ requestedPath: String) async throws -> String {
        let trimmed = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? "~" : trimmed
        let expanded: String
        if path == "~" || path.hasPrefix("~/") {
            let home = try await homeDirectory()
            expanded = path == "~" ? home : home + "/" + path.dropFirst(2)
        } else {
            expanded = path
        }
        guard expanded.hasPrefix("/") else {
            throw HerdrError.fileOperationFailed("path must be absolute or start with ~")
        }
        return (expanded as NSString).standardizingPath
    }

    private func homeDirectory() async throws -> String {
        switch device.kind {
        case .tailcat:
            throw HerdrError.fileOperationFailed(
                "the Files workspace is not supported over a tailcat tunnel"
            )
        case .local:
            return NSHomeDirectory()
        case .ssh:
            if let cachedRemoteHome { return cachedRemoteHome }
            let output = try await runSSHData(command: "printf '%s' \"$HOME\"", timeout: 15)
            let home = String(decoding: output, as: UTF8.self)
            guard home.hasPrefix("/") else {
                throw HerdrError.fileOperationFailed("could not resolve the remote home directory")
            }
            cachedRemoteHome = home
            return home
        }
    }

    private func resolvedDestination(
        name: String,
        directory: String,
        conflictPolicy: FileConflictPolicy
    ) async throws -> String {
        let original = Self.join(directory: directory, name: name)
        let exists = try await pathExists(original)
        switch conflictPolicy {
        case .replace:
            return original
        case .fail:
            guard !exists else {
                throw HerdrError.fileTransferFailed("“\(name)” already exists")
            }
            return original
        case .keepBoth:
            guard exists else { return original }
            for index in 2...10_000 {
                let candidate = Self.keepBothName(name, index: index)
                let path = Self.join(directory: directory, name: candidate)
                if try await !pathExists(path) { return path }
            }
            throw HerdrError.fileTransferFailed("could not find an available name for “\(name)”")
        }
    }

    private func pathExists(_ path: String) async throws -> Bool {
        switch device.kind {
        case .tailcat:
            throw HerdrError.fileOperationFailed(
                "the Files workspace is not supported over a tailcat tunnel"
            )
        case .local:
            return FileManager.default.fileExists(atPath: path)
        case .ssh:
            let command = """
            if [ -e \(HerdrService.shellQuoted(path)) ] || [ -L \(HerdrService.shellQuoted(path)) ]; then
                printf 1
            else
                printf 0
            fi
            """
            let output = try await runSSHData(command: command, timeout: 15)
            return output.first == UInt8(ascii: "1")
        }
    }

    private func runSSHData(command: String, timeout: TimeInterval) async throws -> Data {
        guard case .ssh(let target) = device.kind else {
            throw HerdrError.fileOperationFailed("SSH is unavailable for a local device")
        }
        let authentication = SSHTunnel.authenticationConfiguration(for: device.id)
        defer { authentication.discardAuthorization() }
        let arguments = authentication.arguments + [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            SSHTunnel.sshDestination(target),
            command,
        ]
        return try await SSHFileProcess.capture(
            executableURL: sshExecutableURL,
            arguments: arguments,
            environment: authentication.environment,
            timeout: timeout
        )
    }

    private func runSSHUpload(
        localURL: URL,
        command: String,
        totalBytes: Int64,
        progress: @escaping ProgressHandler
    ) async throws {
        guard case .ssh(let target) = device.kind else {
            throw HerdrError.fileTransferFailed("SSH is unavailable for a local device")
        }
        let authentication = SSHTunnel.authenticationConfiguration(for: device.id)
        defer { authentication.discardAuthorization() }
        let arguments = authentication.arguments + [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            SSHTunnel.sshDestination(target),
            "exec /bin/sh -c \(HerdrService.shellQuoted(command))",
        ]
        try await SSHFileProcess.upload(
            executableURL: sshExecutableURL,
            arguments: arguments,
            environment: authentication.environment,
            localURL: localURL,
            totalBytes: totalBytes,
            progress: progress
        )
    }

    private func runSSHDownload(
        command: String,
        temporaryURL: URL,
        totalBytes: Int64,
        progress: @escaping ProgressHandler
    ) async throws {
        guard case .ssh(let target) = device.kind else {
            throw HerdrError.fileTransferFailed("SSH is unavailable for a local device")
        }
        let authentication = SSHTunnel.authenticationConfiguration(for: device.id)
        defer { authentication.discardAuthorization() }
        let arguments = authentication.arguments + [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            SSHTunnel.sshDestination(target),
            command,
        ]
        try await SSHFileProcess.download(
            executableURL: sshExecutableURL,
            arguments: arguments,
            environment: authentication.environment,
            temporaryURL: temporaryURL,
            totalBytes: totalBytes,
            progress: progress
        )
    }

    static func parseRemoteListing(_ data: Data, directory: String) throws -> [DeviceFileEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        let payload = fields.last?.isEmpty == true ? fields.dropLast() : fields[...]
        guard payload.count.isMultiple(of: 4) else {
            throw HerdrError.fileOperationFailed("the remote host returned malformed directory data")
        }
        var entries: [DeviceFileEntry] = []
        entries.reserveCapacity(payload.count / 4)
        for offset in stride(from: 0, to: payload.count, by: 4) {
            guard let name = String(data: Data(payload[offset]), encoding: .utf8),
                  let type = String(data: Data(payload[offset + 1]), encoding: .utf8),
                  let size = Int64(String(decoding: payload[offset + 2], as: UTF8.self)),
                  let modified = TimeInterval(String(decoding: payload[offset + 3], as: UTF8.self))
            else { continue }
            let kind: DeviceFileEntry.Kind
            switch type.lowercased() {
            case "directory": kind = .directory
            case "regular file": kind = .regularFile
            case "symbolic link": kind = .symbolicLink
            default: kind = .other
            }
            entries.append(
                DeviceFileEntry(
                    name: name,
                    path: join(directory: directory, name: name),
                    kind: kind,
                    size: kind == .regularFile ? size : nil,
                    modificationDate: Date(timeIntervalSince1970: modified),
                    isHidden: name.hasPrefix(".")
                )
            )
        }
        return entries
    }

    static func remoteListingCommand(path: String) -> String {
        """
        cd \(HerdrService.shellQuoted(path)) || exit 1
        if stat -f '%HT' . >/dev/null 2>&1; then
            find . ! -name . -prune -exec /bin/sh -c 'for item do
                type=$(stat -f "%HT" "$item") || continue
                size=$(stat -f "%z" "$item") || continue
                modified=$(stat -f "%m" "$item") || continue
                name=${item#./}
                printf "%s\\0%s\\0%s\\0%s\\0" "$name" "$type" "$size" "$modified"
            done' sh {} +
        else
            find . ! -name . -prune -exec /bin/sh -c 'for item do
                type=$(stat -c "%F" -- "$item") || continue
                size=$(stat -c "%s" -- "$item") || continue
                modified=$(stat -c "%Y" -- "$item") || continue
                name=${item#./}
                printf "%s\\0%s\\0%s\\0%s\\0" "$name" "$type" "$size" "$modified"
            done' sh {} +
        fi
        """
    }

    static func keepBothName(_ name: String, index: Int) -> String {
        let value = name as NSString
        let ext = value.pathExtension
        let stem = value.deletingPathExtension
        return ext.isEmpty ? "\(name) \(index)" : "\(stem) \(index).\(ext)"
    }

    private static func listLocalDirectory(at path: String) throws -> [DeviceFileEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .isPackageKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        return try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: Array(keys),
            options: []
        ).map { url in
            let values = try url.resourceValues(forKeys: keys)
            let kind: DeviceFileEntry.Kind
            if values.isSymbolicLink == true {
                kind = .symbolicLink
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .regularFile
            } else {
                kind = .other
            }
            return DeviceFileEntry(
                name: url.lastPathComponent,
                path: url.path,
                kind: kind,
                size: kind == .regularFile ? Int64(values.fileSize ?? 0) : nil,
                modificationDate: values.contentModificationDate,
                isHidden: values.isHidden == true || url.lastPathComponent.hasPrefix("."),
                isPackage: values.isPackage == true
            )
        }
    }

    private static func sorted(_ entries: [DeviceFileEntry]) -> [DeviceFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.kind == .directory, rhs.kind != .directory { return true }
            if lhs.kind != .directory, rhs.kind == .directory { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func join(directory: String, name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    private static func resolvedLocalDestination(
        name: String,
        directory: URL,
        conflictPolicy: FileConflictPolicy
    ) throws -> URL {
        let manager = FileManager.default
        var destination = directory.appendingPathComponent(name)
        let exists = manager.fileExists(atPath: destination.path)
        switch conflictPolicy {
        case .replace:
            return destination
        case .fail:
            guard !exists else {
                throw HerdrError.fileTransferFailed("“\(name)” already exists")
            }
            return destination
        case .keepBoth:
            guard exists else { return destination }
            for index in 2...10_000 {
                destination = directory.appendingPathComponent(keepBothName(name, index: index))
                if !manager.fileExists(atPath: destination.path) { return destination }
            }
            throw HerdrError.fileTransferFailed("could not find an available name for “\(name)”")
        }
    }

    private static func copyLocalFile(
        from source: URL,
        to destination: URL,
        replace: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw HerdrError.fileTransferFailed("only regular files can be transferred")
        }
        let totalBytes = Int64(values.fileSize ?? 0)
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).herdrm-\(UUID().uuidString.lowercased()).part"
            )
        defer { try? FileManager.default.removeItem(at: temporary) }

        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        defer {
            try? input.close()
            try? output.close()
        }
        var completed: Int64 = 0
        while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            completed += Int64(data.count)
            progress(FileTransferProgress(completedBytes: completed, totalBytes: totalBytes))
        }
        try output.synchronize()
        try installDownloadedFile(temporary, at: destination, replace: replace)
        progress(FileTransferProgress(completedBytes: totalBytes, totalBytes: totalBytes))
        return destination
    }

    private static func installDownloadedFile(
        _ temporary: URL,
        at destination: URL,
        replace: Bool
    ) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            guard replace else {
                throw HerdrError.fileTransferFailed("“\(destination.lastPathComponent)” already exists")
            }
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }
}

private enum SSHFileProcess {
    static func capture(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        let processBox = CancellableProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = configuredProcess(
                        executableURL: executableURL,
                        arguments: arguments,
                        environment: environment
                    )
                    let output = Pipe()
                    let errorOutput = Pipe()
                    process.standardOutput = output
                    process.standardError = errorOutput
                    do {
                        try process.run()
                        processBox.install(process)
                    } catch {
                        continuation.resume(
                            throwing: HerdrError.fileOperationFailed(
                                "could not start SSH: \(error.localizedDescription)"
                            )
                        )
                        return
                    }
                    scheduleTimeout(processBox, after: timeout)
                    let streams = readStreams(output: output, error: errorOutput)
                    process.waitUntilExit()
                    let (data, errorData) = streams()
                    if processBox.didTimeOut {
                        continuation.resume(
                            throwing: HerdrError.fileOperationFailed("SSH timed out")
                        )
                    } else if processBox.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus != 0 {
                        continuation.resume(
                            throwing: HerdrError.fileOperationFailed(
                                failureReason(status: process.terminationStatus, stderr: errorData)
                            )
                        )
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
        } onCancel: {
            processBox.cancel()
        }
    }

    static func upload(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        localURL: URL,
        totalBytes: Int64,
        progress: @escaping DeviceFileService.ProgressHandler
    ) async throws {
        let processBox = CancellableProcess()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = configuredProcess(
                        executableURL: executableURL,
                        arguments: arguments,
                        environment: environment
                    )
                    let errorOutput = Pipe()
                    let source: FileHandle
                    do {
                        source = try FileHandle(forReadingFrom: localURL)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    defer { try? source.close() }
                    process.standardInput = source
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = errorOutput
                    do {
                        try process.run()
                        processBox.install(process)
                    } catch {
                        continuation.resume(
                            throwing: HerdrError.fileTransferFailed(
                                "could not start SSH: \(error.localizedDescription)"
                            )
                        )
                        return
                    }
                    let errorReader = readError(errorOutput)
                    while process.isRunning {
                        if processBox.wasCancelled {
                            process.terminate()
                            break
                        }
                        let offset = lseek(source.fileDescriptor, 0, SEEK_CUR)
                        if offset >= 0 {
                            progress(
                                FileTransferProgress(
                                    completedBytes: Int64(offset),
                                    totalBytes: totalBytes
                                )
                            )
                        }
                        usleep(100_000)
                    }
                    process.waitUntilExit()
                    let errorData = errorReader()
                    if processBox.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus != 0 {
                        continuation.resume(
                            throwing: HerdrError.fileTransferFailed(
                                failureReason(status: process.terminationStatus, stderr: errorData)
                            )
                        )
                    } else {
                        progress(
                            FileTransferProgress(
                                completedBytes: totalBytes,
                                totalBytes: totalBytes
                            )
                        )
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            processBox.cancel()
        }
    }

    static func download(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        temporaryURL: URL,
        totalBytes: Int64,
        progress: @escaping DeviceFileService.ProgressHandler
    ) async throws {
        let processBox = CancellableProcess()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
                    let destination: FileHandle
                    do {
                        destination = try FileHandle(forWritingTo: temporaryURL)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    defer { try? destination.close() }

                    let process = configuredProcess(
                        executableURL: executableURL,
                        arguments: arguments,
                        environment: environment
                    )
                    let output = Pipe()
                    let errorOutput = Pipe()
                    process.standardOutput = output
                    process.standardError = errorOutput
                    do {
                        try process.run()
                        processBox.install(process)
                    } catch {
                        continuation.resume(
                            throwing: HerdrError.fileTransferFailed(
                                "could not start SSH: \(error.localizedDescription)"
                            )
                        )
                        return
                    }
                    let errorReader = readError(errorOutput)
                    var completed: Int64 = 0
                    do {
                        while let data = try output.fileHandleForReading.read(
                            upToCount: 256 * 1024
                        ), !data.isEmpty {
                            if processBox.wasCancelled { throw CancellationError() }
                            try destination.write(contentsOf: data)
                            completed += Int64(data.count)
                            progress(
                                FileTransferProgress(
                                    completedBytes: completed,
                                    totalBytes: totalBytes
                                )
                            )
                        }
                        process.waitUntilExit()
                        let errorData = errorReader()
                        if processBox.wasCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if process.terminationStatus != 0 {
                            continuation.resume(
                                throwing: HerdrError.fileTransferFailed(
                                    failureReason(
                                        status: process.terminationStatus,
                                        stderr: errorData
                                    )
                                )
                            )
                        } else {
                            try destination.synchronize()
                            progress(
                                FileTransferProgress(
                                    completedBytes: totalBytes,
                                    totalBytes: totalBytes
                                )
                            )
                            continuation.resume()
                        }
                    } catch {
                        processBox.cancel()
                        process.waitUntilExit()
                        _ = errorReader()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            processBox.cancel()
        }
    }

    private static func configuredProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        return process
    }

    private static func scheduleTimeout(_ process: CancellableProcess, after timeout: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            process.timeout()
        }
    }

    private static func readStreams(
        output: Pipe,
        error: Pipe
    ) -> () -> (Data, Data) {
        let group = DispatchGroup()
        let data = LockedData()
        let errorData = LockedData()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data.set(output.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.set(error.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        return {
            group.wait()
            return (data.value, errorData.value)
        }
    }

    private static func readError(_ pipe: Pipe) -> () -> Data {
        let group = DispatchGroup()
        let data = LockedData()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data.set(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        return {
            group.wait()
            return data.value
        }
    }

    private static func failureReason(status: Int32, stderr: Data) -> String {
        let detail = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? "SSH exited \(status)" : String(detail.suffix(2_000))
    }
}

private final class CancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    func install(_ process: Process) {
        let shouldCancel = lock.withLock {
            self.process = process
            return cancelled
        }
        if shouldCancel, process.isRunning { process.terminate() }
    }

    func cancel() {
        terminate(cancelled: true, timedOut: false)
    }

    func timeout() {
        terminate(cancelled: false, timedOut: true)
    }

    private func terminate(cancelled: Bool, timedOut: Bool) {
        let runningProcess = lock.withLock {
            self.cancelled = self.cancelled || cancelled
            self.timedOut = self.timedOut || timedOut
            return process
        }
        if runningProcess?.isRunning == true { runningProcess?.terminate() }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.withLock { data }
    }

    func set(_ data: Data) {
        lock.withLock { self.data = data }
    }
}
#endif  // os(macOS)
