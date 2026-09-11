import Darwin
import Foundation
import XCTest
@testable import HerdrKit

final class SocketRPCTests: XCTestCase {
    func testEventSubscriptionsIncludeScopedStatusPanesOnce() throws {
        let params = SocketRPC.eventSubscriptionParams(
            kinds: ["pane.updated"],
            statusPaneIDs: ["w1:p2", "w1:p1", "w1:p2"]
        )
        XCTAssertEqual(
            params,
            .object([
                "subscriptions": .array([
                    .object(["type": .string("pane.updated")]),
                    .object([
                        "type": .string("pane.agent_status_changed"),
                        "pane_id": .string("w1:p1"),
                    ]),
                    .object([
                        "type": .string("pane.agent_status_changed"),
                        "pane_id": .string("w1:p2"),
                    ]),
                ])
            ])
        )
    }

    func testDecodeEventNormalizesLifecycleAndScopedEventNames() throws {
        let lifecycle = try XCTUnwrap(SocketRPC.decodeEvent(
            Data(#"{"event":"pane_updated","data":{"pane":{"pane_id":"w1:p1"}}}"#.utf8)
        ))
        XCTAssertEqual(lifecycle.kind, "pane.updated")

        let status = try XCTUnwrap(SocketRPC.decodeEvent(
            Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"working"}}"#.utf8)
        ))
        XCTAssertEqual(status.kind, HerdrEvent.agentStatusChangedKind)

        let snakeStatus = try XCTUnwrap(SocketRPC.decodeEvent(
            Data(#"{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"working"}}"#.utf8)
        ))
        XCTAssertEqual(snakeStatus.kind, HerdrEvent.agentStatusChangedKind)
    }

    func testStaleStatusPaneRetriesWithoutScopedSubscriptions() {
        XCTAssertTrue(SocketRPC.shouldRetryStatusSubscription(
            after: HerdrError.rpc(code: "pane_not_found", message: "gone"),
            statusPaneIDs: ["w1:p1"]
        ))
        XCTAssertFalse(SocketRPC.shouldRetryStatusSubscription(
            after: HerdrError.rpc(code: "pane_not_found", message: "gone"),
            statusPaneIDs: []
        ))
        XCTAssertFalse(SocketRPC.shouldRetryStatusSubscription(
            after: HerdrError.rpc(code: "invalid_params", message: "bad"),
            statusPaneIDs: ["w1:p1"]
        ))
    }

    func testReadLineKeepsNDJSONRecordsFollowingTheFirstLine() throws {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
        }
        XCTAssertEqual(result, 0, String(cString: strerror(errno)))
        defer {
            close(fds[0])
            close(fds[1])
        }

        // This is what happens when the acknowledgement and an event arrive in
        // one read(). The event bytes must survive consuming the acknowledgement.
        var buffer = Data("ack\n{\"event\":\"pane.updated\"}\n".utf8)
        XCTAssertEqual(
            try SocketRPC.readLine(fd: fds[0], timeoutSeconds: 15, buffer: &buffer),
            Data("ack".utf8)
        )
        XCTAssertEqual(buffer, Data("{\"event\":\"pane.updated\"}\n".utf8))
        XCTAssertEqual(
            try SocketRPC.readLine(fd: fds[0], timeoutSeconds: nil, buffer: &buffer),
            Data("{\"event\":\"pane.updated\"}".utf8)
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testReadLineClearsARequestTimeoutForAnEventStream() throws {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
        }
        XCTAssertEqual(result, 0, String(cString: strerror(errno)))
        defer {
            close(fds[0])
            close(fds[1])
        }

        var first = Array("first\n".utf8)
        XCTAssertEqual(write(fds[1], &first, first.count), first.count)
        var buffer = Data()
        XCTAssertEqual(try SocketRPC.readLine(fd: fds[0], timeoutSeconds: 1, buffer: &buffer), Data("first".utf8))

        var timeout = timeval()
        var timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(
            getsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, &timeoutLength),
            0,
            String(cString: strerror(errno))
        )
        XCTAssertEqual(timeout.tv_sec, 1)

        // Force the second readLine call to return from the existing buffer (no read()).
        buffer = Data("second\n".utf8)
        XCTAssertEqual(try SocketRPC.readLine(fd: fds[0], timeoutSeconds: nil, buffer: &buffer), Data("second".utf8))

        timeout = timeval()
        timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(
            getsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, &timeoutLength),
            0,
            String(cString: strerror(errno))
        )
        XCTAssertEqual(timeout.tv_sec, 0, "the event stream inherited the request timeout")
        XCTAssertEqual(timeout.tv_usec, 0)
    }

    func testConnectDisablesSIGPIPE() throws {
        // Names stay short because sockaddr_un caps paths at 104 bytes and
        // temporaryDirectory already burns most of that (/var/folders/…).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("s.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        XCTAssertLessThan(pathBytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(listener, socketAddress, addressLength)
            }
        }
        XCTAssertEqual(bindResult, 0, String(cString: strerror(errno)))
        XCTAssertEqual(listen(listener, 1), 0, String(cString: strerror(errno)))

        let client = try SocketRPC.connect(path: path)
        defer { close(client) }

        var noSigPipe: Int32 = 0
        var optionLength = socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        XCTAssertEqual(
            getsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &optionLength),
            0,
            String(cString: strerror(errno))
        )
        XCTAssertEqual(noSigPipe, 1)
    }
}
