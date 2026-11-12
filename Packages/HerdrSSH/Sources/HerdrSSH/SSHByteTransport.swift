import Darwin
import Foundation

/// The package-private transport seam used by nested SSH sessions. The inner
/// driver receives only a non-blocking byte descriptor; the outer libssh2
/// session and direct-tcpip channel never cross this boundary.
protocol SSHByteTransport: AnyObject, Sendable {
    func takeDescriptor() throws -> Int32
    func close(timeout: Duration) async throws
    func abort()
}

final class DirectTCPIPByteTransport: SSHByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var innerDescriptor: Int32
    private var pumpTask: Task<Result<Void, SSHError>, Never>?

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SSHError.connectionFailed
        }
        do {
            try Self.makeNonBlocking(descriptors[0])
            try Self.makeNonBlocking(descriptors[1])
            try Self.disableSIGPIPE(descriptors[0])
            try Self.disableSIGPIPE(descriptors[1])
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
        innerDescriptor = descriptors[0]
        pumpDescriptor = descriptors[1]
    }

    private var pumpDescriptor: Int32

    func takePumpDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard pumpDescriptor >= 0 else { throw SSHError.connectionInvalidated }
        let descriptor = pumpDescriptor
        pumpDescriptor = -1
        return descriptor
    }

    func start(_ task: Task<Result<Void, SSHError>, Never>) {
        lock.lock()
        precondition(pumpTask == nil)
        pumpTask = task
        lock.unlock()
    }

    func takeDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard innerDescriptor >= 0 else { throw SSHError.connectionInvalidated }
        let descriptor = innerDescriptor
        innerDescriptor = -1
        return descriptor
    }

    func close(timeout: Duration) async throws {
        let task = lock.withLock { pumpTask }
        guard let task else { return }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let result = await withTaskGroup(of: Result<Void, SSHError>.self) { group in
            group.addTask { await task.value }
            group.addTask {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    return .failure(.timedOut)
                } catch {
                    return .failure(.cancelled)
                }
            }
            let first = await group.next() ?? .failure(.connectionFailed)
            group.cancelAll()
            return first
        }
        if case .failure(.timedOut) = result {
            task.cancel()
            _ = await task.value
        }
        try result.get()
    }

    func abort() {
        lock.lock()
        let descriptor = innerDescriptor
        innerDescriptor = -1
        let unusedPumpDescriptor = pumpTask == nil ? pumpDescriptor : -1
        if unusedPumpDescriptor >= 0 { pumpDescriptor = -1 }
        let task = pumpTask
        lock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
        if unusedPumpDescriptor >= 0 { Darwin.close(unusedPumpDescriptor) }
        task?.cancel()
    }

    deinit {
        abort()
    }

    private static func makeNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SSHError.connectionFailed
        }
    }

    private static func disableSIGPIPE(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            throw SSHError.connectionFailed
        }
    }
}

/// A stream descriptor the caller handed over (`SSHConnection.connect(overDescriptor:)`).
/// There is no pump to wait for: whoever feeds the other end owns that.
final class DescriptorByteTransport: SSHByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) throws {
        guard descriptor >= 0 else { throw SSHError.connectionFailed }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            throw SSHError.connectionFailed
        }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        self.descriptor = descriptor
    }

    func takeDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw SSHError.connectionInvalidated }
        let taken = descriptor
        descriptor = -1
        return taken
    }

    func close(timeout _: Duration) async throws { abort() }

    func abort() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    deinit { abort() }
}
