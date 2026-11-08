import Darwin
import Foundation

/// A long-lived `codex app-server --stdio` session speaking newline-delimited
/// JSON-RPC. The read-only account and rate-limit methods are documented for
/// GUI clients, and `account/login/*` is how the Codex desktop app itself
/// links a ChatGPT subscription — so the Bridge can offer the same flow
/// without touching `~/.codex/auth.json`.
public final class CodexAppServerSession: @unchecked Sendable {
    public struct RPCError: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public let notifications: AsyncStream<[String: Any]>

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var closed = false
    /// Our own duplicate of the stdout descriptor. The reader thread owns it,
    /// so closing the pipe elsewhere can never turn a read into a crash.
    private let readDescriptor: Int32
    private let notificationContinuation: AsyncStream<[String: Any]>.Continuation

    public init(
        executable: URL,
        currentDirectory: URL,
        clientName: String = "claude-codex-bridge",
        clientVersion: String = "0.1.0",
        environment: [String: String] = [:]
    ) async throws {
        var continuation: AsyncStream<[String: Any]>.Continuation!
        notifications = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation = $0 }
        notificationContinuation = continuation

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = currentDirectory
        process.environment = SubprocessEnvironment.make(
            executable: executable,
            currentDirectory: currentDirectory,
            overrides: environment
        )
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        readDescriptor = dup(output.fileHandleForReading.fileDescriptor)
        process.terminationHandler = { [weak self] _ in self?.failAll("Codex app-server exited.") }
        try process.run()
        // The parent no longer needs the pipe's own read end; the dup above
        // is what the reader uses, and dropping this one makes EOF reliable.
        try? output.fileHandleForReading.close()
        startReader()

        _ = try await request(
            "initialize",
            params: [
                "clientInfo": ["name": clientName, "version": clientVersion],
                "capabilities": ["experimentalApi": true],
            ],
            timeoutSeconds: 10
        )
        try send(["method": "initialized"])
    }

    deinit { close() }

    public func request(
        _ method: String,
        params: Any? = nil,
        timeoutSeconds: Int = 15
    ) async throws -> [String: Any] {
        let id: Int = try locked {
            guard !closed else { throw RPCError(message: "Codex app-server session is closed.") }
            let id = nextID
            nextID += 1
            return id
        }
        let message: [String: Any] = ["id": id, "method": method, "params": params ?? NSNull()]

        // The timeout resumes the very same continuation, so an unanswered
        // request can never leave a task suspended forever.
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard let self, !Task.isCancelled else { return }
            let waiter = self.locked { self.pending.removeValue(forKey: id) }
            waiter?.resume(throwing: RPCError(message: "Codex app-server did not answer \(method) in time."))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            locked { pending[id] = continuation }
            do {
                try send(message)
            } catch {
                let waiter = locked { pending.removeValue(forKey: id) }
                waiter?.resume(throwing: error)
            }
        }
    }

    public func close() {
        let alreadyClosed = locked { () -> Bool in
            let previous = closed
            closed = true
            return previous
        }
        guard !alreadyClosed else { return }
        process.terminationHandler = nil
        writeLock.lock()
        try? input.fileHandleForWriting.close()
        writeLock.unlock()
        if process.isRunning {
            // Node-wrapped Codex does not always forward SIGTERM to the Rust
            // child, so terminate the process group the CLI started.
            kill(process.processIdentifier, SIGTERM)
            process.terminate()
        }
        notificationContinuation.finish()
        failAll("Codex app-server session closed.")
    }

    private var isClosed: Bool { locked { closed } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Writes are serialized against `close()` so the stdin handle can never
    /// be closed underneath an in-flight write. The throwing write API turns
    /// a broken pipe into an error instead of an uncatchable exception.
    private func send(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { throw RPCError(message: "Codex app-server session is closed.") }
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        } catch {
            throw RPCError(message: "Codex app-server is no longer accepting requests.")
        }
    }

    private func startReader() {
        let descriptor = readDescriptor
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var frames = CodexRPCFrameBuffer()
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    do {
                        let complete = try frames.append(Data(buffer.prefix(count)))
                        for line in complete { autoreleasepool { self?.handle(line: line) } }
                    } catch {
                        self?.failAll("Codex returned a message larger than the Hub's safe read limit. No account or native session was changed.")
                        self?.close()
                        break
                    }
                    continue
                }
                if count < 0, errno == EINTR { continue }
                break
            }
            Darwin.close(descriptor)
            self?.failAll("Codex app-server closed its output.")
        }
        thread.name = "bridge.codex.app-server.reader"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            let waiter = locked { pending.removeValue(forKey: id) }
            if let error = object["error"] as? [String: Any] {
                waiter?.resume(throwing: RPCError(message: error["message"] as? String ?? "Codex app-server error."))
            } else {
                waiter?.resume(returning: object["result"] as? [String: Any] ?? [:])
            }
        } else if object["method"] != nil {
            notificationContinuation.yield(object)
        }
    }

    private func failAll(_ message: String) {
        let waiters = locked { () -> [Int: CheckedContinuation<[String: Any], Error>] in
            let copy = pending
            pending = [:]
            return copy
        }
        for (_, waiter) in waiters {
            waiter.resume(throwing: RPCError(message: message))
        }
    }
}

/// Bounds one newline-delimited RPC frame before JSON decoding can multiply
/// its allocations. This owns only the Hub's read-only client connection.
struct CodexRPCFrameBuffer {
    enum FrameError: Error { case oversized }
    let maximumBytes: Int
    private(set) var pending = Data()

    init(maximumBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumBytes = max(1, min(maximumBytes, 16 * 1_024 * 1_024))
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        var complete: [Data] = []
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 0x0A)
            let end = newline ?? chunk.endIndex
            let piece = chunk[start..<end]
            guard piece.count <= maximumBytes - pending.count else {
                pending = Data()
                throw FrameError.oversized
            }
            pending.append(piece)
            if let newline {
                complete.append(pending)
                pending = Data()
                start = chunk.index(after: newline)
            } else {
                start = end
            }
        }
        return complete
    }
}
