import Foundation

/// Newline-delimited JSON RPC over a Unix domain socket.
/// Like Heeler, each request opens a fresh connection; event subscriptions
/// hold one long-lived connection and stream lines.
public struct SocketRPC: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - Requests

    public func request(method: String, params: JSONValue? = .object([:])) async throws -> JSONValue {
        let path = socketPath
        return try await Task.detached(priority: .userInitiated) {
            let fd = try Self.connect(path: path)
            defer { close(fd) }
            try Self.writeLine(fd: fd, data: Self.encodeRequest(id: UUID().uuidString, method: method, params: params))
            let line = try Self.readLine(fd: fd, timeoutSeconds: 15)
            return try Self.decodeResponse(line)
        }.value
    }

    public func request<T: Decodable>(method: String, params: JSONValue? = .object([:]), as type: T.Type) async throws -> T {
        let result = try await request(method: method, params: params)
        let data = try JSONEncoder().encode(result)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HerdrError.malformedResponse("\(method): \(error)")
        }
    }

    // MARK: - Event stream

    /// Opens a persistent connection, sends events.subscribe, and yields each event line.
    /// The stream finishes when the connection drops; callers own reconnect policy.
    public func events(
        kinds: [String] = HerdrEvent.allKinds,
        statusPaneIDs: [String] = []
    ) -> AsyncThrowingStream<HerdrEvent, Error> {
        let path = socketPath
        return AsyncThrowingStream { continuation in
            let socketHandle = EventSocketHandle()
            let task = Task.detached(priority: .utility) {
                var scopedPaneIDs = statusPaneIDs
                do {
                    subscriptionAttempt: while !Task.isCancelled {
                        var fd: Int32 = -1
                        do {
                            fd = try Self.connect(path: path)
                            guard socketHandle.install(fd) else {
                                close(fd)
                                continuation.finish()
                                return
                            }
                            let subs = Self.eventSubscriptionParams(
                                kinds: kinds,
                                statusPaneIDs: scopedPaneIDs
                            )
                            try Self.writeLine(
                                fd: fd,
                                data: Self.encodeRequest(
                                    id: "events",
                                    method: "events.subscribe",
                                    params: subs
                                )
                            )
                            // A single read() can contain the acknowledgement and one or
                            // more events. Keep the buffer used for the acknowledgement so
                            // those already-received events are not discarded.
                            var buffer = Data()
                            let ack = try Self.readLine(
                                fd: fd,
                                timeoutSeconds: 15,
                                buffer: &buffer
                            )
                            do {
                                _ = try Self.decodeResponse(ack)
                            } catch where Self.shouldRetryStatusSubscription(
                                after: error,
                                statusPaneIDs: scopedPaneIDs
                            ) {
                                // A pane can close after the snapshot and before
                                // subscribe. Keep lifecycle events alive for one
                                // cycle; subscription.started makes the caller
                                // re-snapshot and reopen with the corrected set.
                                socketHandle.closeIfOwned(fd)
                                fd = -1
                                scopedPaneIDs = []
                                continue subscriptionAttempt
                            }
                            continuation.yield(HerdrEvent(
                                kind: HerdrEvent.subscriptionStartedKind,
                                payload: .object([:])
                            ))
                            while !Task.isCancelled {
                                guard let line = try Self.readLine(
                                    fd: fd,
                                    timeoutSeconds: nil,
                                    buffer: &buffer
                                ) else { break }
                                guard !line.isEmpty else { continue }
                                if let event = Self.decodeEvent(line) {
                                    continuation.yield(event)
                                }
                            }
                            if fd >= 0 {
                                socketHandle.closeIfOwned(fd)
                            }
                            continuation.finish()
                            return
                        } catch {
                            if fd >= 0 {
                                socketHandle.closeIfOwned(fd)
                            }
                            throw error
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                socketHandle.terminate()
            }
        }
    }

    public static func eventSubscriptionParams(
        kinds: [String],
        statusPaneIDs: [String]
    ) -> JSONValue {
        var subscriptions = kinds.map {
            JSONValue.object(["type": .string($0)])
        }
        subscriptions.append(contentsOf: Set(statusPaneIDs).sorted().map {
            JSONValue.object([
                "type": .string(HerdrEvent.agentStatusChangedKind),
                "pane_id": .string($0),
            ])
        })
        return .object(["subscriptions": .array(subscriptions)])
    }

    public static func decodeEvent(_ line: Data) -> HerdrEvent? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return nil
        }
        let rawKind = value["event"]?.stringValue
            ?? value["event"]?["type"]?.stringValue
            ?? value["type"]?.stringValue
            ?? value["kind"]?.stringValue
            ?? "unknown"
        return HerdrEvent(kind: HerdrEvent.normalizedKind(rawKind), payload: value)
    }

    public static func shouldRetryStatusSubscription(
        after error: Error,
        statusPaneIDs: [String]
    ) -> Bool {
        guard !statusPaneIDs.isEmpty,
              case HerdrError.rpc(let code, _) = error
        else { return false }
        return code == "pane_not_found"
    }

    // MARK: - Wire helpers

    public static func encodeRequest(id: String, method: String, params: JSONValue?) -> Data {
        // herdr requires `params` to be present even when empty.
        var object: [String: JSONValue] = ["id": .string(id), "method": .string(method)]
        object["params"] = params ?? .object([:])
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return data + Data([0x0A])
    }

    public static func decodeResponse(_ line: Data?) throws -> JSONValue {
        guard let line, !line.isEmpty else { throw HerdrError.malformedResponse("empty reply") }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            throw HerdrError.malformedResponse("undecodable reply")
        }
        if let error = value["error"] {
            let code = error["code"]?.stringValue ?? "unknown"
            let message = error["message"]?.stringValue ?? "unknown error"
            throw HerdrError.rpc(code: code, message: message)
        }
        guard let result = value["result"] else {
            throw HerdrError.malformedResponse("reply has neither result nor error")
        }
        return result
    }

    static func connect(path: String) throws -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else {
            throw HerdrError.socketUnavailable(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.connectionFailed("socket(): \(String(cString: strerror(errno)))") }
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        ) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw HerdrError.connectionFailed("setsockopt(SO_NOSIGPIPE): \(reason)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw HerdrError.connectionFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }

        guard rc == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw HerdrError.connectionFailed("connect(): \(reason)")
        }
        return fd
    }

    static func writeLine(fd: Int32, data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            guard written > 0 else { throw HerdrError.connectionFailed("write(): \(String(cString: strerror(errno)))") }
            remaining = remaining.dropFirst(written)
        }
    }

    private final class EventSocketHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var terminated = false

        func install(_ fd: Int32) -> Bool {
            lock.lock()
            guard !terminated else {
                lock.unlock()
                return false
            }
            self.fd = fd
            lock.unlock()
            return true
        }

        func closeIfOwned(_ expected: Int32) {
            lock.lock()
            let owned = fd == expected ? fd : -1
            if owned >= 0 { fd = -1 }
            lock.unlock()
            if owned >= 0 { close(owned) }
        }

        func terminate() {
            lock.lock()
            terminated = true
            let current = fd
            fd = -1
            lock.unlock()
            if current >= 0 {
                Darwin.shutdown(current, SHUT_RDWR)
                close(current)
            }
        }
    }

    /// Reads one \n-terminated line. `timeoutSeconds: nil` blocks indefinitely (event stream).
    static func readLine(fd: Int32, timeoutSeconds: Int32?) throws -> Data? {
        var buffer = Data()
        return try readLine(fd: fd, timeoutSeconds: timeoutSeconds, buffer: &buffer)
    }

    static func readLine(fd: Int32, timeoutSeconds: Int32?, buffer: inout Data) throws -> Data? {
        // SO_RCVTIMEO belongs to the file descriptor, not to an individual
        // read, so it must be (re)applied on every call — including the
        // buffer-only fast path below — or a timeout left by an earlier timed
        // read would survive into a blocking (nil timeout) call. The event
        // stream must block indefinitely, so a nil timeout restores the zero
        // value; an idle stream failing with EAGAIN every 15s is a regression.
        var tv = timeval(
            tv_sec: timeoutSeconds.map { Int($0) } ?? 0,
            tv_usec: 0
        )
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw HerdrError.connectionFailed("setsockopt(SO_RCVTIMEO): \(String(cString: strerror(errno)))")
        }
        if let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: index)
            buffer.removeSubrange(...index)
            return Data(line)
        }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { return buffer.isEmpty ? nil : buffer }
            if count < 0 {
                if errno == EINTR { continue }
                throw HerdrError.connectionFailed("read(): \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: chunk[0..<count])
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: index)
                buffer.removeSubrange(...index)
                return Data(line)
            }
        }
    }
}
