import Foundation
import XCTest
@testable import BridgeCore

final class TranscriptCacheMemoryTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testDefaultRetentionIsBoundedByCountAndEstimatedBytes() {
        let cache = TranscriptCache()
        for index in 0..<200 { cache.store(CodexActivityTranscript(), for: key("path-\(index)", bytes: 1_024 * 1_024)) }
        let state = cache.diagnostics()
        XCTAssertLessThanOrEqual(state.entryCount, 24)
        XCTAssertLessThanOrEqual(state.estimatedCostBytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(state.maximumEntryCount, 24)
        XCTAssertEqual(state.maximumEstimatedCostBytes, 16 * 1_024 * 1_024)
    }

    func testHitsRefreshRecencyAndCountEvictionKeepsOtherEntries() {
        let cache = TranscriptCache(limit: 2)
        let a = key("a"), b = key("b"), c = key("c")
        cache.store(CodexActivityTranscript(), for: a)
        cache.store(CodexActivityTranscript(), for: b)
        XCTAssertNotNil(cache.value(for: a))
        cache.store(CodexActivityTranscript(), for: c)
        XCTAssertNil(cache.value(for: b))
        XCTAssertNotNil(cache.value(for: a))
        XCTAssertNotNil(cache.value(for: c))
        XCTAssertEqual(cache.diagnostics().entryCount, 2, "Reaching capacity evicts one LRU entry, not the whole cache")
    }

    func testWeightedEvictionUsesSourceWindowAndNeverExceedsBudget() {
        let cache = TranscriptCache(limit: 10, maximumEstimatedCostBytes: 250 * 1_024)
        let a = key("a", bytes: 80 * 1_024), b = key("b", bytes: 80 * 1_024), c = key("c", bytes: 120 * 1_024)
        cache.store(CodexActivityTranscript(), for: a)
        cache.store(CodexActivityTranscript(), for: b)
        XCTAssertNotNil(cache.value(for: a))
        cache.store(CodexActivityTranscript(), for: c)
        XCTAssertNil(cache.value(for: b))
        XCTAssertNotNil(cache.value(for: a))
        XCTAssertNotNil(cache.value(for: c))
        XCTAssertEqual(cache.diagnostics().estimatedCostBytes, 200 * 1_024)
    }

    func testReadWindowAndChangedFileVariantsReplaceInsteadOfAccumulating() {
        let cache = TranscriptCache()
        let narrow = key("same", bytes: 1_024 * 1_024)
        var wide = narrow; wide.size = 8 * 1_024 * 1_024; wide.maximumBytes = wide.size
        cache.store(CodexActivityTranscript(), for: narrow)
        cache.store(CodexActivityTranscript(), for: wide)
        XCTAssertEqual(cache.diagnostics().entryCount, 1)
        XCTAssertEqual(cache.diagnostics().estimatedCostBytes, 8 * 1_024 * 1_024)
        XCTAssertNil(cache.value(for: narrow))
        XCTAssertNotNil(cache.value(for: wide), "A stale lookup must not evict a newer valid parse")
        var changed = wide; changed.modified = stamp.addingTimeInterval(1)
        cache.store(CodexActivityTranscript(), for: changed)
        XCTAssertNil(cache.value(for: wide))
        XCTAssertNotNil(cache.value(for: changed))
        XCTAssertEqual(cache.diagnostics().entryCount, 1)
    }

    func testOversizedEntryIsNotRetainedAndDoesNotFlushOtherPaths() {
        let cache = TranscriptCache(limit: 4, maximumEstimatedCostBytes: 128 * 1_024)
        let small = key("small"), large = key("large", bytes: 1_024 * 1_024)
        cache.store(CodexActivityTranscript(), for: small)
        cache.store(CodexActivityTranscript(), for: large)
        XCTAssertNil(cache.value(for: large))
        XCTAssertNotNil(cache.value(for: small))
        XCTAssertEqual(cache.diagnostics().entryCount, 1)
        var largerSmall = small; largerSmall.size = large.size; largerSmall.maximumBytes = large.maximumBytes
        cache.store(CodexActivityTranscript(), for: largerSmall)
        XCTAssertNil(cache.value(for: small), "An obsolete same-path variant must not linger after an oversized replacement")
        XCTAssertEqual(cache.diagnostics().estimatedCostBytes, 0)
    }

    func testDenseParsedMetadataCannotHideBehindTinySourceWeight() {
        let cache = TranscriptCache(limit: 4, maximumEstimatedCostBytes: 128 * 1_024)
        var dense = CodexActivityTranscript()
        var turn = CodexActivityTranscript.Turn()
        turn.itemIDs = Set((0..<2_000).map { "item-\($0)-" + String(repeating: "x", count: 64) })
        dense.turns["turn"] = turn
        let tiny = key("dense", bytes: 1)
        cache.store(dense, for: tiny)
        XCTAssertNil(cache.value(for: tiny))
        XCTAssertEqual(cache.diagnostics().entryCount, 0)
    }

    func testCachePreservesTelemetryWithoutChangingCountsOrPartialFlags() throws {
        let cache = TranscriptCache()
        var transcript = CodexActivityTranscript()
        var turn = CodexActivityTranscript.Turn()
        turn.model = "requested-model"; turn.effort = "high"
        turn.startedAt = stamp; turn.completedAt = stamp.addingTimeInterval(60)
        turn.beganInWindow = true; turn.completedInWindow = true
        turn.promptIDs = ["prompt"]; turn.toolIDs = ["tool"]
        turn.categories = ["research": 1]
        turn.usage = TokenUsage(input: 10, output: 5, total: 15, provenance: .providerReported)
        turn.artifacts["file"] = ActivityArtifact(id: "file", path: "/fixture/file.swift")
        transcript.turns["turn"] = turn; transcript.scanTruncated = true
        transcript.warnings = ["Partial source window"]
        let identity = key("telemetry")
        cache.store(transcript, for: identity)
        let restored = try XCTUnwrap(cache.value(for: identity))
        XCTAssertEqual(restored.turns["turn"]?.usage, turn.usage)
        XCTAssertEqual(restored.turns["turn"]?.observedPromptCount, 1)
        XCTAssertEqual(restored.turns["turn"]?.observedToolCount, 1)
        XCTAssertEqual(restored.turns["turn"]?.model, "requested-model")
        XCTAssertEqual(restored.turns["turn"]?.artifacts["file"], turn.artifacts["file"])
        XCTAssertEqual(restored.warnings, transcript.warnings)
        XCTAssertTrue(restored.scanTruncated)
        XCTAssertEqual(restored.usageIsPartial(for: "turn", status: "completed"), true)
    }

    func testDisabledAndConcurrentCachesKeepAccountingWithinBounds() {
        let disabled = TranscriptCache(limit: 0)
        disabled.store(CodexActivityTranscript(), for: key("disabled"))
        XCTAssertEqual(disabled.diagnostics().entryCount, 0)
        let zeroBudget = TranscriptCache(maximumEstimatedCostBytes: 0)
        zeroBudget.store(CodexActivityTranscript(), for: key("disabled"))
        XCTAssertEqual(zeroBudget.diagnostics().estimatedCostBytes, 0)
        let cache = TranscriptCache(limit: 6, maximumEstimatedCostBytes: 512 * 1_024)
        let keys = (0..<30).map { key("concurrent-\($0)") }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let identity = keys[index % keys.count]
            cache.store(CodexActivityTranscript(), for: identity)
            _ = cache.value(for: identity)
            let state = cache.diagnostics()
            XCTAssertLessThanOrEqual(state.entryCount, state.maximumEntryCount)
            XCTAssertLessThanOrEqual(state.estimatedCostBytes, state.maximumEstimatedCostBytes)
        }
    }

    private func key(_ path: String, bytes: UInt64 = 64 * 1_024) -> TranscriptCache.Key {
        TranscriptCache.Key(path: "/fixture/\(path).jsonl", size: bytes, modified: stamp, maximumBytes: bytes)
    }
}
