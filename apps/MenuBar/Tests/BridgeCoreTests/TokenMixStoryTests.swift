@testable import BridgeCore
import XCTest

final class TokenMixStoryTests: XCTestCase {
    private func breakdown(fresh: Int, reread: Int, writes: Int, output: Int) -> ActivityAccounting.Breakdown {
        .init(freshInput: fresh, rereadContext: reread, cacheWrites: writes, output: output, receipts: 1, isComplete: true)
    }

    func testDominantRereadKeepsTheRemainderAsItsOwnSplit() throws {
        let story = try XCTUnwrap(TokenMixStory(breakdown(fresh: 125, reread: 33_900, writes: 10, output: 37)))
        XCTAssertTrue(story.rereadDominates)
        XCTAssertEqual(story.total, 34_072)
        XCTAssertEqual(try XCTUnwrap(story.rereadPerWritten), 33_900.0 / 37, accuracy: 0.001)
        XCTAssertEqual(story.remainder.map(\.kind), [.freshInput, .cacheWrites, .output])
        XCTAssertEqual(story.remainder.map(\.shareOfRemainder).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(story.remainder.first?.shareOfRemainder ?? 0, 125.0 / 172, accuracy: 1e-9)
    }

    func testMissingOrZeroBreakdownsHaveNoStory() {
        XCTAssertNil(TokenMixStory(breakdown(fresh: 0, reread: 0, writes: 0, output: 0)))
        XCTAssertNil(TokenMixStory(breakdown(fresh: -1, reread: 10, writes: 0, output: 1)), "corrupt components are unknown, not a share")
        XCTAssertNil(TokenMixStory(breakdown(fresh: .max, reread: 1, writes: 0, output: 0)), "overflow is unknown, not a share")
    }

    func testNothingWrittenLeavesTheRatioUnknownAndOmitsZeroParts() throws {
        let story = try XCTUnwrap(TokenMixStory(breakdown(fresh: 5, reread: 95, writes: 0, output: 0)))
        XCTAssertNil(story.rereadPerWritten)
        XCTAssertEqual(story.remainder.map(\.kind), [.freshInput])
        let reread = try XCTUnwrap(TokenMixStory(breakdown(fresh: 0, reread: 10, writes: 0, output: 0)))
        XCTAssertTrue(reread.remainder.isEmpty)
        XCTAssertEqual(reread.rereadShare, 1)
    }

    func testPercentNeverRoundsPartialSharesToTheExtremes() {
        XCTAssertEqual(TokenMixStory.percent(0.9996), "99.9%")
        XCTAssertEqual(TokenMixStory.percent(0.996), "99.6%")
        XCTAssertEqual(TokenMixStory.percent(0.99), "99.0%")
        XCTAssertEqual(TokenMixStory.percent(0.004), "<1%")
        XCTAssertEqual(TokenMixStory.percent(0.5), "50%")
        XCTAssertEqual(TokenMixStory.percent(0), "0%")
        XCTAssertEqual(TokenMixStory.percent(1), "100%")
        XCTAssertEqual(TokenMixStory.percent(.nan), "—")
    }
}
