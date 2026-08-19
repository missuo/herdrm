import XCTest
@testable import HerdrKit

/// Hermetic tests for the local herdr auto-start: the launcher is injected and every socket
/// lives in a per-test temp directory, so nothing here touches the real herdr server or
/// `~/.config/herdr`. Names stay short because sockaddr_un caps paths at 104 bytes.
final class LocalServerTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String!
    private var listeners: [FakeListener] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
    }

    override func tearDownWithError() throws {
        listeners.forEach { $0.stop() }
        listeners = []
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Starting

    func testServerThatOpensTheSocketIsAwaited() async throws {
        let path = socketPath!
        let listener = makeListener()
        let launches = Recorder()
        let server = LocalHerdrServer(
            binaryPath: { "/fake/herdr" },
            launcher: { binary in
                launches.record(binary)
                // Same shape as the real thing: the socket lands well after the spawn returns.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { try? listener.start(at: path) }
                return .alive()
            }
        )

        try await server.ensureRunning(socketPath: path, timeout: 3)

        XCTAssertEqual(launches.values, ["/fake/herdr"])
        XCTAssertTrue(LocalHerdrServer.socketAcceptsConnections(path))
    }

    func testLiveSocketLaunchesNothing() async throws {
        let path = socketPath!
        try makeListener().start(at: path)
        let launches = Recorder()
        // A poll interval far larger than a connect(): every connect herdrm makes goes through
        // here, so answering must cost one probe, not one poll.
        let server = LocalHerdrServer(
            binaryPath: { "/fake/herdr" },
            launcher: { binary in
                launches.record(binary)
                return .alive()
            },
            pollInterval: 0.5
        )

        let started = Date()
        try await server.ensureRunning(socketPath: path, timeout: 3)

        XCTAssertEqual(launches.values, [], "a server already serving must not be started again")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "the happy path waited for a poll")
    }

    func testStaleSocketFileStillStartsTheServer() async throws {
        let path = socketPath!
        let stale = makeListener()
        try stale.start(at: path)
        stale.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "expected an orphaned socket file")
        XCTAssertFalse(LocalHerdrServer.socketAcceptsConnections(path))

        let listener = makeListener()
        let launches = Recorder()
        let server = LocalHerdrServer(
            binaryPath: { "/fake/herdr" },
            launcher: { binary in
                launches.record(binary)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { try? listener.start(at: path) }
                return .alive()
            }
        )

        try await server.ensureRunning(socketPath: path, timeout: 3)

        XCTAssertEqual(launches.values.count, 1, "an orphaned socket file is not a running server")
    }

    /// `herdr server` exits non-zero when another process wins the race to bind the socket.
    /// The socket, not the exit status, decides.
    func testExitedProcessWithAUsableSocketSucceeds() async throws {
        let path = socketPath!
        let listener = makeListener()
        let exited = Flag()
        let server = LocalHerdrServer(
            binaryPath: { "/fake/herdr" },
            launcher: { _ in
                // Death first, socket 50 ms later, both on one thread: the gap is a real sleep
                // instead of two independent timers, so the post-exit grace is what is being
                // measured and not the scheduler.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                    exited.set()
                    Thread.sleep(forTimeInterval: 0.05)
                    try? listener.start(at: path)
                }
                return LocalHerdrServer.Launched(
                    isRunning: { !exited.value },
                    output: { "error: herdr server is already running" }
                )
            }
        )

        try await server.ensureRunning(socketPath: path, timeout: 3)

        XCTAssertTrue(LocalHerdrServer.socketAcceptsConnections(path))
    }

    // MARK: - Failing

    func testMissingBinaryReportsHowToInstallIt() async throws {
        let launches = Recorder()
        let server = LocalHerdrServer(
            binaryPath: { nil },
            launcher: { binary in
                launches.record(binary)
                return .alive()
            }
        )

        let error = await captureError { try await server.ensureRunning(socketPath: socketPath, timeout: 1) }

        guard case .herdrNotInstalled? = error as? HerdrError else {
            return XCTFail("expected herdrNotInstalled, got \(String(describing: error))")
        }
        let description = try XCTUnwrap((error as? HerdrError)?.errorDescription)
        XCTAssertTrue(description.contains("brew install herdr"), description)
        XCTAssertTrue(description.contains("not found"), "the CLI may just be off herdrm's PATH: \(description)")
        XCTAssertEqual(launches.values, [])
    }

    func testFailedStartReportsTheProcessOutput() async throws {
        let server = LocalHerdrServer(
            binaryPath: { "/fake/herdr" },
            launcher: { _ in
                LocalHerdrServer.Launched(
                    isRunning: { false },
                    output: { "error: failed to read config at line 7" }
                )
            }
        )

        let error = await captureError { try await server.ensureRunning(socketPath: socketPath, timeout: 5) }

        let description = try XCTUnwrap((error as? HerdrError)?.errorDescription)
        XCTAssertTrue(description.contains("failed to read config at line 7"), description)
    }

    func testServerThatNeverOpensTheSocketTimesOut() async throws {
        let server = LocalHerdrServer(binaryPath: { "/fake/herdr" }, launcher: { _ in .alive() })

        let started = Date()
        let error = await captureError { try await server.ensureRunning(socketPath: socketPath, timeout: 1) }
        let elapsed = Date().timeIntervalSince(started)

        let description = try XCTUnwrap((error as? HerdrError)?.errorDescription)
        XCTAssertTrue(description.contains("timed out"), description)
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "gave up before the timeout")
        XCTAssertLessThan(elapsed, 3, "waited past the requested timeout")
    }

    // MARK: - Spawning and resolving
    /// A healthy server whose accept queue is momentarily full refuses connections on macOS.
    /// Spawning then would make `herdr server` unlink its socket and strand it.
    func testExistingSocketThatStartsAcceptingIsNeverRespawned() async throws {
        let path = socketPath!
        let stale = makeListener()
        try stale.start(at: path)
        stale.stop()  // the file stays: the ambiguous case, refusing for now

        let listener = makeListener()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { try? listener.start(at: path) }
        let launches = Recorder()
        let server = LocalHerdrServer(
            binaryPath: { "/fake/herdr" },
            launcher: { binary in
                launches.record(binary)
                return .alive()
            }
        )

        let started = Date()
        try await server.ensureRunning(socketPath: path, timeout: 5)

        XCTAssertEqual(launches.values, [], "herdrm spawned a second server over a live one")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "did not return as soon as it was served")
    }


    func testSpawnRunsTheServerSubcommandAndKeepsItsOutput() async throws {
        let script = directory.appendingPathComponent("fake-herdr")
        try """
        #!/bin/sh
        echo "argv: $*"
        echo "boom" >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let launched = try LocalHerdrServer.spawn(binary: script.path)
        for _ in 0..<100 where launched.isRunning() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(launched.isRunning())
        let output = launched.output()
        XCTAssertTrue(output.contains("argv: server"), output)
        XCTAssertTrue(output.contains("boom"), output)
    }

    /// The bug this guards: a GUI app has no `SHELL`, herdr then hands out `sh` panes and the
    /// user loses their rc files and everything under `~/.local/bin`.
    func testSpawnGivesTheServerAShellEvenWhenTheAppHasNone() async throws {
        let inherited = ProcessInfo.processInfo.environment["SHELL"]
        unsetenv("SHELL")
        setenv("HERDRM_TEST_MARKER", "kept", 1)
        defer {
            if let inherited { setenv("SHELL", inherited, 1) }
            unsetenv("HERDRM_TEST_MARKER")
        }

        let script = directory.appendingPathComponent("fake-herdr-env")
        try """
        #!/bin/sh
        echo "shell: $(printenv SHELL)"
        echo "marker: $(printenv HERDRM_TEST_MARKER)"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let launched = try LocalHerdrServer.spawn(binary: script.path)
        for _ in 0..<100 where launched.isRunning() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let output = launched.output()
        let shell = try XCTUnwrap(LocalHerdrServer.loginShell())
        XCTAssertTrue(output.contains("shell: \(shell)"), output)
        XCTAssertTrue(output.contains("marker: kept"), "the server lost the app's environment: \(output)")
    }

    func testTwoSpawnsDoNotShareALogFile() async throws {
        func script(named name: String, saying text: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try "#!/bin/sh\necho \"\(text)\"\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        let first = try LocalHerdrServer.spawn(binary: try script(named: "fake-a", saying: "first-server"))
        let second = try LocalHerdrServer.spawn(binary: try script(named: "fake-b", saying: "second-server"))
        for _ in 0..<100 where first.isRunning() || second.isRunning() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(first.output().contains("first-server"), first.output())
        XCTAssertFalse(first.output().contains("second-server"), "one spawn truncated the other's log")
        XCTAssertTrue(second.output().contains("second-server"), second.output())
    }

    func testServerEnvironmentDropsTheAppsProcessIdentity() {
        let base = [
            "__CFBundleIdentifier": "dev.bybee.herdrm",
            "XPC_SERVICE_NAME": "application.dev.bybee.herdrm.1.2",
            "XPC_FLAGS": "0x0",
            "OSLogRateLimit": "1",
            "MallocNanoZone": "0",
            "OS_ACTIVITY_DT_MODE": "YES",
            "DYLD_INSERT_LIBRARIES": "/usr/lib/libLogRedirect.dylib",
            "DYLD_FRAMEWORK_PATH": "/tmp/frameworks",
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/nobody",
            "LANG": "en_US.UTF-8",
        ]

        let environment = LocalHerdrServer.serverEnvironment(base: base)

        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "OSLogRateLimit",
                    "MallocNanoZone", "OS_ACTIVITY_DT_MODE", "DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH"] {
            XCTAssertNil(environment[key], "\(key) reached the daemon and every pane under it")
        }
        for key in ["PATH", "HOME", "LANG"] {
            XCTAssertEqual(environment[key], base[key], "the user's \(key) was thrown away")
        }
    }

    func testServerEnvironmentFillsInTheLoginShellWhenMissing() throws {
        let environment = LocalHerdrServer.serverEnvironment(base: ["PATH": "/usr/bin"])

        let shell = try XCTUnwrap(environment["SHELL"], "the server would hand out sh panes")
        XCTAssertFalse(shell.isEmpty)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell), shell)
    }

    func testServerEnvironmentKeepsAnExplicitShell() {
        let environment = LocalHerdrServer.serverEnvironment(base: ["SHELL": "/opt/homebrew/bin/fish"])

        XCTAssertEqual(environment["SHELL"], "/opt/homebrew/bin/fish", "a deliberate SHELL was overwritten")
    }

    func testServerEnvironmentTreatsAnEmptyShellAsMissing() throws {
        let environment = LocalHerdrServer.serverEnvironment(base: ["SHELL": ""])

        let shell = try XCTUnwrap(environment["SHELL"])
        XCTAssertFalse(shell.isEmpty, "an empty SHELL leaves herdr with no shell to pick")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell), shell)
    }

    func testServerEnvironmentPreservesTheRestOfTheEnvironment() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/nobody", "HERDRM_MARKER": "keep-me"]

        let environment = LocalHerdrServer.serverEnvironment(base: base)

        for (key, value) in base {
            XCTAssertEqual(environment[key], value, "the server lost \(key) from its environment")
        }
    }

    func testLoginShellIsAnExecutableFile() throws {
        let shell = try XCTUnwrap(LocalHerdrServer.loginShell())

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: shell, isDirectory: &isDirectory), shell)
        XCTAssertFalse(isDirectory.boolValue, "\(shell) is a directory, not a shell")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell), shell)
    }

    /// The condition the PATH export exists for: an app launched from Finder gets launchd's
    /// PATH, which has none of the places herdr installs into.
    func testResolverFindsHerdrUnderLaunchdsPath() throws {
        let sessionSocket = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/herdr/herdr.sock")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sessionSocket), "herdr is not installed here")

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let binary = try XCTUnwrap(
            LocalHerdrServer.resolveBinary(environment: environment),
            "herdr is installed but invisible to an app launched from Finder"
        )

        XCTAssertTrue(binary.hasSuffix("/herdr"), binary)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary), binary)
    }

    /// `mise use -g herdr` puts the CLI in a shim directory no other install method uses.
    func testResolverFindsAMiseShimmedHerdr() throws {
        let shims = directory.appendingPathComponent(".local/share/mise/shims", isDirectory: true)
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        let shim = shims.appendingPathComponent("herdr")
        try "#!/bin/sh\nexit 0\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let binary = LocalHerdrServer.resolveBinary(
            environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        )

        XCTAssertEqual(binary, shim.path, "a mise-installed herdr is invisible to herdrm")
    }

    // MARK: - Retry policy

    func testConnectStartsTheLocalServerAndRetriesThePing() async throws {
        let path = socketPath!
        let listener = makeListener()
        let launches = Recorder()
        let localServer = LocalHerdrServer(
            binaryPath: { "/fake/herdr" },
            launcher: { binary in
                launches.record(binary)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    try? listener.start(
                        at: path,
                        replyingWith: #"{"id":"1","result":{"version":"0.8.0","protocol":19}}"#
                    )
                }
                return .alive()
            }
        )
        let service = HerdrService(
            device: Device(name: "Test", kind: .local, socketPath: path),
            localServer: localServer
        )

        let pong = try await service.connect()

        XCTAssertEqual(pong.version, "0.8.0")
        XCTAssertEqual(pong.protocolVersion, 19)
        XCTAssertEqual(launches.values, ["/fake/herdr"], "the dead socket did not trigger a start")
    }

    /// Asserted on the wiring rather than through `connect()`: a broken flag would otherwise
    /// spawn a real `herdr server` against the machine's own socket, not the test's.
    func testAutoStartIsWiredOnlyForLocalDevicesThatAskedForIt() async {
        let local = Device(name: "Test", kind: .local, socketPath: socketPath)
        let remote = Device(name: "Remote", kind: .ssh(target: "nobody@example.invalid"))

        let byDefault = await HerdrService(device: local).autoStartsLocalServer
        let turnedOff = await HerdrService(device: local, autoStartLocalServer: false).autoStartsLocalServer
        let overSSH = await HerdrService(device: remote).autoStartsLocalServer

        XCTAssertTrue(byDefault, "the app relies on the default being on")
        XCTAssertFalse(turnedOff, "the flag did not turn auto-start off")
        XCTAssertFalse(overSSH, "remote servers are the user's to run")
    }

    /// A server that answered once and is gone was stopped on purpose (`herdr server stop`,
    /// or the restart inside `herdr update`). Reviving it would undo that decision.
    func testNoAutoStartAfterTheServerHasAnsweredOnce() async throws {
        let path = socketPath!
        let listener = makeListener()
        let launches = Recorder()
        let localServer = LocalHerdrServer(
            binaryPath: { "/fake/herdr" },
            launcher: { binary in
                launches.record(binary)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    try? listener.start(
                        at: path,
                        replyingWith: #"{"id":"1","result":{"version":"0.8.0","protocol":19}}"#
                    )
                }
                return .alive()
            }
        )
        let service = HerdrService(
            device: Device(name: "Test", kind: .local, socketPath: path),
            localServer: localServer
        )
        _ = try await service.connect()
        XCTAssertEqual(launches.values.count, 1)

        listener.stop()  // as `herdr server stop` does: the socket file outlives the server
        let error = await captureError { _ = try await service.connect() }

        XCTAssertNotNil(error, "the stopped server was silently restarted")
        XCTAssertEqual(launches.values.count, 1, "herdrm revived a server the user stopped")
    }

    func testOnlyADeadServerTriggersAnAutoStart() {
        XCTAssertTrue(HerdrService.isServerDown(.socketUnavailable("/tmp/herdr.sock")))
        XCTAssertTrue(HerdrService.isServerDown(.connectionFailed("connect(): Connection refused")))
        // Everything below proves somebody was on the other end: a second daemon on top of a
        // live one is how the user's panes get stranded.
        XCTAssertFalse(HerdrService.isServerDown(.connectionFailed("read(): Resource temporarily unavailable")))
        XCTAssertFalse(HerdrService.isServerDown(.connectionFailed("write(): Broken pipe")))
        XCTAssertFalse(HerdrService.isServerDown(.connectionFailed("socket(): Too many open files")))
        XCTAssertFalse(HerdrService.isServerDown(.connectionFailed("connect(): Permission denied")))
        XCTAssertFalse(HerdrService.isServerDown(.connectionFailed("not connected")))
        XCTAssertFalse(HerdrService.isServerDown(.rpc(code: "unknown_method", message: "nope")))
        XCTAssertFalse(HerdrService.isServerDown(.malformedResponse("empty reply")))
        XCTAssertFalse(HerdrService.isServerDown(.incompatibleProtocol(3)))
        XCTAssertFalse(HerdrService.isServerDown(.tunnelFailed("ssh exited 255")))
        XCTAssertFalse(HerdrService.isServerDown(.herdrNotInstalled))
    }

    // MARK: - Helpers

    private func makeListener() -> FakeListener {
        let listener = FakeListener()
        listeners.append(listener)
        return listener
    }

    /// XCTAssertThrowsError has no async form; the failure tests need the error itself.
    private func captureError(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }
}

private extension LocalHerdrServer.Launched {
    /// A process that is still up and has said nothing — the normal state while starting.
    static func alive() -> Self {
        .init(isRunning: { true }, output: { "" })
    }
}

/// A real listening Unix socket: the probe under test does a real `connect()`, so a stub
/// would prove nothing. `replyingWith` additionally answers one NDJSON line per connection,
/// which is all a `ping` needs. Started from background queues, hence the lock.
private final class FakeListener: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var reply: String?

    /// Binds and listens, clearing any orphaned socket file first — as herdr itself does.
    func start(at path: String, replyingWith reply: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }
        self.reply = reply
        try? FileManager.default.removeItem(atPath: path)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw HerdrError.connectionFailed("socket(): \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sock)
            throw HerdrError.connectionFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, len) }
        }
        guard bound == 0, Darwin.listen(sock, 4) == 0 else {
            let reason = String(cString: strerror(errno))
            close(sock)
            throw HerdrError.connectionFailed("listen(\(path)): \(reason)")
        }
        fd = sock
        if reply != nil { serve(on: sock) }
    }

    /// Closes the listener but leaves the socket file behind — the stale-socket fixture.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    /// One NDJSON reply per connection; the accept loop ends when `stop()` closes the socket.
    private func serve(on sock: Int32) {
        Thread.detachNewThread { [weak self] in
            while true {
                let connection = accept(sock, nil, nil)
                guard connection >= 0 else { return }
                // A peer may hang up before the reply (the liveness probe does exactly
                // that); writing into a closed connection would SIGPIPE the test process.
                var noSignal: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var request = [UInt8](repeating: 0, count: 4_096)
                let received = read(connection, &request, request.count)
                if received > 0, var line = self?.replyLine.map({ Array(($0 + "\n").utf8) }) {
                    _ = write(connection, &line, line.count)
                }
                close(connection)
            }
        }
    }

    private var replyLine: String? {
        lock.lock()
        defer { lock.unlock() }
        return reply
    }
}

/// A thread-safe one-way switch, for fakes that change state from a background queue.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        raised = true
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

/// Records what the injected launcher was asked to run, from whichever thread calls it.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
