import XCTest
import SQLite3
@testable import BridgeCore

final class ActivityConnectionHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    func testSyntheticChartFixtureWithKnownUnknownAndOfflineIntervals() throws {
        // Opt-in rendering fixture. No live network changes or provider reads.
        let now = Date()
        var history = ActivityConnectionHistory()
        let start = now.addingTimeInterval(-5 * 3_600)
        for second in stride(from: 0, through: 3_600, by: 30) {
            history.observe(.routeUnavailable, at: start.addingTimeInterval(Double(second)), monitorID: "synthetic")
        }
        history.observe(.routeAvailable, at: start.addingTimeInterval(3_630), monitorID: "synthetic")
        let turns = (0..<12).map { index in
            ActivityTurn(id: "fixture-\(index)", startedAt: now.addingTimeInterval(Double(index - 12) * 3_600),
                         completedAt: now.addingTimeInterval(Double(index - 12) * 3_600 + 600), status: "completed",
                         usage: TokenUsage(total: index == 8 ? nil : 1_000_000 + index * 250_000,
                                           provenance: index == 8 ? .unavailable : .providerReported))
        }
        let session = ActivitySession(id: "synthetic-connectivity", provider: .claude, nativeID: "synthetic",
                                      title: "Synthetic chart fixture", createdAt: now.addingTimeInterval(-86_400), updatedAt: now,
                                      turns: turns, historyComplete: true, source: "synthetic")
        let overview = ActivityOverview(generatedAt: now, sessions: [session],
                                       sources: [ActivitySourceHealth(id: "synthetic", status: "ready", checkedAt: now, message: "Synthetic fixture only")],
                                       connectionHistory: history)
        XCTAssertEqual(history.interruptions(from: now.addingTimeInterval(-86_400), to: now).count, 1)
        XCTAssertNotNil(ActivityAccounting.build(overview: overview, from: now.addingTimeInterval(-86_400), to: now).totals.tokensKnown)
        if let path = ProcessInfo.processInfo.environment["BRIDGE_CONNECTION_FIXTURE_OUT"] {
            let url = URL(fileURLWithPath: path)
            let data = try BridgeJSON.compactEncoder.encode(overview)
            try ActivityAccountingExport.write(data, to: url)
        }
    }

    func testOldCallbacksAndClockReversalsCannotManufactureRecovery() {
        var policy = ActivityConnectionRecoveryPolicy()
        policy.start(id: "a")
        XCTAssertEqual(policy.accept(.routeUnavailable, at: at(0), id: "a"), false)
        XCTAssertEqual(policy.accept(.needsConnection, at: at(30), id: "a"), false)
        XCTAssertEqual(policy.accept(.routeAvailable, at: at(60), id: "a"), true)
        XCTAssertEqual(policy.accept(.routeUnavailable, at: at(70), id: "a"), false)
        XCTAssertEqual(policy.accept(.routeAvailable, at: at(80), id: "a"), false, "Flapping must not spam forced refreshes")
        XCTAssertEqual(policy.accept(.routeUnavailable, at: at(120), id: "a"), false)
        XCTAssertEqual(policy.accept(.routeAvailable, at: at(130), id: "a"), true)
        XCTAssertNil(policy.accept(.routeUnavailable, at: at(30), id: "a"))
        policy.stop(); policy.start(id: "b")
        XCTAssertNil(policy.accept(.routeUnavailable, at: at(90), id: "a"))
        XCTAssertEqual(policy.accept(.routeAvailable, at: at(120), id: "b"), false)
        policy.stop()
        XCTAssertNil(policy.accept(.routeUnavailable, at: at(150), id: "b"))
    }

    func testObservedOfflineSpanIsClippedAndDoesNotAssertInternetReachability() {
        var history = ActivityConnectionHistory()
        history.observe(.routeAvailable, at: at(0), monitorID: "a")
        history.observe(.routeUnavailable, at: at(30), monitorID: "a")
        history.observe(.routeUnavailable, at: at(60), monitorID: "a")
        history.observe(.routeAvailable, at: at(90), monitorID: "a")
        let overlaps = history.interruptions(from: at(45), to: at(75))
        XCTAssertEqual(overlaps.count, 1)
        XCTAssertEqual(overlaps.first?.start, at(45)); XCTAssertEqual(overlaps.first?.end, at(75))
        XCTAssertTrue(history.interruptions(from: at(90), to: at(120)).isEmpty)
        XCTAssertTrue(history.interruptions(from: at(-100), to: at(30)).isEmpty)
        XCTAssertTrue(ActivityConnectionHistory.explanation.contains("not a confirmed provider outage"))
    }
    func testRestartAndLongSuspendDoNotInventContinuousOutage() {
        var history = ActivityConnectionHistory()
        history.observe(.routeUnavailable, at: at(0), monitorID: "a")
        history.observe(.routeUnavailable, at: at(30), monitorID: "a")
        history.observe(.routeUnavailable, at: at(60), monitorID: "b")
        history.observe(.routeUnavailable, at: at(90), monitorID: "b")
        history.observe(.routeUnavailable, at: at(3_600), monitorID: "b")
        history.observe(.routeAvailable, at: at(3_630), monitorID: "b")
        XCTAssertTrue(history.interruptions(from: at(30), to: at(60)).isEmpty)
        XCTAssertTrue(history.interruptions(from: at(90), to: at(3_600)).isEmpty)
        XCTAssertEqual(history.interruptions(from: at(-10), to: at(4_000)).count, 3)
    }
    func testLegacyAbsentHistoryAndNoRouteFailureCannotBeRetroactivelyOffline() throws {
        let legacy = ActivityOverview(generatedAt: at(100))
        let decoded = try BridgeJSON.decoder.decode(ActivityOverview.self, from: BridgeJSON.compactEncoder.encode(legacy))
        XCTAssertNil(decoded.connectionHistory)
        var history = ActivityConnectionHistory()
        history.observe(.routeAvailable, at: at(0), monitorID: "a")
        history.observe(.needsConnection, at: at(30), monitorID: "a")
        history.observe(.routeAvailable, at: at(60), monitorID: "a")
        XCTAssertTrue(history.interruptions(from: at(-100), to: at(100)).isEmpty)
        XCTAssertTrue(ActivityConnectionHistory.gapDescription(hasRecords: true, networkInterrupted: false).contains("no cause is established"))
    }
    func testHistoryIsBoundedAndRejectsReplayedOrReversedClocks() {
        var history = ActivityConnectionHistory()
        for index in 0..<3_000 { history.observe(index % 2 == 0 ? .routeAvailable : .routeUnavailable, at: at(Double(index)), monitorID: "a") }
        XCTAssertEqual(history.intervals.count, ActivityConnectionHistory.maximumIntervals)
        let old = history
        history.observe(.routeUnavailable, at: at(0), monitorID: "a")
        history.observe(.routeUnavailable, at: at(2_999), monitorID: "a")
        XCTAssertEqual(old, history)
        history.observe(.routeAvailable, at: at(40 * 86_400), monitorID: "b")
        XCTAssertEqual(history.intervals.count, 1)
    }
    func testConnectivityIsPersistentButDoesNotAlterAccountingOrKnownUsage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("connection-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.sqlite")
        let database = try ActivityDatabase(url: url)
        let turn = ActivityTurn(id: "t", startedAt: at(0), completedAt: at(60), status: "completed", usage: TokenUsage(total: 42, provenance: .providerReported))
        let session = ActivitySession(id: "s", provider: .claude, nativeID: "s", title: "Fixture", createdAt: at(0), updatedAt: at(60), turns: [turn], historyComplete: true, source: "fixture")
        try database.merge([ActivityCollection(sessions: [session], health: ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: at(90), message: "Fixture"))], now: at(90))
        let before = ActivityAccounting.build(overview: try database.overview(), from: at(0), to: at(90))
        try database.recordConnection(.routeUnavailable, at: at(0), monitorID: "a")
        try database.recordConnection(.routeUnavailable, at: at(60), monitorID: "a")
        let restored = try ActivityDatabase(url: url).overview()
        XCTAssertEqual(restored.connectionHistory?.interruptions(from: at(0), to: at(90)).count, 1)
        let after = ActivityAccounting.build(overview: restored, from: at(0), to: at(90))
        XCTAssertEqual(try BridgeJSON.compactEncoder.encode(before), try BridgeJSON.compactEncoder.encode(after))
        XCTAssertEqual(after.totals.tokensKnown, 42)
        XCTAssertEqual(TokenAccountingSeriesAdapter.build(overview: restored).connectionHistory, restored.connectionHistory)
        var withoutConnection = restored; withoutConnection.connectionHistory = nil
        XCTAssertEqual(try ActivityJournalBuilder.build(snapshot: restored, now: at(90), timezone: TimeZone(secondsFromGMT: 0)!).snapshotDigest,
                       try ActivityJournalBuilder.build(snapshot: withoutConnection, now: at(90), timezone: TimeZone(secondsFromGMT: 0)!).snapshotDigest)
        // An optional observation sidecar must never take down the dashboard.
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &rawDB), SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        XCTAssertEqual(sqlite3_exec(rawDB, "UPDATE activity_meta SET payload='not valid JSON' WHERE key='connection-history'", nil, nil, nil), SQLITE_OK)
        let damaged = try database.overview()
        XCTAssertNil(damaged.connectionHistory)
        XCTAssertEqual(ActivityAccounting.build(overview: damaged, from: at(0), to: at(90)).totals.tokensKnown, 42)
        // A later recovery reading revises its original event window, not the
        // collection hour, and replay cannot add the old total a second time.
        var recoveredSession = session
        recoveredSession.turns[0].usage.total = 84
        let collection = ActivityCollection(sessions: [recoveredSession], health: ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: at(3_600), message: "Recovered"))
        try database.merge([collection], now: at(3_600))
        try database.merge([collection], now: at(3_601))
        let recovered = try database.overview()
        let originalWindow = ActivityAccounting.build(overview: recovered, from: at(0), to: at(90))
        XCTAssertEqual(originalWindow.totals.tokensKnown, 84)
        XCTAssertEqual(originalWindow.series(granularity: .hour, timeZone: TimeZone(secondsFromGMT: 0)!).points.first?.tokensKnown, 84)
        XCTAssertNil(ActivityAccounting.build(overview: recovered, from: at(90), to: at(3_601)).totals.tokensKnown)
    }
}
