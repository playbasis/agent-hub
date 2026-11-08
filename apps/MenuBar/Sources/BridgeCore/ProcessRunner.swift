import Darwin
import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

public enum ExecutableLocator {
    public static func resolve(
        _ command: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) throws -> URL {
        if command.contains("/") {
            let url = URL(fileURLWithPath: command).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw BridgeError.processFailed("Not executable: \(url.path)")
            }
            return url
        }
        var search = environmentPath.split(separator: ":").map(String.init)
            + [
                home.appendingPathComponent(".local/bin").path,
                home.appendingPathComponent(".volta/bin").path,
                home.appendingPathComponent(".asdf/shims").path,
                home.appendingPathComponent(".bun/bin").path,
                home.appendingPathComponent(".local/share/mise/shims").path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
            ]
        let nvm = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvm,
            includingPropertiesForKeys: nil
        ) {
            search.insert(
                contentsOf: versions
                    // Newest first by version number, so v20 wins over v9.
                    .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                    .map { $0.appendingPathComponent("bin").path },
                at: 0
            )
        }
        for directory in search {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        throw BridgeError.processFailed("Could not find \(command) on PATH. Install it, or set its full path in config.json.")
    }
}

/// A Finder-launched app may locate an npm CLI through a known installation
/// directory while inheriting a PATH that cannot find its sibling Node binary.
/// Pair only that explicitly resolved installation; never source shell
/// profiles or add the provider's project working directory to PATH.
public enum SubprocessEnvironment {
    public static func make(
        executable: URL,
        currentDirectory: URL,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = inherited.merging(overrides, uniquingKeysWith: { _, supplied in supplied })
        guard executable.isFileURL else { return environment }
        // Do not resolve the CLI symlink here: npm's bin/codex points inside
        // node_modules, but its paired runtime belongs to the original bin/.
        let directory = executable.standardizedFileURL.deletingLastPathComponent()
        let actualDirectory = directory.resolvingSymlinksInPath()
        guard actualDirectory.path != currentDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
              directory.path != "/", actualDirectory.path != "/" else { return environment }
        let node = directory.appendingPathComponent("node")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: node.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: node.path) else { return environment }
        let components = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // Remove duplicate spellings of the paired bin while preserving the
        // caller's other PATH choices and their order. Empty components are
        // omitted so an absent PATH cannot introduce an implicit cwd lookup.
        let remainder = components.filter { component in
            guard component.hasPrefix("/") else { return true }
            return URL(fileURLWithPath: component).standardizedFileURL.resolvingSymlinksInPath().path != actualDirectory.path
        }
        environment["PATH"] = ([directory.path] + remainder).joined(separator: ":")
        return environment
    }
}

public enum ProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        stdin: String,
        timeoutSeconds: Int,
        maximumOutputCharacters: Int,
        environment: [String: String] = [:],
        onOutputLine: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        let executableURL = try ExecutableLocator.resolve(executable)
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = SubprocessEnvironment.make(
            executable: executableURL,
            currentDirectory: currentDirectory,
            overrides: environment
        )

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let gate = ProcessCompletionGate()
        let termination = AsyncStream<Bool> { continuation in
            gate.register(continuation)
        }
        process.terminationHandler = { _ in
            gate.finish(timedOut: false)
        }

        try process.run()

        let stdoutTask = Task.detached {
            await drain(output.fileHandleForReading, characterLimit: maximumOutputCharacters, onOutputLine: onOutputLine)
        }
        let stderrTask = Task.detached {
            await drain(errors.fileHandleForReading, characterLimit: maximumOutputCharacters, onOutputLine: nil)
        }

        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()

        let timeoutTask = Task.detached {
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
            catch { return }
            if gate.finish(timedOut: true), process.isRunning {
                terminate(process)
            }
        }
        defer { timeoutTask.cancel() }

        let timedOut = await withTaskCancellationHandler {
            var iterator = termination.makeAsyncIterator()
            return await iterator.next() ?? false
        } onCancel: {
            terminate(process)
        }

        if timedOut {
            terminate(process)
        }
        process.waitUntilExit()

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        return ProcessOutput(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Both pipes must keep draining even after capture is full. Reads and
    /// retained payloads are independently bounded; callback backpressure
    /// cannot prevent stderr from being consumed on its own task.
    private static func drain(_ handle: FileHandle, characterLimit: Int, onOutputLine: (@Sendable (String) async -> Void)?) async -> String {
        await withCheckedContinuation { continuation in
            // Blocking pipe reads must not occupy Swift's cooperative pool.
            // Otherwise several simultaneous children can starve the other
            // pipe readers and even the async timeout/cancellation work.
            DispatchQueue.global(qos: .utility).async {
                var capture = BoundedProcessOutputCapture(characterLimit: characterLimit)
                var lines = BoundedProcessLineFramer()
                var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                defer { continuation.resume(returning: capture.result()) }
                while true {
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    let completed: [String] = autoreleasepool {
                        let chunk = Data(bytes.prefix(count))
                        capture.append(chunk)
                        return onOutputLine == nil ? [] : lines.append(chunk)
                    }
                    if let onOutputLine {
                        for line in completed { deliver(line, to: onOutputLine) }
                    }
                }
                if let onOutputLine, let final = lines.finish() { deliver(final, to: onOutputLine) }
            }
        }
    }

    private static func deliver(_ line: String, to callback: @escaping @Sendable (String) async -> Void) {
        let finished = DispatchSemaphore(value: 0)
        Task {
            // Completion is signalled even if a cooperative callback returns
            // early because of cancellation. No callback queue can grow: this
            // GCD reader waits for this one delivery before reading again.
            defer { finished.signal() }
            await callback(line)
        }
        finished.wait()
    }
}

/// Retain the beginning and end, not the entire process output. Character
/// limits normally need at most four UTF-8 bytes per scalar. A byte ceiling is
/// still required: one grapheme may contain arbitrarily many combining marks,
/// and configuration values must not overflow or allocate unbounded memory.
struct BoundedProcessOutputCapture {
    static let maximumCaptureBytes = 8 * 1024 * 1024
    static let truncationMarker = "\n[…bridge output truncated…]\n"
    let characterLimit: Int
    let byteLimit: Int
    private var initial = Data()
    private var head = Data()
    private var tail = Data()
    private var byteTruncated = false

    init(characterLimit: Int) {
        self.characterLimit = max(0, characterLimit)
        let (scaled, overflow) = self.characterLimit.multipliedReportingOverflow(by: 4)
        byteLimit = overflow ? Self.maximumCaptureBytes : min(scaled, Self.maximumCaptureBytes)
    }

    var retainedByteCount: Int { initial.count + head.count + tail.count }

    mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        if !byteTruncated {
            if chunk.count <= byteLimit - initial.count {
                initial.append(chunk)
                return
            }
            // The initial region is released as soon as the two bounded
            // regions are formed. Even this transition has a fixed upper
            // bound (two byte budgets plus the reader's 16 KiB chunk).
            let headLimit = byteLimit / 2
            let tailLimit = byteLimit - headLimit
            if initial.count >= headLimit {
                head = initial.subdata(in: 0 ..< headLimit)
            } else {
                head = initial
                head.append(chunk.prefix(headLimit - head.count))
            }
            if chunk.count >= tailLimit {
                tail = Data(chunk.suffix(tailLimit))
            } else {
                tail = Data(initial.suffix(tailLimit - chunk.count))
                tail.append(chunk)
            }
            initial = Data()
            byteTruncated = true
        } else {
            let tailLimit = byteLimit - byteLimit / 2
            if chunk.count >= tailLimit {
                tail = Data(chunk.suffix(tailLimit))
            } else {
                tail.append(chunk)
                if tail.count > tailLimit { tail = tail.subdata(in: tail.count - tailLimit ..< tail.count) }
            }
        }
    }

    func result() -> String {
        if !byteTruncated {
            let value = String(decoding: initial, as: UTF8.self)
            guard value.count > characterLimit else { return value }
            return String(value.prefix(characterLimit / 2)) + Self.truncationMarker + String(value.suffix(characterLimit / 2))
        }
        let first = Self.decodePrefix(head)
        let last = Self.decodeSuffix(tail)
        return String(first.prefix(characterLimit / 2)) + Self.truncationMarker + String(last.suffix(characterLimit / 2))
    }

    /// Do not manufacture a replacement character when a capture boundary
    /// falls partway through an otherwise valid multi-byte UTF-8 scalar.
    private static func decodePrefix(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var lead = data.index(before: data.endIndex)
        var scanned = 0
        while lead > data.startIndex, (data[lead] & 0xC0) == 0x80, scanned < 3 {
            lead = data.index(before: lead); scanned += 1
        }
        let byte = data[lead]
        let expected = byte >= 0xF0 && byte <= 0xF4 ? 4 : (byte >= 0xE0 && byte <= 0xEF ? 3 : (byte >= 0xC2 && byte <= 0xDF ? 2 : 1))
        let end = data.distance(from: lead, to: data.endIndex) < expected ? lead : data.endIndex
        return String(decoding: data[..<end], as: UTF8.self)
    }

    private static func decodeSuffix(_ data: Data) -> String {
        var start = data.startIndex
        var skipped = 0
        while start < data.endIndex, (data[start] & 0xC0) == 0x80, skipped < 3 {
            start = data.index(after: start); skipped += 1
        }
        return String(decoding: data[start...], as: UTF8.self)
    }
}

/// An oversized logical line is discarded until its delimiter, rather than
/// clearing carry and emitting a misleading suffix as if it were a valid JSON
/// event. Following normal lines and a normal final unterminated line survive.
struct BoundedProcessLineFramer {
    static let maximumLineBytes = 1_000_000
    private var pending = Data()
    private var discarding = false
    var retainedByteCount: Int { pending.count }

    mutating func append(_ chunk: Data) -> [String] {
        var completed: [String] = []
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 10)
            let end = newline ?? chunk.endIndex
            let segment = chunk[start ..< end]
            if !discarding {
                if segment.count <= Self.maximumLineBytes - pending.count { pending.append(segment) }
                else { pending = Data(); discarding = true }
            }
            if let newline {
                if !discarding { completed.append(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: false)
                discarding = false
                start = chunk.index(after: newline)
            } else { break }
        }
        return completed
    }

    mutating func finish() -> String? {
        defer { pending = Data(); discarding = false }
        guard !discarding, !pending.isEmpty else { return nil }
        return String(decoding: pending, as: UTF8.self)
    }
}

private final class ProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Bool>.Continuation?
    private var completed = false

    func register(_ continuation: AsyncStream<Bool>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func finish(timedOut: Bool) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.yield(timedOut)
        continuation?.finish()
        return true
    }
}
