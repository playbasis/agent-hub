@testable import BridgeCore
import XCTest

final class ChartScaleTests: XCTestCase {
    func testTopHugsThePeakOnANiceStep() {
        XCTAssertEqual(ChartScale(peak: 300_000_000).upperBound, 350_000_000, "not a quarter of empty plot above the tallest bar")
        XCTAssertEqual(ChartScale(peak: 300_000_000).ticks.count, 8)
        XCTAssertEqual(ChartScale(peak: 7_100_000_000).ticks, [0, 2_500_000_000, 5_000_000_000, 7_500_000_000])
        XCTAssertEqual(ChartScale(peak: 715).upperBound, 750)
        XCTAssertEqual(ChartScale(peak: 4).upperBound, 5)
    }

    func testEveryPeakFitsWithHeadroomAndFewTicks() {
        for peak in [0.3, 1, 7, 9.9, 10, 99, 101, 333, 4_999, 123_456_789, 9.99e15] {
            let scale = ChartScale(peak: peak)
            XCTAssertGreaterThanOrEqual(scale.upperBound, peak * ChartScale.headroom, "\(peak)")
            XCTAssertLessThan(scale.upperBound, peak * 1.7, "\(peak): the top adapts to the data")
            XCTAssertTrue((4 ... 8).contains(scale.ticks.count), "\(peak): \(scale.ticks)")
            XCTAssertEqual(scale.ticks.first, 0)
            XCTAssertEqual(scale.ticks.last ?? 0, scale.upperBound, accuracy: scale.upperBound * 1e-12)
        }
    }

    func testEmptyAndCorruptInputStayFinite() {
        for peak: Double in [0, -1, .nan, .infinity, -.infinity] {
            XCTAssertEqual(ChartScale(peak: peak), ChartScale(peak: 0))
        }
        XCTAssertEqual(ChartScale(peak: 0).upperBound, 1)
        XCTAssertTrue(ChartScale(peak: .greatestFiniteMagnitude).ticks.allSatisfy(\.isFinite))
    }

    func testStackedPeakIsTheLargestBucketSum() {
        let scale = ChartScale(stacked: [(bucket: 1, value: 200), (bucket: 1, value: 110), (bucket: 2, value: 290), (bucket: 3, value: -5)])
        XCTAssertEqual(scale, ChartScale(peak: 310))
    }
}
