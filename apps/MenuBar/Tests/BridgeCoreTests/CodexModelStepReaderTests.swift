@testable import BridgeCore
import Foundation
import XCTest

final class CodexModelStepReaderTests: XCTestCase {
    private var directory: URL!
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-model-steps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func line(_ type: String, _ payload: [String: Any], at seconds: Double? = 0) throws -> String {
        var root: [String: Any] = ["type": type, "payload": payload]
        if let seconds { root["timestamp"] = ISO8601DateFormatter().string(from: clock.addingTimeInterval(seconds)) }
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }

    private func start(_ id: String, at seconds: Double = 0) throws -> String {
        try line("event_msg", ["type": "task_started", "turn_id": id], at: seconds)
    }

    private func context(_ id: String, model: String = "gpt-6-astra", effort: String = "ultra") throws -> String {
        try line("turn_context", ["turn_id": id, "model": model, "effort": effort])
    }

    private func finish(_ id: String, at seconds: Double = 30) throws -> String {
        try line("event_msg", ["type": "task_complete", "turn_id": id], at: seconds)
    }

    private func usage(_ total: Int, last: Int = 10, at seconds: Double? = 10, cached: Int = 0, lastCached: Int = 0) throws -> String {
        func fields(_ input: Int, _ cache: Int) -> [String: Int] {
            ["input_tokens": input, "output_tokens": 0, "cached_input_tokens": cache,
             "cache_write_input_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": input]
        }
        return try line("event_msg", ["type": "token_count", "info": [
            "total_token_usage": fields(total, cached), "last_token_usage": fields(last, lastCached),
        ]], at: seconds)
    }

    private func write(_ lines: [String], name: String = "rollout.jsonl") throws -> URL {
        let file = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func append(_ lines: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func read(_ store: CodexModelStepReader.Store, _ file: URL, maximumBytes: UInt64 = 128 * 1_024 * 1_024) -> CodexModelStepReader.Result {
        store.read(path: file.path, deadline: Date().addingTimeInterval(30), maximumBytes: maximumBytes)
    }

    func testOneNativeTurnContainsManyStepsAndQuotaSnapshotsDoNotCount() throws {
        let file = try write([start("t"), context("t"), usage(10), usage(20), usage(20, last: 999, at: 11), usage(20, cached: 1), usage(30), finish("t")])
        let result = read(.init(), file)
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.turns.count, 1)
        let turn = try XCTUnwrap(result.turns["t"])
        XCTAssertEqual(turn.modelSteps.count, 3)
        XCTAssertEqual(ActivityMetrics.knownTotal(turn.modelSteps.map(\.usage.total)), 30)
        XCTAssertTrue(turn.modelSteps.allSatisfy { $0.model == "gpt-6-astra" && $0.effort == "ultra" })
        XCTAssertTrue(turn.modelStepsComplete)
    }

    func testModelAndEffortSwitchInsideOneTurnKeepSeparateCheckpointIdentity() throws {
        let file = try write([start("t"), context("t"), usage(10), context("t", model: "gpt-6.1-sol", effort: "high"), usage(30, last: 20), finish("t")])
        let steps = try XCTUnwrap(read(.init(), file).turns["t"]?.modelSteps)
        XCTAssertEqual(steps.map(\.model), ["gpt-6-astra", "gpt-6.1-sol"])
        XCTAssertEqual(steps.map(\.effort), ["ultra", "high"])
        XCTAssertEqual(steps.map(\.usage.total), [10, 20])
    }

    func testHeadContextSurvivesMoreThanTheOldTailWindowAndIrrelevantOversizeLines() throws {
        let padding = String(repeating: "x", count: 9 * 1_024 * 1_024)
        let irrelevant = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":"PRIVATE_REASONING_\#(padding)"}}"#
        let file = try write([start("long"), context("long"), irrelevant, usage(10), finish("long")])
        let result = read(.init(), file)
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.turns["long"]?.modelSteps.first?.model, "gpt-6-astra")
        XCTAssertTrue(result.turns["long"]?.modelStepsComplete == true, "irrelevant output does not erase the active turn context")
        XCTAssertFalse(result.warnings.joined().contains("PRIVATE_REASONING"))
    }

    func testByteBudgetResumesAndAppendRetainsContextWithoutRereadingTheHead() throws {
        let file = try write([start("t"), context("t"), usage(10), usage(20), finish("t")])
        let store = CodexModelStepReader.Store()
        var result = read(store, file, maximumBytes: 100)
        XCTAssertTrue(result.hitBudget)
        XCTAssertEqual(result.readOffset, 100)
        var previous = result.readOffset
        for _ in 0..<100 where !result.finished {
            result = read(store, file, maximumBytes: 100)
            XCTAssertGreaterThan(result.readOffset, previous)
            previous = result.readOffset
        }
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.turns["t"]?.modelSteps.count, 2)
        let idle = read(store, file)
        XCTAssertEqual(idle.bytesRead, 0)
        try append([start("next", at: 40), context("next", model: "gpt-6.1-sol"), usage(30, at: 50), finish("next", at: 60)], to: file)
        let appended = read(store, file)
        XCTAssertEqual(appended.turns["t"]?.modelSteps.count, 2)
        XCTAssertEqual(appended.turns["next"]?.modelSteps.count, 1)
        XCTAssertLessThan(appended.bytesRead, appended.readOffset, "only appended bytes were parsed")
    }

    func testCounterResetStartsANewSegmentAndLaterUsageDoesNotWaitForTheOldHighWater() throws {
        let file = try write([start("t"), context("t"), usage(10), usage(20), usage(5, last: 5), usage(10, last: 5), finish("t")])
        let result = read(.init(), file)
        let steps = try XCTUnwrap(result.turns["t"]?.modelSteps)
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(Set(steps.map(\.id)).count, 4)
        XCTAssertEqual(ActivityMetrics.knownTotal(steps.map(\.usage.total)), 30)
        XCTAssertTrue(result.warnings.contains { $0.contains("new counter segment") })
    }

    func testReplayAndForkCopiesHaveStableIDsIndependentOfFileAndTimestamp() throws {
        let first = try write([start("shared"), context("shared"), usage(10, at: 1), usage(20, at: 2), finish("shared")], name: "original.jsonl")
        let fork = try write([start("shared", at: 100), context("shared"), usage(10, at: 101), usage(20, at: 102), finish("shared", at: 130)], name: "fork.jsonl")
        let store = CodexModelStepReader.Store()
        let original = read(store, first)
        let copy = read(store, fork)
        XCTAssertEqual(original.turns["shared"]?.modelSteps.map(\.id), copy.turns["shared"]?.modelSteps.map(\.id))
        try append([start("shared", at: 200), context("shared"), usage(10, at: 201), usage(20, at: 202), finish("shared", at: 230)], to: first)
        XCTAssertEqual(read(store, first).turns["shared"]?.modelSteps.count, 2, "a replay is not another pair of model steps")
    }

    func testNewTurnWithoutContextNeverInheritsThePreviousModelsIdentity() throws {
        let file = try write([start("a"), context("a"), usage(10), finish("a"), start("b"), usage(20), finish("b")])
        let result = read(.init(), file)
        let second = try XCTUnwrap(result.turns["b"])
        XCTAssertNil(second.model)
        XCTAssertNil(second.effort)
        XCTAssertNil(second.modelSteps.first?.model)
        XCTAssertFalse(second.modelStepsComplete)
        XCTAssertEqual(second.modelSteps.first?.usageIsPartial, true)
    }

    func testCheckpointTimestampRatherThanNativeTurnCompletionControlsTheDate() throws {
        let midnight = Date(timeIntervalSince1970: floor(clock.timeIntervalSince1970 / 86_400) * 86_400)
        let before = midnight.timeIntervalSince(clock) - 1
        let after = midnight.timeIntervalSince(clock) + 1
        let file = try write([start("t", at: before - 60), context("t"), usage(10, at: before), usage(20, at: after), finish("t", at: after + 60)])
        let steps = try XCTUnwrap(read(.init(), file).turns["t"]?.modelSteps)
        XCTAssertEqual(steps[0].timestamp, midnight.addingTimeInterval(-1))
        XCTAssertEqual(steps[1].timestamp, midnight.addingTimeInterval(1))
        XCTAssertNotEqual(steps[0].timestamp, steps[1].timestamp)
    }

    func testRotationAndSameSizeRewriteInvalidateStaleCheckpointState() throws {
        let file = try write([start("old"), context("old"), usage(10), finish("old")])
        let store = CodexModelStepReader.Store()
        XCTAssertNotNil(read(store, file).turns["old"])
        _ = try write([start("new"), context("new"), usage(10), finish("new")]) // atomic replace changes inode
        let rotated = read(store, file)
        XCTAssertNil(rotated.turns["old"])
        XCTAssertNotNil(rotated.turns["new"])
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "new", with: "alt")
        try text.write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        let rewritten = read(store, file)
        XCTAssertNil(rewritten.turns["new"])
        XCTAssertNotNil(rewritten.turns["alt"])
    }

    func testNoUsageDoesNotBecomeAnAuthoritativeZeroAndGapsStayPartial() throws {
        let empty = try write([start("empty"), context("empty"), finish("empty")], name: "empty.jsonl")
        XCTAssertFalse(read(.init(), empty).turns["empty"]?.modelStepsComplete ?? true)
        let gap = try write([start("gap"), context("gap"), usage(100, last: 10), finish("gap")], name: "gap.jsonl")
        let partial = try XCTUnwrap(read(.init(), gap).turns["gap"])
        XCTAssertTrue(partial.modelSteps.isEmpty, "the first cumulative snapshot does not prove a fresh usage advance")
        XCTAssertFalse(partial.modelStepsComplete)
    }

    func testMissingTimestampRemainsNilAndStepLimitsAreExplicit() throws {
        let file = try write([start("t"), context("t"), usage(10, at: nil), usage(20), usage(30), finish("t")])
        let result = read(.init(maximumSteps: 2), file)
        XCTAssertEqual(result.turns["t"]?.modelSteps.count, 2)
        XCTAssertNil(result.turns["t"]?.modelSteps.first?.timestamp)
        XCTAssertTrue(result.hitLimit)
        XCTAssertFalse(result.turns["t"]?.modelStepsComplete ?? true)
        XCTAssertTrue(result.warnings.contains { $0.contains("memory limit") })
    }

    func testPastDeadlineAndZeroBudgetDoNotAdvanceTheCursor() throws {
        let file = try write([start("t"), context("t"), usage(10), finish("t")])
        let store = CodexModelStepReader.Store()
        let timed = store.read(path: file.path, deadline: Date().addingTimeInterval(-1), maximumBytes: 100)
        XCTAssertTrue(timed.hitDeadline)
        XCTAssertEqual(timed.readOffset, 0)
        let zero = read(store, file, maximumBytes: 0)
        XCTAssertTrue(zero.hitBudget)
        XCTAssertEqual(zero.readOffset, 0)
        XCTAssertTrue(read(store, file).finished)
    }

    func testUnfinishedPriorityFileIsNotEvictedByLaterCompletedFiles() throws {
        let large = try write([start("priority"), context("priority"), usage(10), finish("priority")], name: "priority.jsonl")
        let store = CodexModelStepReader.Store(maximumPaths: 1)
        let partial = read(store, large, maximumBytes: 100)
        for index in 0..<3 {
            let small = try write([start("s\(index)"), context("s\(index)"), usage(10), finish("s\(index)")], name: "small\(index).jsonl")
            _ = read(store, small)
        }
        let resumed = read(store, large, maximumBytes: 100)
        XCTAssertEqual(resumed.readOffset, partial.readOffset + 100)
    }

    func testPartialEOFLinesResumeWithoutInventingAReadingOrLosingContext() throws {
        let file = try write([start("t"), context("t"), usage(10)])
        let store = CodexModelStepReader.Store()
        _ = read(store, file)
        let second = try usage(20, at: 20)
        let split = second.index(second.startIndex, offsetBy: second.count / 2)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second[..<split].utf8))
        try handle.close()
        let partial = read(store, file)
        XCTAssertFalse(partial.finished)
        XCTAssertEqual(partial.turns["t"]?.modelSteps.count, 1)
        let tail = try FileHandle(forWritingTo: file)
        try tail.seekToEnd()
        try tail.write(contentsOf: Data((String(second[split...]) + "\n" + finish("t") + "\n").utf8))
        try tail.close()
        let complete = read(store, file)
        XCTAssertTrue(complete.finished)
        XCTAssertEqual(complete.turns["t"]?.modelSteps.count, 2)
        XCTAssertTrue(complete.turns["t"]?.modelStepsComplete == true)
    }

    func testOversizedRelevantContextCannotMisattributeLaterStepsToThePreviousModel() throws {
        let giantStart = try line("event_msg", ["type": "task_started", "turn_id": "b", "padding": String(repeating: "x", count: 1_024 * 1_024)])
        let file = try write([start("a"), context("a"), usage(10), giantStart, usage(20),
                              context("b", model: "gpt-6.1-sol"), usage(30), finish("b")])
        let result = read(.init(), file)
        XCTAssertEqual(result.turns["a"]?.modelSteps.count, 1)
        XCTAssertEqual(result.turns["b"]?.modelSteps.count, 1)
        XCTAssertEqual(result.turns["b"]?.modelSteps.first?.model, "gpt-6.1-sol")
        XCTAssertFalse(result.turns["a"]?.modelStepsComplete ?? true)
        XCTAssertFalse(result.turns["b"]?.modelStepsComplete ?? true)
        XCTAssertTrue(result.warnings.contains { $0.contains("oversized relevant") })
    }

    func testObservedZeroCounterDecreaseDoesNotCountButLaterAdvancesRemainVisible() throws {
        let compacted = try line("event_msg", ["type": "context_compacted"])
        let file = try write([start("t"), context("t"), usage(10), compacted, usage(0, last: 0), usage(5, last: 5), finish("t")])
        let result = read(.init(), file)
        XCTAssertEqual(result.turns["t"]?.modelSteps.count, 2)
        XCTAssertEqual(ActivityMetrics.knownTotal(result.turns["t"]?.modelSteps.map(\.usage.total) ?? []), 15)
    }

    func testGlobalStepAndTurnBudgetsEvictParsedCachesRatherThanMultiplyingPerPath() throws {
        let store = CodexModelStepReader.Store(maximumSteps: 4, maximumTurns: 2)
        let first = try write([start("a"), context("a"), usage(10), usage(20), usage(30), finish("a")], name: "a.jsonl")
        let second = try write([start("b"), context("b"), usage(10), finish("b"),
                                start("c"), context("c"), usage(20), usage(30), finish("c")], name: "b.jsonl")
        _ = read(store, first)
        let next = read(store, second)
        XCTAssertTrue(next.warnings.contains { $0.contains("evicted") })
        XCTAssertGreaterThan(read(store, first).bytesRead, 0, "the first parsed cache was evicted to respect global limits")
    }

    func testAmbiguousInitialQuotaBaselineIsNotDatedOrCountedAsAModelStep() throws {
        let file = try write([start("t"), context("t"), usage(100, last: 10, at: 1),
                              usage(100, last: 10, at: 2), usage(110, last: 10, at: 3), finish("t")])
        let result = read(.init(), file)
        let turn = try XCTUnwrap(result.turns["t"])
        XCTAssertEqual(turn.modelSteps.count, 1)
        XCTAssertEqual(turn.modelSteps.first?.timestamp, clock.addingTimeInterval(3))
        XCTAssertEqual(turn.modelSteps.first?.usage.total, 10)
        XCTAssertFalse(turn.modelStepsComplete)
        XCTAssertTrue(result.warnings.contains { $0.contains("initial usage baseline") })
    }

    func testCompactionDoesNotResetCountersAndRepeatedQuotaEchoesDoNotCount() throws {
        let markers = [try line("event_msg", ["type": "context_compacted"]), try line("compacted", [:])]
        for (index, compacted) in markers.enumerated() {
            let file = try write([start("t"), context("t"), usage(10), compacted,
                                  usage(10), usage(20), finish("t")], name: "compact-\(index).jsonl")
            let result = read(.init(), file)
            let steps = try XCTUnwrap(result.turns["t"]?.modelSteps)
            XCTAssertEqual(steps.count, 2, "the same-total echo after compaction is not an extra model response")
            XCTAssertEqual(Set(steps.map(\.id)).count, 2)
            XCTAssertEqual(ActivityMetrics.knownTotal(steps.map(\.usage.total)), 20)
            XCTAssertTrue(steps.allSatisfy { $0.id.contains(":t:0:") }, "compaction cannot create a counter segment")
            XCTAssertTrue(result.turns["t"]?.modelStepsComplete == true)
        }
    }

    func testPostCompactionNondecreasingCounterStillRequiresOrdinaryDeltaReconciliation() throws {
        let compacted = try line("event_msg", ["type": "context_compacted"])
        for last in [90, 100] {
            let file = try write([start("t"), context("t"), usage(10), compacted, usage(100, last: last), finish("t")], name: "advance-\(last).jsonl")
            let result = read(.init(), file)
            let turn = try XCTUnwrap(result.turns["t"])
            XCTAssertEqual(turn.modelSteps.count, last == 90 ? 2 : 1)
            XCTAssertEqual(ActivityMetrics.knownTotal(turn.modelSteps.map(\.usage.total)), last == 90 ? 100 : 10)
            XCTAssertEqual(turn.modelStepsComplete, last == 90)
            if last == 100 { XCTAssertTrue(result.warnings.contains { $0.contains("did not reconcile") }) }
        }
    }

    func testCorrectedCacheBreakdownKeepsStepIdentityAcrossFilesAndSameInodeRewrite() throws {
        let original = try write([start("t"), context("t"), usage(10), finish("t")], name: "original.jsonl")
        let correctedLines = try [start("t"), context("t"), usage(10, cached: 5, lastCached: 5), finish("t")]
        let corrected = try write(correctedLines, name: "corrected.jsonl")
        let store = CodexModelStepReader.Store()
        let first = try XCTUnwrap(read(store, original).turns["t"]?.modelSteps)
        let replay = try XCTUnwrap(read(store, corrected).turns["t"]?.modelSteps)
        XCTAssertEqual(first.map(\.id), replay.map(\.id), "a corrected breakdown is not a new response")
        XCTAssertEqual(replay.first?.usage.cachedInput, 5)
        let oldTurn = ActivityTurn(id: "codex:turn:t", modelSteps: first, modelStepsComplete: true)
        let copiedTurn = ActivityTurn(id: "codex:turn:t", modelSteps: replay, modelStepsComplete: true)
        XCTAssertEqual(oldTurn.merging(copiedTurn).modelSteps?.count, 1, "persistent receipt union remains one step")

        try (correctedLines.joined(separator: "\n") + "\n").write(to: original, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: original.path)
        let rewritten = try XCTUnwrap(read(store, original).turns["t"]?.modelSteps)
        XCTAssertEqual(rewritten.map(\.id), first.map(\.id))
        XCTAssertEqual(rewritten.first?.usage.cachedInput, 5)
        XCTAssertEqual(oldTurn.merging(ActivityTurn(id: oldTurn.id, modelSteps: rewritten, modelStepsComplete: true)).modelSteps?.count, 1)
    }

    func testCompletedPriorityGoalRemainsIncrementalAcrossSmallFileChurn() throws {
        let goal = try write([start("goal"), context("goal"), usage(10), finish("goal")], name: "goal.jsonl")
        let store = CodexModelStepReader.Store(maximumPaths: 2)
        let initial = store.read(path: goal.path, deadline: Date().addingTimeInterval(30), priority: true)
        XCTAssertTrue(initial.finished)
        for index in 0..<3 {
            let small = try write([start("small-\(index)"), context("small-\(index)"), usage(10), finish("small-\(index)")], name: "churn-\(index).jsonl")
            _ = read(store, small)
        }
        let lines = try [start("next"), context("next"), usage(20), finish("next")]
        let appendedBytes = (lines.joined(separator: "\n") + "\n").utf8.count
        try append(lines, to: goal)
        let updated = store.read(path: goal.path, deadline: Date().addingTimeInterval(30), priority: true)
        XCTAssertEqual(updated.bytesRead, UInt64(appendedBytes), "the completed priority file must not restart from its head")
        XCTAssertEqual(updated.turns["goal"]?.modelSteps.map(\.id), initial.turns["goal"]?.modelSteps.map(\.id))
        XCTAssertEqual(updated.turns["next"]?.modelSteps.count, 1)
    }

    func testRecentOpenNonGoalTurnIsHotWithoutExplicitCallerPriority() throws {
        let open = try write([start("chat"), context("chat", model: "gpt-6.1-sol"), usage(10)], name: "chat.jsonl")
        let store = CodexModelStepReader.Store(maximumPaths: 2)
        _ = read(store, open)
        for index in 0..<3 {
            let small = try write([start("small-\(index)"), context("small-\(index)"), usage(10), finish("small-\(index)")], name: "cold-\(index).jsonl")
            _ = read(store, small)
        }
        let extra = try usage(20, at: 20)
        try append([extra], to: open)
        let updated = read(store, open)
        XCTAssertEqual(updated.bytesRead, UInt64((extra + "\n").utf8.count))
        XCTAssertEqual(updated.turns["chat"]?.modelSteps.count, 2)
    }

    func testFalseCallerPriorityDemotesAClosedGoalOnItsNextRead() throws {
        let goal = try write([start("done"), context("done"), usage(10), finish("done")], name: "done.jsonl")
        let store = CodexModelStepReader.Store(maximumPaths: 2)
        _ = store.read(path: goal.path, deadline: Date().addingTimeInterval(30), priority: true)
        XCTAssertEqual(read(store, goal).bytesRead, 0, "demotion is a metadata-only cache touch")
        for index in 0..<2 {
            let file = try write([start("cold-\(index)"), context("cold-\(index)"), usage(10), finish("cold-\(index)")], name: "demote-\(index).jsonl")
            _ = read(store, file)
        }
        XCTAssertGreaterThan(read(store, goal).bytesRead, 0, "a closed, no-longer-priority goal can be evicted")
    }
}
