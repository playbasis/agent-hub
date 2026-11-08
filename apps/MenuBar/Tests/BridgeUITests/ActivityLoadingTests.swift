import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class ActivityLoadingTests: XCTestCase {
    private let snapshotBase = Date().addingTimeInterval(-3_600)
    private func cacheURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Snapshot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("activity-snapshot.json")
    }

    private func overview(_ seconds: TimeInterval, sessions: Int = 1) -> ActivityOverview {
        let at = snapshotBase.addingTimeInterval(seconds)
        return ActivityOverview(generatedAt: at, sessions: (0 ..< sessions).map {
            ActivitySession(id: "s\($0)", provider: .codex, nativeID: "s\($0)", title: "Session \($0)", createdAt: at, updatedAt: at, source: "test")
        })
    }

    func testSnapshotRoundTripsPrivatelyAndSkipsOlderOrThrottledWrites() async throws {
        let url = try cacheURL()
        let cache = ActivitySnapshotCache(url: url, minimumWriteInterval: 60)
        let now = Date()
        cache.save(overview(0), now: now)
        cache.flush()
        let loaded = await cache.load()
        XCTAssertEqual(loaded?.sessions.map(\.id), ["s0"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "the snapshot holds session titles and paths")

        cache.save(overview(10, sessions: 2), now: now.addingTimeInterval(5))
        cache.flush()
        let throttled = await cache.load()
        XCTAssertEqual(throttled?.sessions.count, 1, "a minute-by-minute refresh isn't written every minute")
        cache.save(overview(10, sessions: 2), force: true, now: now.addingTimeInterval(6))
        cache.flush()
        let forced = await cache.load()
        XCTAssertEqual(forced?.sessions.count, 2)
        cache.save(overview(-100, sessions: 3), force: true, now: now.addingTimeInterval(7))
        cache.flush()
        let kept = await cache.load()
        XCTAssertEqual(kept?.sessions.count, 2, "an older snapshot never replaces a newer one")
    }

    func testMissingOrEmptySnapshotLoadsAsNothing() async throws {
        let cache = ActivitySnapshotCache(url: try cacheURL())
        let missing = await cache.load()
        XCTAssertNil(missing)
        cache.save(.empty, force: true)
        cache.flush()
        let empty = await cache.load()
        XCTAssertNil(empty)
    }

    @MainActor
    func testSavedSnapshotPaintsFirstButNeverOverridesLiveData() throws {
        let model = BridgeViewModel(automaticallyConnect: false, activitySnapshot: ActivitySnapshotCache(url: try cacheURL()))
        model.restoreSavedActivity(overview(0))
        XCTAssertTrue(model.isShowingSavedActivity)
        XCTAssertEqual(model.activityOverview.sessions.count, 1)
        model.restoreSavedActivity(overview(50, sessions: 4))
        XCTAssertEqual(model.activityOverview.sessions.count, 1, "only an empty window is filled from the saved snapshot")
    }

    func testTwentyFourHourPeriodNeverDropsThePartialFirstHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ActivityAnalytics.reportingTimeZone
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 5, minute: 41, second: 12))!
        let cutoff = ReportPeriod.day.cutoff(at: now)!
        XCTAssertEqual(now.timeIntervalSince(cutoff), 86_400, accuracy: 0.001)
        XCTAssertEqual(cutoff, calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 5, minute: 41, second: 12))!,
                       "Both partial clock-hour edges belong to the exact trailing day")
        XCTAssertEqual(ActivityAnalytics.series([], from: cutoff, to: now, granularity: .hour).count, 25)
        XCTAssertEqual(ReportPeriod.day.granularity, .hour)
        XCTAssertEqual(ReportPeriod.week.granularity, .day)
    }

    func testSessionLengthHistogramHighlightsTheMiddleSession() {
        let histogram = ActivityReportsView.durationHistogram([60, 400, 1_000, 2_000, 20_000])
        XCTAssertEqual(histogram.counts, [1, 1, 2, 0, 1])
        XCTAssertEqual(histogram.medianBucket, 2)
        XCTAssertNil(ActivityReportsView.durationHistogram([]).medianBucket)
    }
}
