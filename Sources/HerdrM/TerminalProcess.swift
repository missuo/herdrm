import Darwin
import Foundation

/// A local child process attached to a pseudo-terminal — the byte pump that
/// SwiftTerm's `LocalProcess` used to provide underneath the terminal view.
///
/// Output chunks arrive on a private serial queue; the exit callback fires
/// exactly once, on the main queue. All entry points are safe to call from
/// any thread.
final class TerminalProcess: @unchecked Sendable {
    private(set) var shellPid: pid_t = 0
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    /// Reads, the exit watch, and EOF handling are serialized here.
    private let ioQueue = DispatchQueue(label: "dev.bybee.herdrm.terminal-process.io")
    /// Writes go through a dedicated queue so a blocked child can never stall a
    /// caller (keyboard bytes arrive on Ghostty's IO thread).
    private let writeQueue = DispatchQueue(label: "dev.bybee.herdrm.terminal-process.write")
    private let stateLock = NSLock()
    private var exitReported = false

    /// Called on the IO queue with each chunk read from the PTY.
    var onOutput: ((Data) -> Void)?
    /// Called exactly once, on the main queue, when the child exits. The code is
    /// the real exit status (ssh transport failures exit 255); nil when the
    /// child died to a signal.
    var onExit: ((Int32?) -> Void)?

    /// Forks a PTY and execs `executable` with the given (complete) environment.
    @discardableResult
    func start(
        executable: String,
        args: [String],
        environment: [String],
        columns: UInt16 = 80,
        rows: UInt16 = 24
    ) -> Bool {
        stateLock.lock()
        let alreadyRunning = shellPid > 0
        stateLock.unlock()
        guard !alreadyRunning else { return false }

        // Build the C arrays before forking: the child must reach execve without
        // touching the Swift runtime or the allocator.
        var argv = ([executable] + args).map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)

        if pid == 0 {
            // Child. forkpty made the slave the controlling terminal on stdin/
            // stdout/stderr; only exec remains.
            execve(executable, &argv, &envp)
            _exit(127)
        }

        for string in argv { free(string) }
        for string in envp { free(string) }

        guard pid > 0, master >= 0 else {
            if master >= 0 { close(master) }
            return false
        }

        stateLock.lock()
        shellPid = pid
        masterFD = master
        stateLock.unlock()

        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        read.setEventHandler { [weak self] in self?.drainOutput() }
        read.setCancelHandler { close(master) }
        readSource = read
        read.activate()

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        exit.setEventHandler { [weak self] in self?.handleChildExit() }
        exitSource = exit
        exit.activate()
        return true
    }

    /// Queues bytes for the child. Never blocks the caller.
    func write(_ data: Data) {
        writeQueue.async { [weak self] in
            self?.writeSynchronously(data)
        }
    }

    private func writeSynchronously(_ data: Data) {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    func resize(columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32) {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0 else { return }
        var size = winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: UInt16(min(widthPixels, UInt32(UInt16.max))),
            ws_ypixel: UInt16(min(heightPixels, UInt32(UInt16.max)))
        )
        // TIOCSWINSZ on the master delivers SIGWINCH to the foreground group.
        ioctl(fd, TIOCSWINSZ, &size)
    }

    /// Tears the process down without reporting an exit: a view being destroyed
    /// must not surface its own teardown as a session end. Interactive shells
    /// ignore SIGTERM, so this sends SIGHUP — the "terminal went away" signal
    /// shells exit on — and escalates to SIGKILL when a stuck foreground job
    /// holds the shell up.
    func terminate() {
        stateLock.lock()
        exitReported = true
        let pid = shellPid
        shellPid = 0
        masterFD = -1
        stateLock.unlock()

        // Cancelling the read source closes the master fd (its cancel handler),
        // which alone hangs up most children.
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil

        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    private func drainOutput() {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0, let readSource else { return }

        // One read per event, sized to what the source reports as available.
        // Looping to EOF on a blocking PTY fd would park the IO queue — and
        // with it the cancel handler that terminate() is waiting on.
        var buffer = [UInt8](repeating: 0, count: max(Int(readSource.data), 4096))
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            onOutput?(Data(buffer[..<count]))
            return
        }
        if count == 0 || (count < 0 && errno == EIO) {
            // The child closed its side. Output stops here; the exit watch
            // reports the actual termination.
            stateLock.lock()
            masterFD = -1
            stateLock.unlock()
            self.readSource?.cancel()
            self.readSource = nil
        }
        // EINTR and transient errors: wait for the next event.
    }

    /// Runs on the IO queue. Report immediately, like the old LocalProcess
    /// monitor did: the last output chunks may still be in flight and the read
    /// source keeps draining them until EOF.
    private func handleChildExit() {
        stateLock.lock()
        let pid = shellPid
        shellPid = 0
        stateLock.unlock()
        guard pid > 0 else { return }

        var status: Int32 = 0
        guard waitpid(pid, &status, 0) > 0 else { return }
        // WIFEXITED(status) && WEXITSTATUS(status); Darwin's macros are not
        // visible from Swift.
        let code: Int32? = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : nil

        stateLock.lock()
        let alreadyReported = exitReported
        exitReported = true
        stateLock.unlock()
        exitSource?.cancel()
        exitSource = nil
        guard !alreadyReported, let onExit else { return }
        DispatchQueue.main.async { onExit(code) }
    }

    deinit {
        terminate()
    }
}
