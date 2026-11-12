import Foundation
import Testing
@testable import HerdrKit

struct RemoteAgentCatalogTests {
    @Test func batchProbeFindsOnlyExecutablesAndPreservesManifestOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent tools \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["cursor-agent", "codex", "omp", "not-executable"] {
            let binary = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: name == "not-executable" ? 0o644 : 0o755], ofItemAtPath: binary.path)
        }
        let kinds = ["missing", "cursor", "codex", "not-executable", "omp"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteAgentCatalog.unixScript(kinds: kinds)]
        process.environment = ["PATH": directory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let found = try RemoteAgentCatalog.parse(String(decoding: data, as: UTF8.self), kinds: kinds)
        #expect(found.map(\.kind) == ["cursor", "codex", "omp"])
        #expect(found.map(\.path) == ["cursor-agent", "codex", "omp"].map { directory.appendingPathComponent($0).path })
    }

    @Test func loginBannersAreIgnoredAndAnEmptyCatalogRequiresACompletedProbe() throws {
        let output = "Server health report\r\n\(RemoteAgentCatalog.begin)\r\n1\t/home/test/bin/codex\r\n\(RemoteAgentCatalog.end)\r\nLogged out\r\n"
        let found = try RemoteAgentCatalog.parse(output, kinds: ["claude", "codex"])
        #expect(found.map(\.kind) == ["codex"])
        #expect(try RemoteAgentCatalog.parse("\(RemoteAgentCatalog.begin)\n\(RemoteAgentCatalog.end)\n", kinds: ["codex"]).isEmpty)
        #expect(throws: HerdrError.self) { try RemoteAgentCatalog.parse("Login banner only\n", kinds: ["codex"]) }
        #expect(throws: HerdrError.self) { try RemoteAgentCatalog.parse("\(RemoteAgentCatalog.begin)\n", kinds: ["codex"]) }
    }

    @Test func windowsProbeUsesPowerShellAndFindsExecutableScripts() throws {
        let kinds = ["cursor", "codex"]
        let command = RemoteAgentCatalog.command(kinds: kinds, platform: .windows(home: "C:\\Users\\test", herdrExecutable: "herdr.exe"))
        let encoded = try #require(command.components(separatedBy: "-EncodedCommand ").last)
        let data = try #require(Data(base64Encoded: encoded))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains("-Name 'cursor-agent'"))
        #expect(script.contains("-CommandType Application,ExternalScript"))
        let found = try RemoteAgentCatalog.parse("\(RemoteAgentCatalog.begin)\r\n1\tC:\\Program Files\\nodejs\\codex.cmd\r\n\(RemoteAgentCatalog.end)\r\n", kinds: kinds)
        #expect(found.first?.kind == "codex")
        #expect(found.first?.path == "C:\\Program Files\\nodejs\\codex.cmd")
    }

    @Test func anUnreachableRemoteNeverUsesTheMacsInstalledAgents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("test-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let local = ShellEnvironment(variables: ["PATH": directory.path, "HOME": directory.path])
        let service = HerdrService(device: Device(name: "test-server", kind: .ssh(target: "test.invalid")))
        do {
            _ = try await service.installedAgents(from: ["test-agent"], snapshot: local)
            Issue.record("A failed remote lookup must report failure, not return the Mac's test-agent")
        } catch {
            #expect(error is HerdrError)
        }
    }
}
