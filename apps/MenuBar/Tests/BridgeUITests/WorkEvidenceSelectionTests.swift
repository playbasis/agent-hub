import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class WorkEvidenceSelectionTests: XCTestCase {
    func testIntentionalInspectionKeepsItsSnapshotAndBoundsClusterSize() {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        var overview = ActivityOverview(generatedAt: time)
        let selection = WorkEvidenceSelection(overview: overview, sessionID: "synthetic", turnIDs: (0..<500).map { "turn-\($0)" })
        overview.generatedAt = time.addingTimeInterval(60)
        XCTAssertEqual(selection.overview.generatedAt, time)
        XCTAssertEqual(selection.turnIDs.count, 160)
        XCTAssertEqual(selection.requestedCount, 500)
        XCTAssertEqual(selection.turnIDs.first, "turn-0")
    }
}
