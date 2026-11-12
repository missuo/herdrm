import Foundation

/// Runs the project probe script on a device and returns its raw output frame(s).
public protocol ProjectProbeRunning: Sendable {
    func run(device: Device, sections: [String], cwds: [String]) async throws -> String
}

#if os(macOS)
/// The real runner: the same `exec /bin/sh -c '<script>' …` command line works under the local
/// `sh -c` and over plain `ssh`, so every device takes one path.
public struct DeviceProjectProbeRunner: ProjectProbeRunning {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    /// Drops directories the probe cannot print safely. Control characters go everywhere: the script
    /// echoes each cwd into its frame, so a newline could forge a frame line. A backslash only
    /// matters to a remote login shell (fish treats it as an escape even inside single quotes).
    public static func safeCwds(_ cwds: [String], for device: Device) -> [String] {
        let remote = !device.isLocal
        return cwds.filter { cwd in
            !cwd.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7f || (remote && $0 == "\\")
            }
        }
    }

    /// A timeout or a non-zero exit still returns the frame read so far, which the parser flags
    /// as partial; only a run that produced no frame at all is an error.
    public func run(device: Device, sections: [String], cwds: [String]) async throws -> String {
        let command = ProjectProbeScript.remoteCommand(sections: sections, cwds: Self.safeCwds(cwds, for: device))
        let result = try await DeviceFileService(device: device).runCollecting(command, timeout: timeout)
        let text = String(decoding: result.stdout, as: UTF8.self)
        if text.contains("@@pp-begin") { return text }
        if result.timedOut { throw HerdrError.fileOperationFailed("SSH timed out") }
        if let status = result.exitStatus, status != 0 {
            let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrError.fileOperationFailed(detail.isEmpty ? "SSH exited \(status)" : detail)
        }
        return text
    }
}
#endif
