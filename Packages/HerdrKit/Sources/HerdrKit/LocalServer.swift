import Foundation

/// Starts the local herdr server on demand, so a cold boot connects instead of telling the
/// user to go run `herdr` in a terminal first.
///
/// Every collaborator is injected: `binaryPath` finds the CLI, `launcher` spawns it, and
/// `ensureRunning` takes the socket path and the timeout. Nothing is global, so the whole
/// flow is exercisable on a machine where herdr isn't installed.
public struct LocalHerdrServer: Sendable {
    /// A spawned `herdr server`: watched, never owned. See `spawn(binary:)`.
    public struct Launched: Sendable {
        /// Whether the spawned process is still alive.
        public let isRunning: @Sendable () -> Bool
        /// What the process printed. Meaningful once it has exited.
        public let output: @Sendable () -> String

        public init(
            isRunning: @escaping @Sendable () -> Bool,
            output: @escaping @Sendable () -> String
        ) {
            self.isRunning = isRunning
            self.output = output
        }
    }

    /// PATH used to find the herdr CLI. GUI apps launched from Finder don't inherit a
    /// login-shell PATH, hence the same export the SSH side uses, plus mise's shim
    /// directory: `mise use -g herdr` is one of herdr's install methods and its shims sit
    /// in none of the other directories. `SSHTunnel.remotePathExport` stays untouched on
    /// purpose — it is shared with the tunnel and the terminal attach, where the extra
    /// directory would belong to the remote user, not to this Mac.
    public static let localPathExport =
        "\(SSHTunnel.remotePathExport); export PATH=\"$HOME/.local/share/mise/shims:$PATH\""

    /// Grace given to the socket after the spawned process exits. `herdr server` also exits
    /// non-zero when another process won the race to bind the socket — that server is
    /// serving, so an exit on its own is not a failure.
    private static let exitGracePeriod: TimeInterval = 0.5

    /// How long an existing-but-refusing socket is re-probed before it counts as stale.
    /// Sized for a momentarily full accept queue (milliseconds), not for a slow start.
    private static let ambiguousSocketGrace: TimeInterval = 1

    private let binaryPath: @Sendable () -> String?
    private let launcher: @Sendable (String) throws -> Launched
    private let pollInterval: TimeInterval

    public init(
        binaryPath: @escaping @Sendable () -> String? = { LocalHerdrServer.resolveBinary() },
        launcher: @escaping @Sendable (String) throws -> Launched = { try LocalHerdrServer.spawn(binary: $0) },
        pollInterval: TimeInterval = 0.05
    ) {
        self.binaryPath = binaryPath
        self.launcher = launcher
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    /// Returns once `socketPath` accepts connections, starting `herdr server` if it doesn't.
    /// Cheap and safe to call on every connect: a live socket short-circuits.
    public func ensureRunning(socketPath: String, timeout: TimeInterval = 10) async throws {
        guard try await serverIsGone(socketPath: socketPath) else { return }
        guard let binary = binaryPath() else { throw HerdrError.herdrNotInstalled }
        let launched = try launcher(binary)

        let timeoutDeadline = Date().addingTimeInterval(timeout)
        var deadline = timeoutDeadline
        var exited = false
        while true {
            // Only a real connection proves the server is up: herdr creates the socket file
            // tens of milliseconds before it accepts, and a dead server leaves it behind.
            if Self.socketAcceptsConnections(socketPath) { return }
            if !exited, !launched.isRunning() {
                exited = true
                deadline = min(Date().addingTimeInterval(Self.exitGracePeriod), timeoutDeadline)
            }
            guard Date() < deadline else { break }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        if exited {
            throw HerdrError.connectionFailed(
                "herdr server exited without serving \(socketPath): \(launched.output())"
            )
        }
        throw HerdrError.connectionFailed("timed out waiting for the herdr server at \(socketPath)")
    }

    /// Whether nobody is serving `socketPath`, and starting a server is therefore safe.
    ///
    /// An existing socket file is the ambiguous case, and getting it wrong is expensive: when
    /// a healthy server's accept queue is momentarily full macOS answers `ECONNREFUSED`, and
    /// `herdr server` reacts to a refused socket by unlinking it and binding its own — which
    /// would strand the running server holding all of the user's panes, unreachable and
    /// invisible to `herdr server stop`. A full backlog drains in milliseconds while a stale
    /// socket stays dead forever, so the ambiguous case is re-probed before concluding
    /// anything. No file means no ambiguity: nothing to strand, and no latency added to the
    /// case that matters.
    private func serverIsGone(socketPath: String) async throws -> Bool {
        if Self.socketAcceptsConnections(socketPath) { return false }
        guard FileManager.default.fileExists(atPath: socketPath) else { return true }
        let deadline = Date().addingTimeInterval(Self.ambiguousSocketGrace)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if Self.socketAcceptsConnections(socketPath) { return false }
        }
        return true
    }

    // MARK: - Collaborators

    /// Locates the herdr CLI (`command -v` under `localPathExport`); nil when not found.
    /// `environment` overrides what the lookup inherits, which is how a launchd-style PATH
    /// (or a different `$HOME`) can be exercised without touching this process.
    public static func resolveBinary(environment: [String: String]? = nil) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "\(localPathExport); command -v herdr"]
        if let environment { proc.environment = environment }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Spawns `herdr server` and hands back a handle for watching it.
    ///
    /// The process is deliberately **not** owned: nothing here terminates it, and there is no
    /// counterpart to `SSHTunnel.tearDown()`. herdr's server is a shared daemon holding every
    /// agent's PTY, so killing it when herdrm quits would take the user's running agents down
    /// with it. It is meant to outlive us (launchd reparents it) and a second `herdr server`
    /// is a harmless no-op, so leaving it running is the correct end state.
    ///
    /// Its output goes to a file for the same reason: an undrained pipe stalls the daemon once
    /// the buffer fills, and closing our end of it would break the daemon's stdout — while a
    /// file still carries the real error text when the start fails.
    public static func spawn(binary: String) throws -> Launched {
        // Unique per spawn: a fixed name would let a second herdrm (or a second start)
        // truncate a log file the live daemon still holds open at a non-zero offset.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-herdr-server-\(getpid())-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            throw HerdrError.connectionFailed("could not open \(logURL.path)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["server"]
        proc.environment = serverEnvironment()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = log
        proc.standardError = log
        do {
            try proc.run()
        } catch {
            throw HerdrError.connectionFailed("herdr server spawn: \(error.localizedDescription)")
        }
        let watched = ProcessBox(proc)
        return Launched(
            isRunning: { watched.process.isRunning },
            output: {
                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                return String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2_000))
            }
        )
    }

    /// The environment handed to the server, which is `base` plus a `SHELL` when it has none.
    ///
    /// herdr picks the shell of every pane from `$SHELL`, and launchd does not export it: a GUI
    /// app started from Finder has no `SHELL` in its environment (`launchctl getenv SHELL` is
    /// empty), so a server spawned from herdrm would give the user `sh` panes instead of their
    /// login shell — no `.zshrc`, and none of the agents installed under `~/.local/bin` (claude
    /// among them) on PATH. The panes are interactive shells that rebuild their own PATH from
    /// the rc files, so `SHELL` is the only variable that has to be right here.
    ///
    /// An explicit `SHELL` is never overwritten: running a shell other than the account's is a
    /// deliberate choice. When the login shell cannot be resolved, nothing is set and herdr
    /// keeps whatever default it has.
    /// Process identity of the GUI app, which must not reach the daemon: the server outlives
    /// herdrm and every pane inherits its environment, so `__CFBundleIdentifier` would make a
    /// pane's `defaults`/NSUserDefaults hit herdrm's domain and TCC prompts get attributed to
    /// the app (revoking herdrm's permissions would then break agents). `DYLD_*` and friends
    /// come from an Xcode debug launch and would be baked into a daemon outliving Xcode.
    /// Everything else the user's environment carries is wanted and stays.
    private static let strippedEnvironmentKeys: Set<String> = [
        "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS",
        "OSLogRateLimit", "MallocNanoZone", "OS_ACTIVITY_DT_MODE",
    ]

    private static let strippedEnvironmentPrefix = "DYLD_"

    static func serverEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base.filter {
            !strippedEnvironmentKeys.contains($0.key) && !$0.key.hasPrefix(strippedEnvironmentPrefix)
        }
        let declared = base["SHELL"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard declared.isEmpty, let shell = loginShell() else { return environment }
        environment["SHELL"] = shell
        return environment
    }

    /// The account's login shell straight from the password database (`getpwuid`), which is
    /// where it lives when the environment doesn't carry it. nil when it can't be read.
    static func loginShell() -> String? {
        guard let entry = getpwuid(getuid())?.pointee.pw_shell else { return nil }
        let shell = String(cString: entry).trimmingCharacters(in: .whitespaces)
        return shell.isEmpty ? nil : shell
    }

    /// True when something is listening on `path` right now, using the very same connect the
    /// RPC client does — a `fileExists` check would accept a stale socket file.
    static func socketAcceptsConnections(_ path: String) -> Bool {
        guard let fd = try? SocketRPC.connect(path: path) else { return false }
        close(fd)
        return true
    }
}

/// Lets the observation closures be `@Sendable` around a `Process`, which isn't.
/// Safe because the wrapped process is only ever read (`isRunning`), never mutated.
private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
