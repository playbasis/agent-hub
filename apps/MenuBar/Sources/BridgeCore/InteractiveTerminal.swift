import Darwin
import Foundation

/// Plain-text view of a terminal transcript: ANSI escapes removed, control
/// characters collapsed, carriage-return overwrites resolved to the last
/// rendered line. Shared by every parser that reads a CLI through a PTY.
public enum TerminalText {
    private static let escape = "\u{1B}"
    private static let bell = "\u{07}"
    private static let escapePattern =
        escape + "(?:\\[[0-?]*[ -/]*[@-~]|\\][^" + bell + "]*(?:" + bell + "|" + escape + "\\\\)|[78=>])"

    public static func normalize(_ value: String) -> String {
        let withoutEscapes = (try? NSRegularExpression(pattern: escapePattern))
            .map {
                $0.stringByReplacingMatches(
                    in: value,
                    range: NSRange(value.startIndex..., in: value),
                    withTemplate: ""
                )
            } ?? value
        var lines: [String] = []
        var current = ""
        let unified = withoutEscapes.replacingOccurrences(of: "\r\n", with: "\n")
        for scalar in unified.unicodeScalars {
            switch scalar.value {
            case 10:
                lines.append(current)
                current = ""
            case 13:
                // A bare carriage return redraws the current line; keep only
                // the final rendering so progress spinners do not pollute
                // the transcript.
                current = ""
            case 0 ..< 32, 127:
                current.append(" ")
            default:
                current.unicodeScalars.append(scalar)
            }
        }
        lines.append(current)
        return lines.joined(separator: "\n")
    }
}

/// A child process attached to a pseudo-terminal, with a live output stream
/// and a writable stdin. Used to drive the provider CLIs' interactive sign-in
/// commands from the app without a visible Terminal window.
public final class PseudoTerminalProcess: @unchecked Sendable {
    public let output: AsyncStream<String>
    public let processID: pid_t

    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var master: Int32
    private var slave: Int32
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var readerThread: Thread?

    public init(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment extraEnvironment: [String: String] = [:],
        columns: UInt16 = 400,
        rows: UInt16 = 60
    ) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw BridgeError.processFailed("Could not create a pseudo-terminal.")
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = String(columns)
        environment["LINES"] = String(rows)
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        let argumentStrings = TerminalCStringArray([executable.path] + arguments)
        let environmentStrings = TerminalCStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer {
            argumentStrings.free()
            environmentStrings.free()
        }

        var pid: pid_t = 0
        let spawnStatus = argumentStrings.withUnsafeMutablePointer { argv in
            environmentStrings.withUnsafeMutablePointer { envp in
                posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
            }
        }
        guard spawnStatus == 0 else {
            close(master)
            close(slave)
            throw BridgeError.processFailed(String(cString: strerror(spawnStatus)))
        }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        self.master = master
        self.slave = slave
        processID = pid
        var streamContinuation: AsyncStream<String>.Continuation!
        output = AsyncStream<String>(bufferingPolicy: .unbounded) { streamContinuation = $0 }
        continuation = streamContinuation
        startReader()
    }

    deinit {
        lock.lock()
        let descriptors = [master, slave]
        lock.unlock()
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }

    /// Writes raw text to the child's terminal. Interactive prompts usually
    /// need a trailing carriage return, which the caller supplies.
    public func write(_ text: String) {
        lock.lock()
        let descriptor = master
        lock.unlock()
        guard descriptor >= 0 else { return }
        text.withCString { pointer in
            _ = Darwin.write(descriptor, pointer, strlen(pointer))
        }
    }

    /// Terminates the whole process group, escalating to SIGKILL if the CLI
    /// ignores the polite request.
    public func terminate() {
        lock.lock()
        let finished = exitStatus != nil
        lock.unlock()
        guard !finished else { return }
        kill(-processID, SIGTERM)
        let pid = processID
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = self.exitStatus == nil
            self.lock.unlock()
            if stillRunning { kill(-pid, SIGKILL) }
        }
    }

    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func startReader() {
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "bridge.pty.reader"
        thread.qualityOfService = .utility
        readerThread = thread
        thread.start()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        var decoder = IncrementalUTF8()

        func drain(_ descriptor: Int32) {
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                let text = decoder.decode(buffer[0 ..< count])
                if !text.isEmpty { continuation.yield(text) }
            }
        }

        while true {
            lock.lock()
            let descriptor = master
            lock.unlock()
            guard descriptor >= 0 else { return }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&pollDescriptor, 1, 100) > 0, pollDescriptor.revents & Int16(POLLIN) != 0 {
                drain(descriptor)
            }
            var status: Int32 = 0
            if waitpid(processID, &status, WNOHANG) == processID {
                // The slave is still open on our side, so nothing the child
                // wrote before exiting has been discarded yet.
                drain(descriptor)
                finish(rawStatus: status)
                return
            }
        }
    }

    private func finish(rawStatus: Int32) {
        let code: Int32 = (rawStatus & 0x7F) == 0 ? (rawStatus >> 8) & 0xFF : 128 + (rawStatus & 0x7F)
        lock.lock()
        exitStatus = code
        let waiters = exitWaiters
        exitWaiters = []
        let descriptors = [master, slave]
        master = -1
        slave = -1
        lock.unlock()
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
        continuation.finish()
        for waiter in waiters {
            waiter.resume(returning: code)
        }
    }
}

/// Decodes UTF-8 across chunk boundaries so a multi-byte character split by
/// a read never becomes a replacement glyph in the transcript.
private struct IncrementalUTF8 {
    private var pending: [UInt8] = []

    mutating func decode(_ bytes: ArraySlice<UInt8>) -> String {
        pending.append(contentsOf: bytes)
        var cut = pending.count
        var index = pending.count - 1
        var trailing = 0
        while index >= 0, trailing < 3 {
            let byte = pending[index]
            if byte & 0xC0 == 0x80 {
                trailing += 1
                index -= 1
                continue
            }
            let needed: Int
            if byte & 0x80 == 0 { needed = 1 }
            else if byte & 0xE0 == 0xC0 { needed = 2 }
            else if byte & 0xF0 == 0xE0 { needed = 3 }
            else if byte & 0xF8 == 0xF0 { needed = 4 }
            else { needed = 1 }
            if trailing + 1 < needed { cut = index }
            break
        }
        let text = String(decoding: pending[0 ..< cut], as: UTF8.self)
        pending = Array(pending[cut...])
        return text
    }
}

final class TerminalCStringArray: @unchecked Sendable {
    private var storage: [UnsafeMutablePointer<CChar>?]

    init(_ values: [String]) {
        storage = values.map { strdup($0) }
        storage.append(nil)
    }

    func withUnsafeMutablePointer<T>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) rethrows -> T {
        try storage.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    func free() {
        for pointer in storage.dropLast() {
            Darwin.free(pointer)
        }
        storage = [nil]
    }
}
