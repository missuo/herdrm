import XCTest
@testable import HerdrKit

final class ShellEnvironmentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-shell-env-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Parser

    func testNulParserPreservesEqualsNewlinesAndDropsInjectedKeys() {
        var data = Data()
        data.append(entry("PLAIN", "value"))
        data.append(entry("EQUALS", "left=right"))
        data.append(entry("LINES", "one\ntwo"))
        data.append(entry("EMPTY", ""))
        data.append(entry(ShellEnvironment.captureFileKey, "/tmp/probe"))
        data.append(entry("DISABLE_AUTO_UPDATE", "true"))
        data.append(entry("ZSH_TMUX_AUTOSTART", "false"))
        data.append(Data("malformed-no-equals".utf8))
        data.append(0)

        let environment = ShellEnvironment.parseNulEnvironment(data)

        XCTAssertEqual(environment["PLAIN"], "value")
        XCTAssertEqual(environment["EQUALS"], "left=right")
        XCTAssertEqual(environment["LINES"], "one\ntwo")
        XCTAssertEqual(environment["EMPTY"], "")
        XCTAssertNil(environment[ShellEnvironment.captureFileKey])
        XCTAssertNil(environment["DISABLE_AUTO_UPDATE"])
        XCTAssertNil(environment["ZSH_TMUX_AUTOSTART"])
        XCTAssertNil(environment["malformed-no-equals"])
    }

    func testNulParserAcceptsLatin1WhenNotUTF8() {
        var data = Data("PATH=".utf8)
        data.append(0xFF)
        data.append(contentsOf: "/bin".utf8)
        data.append(0)

        let environment = ShellEnvironment.parseNulEnvironment(data)
        XCTAssertEqual(environment["PATH"]?.unicodeScalars.first, Unicode.Scalar(0xFF))
        XCTAssertTrue(environment["PATH"]?.hasSuffix("/bin") == true)
    }

    // MARK: - findExecutable

    func testSearchOrderPrefersShellPathOverProcessPathOverWellKnown() throws {
        let shellDir = try bin("shell-bin", command: "codex")
        let processDir = try bin("process-bin", command: "codex")
        let wellKnown = try bin(".local/bin", command: "codex")

        let snapshot = ShellEnvironment(variables: [
            "PATH": shellDir.path,
            "HOME": directory.path,
        ])

        XCTAssertEqual(
            snapshot.findExecutable("codex", processPath: processDir.path, home: directory.path),
            shellDir.appendingPathComponent("codex").path
        )

        let noShell = ShellEnvironment(variables: ["HOME": directory.path])
        XCTAssertEqual(
            noShell.findExecutable("codex", processPath: processDir.path, home: directory.path),
            processDir.appendingPathComponent("codex").path
        )

        let empty = ShellEnvironment(variables: ["HOME": directory.path])
        XCTAssertEqual(
            empty.findExecutable("codex", processPath: "/usr/bin:/bin", home: directory.path),
            wellKnown.appendingPathComponent("codex").path
        )
    }

    func testFindExecutableExpandsHomeAndRejectsMissingOverride() throws {
        let nested = try bin("tools", command: "claude")
        let snapshot = ShellEnvironment(variables: ["HOME": directory.path])

        XCTAssertEqual(
            snapshot.findExecutable("~/tools/claude", home: directory.path),
            nested.appendingPathComponent("claude").path
        )
        XCTAssertNil(snapshot.findExecutable("~/missing/claude", home: directory.path))
        XCTAssertNil(snapshot.findExecutable("with space"))
        XCTAssertNil(snapshot.findExecutable(""))
    }

    func testCursorKindMapsToCursorAgent() {
        XCTAssertEqual(HerdrService.binaryName(for: "cursor"), "cursor-agent")
        XCTAssertEqual(HerdrService.binaryName(for: "codex"), "codex")
    }

    func testLaunchEnvironmentKeepsWrapperVarsAndAppendsBinaryDirectory() {
        let snapshot = ShellEnvironment(variables: [
            "PATH": "/shell/bin",
            "HOME": directory.path,
            "NVM_DIR": "\(directory.path)/.nvm",
            "FNM_MULTISHELL_PATH": "/tmp/fnm",
        ])
        let launched = snapshot.launchEnvironment(
            binary: "/opt/custom/codex",
            processEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        )

        XCTAssertEqual(launched["NVM_DIR"], "\(directory.path)/.nvm")
        XCTAssertEqual(launched["FNM_MULTISHELL_PATH"], "/tmp/fnm")
        let path = launched["PATH"] ?? ""
        let parts = path.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.first, "/shell/bin")
        XCTAssertTrue(parts.contains("/usr/bin"))
        XCTAssertTrue(parts.contains("\(directory.path)/.local/bin"))
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
        XCTAssertEqual(parts.last, "/opt/custom")
    }

    func testInstalledAgentsHonorsOverrideAndCursorAlias() async throws {
        let cursor = try bin("bin", command: "cursor-agent")
        _ = try bin("bin", command: "codex")
        let snapshot = ShellEnvironment(variables: [
            "PATH": cursor.path,
            "HOME": directory.path,
        ])
        let service = HerdrService(device: .local, localServer: nil)

        let found = await service.installedAgents(
            from: ["claude", "cursor", "codex"],
            snapshot: snapshot
        )
        // `claude` is not planted here; a real ~/.local/bin/claude on the
        // machine must not leak into this assertion.
        XCTAssertEqual(found.map(\.kind).filter { $0 != "claude" }, ["cursor", "codex"])
        XCTAssertEqual(
            found.first { $0.kind == "cursor" }?.path,
            cursor.appendingPathComponent("cursor-agent").path
        )

        let overridden = await service.installedAgents(
            from: ["codex"],
            overrides: ["codex": "/no/such/codex"],
            snapshot: snapshot
        )
        XCTAssertTrue(overridden.isEmpty, "a missing override must not fall back to auto-detect")

        let redirected = await service.installedAgents(
            from: ["codex"],
            overrides: ["codex": "~/bin/cursor-agent"],
            snapshot: snapshot
        )
        XCTAssertEqual(redirected.first?.path, cursor.appendingPathComponent("cursor-agent").path)
    }

    func testHookAgentIsDiscoveredWithoutManifestAlongsidePi() async throws {
        let binaries = try bin("bin", command: "omp")
        _ = try bin("bin", command: "pi")
        let snapshot = ShellEnvironment(variables: [
            "PATH": binaries.path,
            "HOME": directory.path,
        ])
        let service = HerdrService(device: .local, localServer: nil)
        let found = await service.installedAgents(
            from: ["pi"],
            includingIntegrationKinds: ["omp", "omp"],
            snapshot: snapshot
        )
        XCTAssertEqual(found.map(\.kind), ["pi", "omp"])
        XCTAssertEqual(found.map(\.path), [
            binaries.appendingPathComponent("pi").path,
            binaries.appendingPathComponent("omp").path,
        ])

        let advertised = await service.installedAgents(
            from: ["omp", "pi"],
            includingIntegrationKinds: ["omp"],
            snapshot: snapshot
        )
        XCTAssertEqual(advertised.map(\.kind), ["omp", "pi"])

        let missing = await service.installedAgents(
            from: ["pi"],
            includingIntegrationKinds: ["omp"],
            overrides: ["omp": directory.appendingPathComponent("missing-omp").path],
            snapshot: snapshot
        )
        XCTAssertEqual(missing.map(\.kind), ["pi"])
    }

    // MARK: - Real zsh

    func testCaptureRunsLoginAndInteractiveStartupFilesAndIgnoresStdoutBanners() throws {
        let bin = directory.appendingPathComponent("agent-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "export HERDRM_LOGIN_MARKER=from-zprofile\n"
            .write(to: directory.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try """
        echo 'WELCOME TO ZSH'
        print -P '%F{red}prompt%f'
        export HERDRM_INTERACTIVE_MARKER=from-zshrc
        export HERDRM_COMPLEX_VALUE='left=right
        second line'
        export PATH="$HOME/agent-bin:$PATH"
        """.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let snapshot = ShellEnvironment.capture(from: [
            "HOME": directory.path,
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
        ])

        XCTAssertEqual(snapshot["HERDRM_LOGIN_MARKER"], "from-zprofile")
        XCTAssertEqual(snapshot["HERDRM_INTERACTIVE_MARKER"], "from-zshrc")
        XCTAssertEqual(snapshot["HERDRM_COMPLEX_VALUE"], "left=right\nsecond line")
        XCTAssertEqual(snapshot["PATH"]?.split(separator: ":").first, Substring(bin.path))
        XCTAssertFalse(snapshot["PATH"]?.contains("WELCOME") == true)
        XCTAssertNil(snapshot[ShellEnvironment.captureFileKey])
    }

    func testInteractiveHangFallsBackToLoginShell() throws {
        try "export HERDRM_LOGIN_MARKER=from-zprofile\n"
            .write(to: directory.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try """
        sleep 30
        export HERDRM_INTERACTIVE_MARKER=from-zshrc
        """.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let snapshot = ShellEnvironment.capture(
            from: [
                "HOME": directory.path,
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TERM": "dumb",
            ],
            interactiveTimeout: 0.4,
            roundTimeout: 2
        )

        XCTAssertEqual(snapshot["HERDRM_LOGIN_MARKER"], "from-zprofile")
        XCTAssertNil(snapshot["HERDRM_INTERACTIVE_MARKER"], "killed -i must not leak a partial interactive rc")
        XCTAssertNotNil(snapshot["PATH"])
    }

    func testCapturedPathFindsABinaryTheProcessPathCannotSee() throws {
        // A unique name: searchDirectories always appends the real machine's
        // well-known prefixes, so a genuine codex in /opt/homebrew/bin would
        // satisfy (or break) assertions about a fixture named after it.
        let command = "hkt-agent-\(UUID().uuidString.lowercased().prefix(8))"
        let bin = try bin("agent-bin", command: command)
        try #"export PATH="$HOME/agent-bin:$PATH""#
            .write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let snapshot = ShellEnvironment.capture(from: [
            "HOME": directory.path,
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
        ])

        XCTAssertEqual(
            snapshot.findExecutable(command, processPath: "/usr/bin:/bin", home: directory.path),
            bin.appendingPathComponent(command).path
        )
        XCTAssertNil(
            ShellEnvironment.empty.findExecutable(
                command,
                processPath: "/usr/bin:/bin",
                home: NSTemporaryDirectory()
            )
        )
    }

    func testShellCandidatesPreferProcessShellThenPasswd() {
        let candidates = ShellEnvironment.shellCandidates(from: ["SHELL": "/bin/zsh"])
        XCTAssertEqual(candidates.first, "/bin/zsh")
        XCTAssertTrue(candidates.contains("/bin/sh"))
    }

    // MARK: - Helpers

    private func bin(_ relative: String, command: String) throws -> URL {
        let url = directory.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(command)
        try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return url
    }

    private func entry(_ name: String, _ value: String) -> Data {
        var data = Data(name.utf8)
        data.append(UInt8(ascii: "="))
        data.append(Data(value.utf8))
        data.append(0)
        return data
    }
}
