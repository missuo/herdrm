import CryptoKit
import Darwin
import Foundation
import Testing

@testable import HerdrSSH

/// `SSHConnection.connect(overDescriptor:)`: SSH over a stream the caller
/// pumps (Herdrm's relay hands libssh2 one end of a socketpair). Here the
/// other end is pumped into a TCP connection to a disposable sshd.
///
/// HERDRSSH_DESCRIPTOR_SSHD_PORT (on 127.0.0.1), HERDRSSH_DESCRIPTOR_USER and
/// HERDRSSH_DESCRIPTOR_KEY_SEED (base64 Ed25519 seed whose key that sshd
/// accepts). Pass them with TEST_RUNNER_ prefixes through xcodebuild.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["HERDRSSH_DESCRIPTOR_SSHD_PORT"] != nil),
    .timeLimit(.minutes(1)))
struct DescriptorConnectionTests {
    let env = ProcessInfo.processInfo.environment

    static func tcp(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { throw SSHError.connectionFailed }
        return fd
    }

    /// Copies bytes from `a` to `b` until EOF, on a thread.
    static func copy(_ a: Int32, _ b: Int32) {
        Thread {
            var buffer = [UInt8](repeating: 0, count: 32768)
            while true {
                let n = read(a, &buffer, buffer.count)
                if n <= 0 { break }
                var off = 0
                while off < n {
                    let w = buffer.withUnsafeBytes { write(b, $0.baseAddress! + off, n - off) }
                    if w <= 0 { return }
                    off += w
                }
            }
            shutdown(b, SHUT_WR)
        }.start()
    }

    @Test func sshRunsOverACallerPumpedDescriptor() async throws {
        let port = try #require(env["HERDRSSH_DESCRIPTOR_SSHD_PORT"].flatMap(UInt16.init))
        let user = try #require(env["HERDRSSH_DESCRIPTOR_USER"])
        let seed = try #require(env["HERDRSSH_DESCRIPTOR_KEY_SEED"].flatMap { Data(base64Encoded: $0) })
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)

        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let server = try Self.tcp(port: port)
        Self.copy(fds[1], server)
        Self.copy(server, fds[1])

        let connection = try await SSHConnection.connect(overDescriptor: fds[0], timeout: .seconds(10))
        #expect(connection.hostKey.algorithm.contains("ed25519"))
        var blob = Data()
        for part in [Data("ssh-ed25519".utf8), key.publicKey.rawRepresentation] {
            var n = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &n) { blob.append(contentsOf: $0) }
            blob.append(part)
        }
        try await connection.authenticate(
            username: user, publicKey: blob,
            signer: { try key.signature(for: $0) }, timeout: .seconds(10))
        let result = try await connection.execute("printf over-descriptor", timeout: .seconds(10))
        #expect(result.stdout == Data("over-descriptor".utf8))
        #expect(result.exitStatus == 0)
        try await connection.close(timeout: .seconds(2))
    }
}

/// `authenticate(privateKey:passphrase:)` with real key files against a
/// disposable sshd: HERDRSSH_KEY_SSHD_PORT, HERDRSSH_DESCRIPTOR_USER, and
/// base64 file contents in HERDRSSH_KEY_ED25519_PASS (passphrase "correct
/// horse"), HERDRSSH_KEY_RSA (none) and HERDRSSH_KEY_UNAUTHORIZED.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["HERDRSSH_KEY_SSHD_PORT"] != nil),
    .timeLimit(.minutes(1)))
struct PrivateKeyAuthenticationTests {
    let env = ProcessInfo.processInfo.environment

    func key(_ name: String) throws -> Data {
        try #require(env[name].flatMap { Data(base64Encoded: $0) })
    }

    func connect() async throws -> SSHConnection {
        let port = try #require(env["HERDRSSH_KEY_SSHD_PORT"].flatMap(UInt16.init))
        return try await SSHConnection.connect(to: SSHEndpoint(host: "127.0.0.1", port: port), timeout: .seconds(10))
    }

    @Test func aPassphraseProtectedEd25519KeySignsInAndAWrongPassphraseLeavesTheConnectionUsable() async throws {
        let user = try #require(env["HERDRSSH_DESCRIPTOR_USER"])
        let connection = try await connect()
        await #expect(throws: SSHError.privateKeyUnreadable) {
            try await connection.authenticate(username: user, privateKey: try key("HERDRSSH_KEY_ED25519_PASS"),
                                              passphrase: "wrong", timeout: .seconds(10))
        }
        try await connection.authenticate(username: user, privateKey: try key("HERDRSSH_KEY_ED25519_PASS"),
                                          passphrase: "correct horse", timeout: .seconds(10))
        let result = try await connection.execute("printf ed25519-ok", timeout: .seconds(10))
        #expect(result.stdout == Data("ed25519-ok".utf8))
        try await connection.close(timeout: .seconds(2))
    }

    @Test func anRSAKeySignsIn() async throws {
        let user = try #require(env["HERDRSSH_DESCRIPTOR_USER"])
        let connection = try await connect()
        try await connection.authenticate(username: user, privateKey: try key("HERDRSSH_KEY_RSA"),
                                          passphrase: nil, timeout: .seconds(10))
        let result = try await connection.execute("printf rsa-ok", timeout: .seconds(10))
        #expect(result.stdout == Data("rsa-ok".utf8))
        try await connection.close(timeout: .seconds(2))
    }

    @Test func aKeyTheServerDoesNotKnowFailsAndTheNextOneIsTried() async throws {
        let user = try #require(env["HERDRSSH_DESCRIPTOR_USER"])
        let connection = try await connect()
        await #expect(throws: SSHError.authenticationFailed) {
            try await connection.authenticate(username: user, privateKey: try key("HERDRSSH_KEY_UNAUTHORIZED"),
                                              passphrase: nil, timeout: .seconds(10))
        }
        try await connection.authenticate(username: user, privateKey: try key("HERDRSSH_KEY_RSA"),
                                          passphrase: nil, timeout: .seconds(10))
        #expect(try await connection.execute("printf next-ok", timeout: .seconds(10)).stdout == Data("next-ok".utf8))
        try await connection.close(timeout: .seconds(2))
    }
}
