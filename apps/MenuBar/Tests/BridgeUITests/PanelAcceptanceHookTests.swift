import BridgeCore
import XCTest
@testable import ClaudeCodexBridgeMenuBar

final class PanelAcceptanceHookTests: XCTestCase {
    func testDisclosureHookRequiresActiveAcceptanceAndExactScope() {
        XCTAssertNil(PanelDisclosureAcceptance.response(name: "disclosure.open", scope: "panel", active: false, expanded: false))
        XCTAssertNil(PanelDisclosureAcceptance.response(name: "disclosure.open", scope: "panel-chart", active: true, expanded: false))
        XCTAssertNil(PanelDisclosureAcceptance.response(name: "disclosure.open", scope: "hub", active: true, expanded: false))
        let opened = PanelDisclosureAcceptance.response(name: "disclosure.open", scope: "panel", active: true, expanded: false)
        XCTAssertEqual(opened?.expanded, true)
        XCTAssertEqual(opened?.supported, true)
    }

    func testDisclosureReportAndUnsupportedCommandsNeverResetPresentation() {
        for expanded in [false, true] {
            let report = PanelDisclosureAcceptance.response(name: "report", scope: "panel", active: true, expanded: expanded)
            XCTAssertEqual(report?.expanded, expanded)
            XCTAssertEqual(report?.supported, true)
            let unknown = PanelDisclosureAcceptance.response(name: "chart.window", scope: "panel", active: true, expanded: expanded)
            XCTAssertEqual(unknown?.expanded, expanded)
            XCTAssertEqual(unknown?.supported, false)
        }
    }

    func testChartHookRequiresActiveAcceptanceAndExactScope() {
        XCTAssertNil(TokenActivityChart.acceptanceResponse(name: "chart.metric", value: "output", scope: "panel-chart", active: false, bucket: .hour, metric: .total))
        XCTAssertNil(TokenActivityChart.acceptanceResponse(name: "chart.metric", value: "output", scope: "panel", active: true, bucket: .hour, metric: .total))
        XCTAssertNil(TokenActivityChart.acceptanceResponse(name: "chart.metric", value: "output", scope: "hub", active: true, bucket: .hour, metric: .total))
    }

    func testChartWindowAndMetricAcknowledgeActualMachineValues() {
        let day = TokenActivityChart.acceptanceResponse(name: "chart.window", value: "day", scope: "panel-chart", active: true, bucket: .hour, metric: .total)
        XCTAssertEqual(day?.state, ["bucket": "day", "metric": "total"])
        XCTAssertEqual(day?.supported, true)
        let hour = TokenActivityChart.acceptanceResponse(name: "chart.window", value: "hour", scope: "panel-chart", active: true, bucket: .day, metric: .output)
        XCTAssertEqual(hour?.state, ["bucket": "hour", "metric": "output"])
        for value in ["output", "total", "weighted"] {
            let selected = TokenActivityChart.acceptanceResponse(name: "chart.metric", value: value, scope: "panel-chart", active: true, bucket: .day, metric: .total)
            XCTAssertEqual(selected?.state, ["bucket": "day", "metric": value])
            XCTAssertEqual(selected?.supported, true)
        }
    }

    func testInvalidOrUnknownChartCommandsAreUnsupportedAndDoNotChangeSelections() {
        for (name, value) in [("chart.window", "week"), ("chart.metric", "Tokens"), ("chart.metric", ""), ("unrelated", "output")] {
            let response = TokenActivityChart.acceptanceResponse(name: name, value: value, scope: "panel-chart", active: true, bucket: .day, metric: .output)
            XCTAssertEqual(response?.state, ["bucket": "day", "metric": "output"])
            XCTAssertEqual(response?.supported, false)
        }
    }

    func testReportRetainsSelectionAcrossRepeatedSnapshotRefreshReports() throws {
        var selection = try XCTUnwrap(TokenActivityChart.acceptanceResponse(name: "chart.metric", value: "weighted", scope: "panel-chart", active: true, bucket: .day, metric: .total))
        for _ in 0..<5 {
            selection = try XCTUnwrap(TokenActivityChart.acceptanceResponse(name: "report", value: nil, scope: "panel-chart", active: true,
                bucket: selection.bucket, metric: selection.metric))
            XCTAssertEqual(selection.state, ["bucket": "day", "metric": "weighted"])
            XCTAssertTrue(selection.supported)
        }
    }
}
