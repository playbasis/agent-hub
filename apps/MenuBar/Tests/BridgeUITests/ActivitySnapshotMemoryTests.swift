import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class ActivitySnapshotMemoryTests: XCTestCase {
    func testReportMemoHasABoundAndReleasesClosedWindowData() {
        let cache = ReportScopeCache()
        for index in 0..<1_000 {
            let value: String = cache.value("quota-\(index)") { String(repeating: "a", count: 128) }
            XCTAssertEqual(value.count, 128)
            XCTAssertLessThanOrEqual(cache.derivedValueCount, ReportScopeCache.maximumDerivedValues)
        }
        cache.reset()
        XCTAssertEqual(cache.derivedValueCount, 0)
    }

    func testSlowWriterRetainsOnlyLatestWaitingSnapshotAndHonorsForcedSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotMemory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "snapshot-memory-fixture")
        let at = Date()
        let cache = ActivitySnapshotCache(url: directory.appendingPathComponent("snapshot.json"), minimumWriteInterval: 3_600, writeQueue: queue)
        cache.save(ActivityOverview(generatedAt: at), now: at)
        cache.flush()
        queue.suspend()
        for index in 1...500 {
            cache.save(ActivityOverview(generatedAt: at.addingTimeInterval(Double(index) / 10)),
                       force: index == 1, now: at.addingTimeInterval(60))
            XCTAssertEqual(cache.pendingSnapshotCount, 1)
        }
        // An older forced generation must not replace the newer queued one.
        cache.save(ActivityOverview(generatedAt: at), force: true, now: at.addingTimeInterval(60))
        queue.resume()
        cache.flush()
        let loaded = await cache.load(now: at.addingTimeInterval(60))
        XCTAssertEqual(loaded?.generatedAt.timeIntervalSince1970 ?? 0, at.addingTimeInterval(50).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(cache.pendingSnapshotCount, 0)
    }

    func testEqualGenerationPendingCorrectionReplacesPreviousValue() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotCorrection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "snapshot-correction-fixture")
        let at = Date()
        let cache = ActivitySnapshotCache(url: directory.appendingPathComponent("snapshot.json"), writeQueue: queue)
        queue.suspend()
        cache.save(ActivityOverview(generatedAt: at, pinnedSessionID: "first"), force: true, now: at)
        cache.save(ActivityOverview(generatedAt: at, pinnedSessionID: "corrected"), now: at)
        queue.resume()
        cache.flush()
        let loaded = await cache.load(now: at)
        XCTAssertEqual(loaded?.pinnedSessionID, "corrected")
    }

    @MainActor
    func testIdenticalRuntimePollDoesNotRebuildReportsOrRetainAnotherSnapshot() {
        let model = BridgeViewModel(automaticallyConnect: false, activitySnapshot: nil)
        let overview = ActivityOverview(generatedAt: Date())
        model.restoreSavedActivity(overview)
        let revision = model.activityRevision
        XCTAssertTrue(model.isShowingSavedActivity)
        for _ in 0..<100 { XCTAssertTrue(model.acceptRuntimeActivity(overview)) }
        XCTAssertFalse(model.isShowingSavedActivity)
        XCTAssertEqual(model.activityRevision, revision)
    }
}
