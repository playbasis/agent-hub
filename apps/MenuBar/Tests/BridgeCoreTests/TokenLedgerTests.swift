@testable import BridgeCore
import Foundation
import XCTest

final class TokenLedgerTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-ledger-\(UUID().uuidString)")
        claudeRoot = root.appendingPathComponent("claude/projects")
        codexRoot = root.appendingPathComponent("codex/sessions")
        for url in [claudeRoot!, codexRoot!] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func scanner() -> TokenLedgerScanner {
        TokenLedgerScanner(claudeRoot: claudeRoot, codexRoot: codexRoot)
    }

    private func claudeLine(
        requestID: String,
        timestamp: String,
        input: Int = 10,
        cacheRead: Int = 900,
        cacheWrite: Int = 80,
        output: Int = 5
    ) -> String {
        """
        {"type":"assistant","requestId":"\(requestID)","timestamp":"\(timestamp)",\
        "message":{"model":"claude-opus-5","usage":{"input_tokens":\(input),\
        "cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite),\
        "output_tokens":\(output)}}}
        """
    }

    private func codexLine(
        timestamp: String,
        input: Int,
        cached: Int,
        output: Int,
        total: Int,
        cumulativeInput: Int? = nil,
        cumulativeCached: Int? = nil,
        cumulativeOutput: Int? = nil,
        cumulativeTotal: Int? = nil
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":\(cumulativeInput ?? input),\
        "cached_input_tokens":\(cumulativeCached ?? cached),\
        "output_tokens":\(cumulativeOutput ?? output),"total_tokens":\(cumulativeTotal ?? total)},\
        "last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output),"total_tokens":\(total)}}}}
        """
    }

    private func codexMetadata(id: String, sessionID: String? = nil) -> String {
        """
        {"type":"session_meta","payload":{"id":"\(id)","session_id":"\(sessionID ?? id)"}}
        """
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func components(
        in cache: TokenLedgerCache,
        agent: String
    ) -> TokenComponents? {
        cache.buckets
            .filter { TokenBucketKey.split($0.key)?.agent == agent }
            .values
            .reduce(nil) { partial, next in (partial ?? TokenComponents()) + next }
    }

    private func now() -> Date { Date() }

    private func stamp(_ offsetSeconds: TimeInterval) -> String {
        ISO8601.withFractional.string(from: now().addingTimeInterval(offsetSeconds))
    }

    func testClaudeAndCodexSamplesAreParsedWithProviderSpecificCacheSemantics() throws {
        try write(
            [claudeLine(requestID: "req_1", timestamp: stamp(-60))],
            to: claudeRoot.appendingPathComponent("a.jsonl")
        )
        // Codex folds cached tokens into input_tokens; fresh input must net them out.
        try write(
            [codexLine(timestamp: stamp(-60), input: 500, cached: 400, output: 20, total: 520)],
            to: codexRoot.appendingPathComponent("b.jsonl")
        )

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(cache.buckets.count, 2)

        let claude = try XCTUnwrap(components(in: cache, agent: "claude"))
        XCTAssertEqual(claude.freshInput, 10)
        XCTAssertEqual(claude.cacheRead, 900)
        XCTAssertEqual(claude.cacheWrite, 80)
        XCTAssertEqual(claude.output, 5)

        let codex = try XCTUnwrap(components(in: cache, agent: "codex"))
        XCTAssertEqual(codex.freshInput, 100)
        XCTAssertEqual(codex.cacheRead, 400)
        XCTAssertEqual(codex.output, 20)
    }

    func testReplayedTranscriptsDoNotDoubleCount() throws {
        let line = claudeLine(requestID: "req_dup", timestamp: stamp(-120))
        try write([line], to: claudeRoot.appendingPathComponent("original.jsonl"))
        // A resumed session rewrites earlier turns into a brand-new file.
        try write([line], to: claudeRoot.appendingPathComponent("resumed.jsonl"))

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        let claude = try XCTUnwrap(components(in: cache, agent: "claude"))
        XCTAssertEqual(claude.output, 5, "a replayed turn must be counted once")
        XCTAssertEqual(cache.seenKeys.count, 1)
    }

    func testCurrentClaudeUsageDeduplicatesRepeatedSnapshotsByRequestID() throws {
        let usage = """
        {"type":"assistant","requestId":"req_fable_1","timestamp":"\(stamp(-60))",\
        "message":{"id":"msg_fable_1","role":"assistant","model":"claude-fable-5-1",\
        "usage":{"input_tokens":56,"cache_read_input_tokens":761223,\
        "cache_creation_input_tokens":858,"output_tokens":2296,\
        "output_tokens_details":{"thinking_tokens":1527}}}}
        """
        // Claude Code journals display/tool snapshots of a completed request.
        // They have distinct local UUIDs but one provider request ID and must
        // remain one measured provider turn.
        let replay = usage.replacingOccurrences(of: "msg_fable_1", with: "msg_fable_1_copy")
        try write([usage, replay], to: claudeRoot.appendingPathComponent("fable.jsonl"))

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        let claude = try XCTUnwrap(components(in: cache, agent: "claude"))
        XCTAssertEqual(claude.freshInput, 56)
        XCTAssertEqual(claude.cacheRead, 761_223)
        XCTAssertEqual(claude.cacheWrite, 858)
        XCTAssertEqual(claude.output, 2_296)
        XCTAssertEqual(cache.seenKeys.count, 1)
    }

    func testClaudeUsageSupportsWrappedEnvelopeAndTTLCacheFallback() throws {
        let line = """
        {"type":"assistant","created_at":"\(stamp(-60))",\
        "message":{"id":"msg_wrapped","role":"assistant","model":"claude-fable-5-1"},\
        "usage":{"input_tokens":"9","cache_read_input_tokens":11,\
        "cache_creation":{"ephemeral_1h_input_tokens":13,"ephemeral_5m_input_tokens":17},\
        "output_tokens":19}}
        """
        try write([line], to: claudeRoot.appendingPathComponent("wrapped.jsonl"))

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        let claude = try XCTUnwrap(components(in: cache, agent: "claude"))
        XCTAssertEqual(claude, TokenComponents(
            freshInput: 9,
            cacheRead: 11,
            cacheWrite: 30,
            output: 19
        ))
        XCTAssertNotNil(cache.seenKeys["claude:msg_wrapped"])
    }

    func testClaudeSyntheticZeroUsageDoesNotCreateAChartTurn() throws {
        let line = """
        {"type":"assistant","uuid":"synthetic","timestamp":"\(stamp(-60))",\
        "message":{"id":"synthetic-message","role":"assistant","model":"<synthetic>",\
        "usage":{"input_tokens":0,"cache_read_input_tokens":0,\
        "cache_creation_input_tokens":0,"output_tokens":0}}}
        """
        try write([line], to: claudeRoot.appendingPathComponent("synthetic.jsonl"))

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        XCTAssertTrue(cache.buckets.isEmpty)
        XCTAssertTrue(cache.seenKeys.isEmpty)
    }

    /// Resuming a Codex session writes a NEW rollout that replays the whole
    /// conversation — and re-stamps every replayed reading with the resume
    /// time, so the readings are not recognisable by timestamp. Because the
    /// resume is a new path it starts at cursor 0 and is read in full, and
    /// because it arrives in a LATER pass the in-memory per-pass guard is
    /// already empty. Measured on real transcripts this counted a 5.4B-token
    /// fortnight as 235B — a 43.6x overstatement across 53 replays of one
    /// session. The identity has to be (conversation, position), never the clock.
    func testResumedCodexRolloutIsNotRecountedInALaterPass() throws {
        let replayed = [
            codexLine(timestamp: stamp(-600), input: 500, cached: 400, output: 20, total: 520),
            codexLine(timestamp: stamp(-590), input: 700, cached: 600, output: 30, total: 730),
            codexLine(timestamp: stamp(-580), input: 900, cached: 800, output: 40, total: 940),
        ]
        let original = codexRoot.appendingPathComponent("rollout-original.jsonl")
        try write(replayed, to: original)

        let scanner = scanner()
        var cache = scanner.scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.output, 90)

        // The resume: identical readings, fresh timestamps, plus one new turn.
        let resumedLines = [
            codexLine(timestamp: stamp(-120), input: 500, cached: 400, output: 20, total: 520),
            codexLine(timestamp: stamp(-120), input: 700, cached: 600, output: 30, total: 730),
            codexLine(timestamp: stamp(-120), input: 900, cached: 800, output: 40, total: 940),
            codexLine(timestamp: stamp(-110), input: 1_100, cached: 1_000, output: 50, total: 1_150),
        ]
        try write(resumedLines, to: codexRoot.appendingPathComponent("rollout-resumed.jsonl"))

        cache = scanner.scan(cache: cache, now: now())
        let codex = try XCTUnwrap(components(in: cache, agent: "codex"))
        XCTAssertEqual(
            codex.output, 140,
            "replayed readings must be counted once; only the new turn adds 50"
        )
        XCTAssertEqual(codex.cacheRead, 400 + 600 + 800 + 1_000)
    }

    func testDistinctCodexConversationsAreNotMergedByOrdinal() throws {
        // Two unrelated conversations both have a turn at ordinal 0. They must
        // not collapse into one — over-deduplication is as wrong as none.
        try write(
            [codexLine(timestamp: stamp(-300), input: 500, cached: 400, output: 20, total: 520)],
            to: codexRoot.appendingPathComponent("rollout-a.jsonl")
        )
        try write(
            [codexLine(timestamp: stamp(-300), input: 800, cached: 700, output: 35, total: 835)],
            to: codexRoot.appendingPathComponent("rollout-b.jsonl")
        )

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.output, 55)
    }

    func testCodexIdleScansPreserveIdentityAndCumulativeUsage() throws {
        let file = codexRoot.appendingPathComponent("idle.jsonl")
        let reading = codexLine(timestamp: stamp(-300), input: 500, cached: 400,
                                output: 20, total: 520)
        try write([codexMetadata(id: "rollout-original", sessionID: "conversation"), reading], to: file)

        let scanner = scanner()
        var cache = scanner.scan(cache: TokenLedgerCache(), now: now())
        let path = file.resolvingSymlinksInPath().path
        let originalCursor = try XCTUnwrap(cache.cursors[path])
        cache = scanner.scan(cache: cache, now: now())
        XCTAssertEqual(cache.cursors[path], originalCursor, "an idle poll must retain Codex parser state")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // The last request can have identical components to its predecessor;
        // its changing cumulative counter still marks it as new usage.
        let next = codexLine(timestamp: stamp(-60), input: 500, cached: 400,
                             output: 20, total: 520, cumulativeInput: 1_000,
                             cumulativeCached: 800, cumulativeOutput: 40, cumulativeTotal: 1_040)
        handle.write(Data((next + "\n").utf8))
        try handle.close()
        cache = scanner.scan(cache: cache, now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.output, 40)
        XCTAssertEqual(cache.cursors[path]?.ordinal, 2)
    }

    func testCodexUnchangedCumulativeSnapshotsAreNotAdditionalRequests() throws {
        let file = codexRoot.appendingPathComponent("snapshots.jsonl")
        let reading = codexLine(timestamp: stamp(-300), input: 500, cached: 400,
                                output: 20, total: 520)
        let snapshot = codexLine(timestamp: stamp(-200), input: 500, cached: 400,
                                 output: 20, total: 520)
        try write([codexMetadata(id: "conversation"), reading, snapshot], to: file)
        let scanner = scanner()
        var cache = scanner.scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.total, 520)
        XCTAssertEqual(cache.cursors[file.resolvingSymlinksInPath().path]?.ordinal, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data((snapshot + "\n").utf8))
        try handle.close()
        cache = scanner.scan(cache: cache, now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.total, 520,
                       "snapshots appended in a later pass must also be ignored")
        XCTAssertEqual(cache.seenKeys.count, 1)
    }

    func testCodexCumulativeResetStillCountsTheNewLastRequest() throws {
        try write([
            codexMetadata(id: "conversation"),
            codexLine(timestamp: stamp(-300), input: 500, cached: 400, output: 20,
                      total: 520, cumulativeInput: 10_000, cumulativeCached: 8_000,
                      cumulativeOutput: 400, cumulativeTotal: 10_400),
            codexLine(timestamp: stamp(-60), input: 500, cached: 400, output: 20, total: 520),
        ], to: codexRoot.appendingPathComponent("reset.jsonl"))

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.total, 1_040,
                       "a reset must not produce a negative delta or hide a real request")
    }

    func testCodexSessionUUIDDeduplicatesDifferentRolloutIDs() throws {
        let first = codexLine(timestamp: stamp(-300), input: 500, cached: 400,
                              output: 20, total: 520)
        try write([codexMetadata(id: "original", sessionID: "stable-session"), first],
                  to: codexRoot.appendingPathComponent("original.jsonl"))
        let scanner = scanner()
        var cache = scanner.scan(cache: TokenLedgerCache(), now: now())

        let replay = codexLine(timestamp: stamp(-120), input: 500, cached: 400,
                               output: 20, total: 520)
        let next = codexLine(timestamp: stamp(-60), input: 700, cached: 600,
                             output: 30, total: 730, cumulativeInput: 1_200,
                             cumulativeCached: 1_000, cumulativeOutput: 50, cumulativeTotal: 1_250)
        try write([codexMetadata(id: "resumed", sessionID: "stable-session"), replay, replay, next],
                  to: codexRoot.appendingPathComponent("resumed.jsonl"))
        cache = scanner.scan(cache: cache, now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.output, 50)
        XCTAssertEqual(cache.seenKeys.count, 2)
    }

    func testCodexDistinctSessionUUIDsCanHaveIdenticalFirstReadings() throws {
        let reading = codexLine(timestamp: stamp(-60), input: 500, cached: 400,
                                output: 20, total: 520)
        try write([codexMetadata(id: "session-a"), reading],
                  to: codexRoot.appendingPathComponent("a.jsonl"))
        try write([codexMetadata(id: "session-b"), reading],
                  to: codexRoot.appendingPathComponent("b.jsonl"))

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.total, 1_040)
    }

    func testCodexMetadataFallbackUsesIDWhenSessionIDIsMissing() throws {
        let metadata = #"{"type":"session_meta","payload":{"id":"stable-id"}}"#
        let reading = codexLine(timestamp: stamp(-60), input: 500, cached: 400,
                                output: 20, total: 520)
        try write([metadata, reading], to: codexRoot.appendingPathComponent("id.jsonl"))

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(cache.cursors.values.first?.lineage, "session:stable-id")
    }

    func testCodexWithoutMetadataUsesFullComponentsRatherThanAnEqualTotal() throws {
        try write([codexLine(timestamp: stamp(-60), input: 500, cached: 400,
                             output: 20, total: 520)],
                  to: codexRoot.appendingPathComponent("a.jsonl"))
        try write([codexLine(timestamp: stamp(-60), input: 501, cached: 399,
                             output: 19, total: 520)],
                  to: codexRoot.appendingPathComponent("b.jsonl"))

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.total, 1_040)
        XCTAssertEqual(components(in: cache, agent: "codex")?.output, 39)
    }

    func testCacheFromAnOlderDedupSchemeIsDiscardedNotMigrated() throws {
        var stale = TokenLedgerCache()
        stale.version = 1
        stale.buckets["\(TokenBucketKey.epochHour(now()))|codex"] =
            TokenComponents(freshInput: 999_999, cacheRead: 0, cacheWrite: 0, output: 999_999)

        let url = root.appendingPathComponent("ledger-cache.json")
        try BridgeJSON.compactEncoder.encode(stale).write(to: url)

        let decoded = try BridgeJSON.decoder.decode(
            TokenLedgerCache.self, from: Data(contentsOf: url)
        )
        XCTAssertEqual(decoded.version, 1, "a v1 cache still decodes")
        XCTAssertNotEqual(
            decoded.version, TokenLedgerCache.currentVersion,
            "so the store can recognise it as poisoned and drop it"
        )
    }

    func testIncrementalPassReadsOnlyAppendedBytes() throws {
        let file = claudeRoot.appendingPathComponent("a.jsonl")
        try write([claudeLine(requestID: "req_1", timestamp: stamp(-300))], to: file)

        let scanner = scanner()
        var cache = scanner.scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "claude")?.output, 5)
        let firstOffset = try XCTUnwrap(cache.cursors[file.resolvingSymlinksInPath().path]?.offset)
        XCTAssertGreaterThan(firstOffset, 0)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data((claudeLine(requestID: "req_2", timestamp: stamp(-60)) + "\n").utf8))
        try handle.close()

        cache = scanner.scan(cache: cache, now: now())
        XCTAssertEqual(components(in: cache, agent: "claude")?.output, 10)
        XCTAssertGreaterThan(try XCTUnwrap(cache.cursors[file.resolvingSymlinksInPath().path]?.offset), firstOffset)
    }

    func testPartialTrailingLineIsDeferredUntilComplete() throws {
        let file = claudeRoot.appendingPathComponent("a.jsonl")
        let complete = claudeLine(requestID: "req_1", timestamp: stamp(-300))
        let partial = String(claudeLine(requestID: "req_2", timestamp: stamp(-60)).dropLast(40))
        try (complete + "\n" + partial).write(to: file, atomically: true, encoding: .utf8)

        let scanner = scanner()
        var cache = scanner.scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(
            components(in: cache, agent: "claude")?.output, 5,
            "half-written line must not be parsed"
        )

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let remainder = claudeLine(requestID: "req_2", timestamp: stamp(-60)).suffix(40)
        handle.write(Data((remainder + "\n").utf8))
        try handle.close()

        cache = scanner.scan(cache: cache, now: now())
        XCTAssertEqual(
            components(in: cache, agent: "claude")?.output, 10,
            "line must be picked up once complete"
        )
    }

    func testOversizedCompleteRecordIsSkippedAndFollowingMeasurementsRemainExact() throws {
        let file = claudeRoot.appendingPathComponent("oversized.jsonl")
        let large = String(claudeLine(requestID: "too-large", timestamp: stamp(-120)).dropLast())
            + ",\"padding\":\"" + String(repeating: "x", count: 2_048) + "\"}"
        try write([large, claudeLine(requestID: "normal", timestamp: stamp(-60))], to: file)
        let bounded = TokenLedgerScanner(claudeRoot: claudeRoot, codexRoot: codexRoot, maximumLineBytes: 1_024)
        let cache = bounded.scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "claude")?.output, 5)
        let cursor = try XCTUnwrap(cache.cursors[file.resolvingSymlinksInPath().path])
        XCTAssertEqual(cursor.offset, cursor.size)
        XCTAssertFalse(cursor.discardingOversizedLine)
        XCTAssertEqual(cursor.skippedOversizedRecords, 1)
        XCTAssertTrue(cache.partialStatusMessage?.contains("missing usage is not zero") == true)
    }

    func testOversizedUnterminatedLineAdvancesAndPersistsDiscardStateAcrossPolls() throws {
        let file = claudeRoot.appendingPathComponent("unterminated.jsonl")
        try String(repeating: "x", count: 200_000).write(to: file, atomically: true, encoding: .utf8)
        let bounded = TokenLedgerScanner(claudeRoot: claudeRoot, codexRoot: codexRoot, maximumLineBytes: 1_024)
        let path = file.resolvingSymlinksInPath().path
        var cache = bounded.scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(cache.cursors[path]?.offset, 200_000)
        XCTAssertEqual(cache.cursors[path]?.skippedOversizedRecords, 1)
        XCTAssertTrue(cache.cursors[path]?.discardingOversizedLine == true)
        XCTAssertTrue(cache.buckets.isEmpty)
        let persisted = try BridgeJSON.compactEncoder.encode(cache)
        cache = try BridgeJSON.decoder.decode(TokenLedgerCache.self, from: persisted)
        cache = bounded.scan(cache: cache, now: now())
        XCTAssertEqual(cache.cursors[path]?.offset, 200_000, "idle polls do not re-read the giant prefix")
        XCTAssertEqual(cache.cursors[path]?.skippedOversizedRecords, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // This superficially valid record is still part of the discarded line.
        let appended = claudeLine(requestID: "fragment", timestamp: stamp(-60)) + "\n"
            + claudeLine(requestID: "following", timestamp: stamp(-30)) + "\n"
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        cache = bounded.scan(cache: cache, now: now())
        XCTAssertEqual(components(in: cache, agent: "claude")?.output, 5)
        XCTAssertEqual(Set(cache.seenKeys.keys), ["claude:following"])
        XCTAssertFalse(cache.cursors[path]?.discardingOversizedLine ?? true)
        XCTAssertEqual(cache.cursors[path]?.offset, 200_000 + UInt64(appended.utf8.count))
    }

    func testExactlyBoundedLineIsStillMeasured() throws {
        let prefix = String(claudeLine(requestID: "exact", timestamp: stamp(-60)).dropLast()) + ",\"padding\":\""
        let line = prefix + String(repeating: "x", count: 1_024 - prefix.utf8.count - 2) + "\"}"
        XCTAssertEqual(line.utf8.count, 1_024)
        try write([line], to: claudeRoot.appendingPathComponent("exact.jsonl"))
        let bounded = TokenLedgerScanner(claudeRoot: claudeRoot, codexRoot: codexRoot, maximumLineBytes: 1_024)
        let cache = bounded.scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "claude")?.output, 5)
        XCTAssertNil(cache.partialStatusMessage)
    }

    func testBoundedCodexLineagePreservesReplayDedupAfterAnOversizedUnrelatedRecord() throws {
        let lines = [String(repeating: "x", count: 2_048), codexMetadata(id: "native", sessionID: "stable"),
                     codexLine(timestamp: stamp(-60), input: 500, cached: 400, output: 20, total: 520)]
        try write(lines, to: codexRoot.appendingPathComponent("original.jsonl"))
        try write(lines, to: codexRoot.appendingPathComponent("resume.jsonl"))
        let bounded = TokenLedgerScanner(claudeRoot: claudeRoot, codexRoot: codexRoot, maximumLineBytes: 1_024)
        let cache = bounded.scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(components(in: cache, agent: "codex")?.output, 20, "the copied usage is counted once")
        XCTAssertEqual(cache.seenKeys.count, 1)
        XCTAssertTrue(cache.cursors.values.allSatisfy { $0.lineage == "session:stable" && $0.ordinal == 1 && $0.skippedOversizedRecords == 1 })
    }

    func testOldExistingFilesNoLongerKeepCursorsAliveForever() throws {
        let file = claudeRoot.appendingPathComponent("old.jsonl")
        try write(["{}"], to: file)
        let reference = now()
        try FileManager.default.setAttributes([.modificationDate: reference.addingTimeInterval(-Double(TokenLedgerScanner.retentionDays + 1) * 86_400)], ofItemAtPath: file.path)
        var cache = TokenLedgerCache()
        let path = file.resolvingSymlinksInPath().path
        cache.cursors[path] = TokenLedgerCursor(offset: 3, size: 3)
        let scanned = scanner().scan(cache: cache, now: reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(scanned.cursors[path], "retention is based on age, not whether native logs were deleted")
    }

    func testLegacyCursorDecodesNewDiscardStateSafely() throws {
        let data = Data(#"{"offset":7,"size":7,"ordinal":1}"#.utf8)
        let cursor = try BridgeJSON.decoder.decode(TokenLedgerCursor.self, from: data)
        XCTAssertFalse(cursor.discardingOversizedLine)
        XCTAssertEqual(cursor.skippedOversizedRecords, 0)
    }

    func testPartialStoreDoesNotPublishMeasuredZeroOrBypassItsRefreshInterval() async throws {
        let file = claudeRoot.appendingPathComponent("partial.jsonl")
        try String(repeating: "x", count: 2_048).write(to: file, atomically: true, encoding: .utf8)
        let bounded = TokenLedgerScanner(claudeRoot: claudeRoot, codexRoot: codexRoot, maximumLineBytes: 1_024)
        let store = TokenLedgerStore(scanner: bounded, cacheURL: root.appendingPathComponent("bounded-cache.json"), minimumInterval: 60)
        let reference = now()
        let partial = await store.series(now: reference)
        XCTAssertTrue(partial.hourly.points.isEmpty)
        XCTAssertTrue(partial.daily.points.isEmpty)
        XCTAssertTrue(partial.statusMessage?.contains("history is partial") == true)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + claudeLine(requestID: "new", timestamp: stamp(-10)) + "\n").utf8))
        try handle.close()
        let idle = await store.series(now: reference.addingTimeInterval(1))
        XCTAssertEqual(idle, partial, "a warning must not trigger a heavy rescan on every UI poll")
        let measured = await store.series(now: reference.addingTimeInterval(2), force: true)
        XCTAssertEqual(measured.hourly.points.reduce(0) { $0 + $1.combined.output }, 5)
        XCTAssertTrue(measured.statusMessage?.contains("history is partial") == true)
    }

    func testSamplesOutsideRetentionWindowAreDropped() throws {
        let stale = ISO8601.withFractional.string(
            from: now().addingTimeInterval(-Double(TokenLedgerScanner.retentionDays + 2) * 86_400)
        )
        try write(
            [
                claudeLine(requestID: "req_old", timestamp: stale),
                claudeLine(requestID: "req_new", timestamp: stamp(-60)),
            ],
            to: claudeRoot.appendingPathComponent("a.jsonl")
        )

        let cache = scanner().scan(cache: TokenLedgerCache(), now: now())
        XCTAssertEqual(Array(cache.seenKeys.keys), ["claude:req_new"])
        XCTAssertEqual(components(in: cache, agent: "claude")?.output, 5)
    }

    func testBuilderEmitsContiguousBucketsIncludingEmptyOnes() {
        let reference = Date()
        let buckets = [
            TokenBucketKey.make(
                hour: TokenBucketKey.epochHour(reference),
                agent: .claude
            ): TokenComponents(freshInput: 1, cacheRead: 2, cacheWrite: 3, output: 4),
        ]
        let series = TokenSeriesBuilder.build(
            buckets: buckets,
            bucket: .hour,
            span: 6,
            now: reference
        )
        XCTAssertEqual(series.points.count, 6)
        XCTAssertEqual(series.points.last?.combined.total, 10)
        XCTAssertTrue(series.points.dropLast().allSatisfy { $0.byAgent.isEmpty })
        XCTAssertEqual(
            series.points.map(\.start),
            series.points.map(\.start).sorted(),
            "points must run oldest to newest for charting"
        )
    }

    func testBillableEquivalentDiscountsCacheReadsAndWeightsOutput() {
        let components = TokenComponents(
            freshInput: 100,
            cacheRead: 1_000,
            cacheWrite: 100,
            output: 100
        )
        XCTAssertEqual(components.total, 1_300)
        // 100 + 100 + 125 + 500 — a raw total would be dominated by cache reads.
        XCTAssertEqual(components.billableEquivalent, 825)
    }
}
