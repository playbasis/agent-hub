@testable import BridgeCore
import Foundation
import XCTest

final class NormalizedCompositionTests: XCTestCase {
    func testNormalizedUsageReducerMatchesLegacyMathForUniqueReceipts() {
        let values = [
            TokenUsage(input: 1_000, output: 10, cachedInput: 900, total: 1_010),
            TokenUsage(input: 5, output: 20, cachedInput: 500, cacheWriteInput: 75, total: 600),
            TokenUsage(output: 3, total: 50),
            TokenUsage(input: -1, output: 2, cachedInput: 0, cacheWriteInput: 0, total: 2),
            TokenUsage(input: 0, output: 0, cachedInput: 0, cacheWriteInput: 0, total: 0),
        ]
        let legacy = values.enumerated().map { ActivityTurn(id: "record-\($0.offset)", usage: $0.element) }
        XCTAssertEqual(ActivityAnalytics.composition(usages: values.lazy), ActivityAnalytics.composition(legacy))
        XCTAssertEqual(ActivityAnalytics.composition(usages: values)?.receipts, 3)
    }

    func testLegacyDuplicateIDsStillMergeButEqualNormalizedValuesRemainDistinct() throws {
        let prior = TokenUsage(input: 100, output: 1, cachedInput: 90, total: 101)
        let corrected = TokenUsage(input: 200, output: 2, cachedInput: 180, total: 202)
        let duplicate = [ActivityTurn(id: "same", usage: prior), ActivityTurn(id: "same", usage: corrected)]
        let legacy = try XCTUnwrap(ActivityAnalytics.composition(duplicate))
        XCTAssertEqual(legacy.receipts, 1)
        XCTAssertEqual(legacy.total, 202)
        let normalized = try XCTUnwrap(ActivityAnalytics.composition(usages: [corrected, corrected]))
        XCTAssertEqual(normalized.receipts, 2, "equal token figures do not make two already-owned receipts duplicates")
        XCTAssertEqual(normalized.total, 404)
    }

    func testNormalizedAndLegacyOverflowAndMissingDataRulesRemainIdentical() {
        let enormous = TokenUsage(input: Int.max, output: 0, cachedInput: 0, cacheWriteInput: 0, total: Int.max)
        let extra = TokenUsage(input: 1, output: 0, cachedInput: 0, cacheWriteInput: 0, total: 1)
        XCTAssertNil(ActivityAnalytics.composition(usages: [enormous, extra]))
        XCTAssertNil(ActivityAnalytics.composition([ActivityTurn(id: "huge", usage: enormous), ActivityTurn(id: "extra", usage: extra)]))
        XCTAssertNil(ActivityAnalytics.composition(usages: [TokenUsage(), TokenUsage(output: 3, total: 50)]))
        let impossible = TokenUsage(input: 0, output: Int.max, cachedInput: Int.max, cacheWriteInput: 0, total: Int.max)
        XCTAssertNil(ActivityAnalytics.composition(usages: [impossible]))
    }

    func testLargeCanonicalSequenceIsConsumedOnceWithoutMaterializingTurns() throws {
        let sample = TokenUsage(input: 10, output: 1, cachedInput: 8, total: 11)
        var iterators = 0
        var reads = 0
        let values = AnySequence<TokenUsage> {
            iterators += 1
            return AnyIterator<TokenUsage> {
                guard reads < 50_000 else { return nil }
                reads += 1
                return sample
            }
        }
        let result = try XCTUnwrap(ActivityAnalytics.composition(usages: values))
        XCTAssertEqual(iterators, 1)
        XCTAssertEqual(reads, 50_000)
        XCTAssertEqual(result.receipts, 50_000)
        XCTAssertEqual(result.freshInput, 100_000)
        XCTAssertEqual(result.rereadContext, 400_000)
        XCTAssertEqual(result.output, 50_000)
        XCTAssertEqual(result.total, 550_000)
    }
}
