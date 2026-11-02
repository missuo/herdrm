import Foundation

enum SSHConnectionTeardownStep: Sendable, Equatable {
    case targetSession
    case forwardingChannel
    case jumpSession
}

/// Its `deinit`, like those of `SSHPTYChannel`, `SSHStreamLocalChannel`,
/// `SSHSFTPClient` and `SSHSFTPFile`, hands remote cleanup to an unstructured
/// `Task` that nothing retains: `deinit` returns with that work still
/// outstanding, and no caller can await it. In a test process that reads as
/// flakiness rather than as failure, because the work begins whenever the last
/// reference happens to drop — so its cost can land on a later test than the
/// one whose assertions provoked it.
///
/// The cost is uneven across the five, and this `deinit` is the cheap end. It
/// invalidates the driver — no operation mutex, no deadline — and only for a
/// connection opened through a Jump Host does it also abort the forwarding
/// transport and close the parent, so a direct connection reaches no close at
/// all. The one close it can reach, `SessionDriver.close`, is cancellable, and
/// its two-second budget bounds only the native calls: the deadline is computed
/// after `acquireOperation()` returns, so the wait for the driver's operation
/// mutex ahead of it is unbounded. The four channel `deinit`s are the expensive
/// end — they take that same mutex and then run non-cancellably.
///
/// #139 is linked for its timing evidence, not as a cause — nothing here
/// establishes that these `deinit`s produce it; it records the same failure
/// moving between two adjacent tests of one suite, which is timing no single
/// test controls, and its own `deinit` hypothesis was built on
/// `SSHPTYChannel`. #136 has since stopped the four `close*` channel teardowns
/// invalidating the session when a close only ran out of time, but that
/// verdict reaches no further: `SessionDriver.close`, the close reached from
/// here, still invalidates on any failure including a bare expiry, as do the
/// two-second cleanup in `execute`'s catch and its sibling operation paths, of
/// which #149 tracks only some.
public final class SSHConnection: Sendable {
    public let hostKey: SSHHostKey

    private let driver: SessionDriver
    private let parent: SSHConnection?
    private let byteTransport: (any SSHByteTransport)?
    private let teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)?

    private init(
        driver: SessionDriver,
        hostKey: SSHHostKey,
        parent: SSHConnection? = nil,
        byteTransport: (any SSHByteTransport)? = nil,
        teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)? = nil
    ) {
        self.driver = driver
        self.hostKey = hostKey
        self.parent = parent
        self.byteTransport = byteTransport
        self.teardownObserver = teardownObserver
    }

    public static func connect(
        to endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> SSHConnection {
        let driver = SessionDriver()
        let hostKey = try await driver.handshake(endpoint: endpoint, timeout: timeout)
        return SSHConnection(driver: driver, hostKey: hostKey)
    }

    /// Runs the SSH handshake over a stream the caller already has, such as one
    /// end of a socketpair whose other end a relay session pumps. The
    /// connection takes ownership of `descriptor` (it is made non-blocking) and
    /// closes it on close.
    public static func connect(
        overDescriptor descriptor: Int32,
        timeout: Duration
    ) async throws -> SSHConnection {
        let transport = try DescriptorByteTransport(descriptor: descriptor)
        let driver = SessionDriver()
        do {
            let hostKey = try await driver.handshake(transport: transport, timeout: timeout)
            return SSHConnection(driver: driver, hostKey: hostKey, byteTransport: transport)
        } catch {
            await driver.invalidate()
            transport.abort()
            throw error
        }
    }

    /// Opens an SSH connection to `endpoint` through this authenticated Jump
    /// Host. The returned connection owns both hops and closes them in target,
    /// forwarding-channel, Jump Host order.
    public func connectThrough(
        to endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> SSHConnection {
        try await connectThrough(
            to: endpoint,
            timeout: timeout,
            teardownObserver: nil)
    }

    func connectThrough(
        to endpoint: SSHEndpoint,
        timeout: Duration,
        teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)?
    ) async throws -> SSHConnection {
        let transport = try await driver.openDirectTCPIP(
            endpoint: endpoint,
            timeout: timeout)
        let targetDriver = SessionDriver()
        do {
            let hostKey = try await targetDriver.handshake(
                transport: transport,
                timeout: timeout)
            return SSHConnection(
                driver: targetDriver,
                hostKey: hostKey,
                parent: self,
                byteTransport: transport,
                teardownObserver: teardownObserver)
        } catch {
            await targetDriver.invalidate()
            transport.abort()
            try? await transport.close(timeout: .seconds(2))
            try? await close(timeout: .seconds(2))
            throw error
        }
    }

    public func authenticate(
        username: String,
        password: String,
        timeout: Duration
    ) async throws {
        try await driver.authenticate(
            username: username,
            password: password,
            timeout: timeout)
    }

    /// Signs in with a private key file's contents (OpenSSH or PEM format;
    /// Ed25519, ECDSA or RSA; `passphrase` for an encrypted one). A wrong key
    /// or passphrase throws `.authenticationFailed` and leaves the connection
    /// usable for another attempt.
    public func authenticate(
        username: String,
        privateKey: Data,
        passphrase: String?,
        timeout: Duration
    ) async throws {
        try await driver.authenticate(
            username: username, privateKey: privateKey, passphrase: passphrase, timeout: timeout)
    }

    public func authenticate(
        username: String,
        publicKey: Data,
        signer: @escaping SSHSigningClosure,
        timeout: Duration
    ) async throws {
        try await driver.authenticate(
            username: username,
            publicKey: publicKey,
            signer: signer,
            timeout: timeout)
    }

    public func execute(
        _ command: String,
        input: Data = Data(),
        timeout: Duration
    ) async throws -> SSHExecResult {
        try await driver.execute(command: command, input: input, timeout: timeout)
    }

    /// Opens one SSH session channel, sends exactly one newline-terminated
    /// input line, reads one bounded newline-terminated stdout response, and
    /// closes the channel. This is for forced-command request/response
    /// protocols whose process lifetime must not control the caller's bound.
    public func executeResponseLine(
        _ command: String,
        input: Data,
        maximumResponseBytes: Int,
        timeout: Duration
    ) async throws -> Data {
        try await driver.executeResponseLine(
            command: command,
            input: input,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout)
    }

    /// Opens one SSH session channel, requests the configured PTY, and then
    /// executes `command` directly. No login shell or shell request is exposed
    /// to the caller's terminal stream.
    public func openPTY(
        command: String,
        terminal: String = "xterm-256color",
        columns: Int,
        rows: Int,
        timeout: Duration
    ) async throws -> SSHPTYChannel {
        try await driver.openPTY(
            command: command,
            terminal: terminal,
            columns: columns,
            rows: rows,
            timeout: timeout)
    }

    /// Opens one direct-streamlocal channel, writes one request, reads one
    /// newline-terminated response, and closes the channel. Every call owns a
    /// fresh channel to preserve one-request-per-socket protocols.
    public func exchangeStreamLocal(
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int = 1_048_576,
        timeout: Duration
    ) async throws -> Data {
        try await driver.exchangeStreamLocal(
            socketPath: socketPath,
            request: request,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout)
    }

    /// Opens one long-lived direct-streamlocal channel. The returned handle
    /// owns only that channel; closing it leaves this SSH connection reusable
    /// when native teardown succeeds.
    public func openStreamLocal(
        socketPath: String,
        timeout: Duration
    ) async throws -> SSHStreamLocalChannel {
        try await driver.openStreamLocal(
            socketPath: socketPath,
            timeout: timeout)
    }

    /// Opens the package's deliberately small SFTP surface on one SSH session
    /// channel. Closing the returned client leaves this connection reusable.
    public func openSFTP(timeout: Duration) async throws -> SSHSFTPClient {
        try await driver.openSFTP(timeout: timeout)
    }

    /// Whether this session still has a live native connection that can
    /// safely admit another operation. An uncertain channel outcome makes
    /// this false before the app can reuse the connection.
    public var isConnected: Bool {
        get async { await driver.isReusable }
    }

#if DEBUG
    public func delayNextSFTPWriteForTesting(_ delay: Duration) async {
        await driver.delayNextSFTPWriteForTesting(delay)
    }

    public var isSFTPWriteDelayedForTesting: Bool {
        get async { await driver.isSFTPWriteDelayedForTesting }
    }

    public func holdNextSessionWaitForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await driver.holdNextSessionWaitForTesting(hold)
    }

    public func holdNextExecChannelAllocationForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextExecChannelAllocationForTesting(hold)
    }

    public func holdNextExecCleanupForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextExecCleanupForTesting(hold)
    }

    public func runNextCompensationUnlinkPhaseHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.runNextCompensationUnlinkPhaseHookForTesting(hook)
    }

    public func runNextCompensationStatPhaseHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.runNextCompensationStatPhaseHookForTesting(hook)
    }

    public func runNextCompensationShutdownHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.runNextCompensationShutdownHookForTesting(hook)
    }

    public func failNextSFTPInitBeforeEAGAINForTesting() async {
        await driver.failNextSFTPInitBeforeEAGAINForTesting()
    }

    public var operationWaiterCountForTesting: Int {
        get async { await driver.operationWaiterCountForTesting }
    }
#endif

    public func close(timeout: Duration) async throws {
        var firstError: (any Error)?
        do {
            try await driver.close(timeout: timeout)
        } catch {
            firstError = error
        }
        if byteTransport != nil { teardownObserver?(.targetSession) }
        if let byteTransport {
            do {
                try await byteTransport.close(timeout: timeout)
            } catch {
                if firstError == nil { firstError = error }
            }
            teardownObserver?(.forwardingChannel)
        }
        if let parent {
            do {
                try await parent.close(timeout: timeout)
            } catch {
                if firstError == nil { firstError = error }
            }
            teardownObserver?(.jumpSession)
        }
        if let firstError { throw firstError }
    }

    deinit {
        let driver = driver
        let byteTransport = byteTransport
        let parent = parent
        Task {
            await driver.invalidate()
            byteTransport?.abort()
            if let parent { try? await parent.close(timeout: .seconds(2)) }
        }
    }
}
