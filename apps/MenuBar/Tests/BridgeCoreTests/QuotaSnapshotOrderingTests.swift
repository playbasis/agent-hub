import Foundation
import XCTest
@testable import BridgeCore

final class QuotaSnapshotOrderingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnonymousCodexBucketReadsStillKeepTheNewestCompleteObservation() throws {
        var current = reading(balance:"12",offset:30)
        current.accountIdentityHash = nil; current.limitID = "codex"
        var old = reading(balance:"15",offset:10)
        old.accountIdentityHash = nil; old.limitID = "codex"
        XCTAssertEqual(try merged(current,old),current)
        var cleared = old
        cleared.fetchedAt = now.addingTimeInterval(40); cleared.credits = nil
        XCTAssertNil(try merged(current,cleared).credits)
        XCTAssertNil(try merged(cleared,old).credits)
    }

    func testOlderStatusCannotRestoreAnEarlierBalance() throws {
        let current = reading(balance: "12.50", offset: 20)
        let older = reading(balance: "15.00", offset: 10)
        XCTAssertEqual(try merged(current, older), current)
    }

    func testSuccessfulMissingCreditsClearsOldFieldsAndCannotBeUndone() throws {
        let earlier = reading(balance: "15.00", offset: 10)
        var cleared = reading(balance: nil, offset: 20)
        cleared.credits = nil
        XCTAssertEqual(try merged(earlier, cleared), cleared)
        XCTAssertNil(try merged(cleared, earlier).credits)
    }

    func testExplicitMissingBalanceIsNotFilledFromAnOlderReading() throws {
        let earlier = reading(balance: "15.00", offset: 10)
        let missing = reading(balance: nil, offset: 20)
        let result = try merged(earlier, missing)
        XCTAssertNotNil(result.credits)
        XCTAssertNil(result.credits?.balance)
        XCTAssertNil(try merged(result, earlier).credits?.balance)
    }

    func testFailureObservationCannotBeUndoneByAnOlderSuccessfulPoll() throws {
        var failed = reading(balance: "15.00", offset: 10)
        failed.refreshFailedAt = now.addingTimeInterval(30)
        failed.statusMessage = "The latest refresh failed."
        let delayedPoll = reading(balance: "16.00", offset: 20)
        XCTAssertEqual(try merged(failed, delayedPoll), failed)
    }

    func testLaterSuccessfulReadClearsAnEarlierFailure() throws {
        var failed = reading(balance: "15.00", offset: 10)
        failed.refreshFailedAt = now.addingTimeInterval(20)
        let success = reading(balance: "14.00", offset: 30)
        XCTAssertEqual(try merged(failed, success), success)
        XCTAssertNil(try merged(failed, success).refreshFailedAt)
    }

    func testLatestFailureCanClearPayloadAndBlocksEarlierBalanceRestoration() throws {
        let current = reading(balance: "15.00", offset: 10)
        var failed = reading(balance: nil, offset: 0)
        failed.fetchedAt = nil
        failed.credits = nil
        failed.source = .unavailable
        failed.refreshFailedAt = now.addingTimeInterval(20)
        XCTAssertEqual(try merged(current, failed), failed)
        XCTAssertNil(try merged(failed, current).credits)
    }

    func testEqualObservationTimeAcceptsIncomingAuthoritativeNull() throws {
        let current = reading(balance: "15.00", offset: 10)
        var incoming = reading(balance: nil, offset: 10)
        incoming.credits = nil
        XCTAssertEqual(try merged(current, incoming), incoming)
    }

    func testDifferentOrUnknownAccountsNeverBorrowPriorPayload() throws {
        let current = reading(balance: "15.00", offset: 30)
        var other = reading(balance: "2.00", offset: 10)
        other.accountIdentityHash = "account-b"
        XCTAssertEqual(try merged(current, other), other)
        other.accountIdentityHash = nil
        XCTAssertEqual(try merged(current, other), other)
        var unknownCurrent = current
        unknownCurrent.accountIdentityHash = nil
        XCTAssertEqual(try merged(unknownCurrent, other), unknownCurrent,
                       "Two anonymous Codex bucket readings still retain the newer complete observation")
    }

    func testRemovedProviderIsNotResurrected() {
        let current = reading(balance: "15.00", offset: 10)
        XCTAssertTrue(QuotaSnapshotOrdering.merging(current: ["codex": current], incoming: [:]).isEmpty)
    }

    func testRetainedProviderReadingDoesNotRegressObservedCounters() throws {
        var current = reading(balance: "15.00", offset: 20)
        current.observedTurns = 4
        current.observedLimits = 2
        var older = reading(balance: "20.00", offset: 10)
        older.observedTurns = 6
        older.observedLimits = 1
        let result = try merged(current, older)
        XCTAssertEqual(result.credits, current.credits)
        XCTAssertEqual(result.observedTurns, 6)
        XCTAssertEqual(result.observedLimits, 2)
    }

    func testInvalidObservationDatesCannotOverrideAFiniteReading() throws {
        let current = reading(balance: "15.00", offset: 20)
        var invalid = reading(balance: "99.00", offset: 0)
        invalid.fetchedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        invalid.refreshFailedAt = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertEqual(try merged(current, invalid), current)
        XCTAssertEqual(try merged(invalid, current), current)
    }

    func testUnrelatedProviderIsUnchanged() {
        let previous = QuotaEstimate(agent: .claude, fetchedAt: now.addingTimeInterval(20))
        let incoming = QuotaEstimate(agent: .claude, fetchedAt: now)
        XCTAssertEqual(QuotaSnapshotOrdering.merging(current: ["claude": previous], incoming: ["claude": incoming])["claude"], incoming)
    }

    private func reading(balance: String?, offset: TimeInterval) -> QuotaEstimate {
        QuotaEstimate(agent: .codex, source: .live,
                      fetchedAt: now.addingTimeInterval(offset),
                      credits: QuotaCredits(balance: balance, hasCredits: true, unlimited: false),
                      limitID: "codex", accountIdentityHash: "account-a")
    }

    private func merged(_ current: QuotaEstimate, _ incoming: QuotaEstimate) throws -> QuotaEstimate {
        try XCTUnwrap(QuotaSnapshotOrdering.merging(current: ["codex": current], incoming: ["codex": incoming])["codex"])
    }
}

final class CreditAccountIdentityTests: XCTestCase {
    func testCodexSubscriptionIdentityNormalizesWhitespaceAndCase() {
        let status = account(email: " \n Alice@Example.COM \t")
        XCTAssertEqual(status.creditAccountIdentityHash, TraceCrypto.digest("codex:chatgpt:alice@example.com"))
        XCTAssertEqual(status.creditAccountIdentityHash?.count, 64)
    }

    func testIdentityIsStableAcrossPlanRenewalAndCLIVersions() {
        let old = account(email: "alice@example.com")
        var renewed = old
        renewed.planName = "ChatGPT Pro"
        renewed.cliVersion = "new-version"
        renewed.checkedAt = old.checkedAt.addingTimeInterval(60)
        XCTAssertEqual(old.creditAccountIdentityHash, renewed.creditAccountIdentityHash)
    }

    func testDifferentAccountsNeverShareIdentityMarker() {
        XCTAssertNotEqual(account(email: "alice@example.com").creditAccountIdentityHash,
                          account(email: "bob@example.com").creditAccountIdentityHash)
    }

    func testUnlinkedAPIClaudeAndMissingIdentitiesAreUnavailable() {
        var status = account(email: "alice@example.com")
        status.linked = false
        XCTAssertNil(status.creditAccountIdentityHash)
        status = account(email: "alice@example.com")
        status.method = "apikey"
        XCTAssertNil(status.creditAccountIdentityHash)
        status = account(email: "alice@example.com")
        status.provider = .claude
        XCTAssertNil(status.creditAccountIdentityHash)
        XCTAssertNil(account(email: nil).creditAccountIdentityHash)
        XCTAssertNil(account(email: " \n\t ").creditAccountIdentityHash)
    }

    private func account(email: String?) -> ProviderAccountStatus {
        ProviderAccountStatus(provider: .codex, installed: true, linked: true,
                              method: "chatgpt", email: email, planName: "ChatGPT Plus")
    }
}
