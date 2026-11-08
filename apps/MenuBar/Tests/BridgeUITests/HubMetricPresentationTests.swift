import CoreGraphics
import XCTest
@testable import ClaudeCodexBridgeMenuBar

final class HubMetricPresentationTests: XCTestCase {
    func testHistogramFiltersInvalidValuesAndNeverHighlightsAnEmptyBucket() {
        let values = SessionDurationHistogram.build([60, 20_000])
        XCTAssertEqual(values.counts, [1, 0, 0, 0, 1])
        XCTAssertEqual(values.medianBucket, 0, "Highlight a central observed sample, not the empty range between two samples")
        let mixed = SessionDurationHistogram.build([.nan, -1, 30, .infinity, 1_000])
        XCTAssertEqual(mixed.sampleCount, 2)
        XCTAssertEqual(mixed.counts, [1, 0, 1, 0, 0])
        XCTAssertEqual(mixed.medianBucket, 0)
        for invalid in [[], [-1, Double.nan, .infinity]] {
            let empty = SessionDurationHistogram.build(invalid)
            XCTAssertEqual(empty.counts, Array(repeating: nil, count: 5))
            XCTAssertNil(empty.medianBucket)
            XCTAssertEqual(empty.sampleCount, 0)
        }
    }

    func testHistogramBoundarySamplesAreCountedExactlyOnce() {
        let values = SessionDurationHistogram.build([0, 299, 300, 899, 900, 3_599, 3_600, 14_399, 14_400])
        XCTAssertEqual(values.counts, [2, 2, 2, 2, 1])
        XCTAssertEqual(values.counts.compactMap { $0 }.reduce(0, +), Double(values.sampleCount))
        XCTAssertEqual(values.medianBucket, 2)
    }

    func testMetricStripHasOneTwoThreeAndSixColumnFallbacks() {
        XCTAssertEqual(MetricStripLayout.columnCount(for: 1_000, itemCount: 6), 6)
        XCTAssertEqual(MetricStripLayout.columnCount(for: 600, itemCount: 6), 3)
        XCTAssertEqual(MetricStripLayout.columnCount(for: 420, itemCount: 6), 2)
        XCTAssertEqual(MetricStripLayout.columnCount(for: 250, itemCount: 6), 1)
        XCTAssertEqual(MetricStripLayout.columnCount(for: .nan, itemCount: 6), 1)
        XCTAssertEqual(MetricStripLayout.columnCount(for: 1_000, itemCount: 1), 1)
    }

    func testMiniChartDistinguishesNoRecordsUnknownAndMeasuredZero() {
        let values: [Double?] = [nil, nil, 0, 12, -1, .infinity]
        let samples = MiniBarsPresentation.samples(values, emptyIndices: [0, 2, 3, 4])
        XCTAssertEqual(samples, [.noRecords, .unavailable, .measured(0), .measured(12), .unavailable, .unavailable])
        let summary = MiniBarsPresentation.accessibilitySummary(values, emptyIndices: [0, 2, 3, 4])
        XCTAssertTrue(summary.contains("2 measured values"))
        XCTAssertTrue(summary.contains("1 interval with no dated records"))
        XCTAssertTrue(summary.contains("3 intervals with missing measurements"))
        XCTAssertTrue(summary.contains("not a measured zero"))
    }

    func testMiniChartGeometryNeverClipsTheLastBarAtNarrowWidths() {
        let widths: [CGFloat] = [1, 20, 100, 500]
        for width in widths {
            for count in [1, 5, 24, 31, 500] {
                let geometry = MiniBarsPresentation.geometry(width: width, count: count)
                XCTAssertGreaterThanOrEqual(geometry.barWidth, 0)
                XCTAssertGreaterThanOrEqual(geometry.gap, 0)
                let occupied = geometry.barWidth * CGFloat(count) + geometry.gap * CGFloat(count - 1)
                XCTAssertLessThanOrEqual(occupied, width + 0.000_001)
            }
        }
        XCTAssertEqual(MiniBarsPresentation.geometry(width: .nan, count: 5).barWidth, 0)
    }
}
