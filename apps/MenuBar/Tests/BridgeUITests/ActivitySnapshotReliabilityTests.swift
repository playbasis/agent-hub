import Darwin
import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class ActivitySnapshotReliabilityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testFailedWriteCanRetrySameGenerationWithoutWaitingForThrottle() async throws {
        let url = fixtureURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data("blocked".utf8)))
        let cache = ActivitySnapshotCache(url: url, minimumWriteInterval: 120)
        cache.save(snapshot(), now: base)
        cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: directory)
        cache.save(snapshot(), now: base.addingTimeInterval(1))
        cache.flush()
        let saved = await cache.load(now: base.addingTimeInterval(1))
        XCTAssertEqual(saved?.sessions.count, 1)
    }

    func testEncodingFailureDoesNotClaimGenerationWasPersisted() async throws {
        let cache = ActivitySnapshotCache(url: fixtureURL(), minimumWriteInterval: 120)
        var invalid = snapshot()
        invalid.sessions[0].goal = ActivityGoal(id: "goal", sessionID: "session", objective: "Fixture", status: "active", createdAt: base, updatedAt: base, providerTimeSeconds: .nan)
        cache.save(invalid, now: base); cache.flush()
        invalid.sessions[0].goal?.providerTimeSeconds = 60
        cache.save(invalid, now: base.addingTimeInterval(1)); cache.flush()
        let saved = await cache.load(now: base.addingTimeInterval(1))
        XCTAssertEqual(saved?.sessions.first?.goal?.providerTimeSeconds, 60)
    }

    func testEqualGenerationCorrectionsAreSavedPrivatelyAndForceWorks() async throws {
        let url = fixtureURL()
        let cache = ActivitySnapshotCache(url: url, minimumWriteInterval: 120)
        var value = snapshot()
        cache.save(value, now: base); cache.flush()
        value.pinnedSessionID = "session"
        value.repositories = [ActivityRepository(id: "repo", name: "Repo", root: "/tmp/repo", commitHistoryAvailable: true)]
        cache.save(value, force: true, now: base.addingTimeInterval(1)); cache.flush()
        let saved = await cache.load(now: base.addingTimeInterval(1))
        XCTAssertEqual(saved?.pinnedSessionID, "session")
        XCTAssertEqual(saved?.repositories.count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".tmp") })
    }

    func testNewCacheInstanceCannotOverwriteNewerDiskSnapshot() async throws {
        let url = fixtureURL()
        let newest = snapshot(seconds: 20, count: 2)
        let first = ActivitySnapshotCache(url: url)
        first.save(newest, force: true, now: base.addingTimeInterval(100)); first.flush()
        let next = ActivitySnapshotCache(url: url)
        next.save(snapshot(seconds: 10, count: 3), force: true, now: base.addingTimeInterval(101)); next.flush()
        let saved = await next.load(now: base.addingTimeInterval(101))
        XCTAssertEqual(saved?.generatedAt, newest.generatedAt)
        XCTAssertEqual(saved?.sessions.count, 2)
    }

    func testConcurrentCacheInstancesKeepNewestGeneration() async {
        let url = fixtureURL()
        let caches = (0..<12).map { _ in ActivitySnapshotCache(url: url, minimumWriteInterval: 0) }
        for index in caches.indices.reversed() {
            caches[index].save(snapshot(seconds: Double(index), count: index + 1), force: true, now: base.addingTimeInterval(100))
        }
        for cache in caches { cache.flush() }
        // Optional writes may skip a busy lock. The newest caller can retry
        // once current writers have drained, without an artificial throttle.
        caches[11].save(snapshot(seconds: 11, count: 12), force: true, now: base.addingTimeInterval(101))
        caches[11].flush()
        for index in 0..<11 {
            caches[index].save(snapshot(seconds: Double(index)), force: true, now: base.addingTimeInterval(102))
        }
        for cache in caches { cache.flush() }
        let saved = await caches[0].load(now: base.addingTimeInterval(100))
        XCTAssertEqual(saved?.generatedAt, base.addingTimeInterval(11))
        XCTAssertEqual(saved?.sessions.count, 12)
    }

    func testBusyLockNeverBlocksFlushAndSameGenerationCanRetryAfterRelease() async throws {
        let url = fixtureURL(), directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appendingPathComponent("." + url.lastPathComponent + ".lock")
        let held = Darwin.open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(held, 0)
        guard held >= 0 else { return }
        defer { _ = flock(held, LOCK_UN); _ = close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        let cache = ActivitySnapshotCache(url: url, minimumWriteInterval: 120)
        let done = DispatchSemaphore(value: 0), value = snapshot(), measuredAt = base
        DispatchQueue.global().async {
            cache.save(value, now: measuredAt)
            cache.flush(); done.signal()
        }
        @Sendable func waitForFlush(_ signal: DispatchSemaphore) -> DispatchTimeoutResult { signal.wait(timeout: .now() + 1) }
        let completed = await Task.detached { waitForFlush(done) }.value
        let absentWhileHeld = !FileManager.default.fileExists(atPath: url.path)
        _ = flock(held, LOCK_UN) // Release even after a regression, so no task is stranded.
        cache.flush()
        XCTAssertEqual(completed, .success, "An optional startup cache must never hold quit behind another process's lock")
        XCTAssertTrue(absentWhileHeld)
        cache.save(value, now: base.addingTimeInterval(1)); cache.flush()
        let saved = await cache.load(now: base.addingTimeInterval(1))
        XCTAssertEqual(saved?.sessions.count, 1)
    }

    func testSymbolicAndHardLinkedSnapshotsAreNeitherReadNorReplaced() async throws {
        for symbolic in [true, false] {
            let url = fixtureURL(), directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("preserved.json")
            let bytes = try BridgeJSON.compactEncoder.encode(snapshot(seconds: 10))
            try bytes.write(to: target)
            if symbolic { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target) }
            else { try FileManager.default.linkItem(at: target, to: url) }
            let cache = ActivitySnapshotCache(url: url)
            let unsafe = await cache.load(now: base.addingTimeInterval(100))
            XCTAssertNil(unsafe)
            cache.save(snapshot(seconds: 20), force: true, now: base.addingTimeInterval(100)); cache.flush()
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
            if symbolic { XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK)) }
            else { XCTAssertEqual(info.st_nlink, 2) }
        }
    }

    func testLinkedLockIsRejectedWithoutChangingItsTarget() throws {
        for symbolic in [true, false] {
            let url = fixtureURL(), directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("preserve-lock-target")
            try Data("preserve".utf8).write(to: target)
            let lock = directory.appendingPathComponent("." + url.lastPathComponent + ".lock")
            if symbolic { try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target) }
            else { try FileManager.default.linkItem(at: target, to: lock) }
            let cache = ActivitySnapshotCache(url: url)
            cache.save(snapshot(), force: true, now: base); cache.flush()
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try String(contentsOf: target), "preserve")
        }
    }

    func testOversizedMalformedAndFutureFilesAreNotRestored() async throws {
        let url = fixtureURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bounded = ActivitySnapshotCache(url: url, maximumFileBytes: 128)
        try Data(repeating: 0x20, count: 129).write(to: url)
        let oversized = await bounded.load(now: base)
        XCTAssertNil(oversized)
        try Data("{broken".utf8).write(to: url)
        let malformed = await bounded.load(now: base)
        XCTAssertNil(malformed)
        let futureBytes = try BridgeJSON.compactEncoder.encode(snapshot(seconds: 3_600))
        try futureBytes.write(to: url)
        let cache = ActivitySnapshotCache(url: url)
        let future = await cache.load(now: base)
        XCTAssertNil(future)
        cache.save(snapshot(), force: true, now: base); cache.flush()
        XCTAssertEqual(try Data(contentsOf: url), futureBytes, "An older write must not destroy a future-dated saved file")
    }

    @MainActor
    func testSavedPaintCannotVetoRuntimeAndOnlyAcceptedReadsClearSavedState() {
        let cache = ActivitySnapshotCache(url: fixtureURL())
        defer { cache.flush() }
        let model = BridgeViewModel(automaticallyConnect: false, activitySnapshot: cache)
        model.restoreSavedActivity(snapshot(seconds: 50, count: 2))
        let restoredRevision = model.activityRevision
        XCTAssertTrue(model.isShowingSavedActivity)
        XCTAssertFalse(model.acceptRuntimeActivity(.empty))
        XCTAssertFalse(model.acceptRuntimeActivity(snapshot(seconds: 60), requestRevision: 1))
        XCTAssertTrue(model.isShowingSavedActivity)
        XCTAssertEqual(model.activityRevision, restoredRevision)
        XCTAssertTrue(model.acceptRuntimeActivity(snapshot(seconds: 10)))
        XCTAssertFalse(model.isShowingSavedActivity)
        XCTAssertEqual(model.activityOverview.sessions.count, 1)
        XCTAssertGreaterThan(model.activityRevision, restoredRevision)
        XCTAssertFalse(model.acceptRuntimeActivity(snapshot(seconds: 5, count: 3)))
        var correction = snapshot(seconds: 10); correction.pinnedSessionID = "session"
        let revision = model.activityRevision
        XCTAssertTrue(model.acceptRuntimeActivity(correction))
        XCTAssertGreaterThan(model.activityRevision, revision, "Equal-timestamp metadata must invalidate cached projections")
    }

    @MainActor
    func testFutureCacheCannotPaintTheWorkspace() {
        let model = BridgeViewModel(automaticallyConnect: false)
        var future = snapshot(); future.generatedAt = Date().addingTimeInterval(3_600)
        model.restoreSavedActivity(future)
        XCTAssertEqual(model.activityOverview, .empty)
        XCTAssertFalse(model.isShowingSavedActivity)
    }

    private func snapshot(seconds: Double = 0, count: Int = 1) -> ActivityOverview {
        let stamp = base.addingTimeInterval(seconds)
        return ActivityOverview(generatedAt: stamp, sessions: (0..<count).map { index in
            ActivitySession(id: index == 0 ? "session" : "session-\(index)", provider: .codex, nativeID: String(index), title: "Fixture", createdAt: stamp, updatedAt: stamp, observedAt: stamp, source: "fixture")
        })
    }
    private func fixtureURL() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheReliability-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("private/activity-snapshot.json")
    }
}
