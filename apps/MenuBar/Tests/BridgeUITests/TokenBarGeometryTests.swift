import XCTest
@testable import ClaudeCodexBridgeMenuBar

final class TokenBarGeometryTests: XCTestCase {
    func testIntervalColumnsStartAtZeroAndStackWithoutOverlayingProviders() {
        let values = TokenActivityChart.stackRanges([20,30,50])
        XCTAssertEqual(values.compactMap { $0?.lower },[0,20,50])
        XCTAssertEqual(values.compactMap { $0?.upper },[20,50,100])
    }
    func testMissingAndInvalidComponentsAreNotInventedAsZero() {
        let values = TokenActivityChart.stackRanges([nil,-1,.nan,.infinity,20,0,30])
        XCTAssertTrue(values.prefix(4).allSatisfy { $0 == nil })
        XCTAssertEqual(values.compactMap { $0?.lower },[0,20,20])
        XCTAssertEqual(values.compactMap { $0?.upper },[20,20,50])
    }
    func testStackOverflowDoesNotPublishInfiniteAxisValues() {
        let values = TokenActivityChart.stackRanges([Double.greatestFiniteMagnitude,Double.greatestFiniteMagnitude])
        XCTAssertNotNil(values[0])
        XCTAssertNil(values[1])
    }
}
