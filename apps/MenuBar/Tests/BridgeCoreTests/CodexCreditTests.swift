@testable import BridgeCore
import Foundation
import XCTest

final class CodexCreditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func parse(_ result: String) throws -> QuotaEstimate {
        try CodexUsageParser.parse(line: "{\"id\":2,\"result\":\(result)}", now: now)
    }

    func testExactBalanceIsIndependentFromPlanWindowsAndEarnedResets() throws {
        let estimate = try parse(#"{"rateLimits":{"limitId":"codex","limitName":"Codex","credits":{"balance":"12345678901234567890.000000000012300","hasCredits":true,"unlimited":false},"primary":{"usedPercent":64,"windowDurationMins":300}},"rateLimitResetCredits":{"availableCount":3}}"#)
        XCTAssertEqual(estimate.credits?.balance, "12345678901234567890.000000000012300")
        XCTAssertEqual(estimate.credits?.hasCredits, true)
        XCTAssertEqual(estimate.credits?.unlimited, false)
        XCTAssertEqual(estimate.limitID, "codex")
        XCTAssertEqual(estimate.limitName, "Codex")
        XCTAssertEqual(estimate.fetchedAt, now)
        XCTAssertEqual(estimate.availableResetCredits, 3)
        XCTAssertEqual(estimate.windows.first?.usedRatio, 0.64)
        XCTAssertEqual(estimate.remainingRatio, 0.36, accuracy: 0.0001)
    }

    func testCreditOnlyResponseHasNoInventedPlanWindows() throws {
        let estimate = try parse(#"{"rateLimits":{"credits":{"balance":"42.50","hasCredits":true,"unlimited":false}}}"#)
        XCTAssertEqual(estimate.source, .live)
        XCTAssertEqual(estimate.fetchedAt, now)
        XCTAssertEqual(estimate.credits?.balance, "42.50")
        XCTAssertTrue(estimate.windows.isEmpty)
        XCTAssertNil(estimate.limitedUntil)
        XCTAssertFalse(estimate.available, "A balance alone is not permission for the Bridge to start paid turns")
    }

    func testExplicitZeroAndFalseAreNotOmitted() throws {
        let estimate = try parse(#"{"rateLimits":{"credits":{"balance":"0.000","hasCredits":false,"unlimited":false}}}"#)
        XCTAssertEqual(estimate.credits, QuotaCredits(balance: "0.000", hasCredits: false, unlimited: false))
        let missing = try parse(#"{"rateLimits":{"credits":{"hasCredits":false}}}"#)
        XCTAssertNil(missing.credits?.balance)
        XCTAssertNil(missing.credits?.unlimited)
        XCTAssertEqual(missing.credits?.hasCredits, false)
    }

    func testUnlimitedWithoutBalanceIsNotZero() throws {
        let estimate = try parse(#"{"rateLimits":{"credits":{"balance":null,"hasCredits":true,"unlimited":true}}}"#)
        XCTAssertNil(estimate.credits?.balance)
        XCTAssertEqual(estimate.credits?.unlimited, true)
    }

    func testMissingOrNullCreditsAreUnknownNotZero() throws {
        for credits in ["", #", "credits":null"#, #", "credits":{}"#] {
            let estimate = try parse(#"{"rateLimits":{"primary":{"usedPercent":10}\#(credits)}}"#)
            XCTAssertNil(estimate.credits)
        }
    }

    func testMalformedBalancesNeverBecomeZeroOrInvalidateValidFlags() throws {
        for raw in [#""NaN""#, #""Infinity""#, #""-1""#, #""1e3""#, #""$12.00""#, #""1.2.3""#, #"" 12 ""#, #""12\n""#, "12.5", "true", "{}", "[]", "null"] {
            let estimate = try parse(#"{"rateLimits":{"credits":{"balance":\#(raw),"hasCredits":true,"unlimited":false}}}"#)
            XCTAssertNil(estimate.credits?.balance, raw)
            XCTAssertEqual(estimate.credits?.hasCredits, true, raw)
            XCTAssertEqual(estimate.credits?.unlimited, false, raw)
        }
    }

    func testMalformedFlagsAreNotCoercedToFalse() throws {
        let estimate = try parse(#"{"rateLimits":{"credits":{"balance":"1.00","hasCredits":"true","unlimited":0}}}"#)
        XCTAssertEqual(estimate.credits?.balance, "1.00")
        XCTAssertNil(estimate.credits?.hasCredits)
        XCTAssertNil(estimate.credits?.unlimited)
    }

    func testMalformedWindowsCannotInvalidateCredits() throws {
        for primary in [#"{"usedPercent":"NaN"}"#, #"{"usedPercent":101}"#, #"{"usedPercent":null}"#, #"{"usedPercent":12,"windowDurationMins":"bad"}"#, "[]", "null"] {
            let estimate = try parse(#"{"rateLimits":{"primary":\#(primary),"secondary":{"usedPercent":"bad"},"planType":"future-plan","credits":{"balance":"20","hasCredits":true,"unlimited":false}}}"#)
            XCTAssertEqual(estimate.credits?.balance, "20", primary)
            XCTAssertTrue(estimate.windows.isEmpty, primary)
            XCTAssertEqual(estimate.source, .live, primary)
        }
    }

    func testMalformedCreditsCannotInvalidateWindows() throws {
        for credits in ["[]", "true", #"{"balance":"bad","hasCredits":0}"#] {
            let estimate = try parse(#"{"rateLimits":{"primary":{"usedPercent":40},"credits":\#(credits)}}"#)
            XCTAssertEqual(estimate.windows.first?.usedRatio, 0.4)
            XCTAssertNil(estimate.credits)
        }
    }

    func testCanonicalCodexBucketWinsWithoutCrossBucketMerging() throws {
        let estimate = try parse(#"{"rateLimits":{"limitId":"codex","credits":{"balance":"999"}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","credits":{"balance":"12.340","hasCredits":true,"unlimited":false}},"code_review":{"credits":{"balance":"888"}},"other":"malformed"}}"#)
        XCTAssertEqual(estimate.credits?.balance, "12.340")
        let noBorrow = try parse(#"{"rateLimits":{"limitId":"codex","credits":{"balance":"999"}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20}},"code_review":{"credits":{"balance":"888"}}}}"#)
        XCTAssertNil(noBorrow.credits)
        XCTAssertEqual(noBorrow.windows.first?.usedRatio, 0.2)
    }

    func testStableSnapshotFallbackNeverUsesAnArbitraryBucket() throws {
        let estimate = try parse(#"{"rateLimits":{"limitId":"codex","credits":{"balance":"10"}},"rateLimitsByLimitId":{"code_review":{"credits":{"balance":"999"}}}}"#)
        XCTAssertEqual(estimate.credits?.balance, "10")
        XCTAssertThrowsError(try parse(#"{"rateLimits":{"limitId":"code_review","credits":{"balance":"999"}},"rateLimitsByLimitId":{"other":{"credits":{"balance":"888"}}}}"#))
        XCTAssertThrowsError(try parse(#"{"rateLimits":{},"rateLimitsByLimitId":{"code_review":{"credits":{"balance":"999"}}}}"#))
    }

    func testConflictingBucketIdentityCannotClaimCodexBalance() throws {
        let estimate = try parse(#"{"rateLimits":{"limitId":"codex","credits":{"balance":"10"}},"rateLimitsByLimitId":{"codex":{"limitId":"code_review","credits":{"balance":"999"}}}}"#)
        XCTAssertEqual(estimate.credits?.balance, "10")
    }

    func testPositiveBalanceNeverOverridesExhaustedPlanOrPolicyBlock() throws {
        for details in [#""primary":{"usedPercent":100}"#, #""rateLimitReachedType":"workspace_owner_credits_depleted""#, #""spendControlReached":true"#] {
            let estimate = try parse(#"{"rateLimits":{\#(details),"credits":{"balance":"100","hasCredits":true,"unlimited":true}}}"#)
            XCTAssertFalse(estimate.available, details)
            XCTAssertEqual(estimate.credits?.balance, "100")
        }
    }

    func testLimitAndSpendStatesAreSeparateProviderFacts() throws {
        let estimate = try parse(#"{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false},"rateLimitReachedType":"workspace_member_usage_limit_reached","spendControlReached":true}}"#)
        XCTAssertEqual(estimate.rateLimitReachedType, "workspace_member_usage_limit_reached")
        XCTAssertEqual(estimate.spendControlReached, true)
        XCTAssertNil(estimate.credits?.balance)
    }

    func testEarnedResetCreditsNeverBecomeSpendableBalance() throws {
        let estimate = try parse(#"{"rateLimits":{"primary":{"usedPercent":12}},"rateLimitResetCredits":{"availableCount":4,"credits":[]}}"#)
        XCTAssertEqual(estimate.availableResetCredits, 4)
        XCTAssertNil(estimate.credits)
        for count in ["-1", #""4""#, "null"] {
            let malformed = try parse(#"{"rateLimits":{"primary":{"usedPercent":12}},"rateLimitResetCredits":{"availableCount":\#(count)}}"#)
            XCTAssertNil(malformed.availableResetCredits)
        }
    }

    func testOldQuotaCacheDecodesWithoutNewCreditFields() throws {
        let estimate = try BridgeJSON.decoder.decode(QuotaEstimate.self, from: Data(#"{"agent":"codex"}"#.utf8))
        XCTAssertNil(estimate.credits)
        XCTAssertNil(estimate.limitID)
        XCTAssertNil(estimate.limitName)
        XCTAssertNil(estimate.rateLimitReachedType)
        XCTAssertNil(estimate.spendControlReached)
        XCTAssertNil(estimate.availableResetCredits)
        XCTAssertNil(estimate.refreshFailedAt)
        XCTAssertNil(estimate.accountIdentityHash)
    }

    func testCreditCacheRoundTripsExactBalanceAndFailureProvenance() throws {
        var original = try parse(#"{"rateLimits":{"limitId":"codex","limitName":"Codex","credits":{"balance":"123.4500","hasCredits":true,"unlimited":false},"rateLimitReachedType":"workspace_owner_usage_limit_reached","spendControlReached":true},"rateLimitResetCredits":{"availableCount":2}}"#)
        original.refreshFailedAt = now.addingTimeInterval(10)
        original.accountIdentityHash = "identity-hash"
        let decoded = try BridgeJSON.decoder.decode(QuotaEstimate.self, from: BridgeJSON.encoder.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testCreditOnlyFailedRefreshRetainsDatedHistoryBeyondWindowGrace() {
        let fetched = now.addingTimeInterval(-QuotaTracker.unavailableReadingGrace - 10)
        var tracker = QuotaTracker(cooldownMinutes: 60)
        tracker.applyProviderUsage(QuotaEstimate(agent: .codex, source: .live, fetchedAt: fetched, credits: QuotaCredits(balance: "42.50", hasCredits: true)), now: now)
        tracker.applyProviderUsage(QuotaEstimate(agent: .codex, source: .unavailable, statusMessage: "Refresh failed"), now: now)
        let retained = tracker.snapshot()["codex"]
        XCTAssertEqual(retained?.credits?.balance, "42.50")
        XCTAssertEqual(retained?.fetchedAt, fetched)
        XCTAssertEqual(retained?.refreshFailedAt, now)
        XCTAssertEqual(retained?.statusMessage, "Refresh failed")
        XCTAssertTrue(retained?.windows.isEmpty == true)
    }

    func testSuccessfulMissingCreditsClearsPreviousBalanceAndFailure() {
        var tracker = QuotaTracker(cooldownMinutes: 60)
        tracker.applyProviderUsage(QuotaEstimate(agent: .codex, source: .live, fetchedAt: now, credits: QuotaCredits(balance: "42.50"), refreshFailedAt: now), now: now)
        tracker.applyProviderUsage(QuotaEstimate(agent: .codex, windows: [QuotaWindow(id: "primary", label: "Plan", usedRatio: 0.4)], source: .live, fetchedAt: now.addingTimeInterval(10)), now: now.addingTimeInterval(10))
        let estimate = tracker.snapshot()["codex"]
        XCTAssertNil(estimate?.credits)
        XCTAssertNil(estimate?.refreshFailedAt)
        XCTAssertEqual(estimate?.windows.first?.usedRatio, 0.4)
    }

    func testChangedKnownIdentityDoesNotRetainPreviousAccountsCredits() {
        var tracker = QuotaTracker(cooldownMinutes: 60)
        tracker.applyProviderUsage(QuotaEstimate(agent: .codex, source: .live, fetchedAt: now, credits: QuotaCredits(balance: "42.50"), accountIdentityHash: "old-account"), now: now)
        tracker.applyProviderUsage(QuotaEstimate(agent: .codex, source: .unavailable, accountIdentityHash: "new-account"), now: now)
        let estimate = tracker.snapshot()["codex"]
        XCTAssertNil(estimate?.credits)
        XCTAssertEqual(estimate?.accountIdentityHash, "new-account")
        XCTAssertEqual(estimate?.source, .unavailable)
    }

    func testWindowResetCannotRemoveAccountOrWorkspaceSpendingBlock() {
        for (reachedType, spendingBlock) in [("workspace_owner_credits_depleted", false), (nil, true)] as [(String?, Bool)] {
            var tracker = QuotaTracker(cooldownMinutes: 60)
            tracker.applyProviderUsage(QuotaEstimate(agent: .codex, available: false, limitedUntil: now.addingTimeInterval(1), source: .live, fetchedAt: now, credits: QuotaCredits(balance: "100", hasCredits: true), rateLimitReachedType: reachedType, spendControlReached: spendingBlock), now: now)
            tracker.refresh(now: now.addingTimeInterval(2))
            XCTAssertEqual(tracker.snapshot()["codex"]?.available, false)
        }
    }

    func testIdentityHashNormalizesEmailAndIgnoresPlanRenewal() {
        let first = CodexUsageParser.accountIdentityHash(result: ["account": ["type": "chatgpt", "email": " Person@Example.com ", "planType": "plus"]])
        let renewed = CodexUsageParser.accountIdentityHash(result: ["account": ["type": "chatgpt", "email": "person@example.com", "planType": "pro"]])
        XCTAssertEqual(first, TraceCrypto.digest(Data("codex:chatgpt:person@example.com".utf8)))
        XCTAssertEqual(first, renewed)
        XCTAssertNotEqual(first, "person@example.com")
        XCTAssertNil(CodexUsageParser.accountIdentityHash(result: ["account": ["type": "apiKey", "email": "person@example.com"]]))
        XCTAssertNil(CodexUsageParser.accountIdentityHash(result: ["account": ["type": "chatgpt", "email": " "]]))
        XCTAssertNil(CodexUsageParser.accountIdentityHash(result: [:]))
    }
}
