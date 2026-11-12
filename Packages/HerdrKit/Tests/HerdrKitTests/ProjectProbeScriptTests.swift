import XCTest
@testable import HerdrKit

final class ProjectProbeScriptTests: XCTestCase {
    func testScriptIsValidPOSIXShell() throws {
        let process = Process()
        // dash is the strictest POSIX sh a Linux host will run; use it where this Mac has it.
        let shell = FileManager.default.isExecutableFile(atPath: "/bin/dash") ? "/bin/dash" : "/bin/sh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-n"]
        let input = Pipe()
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(ProjectProbeScript.source.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testLocalRunPrintsEveryRequestedSectionAndEndsTheFrame() async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        // git reports the physical path (/private/var/…), so hand the probe that one.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let tmp = realpath(raw.path, &buffer) != nil ? String(cString: buffer) : raw.path
        try Self.sh("git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && echo '{}' > package.json && printf 'API_PORT=8100\\nDB_PASSWORD=x\\n' > .env", in: tmp)

        let sections = ["tools", "host", "roots", "listeners", "files", "env", "vms"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ProjectProbeScript.shellArguments(sections: sections, cwds: [tmp])
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0)
        for needle in ["@@pp-begin 1", "@@tools", "@@host", "os Darwin", "@@roots", "\t\(tmp)", "@@listeners lsof", "@@files ", "@@env ", ":API_PORT\n"] {
            XCTAssertTrue(text.contains(needle), "missing \(needle) in:\n\(text)")
        }
        XCTAssertFalse(text.contains("DB_PASSWORD"))
        // Env lines carry key names only, never values.
        XCTAssertFalse(text.contains("8100"))
        // Darwin boottime is the epoch second, not the microseconds after it.
        let boot = text.split(separator: "\n").first { $0.hasPrefix("boottime ") }.flatMap { Double($0.dropFirst(9)) }
        XCTAssertGreaterThan(boot ?? 0, 1_000_000_000)
        XCTAssertTrue(text.contains("@@vms parallels") || text.contains("@@absent prlctl"))
        XCTAssertTrue(text.hasSuffix("@@pp-end\n"), "tail: \(text.suffix(80))")

        // The parser reads the real output back.
        let probe = ProjectProbeParser.parse(text)
        XCTAssertFalse(probe.partial)
        XCTAssertEqual(probe.roots.first?.toplevel, tmp)
        XCTAssertTrue(probe.files[tmp]?.contains { $0.hasSuffix("package.json") } == true)
        XCTAssertEqual(probe.envEntries.map(\.key), ["API_PORT"])
    }

    func testFindErrorsStayOutOfTheFileListAndAreReported() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw.appendingPathComponent("locked"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: raw.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: raw)
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let root = realpath(raw.path, &buffer) != nil ? String(cString: buffer) : raw.path
        try Self.sh("echo '{}' > package.json && touch '@@pp-end' && chmod 000 locked", in: root)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ProjectProbeScript.shellArguments(sections: ["files"], cwds: [root])
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let probe = ProjectProbeParser.parse(text)
        XCTAssertFalse(probe.partial)
        XCTAssertEqual(probe.files[root]?.map { ($0 as NSString).lastPathComponent }, ["package.json"])
        XCTAssertTrue(probe.errors["files"]?.contains("Permission denied") == true, "errors: \(probe.errors)\n\(text)")
    }

    func testLocalRunPidsAndDockerSectionsParseWithoutADaemon() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ProjectProbeScript.shellArguments(sections: ["listeners", "pids", "compose", "containers", "units"], cwds: [])
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let probe = ProjectProbeParser.parse(text)
        XCTAssertFalse(probe.partial)
        // Every listener the lsof pass saw has a process entry, and no entry lost its command name.
        for pid in Set(probe.listeners.flatMap(\.pids)) {
            XCTAssertNotNil(probe.processes[pid], "no process for listener pid \(pid)")
        }
        XCTAssertFalse(probe.processes.values.contains { $0.comm.isEmpty })
        XCTAssertNil(probe.errors["lsofp"])
        XCTAssertNil(probe.errors["listeners"])
    }

    func testRemoteCommandQuotesEverything() {
        let command = ProjectProbeScript.remoteCommand(sections: ["host"], cwds: ["/home/dev/it's here"])
        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertTrue(command.contains("'/home/dev/it'\\''s here'"))
    }

    func testIsSupportedMirrorsMachineStats() {
        XCTAssertTrue(ProjectProbeScript.isSupported(.local))
        XCTAssertFalse(ProjectProbeScript.isSupported(Device(name: "t", kind: .tailcat)))
        XCTAssertFalse(ProjectProbeScript.isSupported(Device(name: "w", kind: .ssh(target: "u@w"), osID: "windows")))
        XCTAssertTrue(ProjectProbeScript.isSupported(Device(name: "l", kind: .ssh(target: "u@l"), osID: "ubuntu")))
    }

    /// Runs the script with `HOME` pointed at a temp directory and returns its output.
    private func runScript(sections: [String], cwds: [String], home: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ProjectProbeScript.shellArguments(sections: sections, cwds: cwds)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return text
    }

    private func physicalTemp() throws -> String {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(raw.path, &buffer) != nil ? String(cString: buffer) : raw.path
    }

    func testPaneInHomeDirectoryScansNeitherFilesNorEnv() throws {
        let home = try physicalTemp()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.sh("echo '{}' > package.json && echo 'HOME_PORT=1' > .env && mkdir proj && echo '{}' > proj/package.json", in: home)

        let text = try runScript(sections: ["files", "env"], cwds: [home, home + "/proj"], home: home)
        XCTAssertFalse(text.contains("@@files \(home)\n"), text)
        XCTAssertFalse(text.contains("@@env \(home)/.env"), text)
        XCTAssertTrue(text.contains("@@files \(home)/proj\n"), text)
        let probe = ProjectProbeParser.parse(text)
        XCTAssertFalse(probe.partial)
        XCTAssertNil(probe.files[home])
        XCTAssertEqual(probe.files[home + "/proj"]?.count, 1)
        XCTAssertEqual(probe.envEntries, [])
    }

    func testDownDockerIsReportedOnceAndSkipsComposeAndContainers() throws {
        let home = try physicalTemp()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // $HOME/.local/bin is first on the script's PATH, so this stands in for a dead daemon.
        try Self.sh("mkdir -p .local/bin && printf '#!/bin/sh\\necho \"@@pp-end\" >&2\\necho \"Cannot connect to the Docker daemon\" >&2\\nexit 1\\n' > .local/bin/docker && chmod +x .local/bin/docker", in: home)

        let text = try runScript(sections: ["host", "compose", "containers"], cwds: [], home: home)
        XCTAssertEqual(text.components(separatedBy: "@@error docker").count - 1, 1, text)
        XCTAssertFalse(text.contains("@@error compose"), text)
        XCTAssertFalse(text.contains("@@error containers"), text)
        XCTAssertTrue(text.contains("docker_error Cannot connect"), text)
        XCTAssertTrue(text.hasSuffix("@@pp-end\n"))
        // A stderr line that looks like a frame header is dropped, not echoed into the frame.
        XCTAssertEqual(text.components(separatedBy: "@@pp-end").count - 1, 1, text)
        let probe = ProjectProbeParser.parse(text)
        XCTAssertFalse(probe.partial)
        XCTAssertEqual(probe.host?.dockerError, "Cannot connect to the Docker daemon")
        XCTAssertTrue(probe.errors["docker"]?.contains("Cannot connect") == true)
        XCTAssertEqual(probe.containers, [])
    }

    func testDockerSectionsComeAfterTheOtherDataSections() {
        let source = ProjectProbeScript.source
        let docker = source.range(of: "docker version")!.lowerBound
        for earlier in ["echo \"@@units\"", "printf '@@files", "printf '@@env"] {
            XCTAssertLessThan(source.range(of: earlier)!.lowerBound, docker, earlier)
        }
        XCTAssertLessThan(docker, source.range(of: "echo \"@@vms parallels\"")!.lowerBound)
    }

    private static func sh(_ command: String, in dir: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command)
    }
}
