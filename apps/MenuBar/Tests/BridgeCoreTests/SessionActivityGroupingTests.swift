import XCTest
@testable import BridgeCore

final class SessionActivityGroupingTests: XCTestCase {

    // These expectations are written for Bangkok (UTC+7) day boundaries; pin the
    // reporting zone so they hold on a Mac in any time zone.
    private var hostReportingZone = ActivityAnalytics.reportingTimeZone
    override func setUp() {
        super.setUp()
        hostReportingZone = ActivityAnalytics.reportingTimeZone
        ActivityAnalytics.reportingTimeZone = TimeZone(identifier: "Asia/Bangkok")!
    }
    override func tearDown() {
        ActivityAnalytics.reportingTimeZone = hostReportingZone
        super.tearDown()
    }
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T17:05:00Z")! // Nov 5, 00:05 Bangkok
    func testBangkokDayBoundariesDoNotUseTheHostTimezoneOrMetadata() {
        XCTAssertEqual(SessionActivityGrouping.group(lastEvidence: now.addingTimeInterval(-60), openOrRecent: false, now: now), .today)
        XCTAssertEqual(SessionActivityGrouping.group(lastEvidence: now.addingTimeInterval(-600), openOrRecent: false, now: now), .yesterday)
        XCTAssertEqual(SessionActivityGrouping.group(lastEvidence: now.addingTimeInterval(-3 * 86400), openOrRecent: false, now: now), .week)
        XCTAssertEqual(SessionActivityGrouping.group(lastEvidence: now.addingTimeInterval(-8 * 86400), openOrRecent: false, now: now), .older)
    }
    func testMissingFutureAndInvalidEvidenceAreUndatedNotRecentWork() {
        for date in [nil, now.addingTimeInterval(1), Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
            XCTAssertEqual(SessionActivityGrouping.group(lastEvidence: date, openOrRecent: false, now: now), .undated)
        }
    }
    func testOpenContextIsLabeledAsOpenNotVerifiedProcessLiveness() {
        XCTAssertEqual(SessionActivityGrouping.group(lastEvidence: nil, openOrRecent: true, now: now), .openOrRecent)
        XCTAssertEqual(SessionActivityGrouping.Group.openOrRecent.rawValue, "Recent or open work")
    }
}
