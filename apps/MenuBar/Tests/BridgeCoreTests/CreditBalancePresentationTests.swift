import XCTest
@testable import BridgeCore

final class CreditBalancePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func estimate(_ balance: String? = "12345.6789012000", has: Bool? = true, unlimited: Bool? = false) -> QuotaEstimate {
        QuotaEstimate(agent: .codex, source: .live, fetchedAt: now, credits: .init(balance: balance, hasCredits: has, unlimited: unlimited),
                      limitID: "codex", accountIdentityHash: "account-a")
    }

    func testCreditOnlyReadingIsFreshWithoutInventingPlanCapacity() {
        let q = estimate()
        let p = CreditBalancePresentation.make(q, now: now)
        XCTAssertEqual(p.state, .available)
        XCTAssertEqual(p.freshness, .fresh)
        XCTAssertEqual(p.exactBalance, "12345.6789012000")
        XCTAssertEqual(p.displayBalance, "12,345.68")
        XCTAssertTrue(p.isRounded)
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(q, now: now), .unavailable)
        XCTAssertFalse(ActivityHighlights.make(.init(sessions: [], from: nil, to: now, quotas: [.codex:q])).contains { $0.kind == .planHealthy })
    }

    func testStringRoundingDoesNotOverflowOrLoseProviderPrecision() {
        for (raw, formatted, rounded) in [
            ("99.999", "100", true), ("0.005", "0.01", true), ("0.004", "0", true),
            ("009.9900", "9.99", false), ("1.999", "2", true), ("0.0000", "0", false),
            ("1234567890123456789012345678901234567890.995", "1,234,567,890,123,456,789,012,345,678,901,234,567,891", true)
        ] {
            let p = CreditBalancePresentation.make(estimate(raw, has: nil), now: now)
            XCTAssertEqual(p.exactBalance, raw)
            XCTAssertEqual(p.displayBalance, formatted)
            XCTAssertEqual(p.isRounded, rounded)
        }
    }

    func testMissingIsNeverZeroAndMalformedIsNeverMoney() {
        for raw in [nil, "", "NaN", "-1", "1e3", "1,000", "$20", " 20", "20\n", String(repeating:"9", count:129)] as [String?] {
            let p = CreditBalancePresentation.make(estimate(raw, has:nil), now:now)
            XCTAssertNil(p.exactBalance, raw ?? "nil")
            XCTAssertEqual(p.displayBalance, "—")
            XCTAssertEqual(p.state, .unavailableBalance)
        }
        let absent = CreditBalancePresentation.make(nil, now:now)
        XCTAssertEqual(absent.state, .notReported)
        XCTAssertNil(absent.exactBalance)
    }

    func testZeroFalseAndUnlimitedAreDifferentEvidence() {
        XCTAssertEqual(CreditBalancePresentation.make(estimate("0",has:false),now:now).state,.depleted)
        let missing = CreditBalancePresentation.make(estimate(nil,has:false),now:now)
        XCTAssertEqual(missing.state,.depleted)
        XCTAssertEqual(missing.displayBalance,"—", "False availability does not invent a numeric amount")
        let uncapped = CreditBalancePresentation.make(estimate(nil,has:true,unlimited:true),now:now)
        XCTAssertEqual(uncapped.state,.unlimited)
        XCTAssertEqual(uncapped.displayBalance,"Uncapped")
        let availableWithoutAmount = CreditBalancePresentation.make(estimate(nil,has:true),now:now)
        XCTAssertEqual(availableWithoutAmount.state,.available)
        XCTAssertEqual(availableWithoutAmount.displayBalance,"—")
        XCTAssertTrue(availableWithoutAmount.detail.contains("did not share an amount"))
    }

    func testContradictoryCreditFlagsAreVisibleNotResolvedByGuessing() {
        for (balance,has) in [("42",false),("0",true)] {
            XCTAssertEqual(CreditBalancePresentation.make(estimate(balance,has:has),now:now).state,.conflicting)
        }
    }

    func testFailuresExpiredAndFutureReadingsStayHistorical() {
        var q = estimate()
        q.refreshFailedAt = now
        XCTAssertEqual(CreditBalancePresentation.make(q,now:now).freshness,.stale)
        XCTAssertEqual(CreditBalancePresentation.make(q,now:now).exactBalance,q.credits?.balance)
        q.refreshFailedAt = nil
        XCTAssertEqual(CreditBalancePresentation.make(q,now:now.addingTimeInterval(961)).freshness,.stale)
        XCTAssertEqual(CreditBalancePresentation.make(q,now:now.addingTimeInterval(-1)).freshness,.stale)
        q.windows = [.init(id:"weekly",label:"Weekly",usedRatio:0.5,resetAt:now.addingTimeInterval(3600))]
        q.refreshFailedAt = now
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(q,now:now),.stale)
        XCTAssertEqual(ActivityPresentationPolicy.runway(q.windows[0],estimate:q,now:now),.unknown)
    }

    func testCreditScopeMismatchAndUnknownIdentityHideSavedBalance() {
        for q in [estimate(), QuotaEstimate(agent:.codex,source:.live,fetchedAt:now,credits:.init(balance:"12",hasCredits:true))] {
            let p = CreditBalancePresentation.make(q,now:now,expectedAccountIdentityHash:"account-b")
            XCTAssertEqual(p.state,.accountMismatch)
            XCTAssertNil(p.exactBalance)
            XCTAssertEqual(p.displayBalance,"—")
        }
        XCTAssertEqual(CreditBalancePresentation.make(estimate(),now:now,accountVerified:false).state,.accountMismatch)
    }

    func testCurrentCodexCreditsCanBeReportedWithoutInventingAnAccountIdentity() {
        var q = estimate()
        q.accountIdentityHash = nil
        let p = CreditBalancePresentation.make(q,now:now,expectedAccountIdentityHash:"named-profile",accountVerified:false)
        XCTAssertEqual(p.exactBalance,"12345.6789012000")
        XCTAssertTrue(p.identityUnreported)
        XCTAssertEqual(p.freshness,.fresh)
        XCTAssertTrue(p.detail.contains("not matched to a named account"))
        XCTAssertNil(q.accountIdentityHash, "Successful credits do not manufacture a sign-in identity")
    }

    func testAnonymousBalancesAreWithheldAfterFailureExpiryOrFromAnotherBucket() {
        var q = estimate()
        q.accountIdentityHash = nil
        XCTAssertNil(CreditBalancePresentation.make(q,now:now.addingTimeInterval(181)).exactBalance)
        q.refreshFailedAt = now
        XCTAssertNil(CreditBalancePresentation.make(q,now:now).exactBalance)
        q.refreshFailedAt = nil; q.limitID = "code_review"
        XCTAssertNil(CreditBalancePresentation.make(q,now:now).exactBalance)
    }

    func testUsedAllowanceAndSpendControlsDoNotClaimExactConsumptionOrAutoReload() {
        var q = estimate()
        q.windows = [.init(id:"weekly",label:"Weekly",usedRatio:1,resetAt:now.addingTimeInterval(3600))]
        q.rateLimitReachedType = "rate_limit_reached"
        let p = CreditBalancePresentation.make(q,now:now)
        XCTAssertEqual(p.state,.available)
        XCTAssertTrue(p.limitMessage?.contains("Included allowance used up") == true)
        XCTAssertFalse(p.detail.contains("Using credits"))
        q.spendControlReached = true
        XCTAssertTrue(CreditBalancePresentation.make(q,now:now).limitMessage?.contains("spending control") == true)
    }

    func testEarnedResetCountIsNotAddedToSpendableBalance() {
        var q = estimate("12")
        q.availableResetCredits = 3
        let p = CreditBalancePresentation.make(q,now:now)
        XCTAssertEqual(p.exactBalance,"12")
        XCTAssertEqual(p.availableResetCredits,3)
    }

    func testCreditAwarePlanHighlightNamesIncludedAllowanceNotAccountExhaustion() throws {
        var q = estimate()
        q.windows = [.init(id:"weekly",label:"Weekly",usedRatio:1,resetAt:now.addingTimeInterval(3600))]
        let low = try XCTUnwrap(ActivityHighlights.make(.init(sessions:[],from:nil,to:now,quotas:[.codex:q])).first { $0.kind == .planLow })
        XCTAssertEqual(low.title,"ChatGPT included allowance used up")
        XCTAssertEqual(low.tone,.warning)
        XCTAssertTrue(low.detail.contains("Credits also available when read"))
    }

    func testSharedCreditWireFieldsAndDecimalGrammarMatchPublishedSchemas() throws {
        let root = (0..<5).reduce(URL(fileURLWithPath:#filePath)) { path, _ in path.deletingLastPathComponent() }
        func schema(_ name:String) throws -> [String:Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("schemas/"+name))) as? [String:Any])
        }
        let quotaSchema = try schema("quota-estimate-v1.schema.json")
        let properties = try XCTUnwrap(quotaSchema["properties"] as? [String:Any])
        let encoded = try BridgeJSON.compactEncoder.encode(estimate())
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertTrue(Set(wire.keys).isSubset(of:Set(properties.keys)))
        let credits = try XCTUnwrap(wire["credits"] as? [String:Any])
        XCTAssertEqual(credits["balance"] as? String,"12345.6789012000")
        XCTAssertEqual(credits["has_credits"] as? Bool,true)
        let creditSpec = try XCTUnwrap(properties["credits"] as? [String:Any])
        let creditFields = try XCTUnwrap(creditSpec["properties"] as? [String:Any])
        let balanceSpec = try XCTUnwrap(creditFields["balance"] as? [String:Any])
        let pattern = try XCTUnwrap(balanceSpec["pattern"] as? String)
        for value in ["0","0123.4500","-1","1\n","1e3","NaN",""] {
            XCTAssertEqual(value.range(of:pattern,options:.regularExpression) != nil,QuotaCredits.validatedBalance(value) != nil,value)
        }
        XCTAssertEqual(balanceSpec["maxLength"] as? Int,128)
        let statusSpec = try schema("status.json")
        let required = try XCTUnwrap(statusSpec["required"] as? [String])
        let status = BridgeStatus(state:.stopped,activeAgent:.grok,session:nil,latestDecision:nil,quota:["codex":estimate()])
        let statusWire = try XCTUnwrap(JSONSerialization.jsonObject(with:BridgeJSON.compactEncoder.encode(status)) as? [String:Any])
        XCTAssertTrue(Set(required).isSubset(of:Set(statusWire.keys)),"Optional absent session/decision fields cannot be schema-required")
        let statusFields = try XCTUnwrap(statusSpec["properties"] as? [String:Any])
        let scope = try XCTUnwrap(statusFields["quota"] as? [String:Any])
        let ref = try XCTUnwrap(scope["additionalProperties"] as? [String:String])
        XCTAssertEqual(ref["$ref"],"quota-estimate-v1.schema.json")
    }
}
