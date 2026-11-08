import XCTest
import Darwin
@testable import BridgeCore

final class CreditHistoryStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("credit-history-test-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("credits.jsonl")
    }
    private func estimate(_ balance: String? = "100.0000", at: Date? = nil, account: String? = "private-account-hash") -> QuotaEstimate {
        .init(agent: .codex, source: .live, fetchedAt: at ?? now,
            statusMessage: "NEVER-EXPORT-SECRET", credits: .init(balance: balance, hasCredits: true, unlimited: false),
            limitID: "codex", accountIdentityHash: account)
    }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func testAppendHashChainExactTextAndPrivatePermissions() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        let first = try await store.record(estimate(), anonymousEpochID: "epoch")
        let second = try await store.record(estimate("99.9999", at: now.addingTimeInterval(120)), anonymousEpochID: "epoch")
        XCTAssertEqual(first.disposition, .appended); XCTAssertEqual(second.disposition, .appended)
        let rows = try Data(contentsOf: url).split(separator: 0x0a).map { try BridgeJSON.decoder.decode(CreditHistoryRecord.self, from: Data($0)) }
        XCTAssertEqual(rows.map(\.reportedBalance), ["100.0000", "99.9999"])
        XCTAssertEqual(rows.map(\.sequence), [1, 2])
        XCTAssertNil(rows.first?.previousHash)
        XCTAssertEqual(rows.last?.previousHash, rows.first?.recordHash)
        for row in rows {
            var unsigned = row; unsigned.recordHash = ""
            XCTAssertEqual(row.recordHash, TraceCrypto.digest(Data((row.previousHash ?? "").utf8) + (try BridgeJSON.compactEncoder.encode(unsigned))))
        }
        let filePermissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
    }

    func testDuplicateTimestampPayloadIsIdempotentAndConflictIsSurfaced() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        _ = try await store.record(estimate(), anonymousEpochID: "epoch")
        let before = try Data(contentsOf: url)
        let duplicate = try await store.record(estimate(), anonymousEpochID: "epoch")
        let conflict = try await store.record(estimate("99"), anonymousEpochID: "epoch")
        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertEqual(conflict.disposition, .rejected)
        XCTAssertEqual(conflict.reason, "same_timestamp_conflicting_payload")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testFailedCachedObservedAndWrongBucketReadingsAreNotNewFacts() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        var bad = estimate(); bad.refreshFailedAt = now
        var observed = estimate(); observed.source = .observed
        var wrongBucket = estimate(); wrongBucket.limitID = "secondary"
        var missingTime = estimate(); missingTime.fetchedAt = nil
        for value in [bad, observed, wrongBucket, missingTime] {
            let result = try await store.record(value, anonymousEpochID: "epoch")
            XCTAssertEqual(result.disposition, .rejected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBackwardsTimestampIsRejectedWithoutRewriting() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        _ = try await store.record(estimate(), anonymousEpochID: "epoch")
        let before = try Data(contentsOf: url)
        let result = try await store.record(estimate("98", at: now.addingTimeInterval(-60)), anonymousEpochID: "epoch")
        XCTAssertEqual(result.reason, "backwards_provider_clock_or_out_of_order_reading")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAnonymousEpochAndAccountAndExplicitImportPartitions() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        _ = try await store.record(estimate(account: nil), anonymousEpochID: "first")
        _ = try await store.record(estimate("90", account: nil), anonymousEpochID: "second")
        _ = try await store.record(estimate("80"), anonymousEpochID: "second")
        _ = try await store.record(estimate("70"), anonymousEpochID: "second", importScope: "explicit-qa-fixture")
        let report = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now)
        XCTAssertEqual(report.scopes.count, 4)
        XCTAssertEqual(report.selectedScope, .imported("explicit-qa-fixture"))
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.forecast.state, .unavailable)
        let known = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now, scope: .account("private-account-hash"))
        XCTAssertEqual(known.records.last?.reportedBalance, "80")
        XCTAssertTrue(known.intervals.isEmpty)
    }

    func testInvalidOrAbsentBalanceRetainsUnknownRatherThanZero() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        let result = try await store.record(estimate("1e9"), anonymousEpochID: "epoch")
        XCTAssertEqual(result.disposition, .appended)
        XCTAssertTrue(result.warnings.contains("invalid_provider_balance_omitted"))
        let report = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now)
        XCTAssertNil(report.records.first?.reportedBalance)
        XCTAssertNil(report.balancePoints.first?.reportedBalance)
        XCTAssertNil(report.forecast.estimatedSecondsRemaining)
    }

    func testTornFinalLineIsVisibleAndBlocksFurtherAppendsWithoutRepair() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        _ = try await store.record(estimate(), anonymousEpochID: "epoch")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"partial\":".utf8)); try handle.close()
        let before = try Data(contentsOf: url)
        let report = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now)
        XCTAssertTrue(report.completeness.tornFinalLine)
        XCTAssertFalse(report.completeness.integrityVerified)
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.forecast.state, .unavailable)
        do {
            _ = try await store.record(estimate("90", at: now.addingTimeInterval(60)), anonymousEpochID: "epoch")
            XCTFail("Must not append after a torn final line")
        } catch CreditHistoryError.corruptHistory {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testHashTamperingIsVisibleAndNoUnverifiedSuffixIsReturned() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        _ = try await store.record(estimate(), anonymousEpochID: "epoch")
        _ = try await store.record(estimate("99", at: now.addingTimeInterval(60)), anonymousEpochID: "epoch")
        let original = try String(contentsOf: url, encoding: .utf8)
        try Data(original.replacingOccurrences(of: "100.0000", with: "999.0000").utf8).write(to: url)
        let report = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now)
        XCTAssertFalse(report.completeness.integrityVerified)
        XCTAssertEqual(report.completeness.invalidLineCount, 2)
        XCTAssertTrue(report.records.isEmpty)
    }

    func testConcurrentStoreInstancesDeduplicateUnderFileLock() async throws {
        let value = estimate()
        for round in 0..<20 {
            let url = location(); defer { cleanup(url) }
            let barrier = CreditHistoryWriterBarrier(participants: 10)
            let results = try await withThrowingTaskGroup(of: CreditHistoryRecordResult.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        await barrier.arrive()
                        return try await CreditHistoryStore(fileURL: url).record(value, anonymousEpochID: "epoch")
                    }
                }
                var results: [CreditHistoryRecordResult] = []
                for try await result in group { results.append(result) }
                return results
            }
            XCTAssertEqual(results.filter { $0.disposition == .appended }.count, 1, "Round \(round)")
            XCTAssertEqual(results.filter { $0.disposition == .duplicate }.count, 9, "Round \(round)")
            XCTAssertEqual(try Data(contentsOf: url).split(separator: 0x0a).count, 1, "Round \(round)")
            let report = try await CreditHistoryStore(fileURL: url).report(now: now, from: now.addingTimeInterval(-86400), to: now)
            XCTAssertTrue(report.completeness.integrityVerified, "Round \(round)")
        }
    }

    func testSanitizedExportDoesNotExposeOriginalScopeOrStatusProse() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        _ = try await store.record(estimate(), anonymousEpochID: "private-process-id")
        let data = try await store.sanitizedExport(now: now, from: now.addingTimeInterval(-86400), to: now)
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(output.contains("private-account-hash"))
        XCTAssertFalse(output.contains("private-process-id"))
        XCTAssertFalse(output.contains("NEVER-EXPORT-SECRET"))
        XCTAssertTrue(output.contains("100.0000"))
        let decoded = try BridgeJSON.decoder.decode(CreditHistoryReport.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, "credit-history/1")
    }

    func testSymlinkFileIsRejectedAndTargetIsUntouched() async throws {
        let url = location(); defer { cleanup(url) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent("target.txt")
        let original = Data("keep-me".utf8); try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        do {
            _ = try await CreditHistoryStore(fileURL: url).record(estimate(), anonymousEpochID: "epoch")
            XCTFail("Must not follow a symlink")
        } catch CreditHistoryError.unsafeFile {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testOversizedFileIsBoundedAndNeverTruncated() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        _ = try await store.record(estimate(), anonymousEpochID: "epoch")
        let fd = Darwin.open(url.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(CreditHistoryStore.maximumFileBytes + 1)), 0)
        Darwin.close(fd)
        do {
            _ = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now)
            XCTFail("Must bound file reads")
        } catch CreditHistoryError.limitExceeded {} catch { XCTFail("Unexpected error: \(error)") }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, CreditHistoryStore.maximumFileBytes + 1)
    }

    func testOversizedLineAndTooManyLinesAreBoundedWithoutRepair() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        _ = try await store.record(estimate(), anonymousEpochID: "epoch")
        let tooLong = Data((String(repeating: "x", count: CreditHistoryStore.maximumLineBytes + 1) + "\n").utf8)
        try tooLong.write(to: url)
        let invalid = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now)
        XCTAssertFalse(invalid.completeness.integrityVerified)
        XCTAssertEqual(invalid.completeness.invalidLineCount, 1)
        XCTAssertEqual(try Data(contentsOf: url), tooLong)
        let tooMany = Data(repeating: 0x0a, count: CreditHistoryStore.maximumRecords + 1)
        try tooMany.write(to: url)
        do {
            _ = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now)
            XCTFail("Must bound line count without materializing all slices")
        } catch CreditHistoryError.limitExceeded {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: url), tooMany)
    }
}

private actor CreditHistoryWriterBarrier {
    private let participants: Int
    private var arrivals = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(participants: Int) { self.participants = participants }
    func arrive() async {
        arrivals += 1
        if arrivals == participants {
            waiting.forEach { $0.resume() }
            waiting.removeAll()
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }
}
