import XCTest
@testable import BridgeCore

final class ActivityTimelineLayoutTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func segment(_ id: String, _ from: Double, _ to: Double, category: String? = nil) -> ActivityAnalytics.Segment {
        .init(turnID: id, start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), category: category, toolCalls: 0)
    }

    func testOverlappingLongTurnsRemainInOneReachableChip() throws {
        let turns = [segment("long", 0, 80), segment("nested", 10, 40)]
        let chips = ActivityTimelineLayout.chips(turns, from: start, to: start.addingTimeInterval(100), width: 100)
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips.first?.segments.count, 2)
        XCTAssertEqual(try XCTUnwrap(chips.first?.recordedSeconds), 80)
    }

    func testSmallBurstsClusterWithoutCrossingRealGaps() {
        let turns = [segment("a", 0, 1), segment("b", 2, 3), segment("far", 50, 51)]
        let chips = ActivityTimelineLayout.chips(turns.reversed(), from: start, to: start.addingTimeInterval(100), width: 100)
        XCTAssertEqual(chips.map { $0.segments.count }, [2, 1])
        XCTAssertEqual(chips, ActivityTimelineLayout.chips(turns, from: start, to: start.addingTimeInterval(100), width: 100))
    }

    func testClippingAndMinimumChipWidthNeverExceedTrack() {
        let turns = [segment("left", -10, 1), segment("right", 99.9, 110), segment("outside", 120, 130)]
        let chips = ActivityTimelineLayout.chips(turns, from: start, to: start.addingTimeInterval(100), width: 100)
        XCTAssertEqual(chips.count, 2)
        XCTAssertTrue(chips.allSatisfy { $0.x0 >= 0 && $0.x1 <= 100 && $0.x1 > $0.x0 })
        XCTAssertEqual(chips.first?.segments.first?.start, start)
        XCTAssertEqual(chips.last?.segments.first?.end, start.addingTimeInterval(100))
    }

    func testUnknownCategoriesAreNotOverruledByASingleKnownReceipt() {
        let chips = ActivityTimelineLayout.chips([segment("a", 0, 1), segment("b", 1, 2), segment("c", 2, 3, category: "Research")], from: start, to: start.addingTimeInterval(100), width: 100)
        XCTAssertNil(chips.first?.category)
    }

    func testInvalidGeometryAndDuplicateReceiptsCannotCreateInvalidChips() {
        let turn = segment("a", 1, 10)
        for width in [Double.nan, .infinity, 0, -1] {
            XCTAssertTrue(ActivityTimelineLayout.chips([turn], from: start, to: start.addingTimeInterval(100), width: width).isEmpty)
        }
        XCTAssertTrue(ActivityTimelineLayout.chips([turn], from: start, to: start, width: 100).isEmpty)
        let chips = ActivityTimelineLayout.chips([turn, turn, segment("invalid", 20, 10)], from: start, to: start.addingTimeInterval(100), width: 100)
        XCTAssertEqual(chips.first?.segments.count, 1)
    }
}
