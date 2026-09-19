#if os(macOS)
import Foundation

/// Serves herdr's NDJSON socket API on a local Unix socket by proxying each
/// accepted connection over SSH to `herdr remote-api-bridge` on a Windows host.
///
/// Win32-OpenSSH cannot forward the `%APPDATA%\herdr\herdr.sock` AF_UNIX path
/// through `ssh -L` (drive-letter colons break the forward parser, and stream-
/// local opens fail on stock sshd). The official CLI uses the same remote-api-
/// bridge exec channel; SocketRPC keeps one request per connection, which matches
/// the bridge's one-shot RPC behaviour, while `events.subscribe` keeps the SSH
/// session open for the event stream.
final class SSHRemoteAPIBridge: @unchecked Sendable {
    let localSocketPath: String
    let target: String
    let herdrExecutable: String
    let credentialID: UUID?
    let sessionName: String

    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var stopped = false
    private var acceptThread: Thread?
    private var children: [ObjectIdentifier: Child] = [:]

    private final class Child {
        let process: Process
        let clientFD: Int32
        let stdinPipe: Pipe
        let stdoutPipe: Pipe

        init(process: Process, clientFD: Int32, stdinPipe: Pipe, stdoutPipe: Pipe) {
            self.process = process
            self.clientFD = clientFD
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
        }
    }

    init(
        localSocketPath: String,
        target: String,
        herdrExecutable: String,
        credentialID: UUID?,
        sessionName: String = "default"
    ) {
        self.localSocketPath = localSocketPath
        self.target = target
        self.herdrExecutable = herdrExecutable
        self.credentialID = credentialID
        self.sessionName = sessionName
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listenerFD < 0 else { return }

        try? FileManager.default.removeItem(atPath: localSocketPath)
        let directory = (localSocketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HerdrError.tunnelFailed("socket(): \(String(cString: strerror(errno)))")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(localSocketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw HerdrError.tunnelFailed("bridge socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len)
            }
        }
        guard bindRC == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw HerdrError.tunnelFailed("bind(\(localSocketPath)): \(reason)")
        }
        guard listen(fd, 32) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw HerdrError.tunnelFailed("listen(): \(reason)")
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        listenerFD = fd
        stopped = false

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "herdrm.windows-api-bridge"
        thread.qualityOfService = .userInitiated
        acceptThread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        let active = Array(children.values)
        children.removeAll()
        let path = localSocketPath
        lock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        for child in active {
            child.process.terminate()
            Darwin.shutdown(child.clientFD, SHUT_RDWR)
            close(child.clientFD)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenerFD >= 0 && !stopped
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let listening = listenerFD
            let done = stopped
            lock.unlock()
            guard !done, listening >= 0 else { return }

            let client = accept(listening, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            )
            do {
                try spawnProxy(clientFD: client)
            } catch {
                close(client)
            }
        }
    }

    private func spawnProxy(clientFD: Int32) throws {
        let authentication = SSHTunnel.authenticationConfiguration(for: credentialID)
        defer { authentication.discardAuthorization() }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = authentication.arguments + [
            "-T",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=60",
            "-o", "ControlPath=\(Self.controlPath(for: target))",
            SSHTunnel.sshDestination(target),
            Self.remoteCommand(herdrExecutable: herdrExecutable, sessionName: sessionName),
        ]
        process.environment = ProcessInfo.processInfo.environment
            .merging(authentication.environment) { _, new in new }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let child = Child(
            process: process,
            clientFD: clientFD,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe
        )
        let id = ObjectIdentifier(process)
        lock.lock()
        children[id] = child
        lock.unlock()

        let stdinFD = stdinPipe.fileHandleForWriting.fileDescriptor
        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor

        process.terminationHandler = { [weak self] finished in
            self?.reap(process: finished)
        }

        // client → ssh stdin
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(clientFD, &buffer, buffer.count)
                if n > 0 {
                    if !Self.writeAll(fd: stdinFD, buffer: buffer, count: n) { break }
                } else {
                    break
                }
            }
            // Half-close stdin so remote-api-bridge sees EOF after one-shot RPCs.
            try? stdinPipe.fileHandleForWriting.close()
            // Keep child alive until stdout side finishes (events.subscribe).
            _ = self
        }

        // ssh stdout → client
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(stdoutFD, &buffer, buffer.count)
                if n > 0 {
                    if !Self.writeAll(fd: clientFD, buffer: buffer, count: n) { break }
                } else {
                    break
                }
            }
            self?.reap(process: process)
        }
    }

    private func reap(process: Process) {
        let id = ObjectIdentifier(process)
        lock.lock()
        let child = children.removeValue(forKey: id)
        lock.unlock()
        guard let child else { return }
        if process.isRunning { process.terminate() }
        Darwin.shutdown(child.clientFD, SHUT_RDWR)
        close(child.clientFD)
        try? child.stdinPipe.fileHandleForWriting.close()
        try? child.stdoutPipe.fileHandleForReading.close()
    }

    private static func writeAll(fd: Int32, buffer: [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), count - offset)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    /// OpenSSH remote argv: PowerShell EncodedCommand running remote-api-bridge.
    static func remoteCommand(herdrExecutable: String, sessionName: String = "default") -> String {
        let exe = herdrExecutable.replacingOccurrences(of: "'", with: "''")
        let session = sessionName.replacingOccurrences(of: "'", with: "")
        // Run in-process under PowerShell so stdin/stdout stay on the SSH channel
        // regardless of the user's DefaultShell (CMD vs PowerShell).
        let script = "& '\(exe)' --session \(session) remote-api-bridge"
        return SSHTunnel.powershellEncodedCommand(script)
    }

    static func controlPath(for target: String) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-ssh-cm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(abs(target.hashValue) % 100_000).sock").path
    }
}
#endif
