import CryptoKit
import Darwin
import Foundation

/// One WebSocket to the relay.
final class RelaySocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = RelayProtocol.maxFrame + 1024
        task.resume()
    }

    func send(_ data: Data) async throws {
        do { try await task.send(.data(data)) } catch { throw mapped(error) }
    }

    func send(control: RelayProtocol.Control) async throws {
        let text = String(decoding: try JSONEncoder().encode(control), as: UTF8.self)
        do { try await task.send(.string(text)) } catch { throw mapped(error) }
    }

    /// The next binary frame. A text frame here is a protocol violation.
    func receiveData() async throws -> Data {
        switch try await receive() {
        case .data(let data): return data
        case .string: throw RelayError.protocolViolation("unexpected text frame")
        @unknown default: throw RelayError.protocolViolation("unknown frame")
        }
    }

    func receiveControl() async throws -> RelayProtocol.Control {
        switch try await receive() {
        case .string(let text):
            do {
                return try JSONDecoder().decode(RelayProtocol.Control.self, from: Data(text.utf8))
            } catch {
                throw RelayError.protocolViolation("bad control message")
            }
        case .data: throw RelayError.protocolViolation("unexpected binary frame")
        @unknown default: throw RelayError.protocolViolation("unknown frame")
        }
    }

    private func receive() async throws -> URLSessionWebSocketTask.Message {
        do { return try await task.receive() } catch { throw mapped(error) }
    }

    /// The relay's close code says why, where there is one.
    private func mapped(_ error: Error) -> Error {
        if let relayError = RelayError.from(closeCode: task.closeCode.rawValue) { return relayError }
        if task.closeCode != .invalid { return RelayError.closed }
        return error
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    deinit { close() }
}

/// An established, end-to-end encrypted session over the relay: whole
/// messages in, whole messages out.
public final class RelayStream: @unchecked Sendable {
    private let socket: RelaySocket
    private let lock = NSLock()
    private var send: NoiseCipher
    private var receive: NoiseCipher
    private let sendQueue = AsyncSerial()
    public let peerStatic: Data

    init(socket: RelaySocket, session: NoiseSession) {
        self.socket = socket
        self.send = session.send
        self.receive = session.receive
        self.peerStatic = session.peerStatic
    }

    /// Sends `data`, split into frames of at most `RelayNoise.maxPlaintext`.
    public func write(_ data: Data) async throws {
        try await sendQueue.run {
            var offset = data.startIndex
            repeat {
                let end = data.index(offset, offsetBy: RelayNoise.maxPlaintext, limitedBy: data.endIndex) ?? data.endIndex
                let frame = try self.lock.withLock { try self.send.encrypt(Data(data[offset..<end])) }
                try await self.socket.send(frame)
                offset = end
            } while offset < data.endIndex
        }
    }

    /// The next message; throws when the session is over or a frame doesn't
    /// decrypt (which ends it: Noise never skips a nonce).
    public func read() async throws -> Data {
        let frame = try await socket.receiveData()
        return try lock.withLock { try receive.decrypt(frame) }
    }

    func writeJSON<T: Encodable>(_ value: T) async throws { try await write(try JSONEncoder().encode(value)) }

    func readJSON<T: Decodable>(_ type: T.Type) async throws -> T {
        do {
            return try JSONDecoder().decode(type, from: try await read())
        } catch let error as RelayError {
            throw error
        } catch let error as RelayNoise.Failure {
            throw error
        } catch {
            throw RelayError.protocolViolation("bad session message")
        }
    }

    public func close() { socket.close() }
}

/// Runs async blocks one at a time, in order.
actor AsyncSerial {
    private var tail: Task<Void, Error>?

    func run(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task {
            _ = try? await previous?.value
            try await body()
        }
        tail = task
        try await task.value
    }
}

/// Moves bytes both ways between a stream socket and a relay session until
/// either side ends, then closes the socket and the session. The Mac uses it
/// for its connection to sshd; the phone for the socketpair its SSH client
/// reads.
public enum RelayPump {
    /// Takes ownership of `descriptor` (blocking mode).
    public static func run(descriptor: Int32, stream: RelayStream) async {
        let queue = DispatchQueue(label: "herdrm.relay.pump.write")
        await withTaskGroup(of: Void.self) { group in
            // socket → relay: a dedicated thread does the blocking reads.
            group.addTask {
                let chunks = AsyncStream<Data> { continuation in
                    let thread = Thread {
                        var buffer = [UInt8](repeating: 0, count: RelayNoise.maxPlaintext)
                        while true {
                            let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                            if n > 0 {
                                continuation.yield(Data(buffer[0..<n]))
                            } else if n < 0, errno == EINTR {
                                continue
                            } else {
                                break
                            }
                        }
                        continuation.finish()
                    }
                    thread.name = "herdrm.relay.pump.read"
                    thread.start()
                }
                for await chunk in chunks {
                    do { try await stream.write(chunk) } catch { break }
                }
                stream.close()
            }
            // relay → socket.
            group.addTask {
                while let data = try? await stream.read() {
                    let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                        queue.async { done.resume(returning: writeAll(descriptor, data)) }
                    }
                    if !ok { break }
                }
                // Wakes the reading thread: its read() returns 0.
                Darwin.shutdown(descriptor, SHUT_RDWR)
                stream.close()
            }
            await group.waitForAll()
        }
        Darwin.close(descriptor)
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// A connected pair of stream sockets, both blocking, SIGPIPE off.
    public static func socketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw RelayError.protocolViolation("socketpair failed") }
        var on: Int32 = 1
        for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        return (fds[0], fds[1])
    }
}

// MARK: - Phone

/// The phone's side: reach the Mac through the relay, run the handshake, say
/// hello, and get back the session.
public enum RelayClient {
    public struct Connection: Sendable {
        public let stream: RelayStream
        public let host: RelayMessage.HostInfo
    }

    /// `psk` is the pairing secret when `pairing` (a scanned code), the
    /// stored key after.
    public static func connect(
        relay: URL,
        hostID: String,
        hostStatic: Data,
        psk: Data,
        phoneKey: Curve25519.KeyAgreement.PrivateKey,
        hello: RelayMessage.Hello,
        pairing: Bool = false
    ) async throws -> Connection {
        let socket = RelaySocket(url: RelayProtocol.endpoint(relay, path: "/v1/connect", query: ["id": hostID]))
        do {
            let open = try await socket.receiveControl()
            guard open.t == "open" else { throw RelayError.protocolViolation("expected open") }
            var noise = try NoiseInitiator(
                prologue: RelayNoise.prologue(hostID: hostID), staticKey: phoneKey,
                responderStatic: hostStatic, psk: psk)
            // `pair` tells the Mac to use the code's secret even for a phone it
            // already knows (pairing again); it still has to hold that secret.
            let opening = pairing ? #"{"v":1,"pair":true}"# : #"{"v":1}"#
            try await socket.send(try noise.writeMessage1(payload: Data(opening.utf8)))
            let (payload, session) = try noise.readMessage2(try await socket.receiveData())
            guard let host = try? JSONDecoder().decode(RelayMessage.HostInfo.self, from: payload) else {
                throw RelayError.protocolViolation("bad host info")
            }
            let stream = RelayStream(socket: socket, session: session)
            try await stream.writeJSON(hello)
            let reply = try await stream.readJSON(RelayMessage.Reply.self)
            guard reply.t == "welcome" else {
                stream.close()
                throw RelayError.refused(reply.message ?? String(localized: "The Mac refused the connection."))
            }
            return Connection(stream: stream, host: host)
        } catch RelayNoise.Failure.decryptionFailed {
            socket.close()
            // Message 2 is the first thing only the real Mac with the right
            // key can produce: a stale pairing or an expired code lands here.
            throw RelayError.refused(String(localized: "The Mac didn't accept this pairing. Scan a new code on the Mac."))
        } catch {
            socket.close()
            throw error
        }
    }
}
