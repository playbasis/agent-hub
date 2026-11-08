import Foundation
import XCTest
@testable import BridgeCore

/// Provider behavior is injected; every history/export path is a unique private
/// test directory. No native CLI, credentials, network, or production history.
final class CreditHistoryIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let accountA = "integration-private-account-a"
    private let accountB = "integration-private-account-b"

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("credit-integration-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("credits.jsonl")
    }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    private func reading(_ balance: String?, account: String?, offset: TimeInterval = 0) -> QuotaEstimate {
        .init(agent: .codex, source: .live, fetchedAt: now.addingTimeInterval(offset),
            credits: balance.map { .init(balance: $0, hasCredits: true, unlimited: false) },
            limitID: "codex", accountIdentityHash: account)
    }
    private func healthy(account: String?) -> [QuotaEstimate] {
        (0..<6).map { reading(String(100 - $0), account: account, offset: Double($0 - 5) * 240) }
    }
    private func service(_ values: [QuotaEstimate], store: CreditHistoryStore) throws -> Orchestrator {
        let reader = CreditHistoryIntegrationReader(values)
        return Orchestrator(configuration: try BridgeConfiguration.makeDefault(),
            configurationSaver: { _ in }, recoveryLoader: { nil }, recoverySaver: { _ in },
            nonCodexUsageReader: { [] }, codexUsageReader: { await reader.read() }, creditHistoryStore: store,
            planUsageLoader: { [:] }, planUsageSaver: { _ in })
    }
    private func seed(_ store: CreditHistoryStore, account: String?) async throws {
        for value in healthy(account: account) { _ = try await store.record(value, anonymousEpochID: "private-seed-epoch") }
    }
    private func assertSuppressed(_ forecast: CreditHistoryForecast, reason: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(forecast.state, .unavailable, file: file, line: line)
        XCTAssertEqual(forecast.reason, reason, file: file, line: line)
        XCTAssertNil(forecast.estimatedCreditsPerHour, file: file, line: line)
        XCTAssertNil(forecast.estimatedSecondsRemaining, file: file, line: line)
        XCTAssertNil(forecast.fasterPaceSecondsRemaining, file: file, line: line)
        XCTAssertNil(forecast.slowerPaceSecondsRemaining, file: file, line: line)
    }

    func testSuccessfulAccountSwitchWithoutCreditsDoesNotKeepOldAccountCurrent() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        let runtime = try service([reading("100", account: accountA, offset: -120), reading(nil, account: accountB)], store: store)
        await runtime.hydrateCodexUsage()
        let first = try await runtime.creditHistory(now: now)
        XCTAssertEqual(first.currentScope, .account(accountA))
        await runtime.hydrateCodexUsage()
        let second = try await runtime.creditHistory(now: now)
        XCTAssertEqual(second.currentScope, .account(accountB))
        XCTAssertEqual(second.history.selectedScope, .account(accountB))
        XCTAssertTrue(second.isCurrentScope)
        XCTAssertTrue(second.history.balancePoints.isEmpty)
        XCTAssertNotEqual(second.history.forecast.state, .estimated)
        XCTAssertNotNil(second.recordingWarning)
        let historical = try await runtime.creditHistory(query: .init(scopeID: CreditHistoryScope.account(accountA).id), now: now)
        XCTAssertFalse(historical.isCurrentScope)
        XCTAssertEqual(historical.history.balancePoints.last?.reportedBalance, "100")
    }

    func testAccountSwitchIsIndependentOfCorruptHistorySaveFailure() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        let runtime = try service([reading("100", account: accountA, offset: -120), reading("80", account: accountB)], store: store)
        await runtime.hydrateCodexUsage()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"torn\":".utf8)); try handle.close()
        let original = try Data(contentsOf: url)
        await runtime.hydrateCodexUsage()
        let snapshot = try await runtime.creditHistory(now: now)
        let status = await runtime.status()
        XCTAssertEqual(snapshot.currentScope, .account(accountB))
        XCTAssertEqual(snapshot.history.selectedScope, .account(accountB))
        XCTAssertTrue(snapshot.history.balancePoints.isEmpty)
        XCTAssertFalse(snapshot.history.completeness.integrityVerified)
        XCTAssertNotNil(snapshot.recordingWarning)
        assertSuppressed(snapshot.history.forecast, reason: "history_integrity_failed")
        XCTAssertEqual(status.quota["codex"]?.credits?.balance, "80")
        XCTAssertEqual(try Data(contentsOf: url), original, "A failed save must not silently repair or replace the history")
    }

    func testKnownIdentityFromFailedProviderReadDoesNotAttributeOldStreamToNewAccount() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        let failedB = QuotaEstimate(agent: .codex, source: .unavailable, accountIdentityHash: accountB)
        let runtime = try service([reading("100", account: accountA, offset: -120), failedB], store: store)
        await runtime.hydrateCodexUsage()
        await runtime.hydrateCodexUsage()
        let snapshot = try await runtime.creditHistory(now: now)
        XCTAssertEqual(snapshot.currentScope, .account(accountB))
        XCTAssertEqual(snapshot.history.selectedScope, .account(accountB))
        XCTAssertTrue(snapshot.history.balancePoints.isEmpty)
        XCTAssertNotNil(snapshot.providerRefreshFailedAt)
        assertSuppressed(snapshot.history.forecast, reason: "latest_provider_read_failed")
        let old = try await runtime.creditHistory(query: .init(scopeID: CreditHistoryScope.account(accountA).id), now: now)
        XCTAssertFalse(old.isCurrentScope)
        XCTAssertEqual(old.history.records.count, 1)
    }

    func testTimestampConflictPreservesDatedChartsButSuppressesCurrentProjection() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        try await seed(store, account: accountA)
        let runtime = try service([reading("95", account: accountA), reading("90", account: accountA)], store: store)
        await runtime.hydrateCodexUsage()
        let healthy = try await runtime.creditHistory(now: now)
        XCTAssertEqual(healthy.history.forecast.state, .estimated)
        let original = try Data(contentsOf: url)
        await runtime.hydrateCodexUsage()
        let conflict = try await runtime.creditHistory(now: now)
        XCTAssertEqual(conflict.currentScope, .account(accountA))
        XCTAssertEqual(conflict.recordingWarning, "same_timestamp_conflicting_payload")
        XCTAssertEqual(conflict.history.balancePoints.count, 6)
        XCTAssertEqual(conflict.history.balancePoints.last?.reportedBalance, "95")
        XCTAssertTrue(conflict.history.completeness.integrityVerified)
        assertSuppressed(conflict.history.forecast, reason: "latest_reading_not_saved")
        XCTAssertEqual(try Data(contentsOf: url), original)
        let status = await runtime.status()
        XCTAssertEqual(status.quota["codex"]?.credits?.balance, "90", "Reported balance and saved history remain distinct facts")
    }

    func testFailedRefreshRetainsHistoricalRowsWithoutFreshRunwayAndCanRecover() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        try await seed(store, account: accountA)
        let failed = QuotaEstimate(agent: .codex, source: .unavailable, accountIdentityHash: accountA)
        let runtime = try service([reading("95", account: accountA), failed, reading("94", account: accountA, offset: 120)], store: store)
        await runtime.hydrateCodexUsage()
        let before = try await runtime.creditHistory(now: now)
        XCTAssertEqual(before.history.forecast.state, .estimated)
        await runtime.hydrateCodexUsage()
        let after = try await runtime.creditHistory(now: now)
        XCTAssertEqual(after.history.balancePoints, before.history.balancePoints)
        XCTAssertEqual(after.history.intervals, before.history.intervals)
        XCTAssertNotNil(after.providerRefreshFailedAt)
        assertSuppressed(after.history.forecast, reason: "latest_provider_read_failed")
        await runtime.hydrateCodexUsage()
        let recovered = try await runtime.creditHistory(now: now.addingTimeInterval(120))
        XCTAssertNil(recovered.providerRefreshFailedAt)
        XCTAssertNil(recovered.recordingWarning)
        XCTAssertEqual(recovered.history.records.count, 7)
        XCTAssertEqual(recovered.history.forecast.state, .estimated)
    }

    func testRestartDoesNotReuseFreshAnonymousHistoryAsCurrentCollector() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        let first = try service(healthy(account: nil), store: store)
        for _ in 0..<6 { await first.hydrateCodexUsage() }
        let old = try await first.creditHistory(now: now)
        XCTAssertEqual(old.currentScope.kind, .anonymous)
        XCTAssertEqual(old.history.forecast.state, .estimated)
        await first.shutdown()
        let restarted = try service([reading("94", account: nil, offset: 120)], store: store)
        let pending = try await restarted.creditHistory(now: now)
        XCTAssertNotEqual(pending.currentScope, old.currentScope)
        XCTAssertEqual(pending.history.selectedScope, pending.currentScope)
        XCTAssertTrue(pending.history.balancePoints.isEmpty)
        XCTAssertNil(pending.history.forecast.estimatedSecondsRemaining)
        XCTAssertTrue(pending.history.scopes.contains { $0.scope == old.currentScope })
        await restarted.hydrateCodexUsage()
        let fresh = try await restarted.creditHistory(now: now.addingTimeInterval(120))
        XCTAssertEqual(fresh.history.records.count, 1)
        XCTAssertTrue(fresh.history.intervals.isEmpty)
        XCTAssertEqual(fresh.history.forecast.state, .insufficientEvidence)
    }

    func testSharedSafetyExpiresRetainedSnapshotsAndSuppressesOfflineProjection() async throws {
        let url = location(); defer { cleanup(url) }
        let store = CreditHistoryStore(fileURL: url)
        try await seed(store, account: accountA)
        let report = try await store.report(now: now, from: now.addingTimeInterval(-86400), to: now, scope: .account(accountA))
        let original = report.forecast
        XCTAssertEqual(original.state, .estimated)
        let boundary = CreditForecastSafety.applying(to: original, now: now.addingTimeInterval(300), isCurrentScope: true)
        XCTAssertEqual(boundary.state, .estimated)
        assertSuppressed(CreditForecastSafety.applying(to: original, now: now.addingTimeInterval(301), isCurrentScope: true), reason: "latest_reading_stale")
        assertSuppressed(CreditForecastSafety.applying(to: original, now: now, isCurrentScope: true, historyReadFailed: true), reason: "history_read_failed")
        assertSuppressed(CreditForecastSafety.applying(to: original, now: now, isCurrentScope: true, providerReadFailed: true), reason: "latest_provider_read_failed")
        assertSuppressed(CreditForecastSafety.applying(to: original, now: now, isCurrentScope: true, recordingFailed: true), reason: "latest_reading_not_saved")
        assertSuppressed(CreditForecastSafety.applying(to: original, now: now, isCurrentScope: true, integrityVerified: false), reason: "history_integrity_failed")
        assertSuppressed(CreditForecastSafety.applying(to: original, now: now.addingTimeInterval(-1), isCurrentScope: true), reason: "future_reading_or_clock_change")
        let historical = CreditForecastSafety.applying(to: original, now: now, isCurrentScope: false, providerReadFailed: true, recordingFailed: true)
        XCTAssertEqual(historical.state, .estimated, "A clearly historical scenario is not the current collector's projection")
        XCTAssertEqual(report.balancePoints.count, 6, "Safety masking must not erase the underlying dated facts")
    }

    func testPublicQueryValidationAndUnknownScopeRejection() async throws {
        XCTAssertThrowsError(try CreditHistoryQuery(query: ["window": "1y"]))
        XCTAssertThrowsError(try CreditHistoryQuery(query: ["scope": "../../secrets"]))
        let scope = CreditHistoryScope.account(accountA)
        let query = try CreditHistoryQuery(query: ["window": "7d", "scope": scope.id])
        XCTAssertEqual(query.window, .week)
        XCTAssertEqual(query.scopeID, scope.id)
        XCTAssertEqual(now.timeIntervalSince(query.from(at: now)), 7 * 86400)
        XCTAssertTrue(query.path().hasPrefix("/credits/history?"))
        XCTAssertTrue(query.path(export: true).hasPrefix("/credits/export?"))
        let url = location(); defer { cleanup(url) }
        let runtime = try service([reading("100", account: accountA)], store: CreditHistoryStore(fileURL: url))
        do {
            _ = try await runtime.creditHistory(query: .init(scopeID: String(repeating: "a", count: 64)), now: now)
            XCTFail("Unknown streams must not fall back to the current account")
        } catch BridgeError.invalidRequest {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExportIsPrivateSanitizedAndNeverOverwritesExistingFile() async throws {
        let url = location(); defer { cleanup(url) }
        let runtime = try service([reading("100.0000", account: accountA)], store: CreditHistoryStore(fileURL: url))
        await runtime.hydrateCodexUsage()
        let snapshot = try await runtime.creditHistory(now: now)
        let data = try BridgeJSON.encoder.encode(snapshot)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(accountA))
        let export = url.deletingLastPathComponent().appendingPathComponent("private-export.json")
        try CreditHistoryExport.write(data, to: export)
        let permissions = try FileManager.default.attributesOfItem(atPath: export.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: export), data)
        XCTAssertThrowsError(try CreditHistoryExport.write(Data("replacement".utf8), to: export))
        XCTAssertEqual(try Data(contentsOf: export), data)
        let decoded = try BridgeJSON.decoder.decode(CreditHistorySnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, "credit-report/1")
        XCTAssertEqual(decoded.history.balancePoints.first?.reportedBalance, "100.0000")
    }
}

private actor CreditHistoryIntegrationReader {
    private let values: [QuotaEstimate]
    private var index = 0
    init(_ values: [QuotaEstimate]) { precondition(!values.isEmpty); self.values = values }
    func read() -> QuotaEstimate {
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}
