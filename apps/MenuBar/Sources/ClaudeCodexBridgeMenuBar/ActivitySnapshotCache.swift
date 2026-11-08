import BridgeCore
import Darwin
import Foundation

/// The last activity snapshot the Hub showed, kept on this Mac so the next
/// launch can paint real numbers immediately instead of empty pages while the
/// runtime starts and re-reads every session. The runtime's own snapshot
/// replaces it as soon as it arrives; nothing here is ever sent anywhere.
final class ActivitySnapshotCache: @unchecked Sendable {
    static let standard = ActivitySnapshotCache(url: BridgePaths.applicationSupport.appendingPathComponent("activity-snapshot.json"))

    let url: URL
    /// Writes are coalesced: the snapshot is tens of megabytes and only paints
    /// the first seconds after launch, so it is rewritten every few minutes.
    private let minimumWriteInterval: TimeInterval
    private let maximumFileBytes: Int
    private let maximumFutureSkew: TimeInterval
    private let queue: DispatchQueue
    private struct PendingWrite {
        var overview: ActivityOverview
        var force: Bool
        var now: Date
    }
    private let pendingLock = NSLock()
    private var pendingWrite: PendingWrite?
    private var writerScheduled = false
    /// Accessed only on queue. Failed or throttled writes never advance it.
    private var lastSuccessfulWrite: Date = .distantPast

    init(url: URL, minimumWriteInterval: TimeInterval = 600,
         maximumFileBytes: Int = 64 * 1_024 * 1_024, maximumFutureSkew: TimeInterval = 300,
         writeQueue: DispatchQueue? = nil) {
        self.url = url
        self.queue = writeQueue ?? DispatchQueue(label: "agent-hub.activity-snapshot", qos: .utility)
        self.minimumWriteInterval = minimumWriteInterval.isFinite ? max(0, minimumWriteInterval) : 120
        self.maximumFileBytes = min(64 * 1_024 * 1_024, max(1, maximumFileBytes))
        self.maximumFutureSkew = maximumFutureSkew.isFinite ? max(0, maximumFutureSkew) : 300
    }

    /// Decodes off the main thread. Returns nil for a missing, unreadable or
    /// empty snapshot rather than surfacing an error at launch.
    func load(now: Date = Date()) async -> ActivityOverview? {
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let stored = readStored(),
                      Self.isValidSnapshotDate(stored.overview.generatedAt, now: now, maximumFutureSkew: maximumFutureSkew) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: stored.overview)
            }
        }
    }

    /// Saves in the background when the snapshot is newer than the last one
    /// written and the write interval has passed, or when `force` is set.
    func save(_ overview: ActivityOverview, force: Bool = false, now: Date = Date()) {
        guard Self.isValidSnapshotDate(overview.generatedAt, now: now, maximumFutureSkew: maximumFutureSkew) else { return }
        pendingLock.lock()
        if let waiting = pendingWrite, waiting.overview.generatedAt > overview.generatedAt {
            pendingWrite?.force = waiting.force || force
        } else {
            pendingWrite = PendingWrite(overview: overview, force: force || (pendingWrite?.force ?? false), now: now)
        }
        let needsWriter = !writerScheduled
        writerScheduled = true
        // The queue captures only self, not each full model. At most one
        // in-progress overview and one latest waiting overview are retained.
        if needsWriter { queue.async { [self] in drainWrites() } }
        pendingLock.unlock()
    }

    var pendingSnapshotCount: Int {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingWrite == nil ? 0 : 1
    }

    private func drainWrites() {
        while true {
            pendingLock.lock()
            guard let next = pendingWrite else {
                writerScheduled = false
                pendingLock.unlock()
                return
            }
            pendingWrite = nil
            pendingLock.unlock()
            autoreleasepool { persist(next) }
        }
    }

    private func persist(_ request: PendingWrite) {
        let overview = request.overview, now = request.now
        guard request.force || now.timeIntervalSince(lastSuccessfulWrite) >= minimumWriteInterval else { return }
            do {
                var data = try BridgeJSON.compactEncoder.encode(overview)
                if data.count > maximumFileBytes {
                    // Keep painting at launch: drop model-step detail older
                    // than a week, which the runtime restores seconds later.
                    data = try BridgeJSON.compactEncoder.encode(Self.withoutOldModelSteps(overview, now: now))
                }
                guard data.count <= maximumFileBytes else { return }
                let generation = try BridgeJSON.decoder.decode(Date.self, from: BridgeJSON.compactEncoder.encode(overview.generatedAt))
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // Serialize compare-and-replace across cache instances and app
                // processes. Atomic rename alone cannot prevent an older writer
                // from racing a newer one between the comparison and rename.
                let lockURL = directory.appendingPathComponent("." + url.lastPathComponent + ".lock")
                let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
                guard descriptor >= 0 else { return }
                defer { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
                guard ownedRegularFile(descriptor, at: lockURL) != nil,
                      Darwin.fchmod(descriptor, 0o600) == 0,
                      flock(descriptor, LOCK_EX | LOCK_NB) == 0,
                      ownedRegularFile(descriptor, at: lockURL) != nil,
                      safeStoredPathForReplacement() else { return }
                if let stored = readStoredGeneration() {
                    // A future generation is not shown at startup, but it is
                    // still preserved rather than overwritten by older data.
                    guard generation >= stored.generation else { return }
                    if stored.data == data { return }
                }
                try writePrivately(data)
                lastSuccessfulWrite = now
            } catch { /* Startup cache is optional; retry remains possible. */ }
    }

    static func withoutOldModelSteps(_ overview: ActivityOverview, now: Date) -> ActivityOverview {
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        var value = overview
        value.sessions = overview.sessions.map { session in
            var copy = session
            copy.turns = session.turns.map { turn in
                guard (turn.completedAt ?? turn.startedAt ?? .distantPast) < cutoff, turn.modelSteps != nil else { return turn }
                var trimmed = turn
                trimmed.modelSteps = nil
                trimmed.modelStepsComplete = nil
                return trimmed
            }
            return copy
        }
        return value
    }

    static func isValidSnapshotDate(_ date: Date, now: Date = Date(), maximumFutureSkew: TimeInterval = 300) -> Bool {
        date != .distantPast && date.timeIntervalSinceReferenceDate.isFinite
            && now.timeIntervalSinceReferenceDate.isFinite && maximumFutureSkew.isFinite && maximumFutureSkew >= 0
            && date.timeIntervalSince(now) <= maximumFutureSkew
    }

    private func readStored() -> (overview: ActivityOverview, data: Data)? {
        guard let data = readStoredData(),
              let overview = try? BridgeJSON.decoder.decode(ActivityOverview.self, from: data),
              overview.generatedAt != .distantPast, overview.generatedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return (overview, data)
    }

    private func readStoredGeneration() -> (generation: Date, data: Data)? {
        // Writers need only the generation, not a second decoded session graph.
        struct Header: Decodable { var generatedAt: Date }
        guard let data = readStoredData(), let header = try? BridgeJSON.decoder.decode(Header.self, from: data),
              header.generatedAt != .distantPast, header.generatedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return (header.generatedAt, data)
    }

    private func readStoredData() -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        guard let info = ownedRegularFile(descriptor, at: url),
              info.st_size >= 0, UInt64(info.st_size) <= UInt64(maximumFileBytes) else {
            _ = Darwin.close(descriptor); return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileBytes + 1), data.count <= maximumFileBytes else { return nil }
        return data
    }

    /// A known private file may be replaced; an unrelated object, link, FIFO
    /// or unreadably large file is preserved rather than treated as "missing".
    private func safeStoredPathForReplacement() -> Bool {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return errno == ENOENT }
        return info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && info.st_uid == geteuid() && info.st_nlink == 1
            && info.st_size >= 0 && UInt64(info.st_size) <= UInt64(maximumFileBytes)
    }

    private func ownedRegularFile(_ descriptor: Int32, at namedURL: URL) -> stat? {
        var info = stat(), named = stat()
        guard Darwin.fstat(descriptor, &info) == 0, Darwin.lstat(namedURL.path, &named) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(), info.st_nlink == 1,
              named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_dev == named.st_dev, info.st_ino == named.st_ino else { return nil }
        return info
    }

    /// The temporary file is owner-only before any snapshot bytes are written;
    /// rename publishes the complete private file in one operation.
    private func writePrivately(_ data: Data) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".activity-snapshot-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = Darwin.unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Blocks until queued writes finish. Used at quit and in tests.
    func flush() {
        // A concurrent saver must enqueue its first worker before the fence.
        pendingLock.lock()
        pendingLock.unlock()
        queue.sync {}
    }
}
