#if os(macOS)
import Foundation
import Testing
@testable import HerdrKit

/// Keys made by the real ssh-keygen at test time; fingerprints must match
/// `ssh-keygen -l` exactly, including for passphrase-protected keys.
struct SSHPrivateKeyFileTests {
    static func keygen(_ args: [String]) throws -> (key: String, fingerprint: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("k").path
        func run(_ a: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = a
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        _ = try run(["-q", "-f", path, "-C", "test"] + args)
        let fingerprint = try run(["-l", "-E", "sha256", "-f", path + ".pub"]).split(separator: " ")[1]
        return (try String(contentsOfFile: path, encoding: .utf8), String(fingerprint))
    }

    @Test(arguments: [
        (["-t", "ed25519", "-N", ""], SSHPrivateKeyFile.Kind.ed25519, false),
        (["-t", "ed25519", "-N", "secret phrase"], .ed25519, true),
        (["-t", "rsa", "-b", "3072", "-N", ""], .rsa, false),
        (["-t", "ecdsa", "-b", "256", "-N", "pw"], .ecdsa, true),
    ])
    func readsOpenSSHKeysWithTheirFingerprint(args: [String], kind: SSHPrivateKeyFile.Kind, encrypted: Bool) throws {
        let made = try Self.keygen(args)
        let summary = try SSHPrivateKeyFile.summarize(made.key)
        #expect(summary.kind == kind)
        #expect(summary.encrypted == encrypted)
        #expect(summary.fingerprint == made.fingerprint)
    }

    @Test func readsLegacyPEMKeys() throws {
        let made = try Self.keygen(["-t", "rsa", "-b", "2048", "-N", "", "-m", "PEM"])
        #expect(made.key.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"))
        let summary = try SSHPrivateKeyFile.summarize(made.key)
        #expect(summary.kind == .rsa)
        #expect(summary.encrypted == false)
    }

    @Test func refusesWhatIsNotAPrivateKey() {
        #expect(throws: SSHPrivateKeyFile.Problem.publicKey) {
            try SSHPrivateKeyFile.summarize("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOf me@laptop")
        }
        #expect(throws: SSHPrivateKeyFile.Problem.putty) {
            try SSHPrivateKeyFile.summarize("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none")
        }
        #expect(throws: SSHPrivateKeyFile.Problem.unrecognized) { try SSHPrivateKeyFile.summarize("hello") }
        #expect(throws: SSHPrivateKeyFile.Problem.unrecognized) {
            try SSHPrivateKeyFile.summarize("-----BEGIN OPENSSH PRIVATE KEY-----\nbm90IGEga2V5\n-----END OPENSSH PRIVATE KEY-----")
        }
    }
}
#endif
