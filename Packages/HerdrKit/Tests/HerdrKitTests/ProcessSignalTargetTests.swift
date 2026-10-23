#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HerdrKit

struct ProcessSignalTargetTests {
    @Test func sendsSignalsToTheCapturedProcess() throws {
        let process = try startProcess()
        defer { stop(process) }
        let target = try #require(ProcessSignalTarget.capture(pid: process.processIdentifier))
        #expect(target.send(SIGKILL) == 0)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
    }

    @Test func rejectsTheSamePIDWithADifferentGeneration() throws {
        let process = try startProcess()
        defer { stop(process) }
        let target = try #require(ProcessSignalTarget.capture(pid: process.processIdentifier))
        var staleToken = target.token
        staleToken.val.7 &+= 1
        let staleTarget = ProcessSignalTarget(token: staleToken)
        #expect(staleTarget.send(SIGKILL) == ESRCH)
        #expect(kill(process.processIdentifier, 0) == 0)
        #expect(process.isRunning)
    }

    @Test func rejectsSignalsAfterTheOriginalProcessExits() throws {
        let process = try startProcess()
        defer { stop(process) }
        let target = try #require(ProcessSignalTarget.capture(pid: process.processIdentifier))
        process.terminate()
        process.waitUntilExit()
        #expect(target.send(SIGKILL) == ESRCH)
    }

    @Test func invalidPIDsHaveNoSignalTarget() {
        #expect(ProcessSignalTarget.capture(pid: 0) == nil)
        #expect(ProcessSignalTarget.capture(pid: -1) == nil)
    }

    private func startProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
#endif
