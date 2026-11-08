import Foundation
import XCTest
@testable import WorkspaceContracts

final class ContractPrimitiveTests: XCTestCase {
    func testTokenQuantitiesAreCanonicalStringsUpToInt64Max() throws {
        XCTAssertEqual(TokenQuantity("0")?.value, 0)
        XCTAssertEqual(TokenQuantity("9223372036854775807")?.value, .max)
        for bad in ["", "01", "+1", "-1", "1e3", "1.0", " 1", "9223372036854775808", "99999999999999999999"] {
            XCTAssertNil(TokenQuantity(bad), bad)
        }
        let encoded = try ContractJSON.encoder.encode([TokenQuantity("9223372036854775807")!])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "[\"9223372036854775807\"]")
        XCTAssertThrowsError(try ContractJSON.decoder.decode([TokenQuantity].self, from: Data("[123]".utf8)), "A JSON number would be rounded by some readers")
        XCTAssertNil(TokenQuantity("9223372036854775807")!.adding(TokenQuantity("1")!), "Overflow is unknown, never wrapped")
        XCTAssertNil(TokenQuantity("1")!.subtracting(TokenQuantity("2")!))
    }

    func testExactDecimalsKeepValueAndWriteCanonicalText() throws {
        XCTAssertEqual(ExactDecimal("8.50")?.description, "8.5")
        XCTAssertEqual(ExactDecimal("-0")?.description, "0")
        XCTAssertEqual(ExactDecimal("0.000001")?.description, "0.000001")
        XCTAssertEqual(ExactDecimal("123456789012345678.123456")?.description, "123456789012345678.123456")
        for bad in ["", ".5", "1.", "1e3", "007", "1.1234567", "1234567890123456789", "1,5", "NaN"] { XCTAssertNil(ExactDecimal(bad), bad) }
        XCTAssertEqual(ExactDecimal("0.1")!.adding(ExactDecimal("0.2")!), ExactDecimal("0.3"), "No binary floating-point drift")
        XCTAssertEqual(ExactDecimal("65.38")!.multiplied(by: ExactDecimal("24")!)?.description, "1569.12")
        XCTAssertEqual(ExactDecimal("2.345")!.rounded(scale: 2).description, "2.34", "Halves round to even")
        XCTAssertEqual(ExactDecimal("2.355")!.rounded(scale: 2).description, "2.36")
        XCTAssertNil(ExactDecimal("1")!.divided(by: .zero))
        XCTAssertEqual(ExactDecimal("8.50"), ExactDecimal("8.5"))
        XCTAssertEqual(Set([ExactDecimal("8.50")!, ExactDecimal("8.5")!]).count, 1)
        let money = MoneyAmount(amount: ExactDecimal("12.3")!, currency: "USD")
        XCTAssertEqual(String(decoding: try ContractJSON.encoder.encode(money), as: UTF8.self), #"{"amount":"12.3","currency":"USD"}"#)
        XCTAssertThrowsError(try MoneyAmount(amount: ExactDecimal("1")!, currency: "usd").validate("money"))
        XCTAssertThrowsError(try MoneyAmount(amount: ExactDecimal("-1")!, currency: "USD").validate("money"))
    }

    func testEstimateRangesKeepOrderUnderNegativeFactors() throws {
        let range = EstimateRange(low: 1, base: 2, high: 4)
        XCTAssertNoThrow(try range.validate("r"))
        XCTAssertThrowsError(try EstimateRange(low: 3, base: 2, high: 4).validate("r"))
        let flipped = try XCTUnwrap(range.multiplied(by: ExactDecimal("-1")!))
        XCTAssertEqual(flipped.low, ExactDecimal("-4"))
        XCTAssertEqual(flipped.high, ExactDecimal("-1"))
    }

    func testSHA256MatchesPublishedVectors() {
        for input in [Data(), Data("abc".utf8), Data((0 ..< 1_000).map { UInt8($0 % 251) })] {
            XCTAssertEqual(ContractDigest.portableHex(input), ContractDigest.hex(input), "The portable fallback agrees with the platform")
        }
        XCTAssertEqual(ContractDigest.portableHex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(ContractDigest.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ContractDigest.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ContractDigest.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(ContractDigest.hex(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testCanonicalJSONFollowsRFC8785ForTheContractValueSpace() throws {
        let value = try ContractJSONValue.parse(Data(#"{"b":[true,null,"é\n\u0001/"],"a":{"z":-0,"y":12345678901234567},"€":1,"A":2}"#.utf8))
        let text = String(decoding: try CanonicalJSON.data(value), as: UTF8.self)
        XCTAssertEqual(text, "{\"A\":2,\"a\":{\"y\":12345678901234567,\"z\":0},\"b\":[true,null,\"é\\n\\u0001/\"],\"€\":1}")
        XCTAssertThrowsError(try CanonicalJSON.data(.number("1.5")), "Digested documents carry integers only")
        XCTAssertThrowsError(try ContractJSONValue.parse(Data(#"{"a":1,"a":2}"#.utf8)), "Duplicate keys are ambiguous")
        XCTAssertThrowsError(try ContractJSONValue.parse(Data("[1,]".utf8)))
        XCTAssertThrowsError(try ContractJSONValue.parse(Data("\"\u{01}\"".utf8)))
        XCTAssertEqual(try ContractJSONValue.parse(Data(#""😀""#.utf8)), .string("😀"))
        XCTAssertEqual(try ContractJSONValue.parse(Data("9223372036854775808".utf8)), .number("9223372036854775808"), "Exact text survives parsing")
    }

    func testExtensionsAndUndigestedFieldsDoNotChangeAReceiptDigest() throws {
        let receipt = try Self.receipt().sealed()
        var observedLater = receipt
        observedLater.observedAt = receipt.observedAt.addingTimeInterval(60)
        observedLater.revision = 2
        XCTAssertEqual(try observedLater.computedDigest(), receipt.contentDigest)
        var changed = receipt
        changed.usage.total = TokenQuantity("11")
        XCTAssertNotEqual(try changed.computedDigest(), receipt.contentDigest)
        XCTAssertThrowsError(try changed.validate(), "A stale digest is detected")

        var object = try XCTUnwrap(try ContractJSONValue.parse(ContractJSON.encoder.encode(receipt)).objectValue)
        object["x-producer-run"] = .string("run-1")
        let decoded = try ContractJSON.decoder.decode(WorkspaceReceipt.self, from: CanonicalJSON.data(.object(object)))
        XCTAssertEqual(decoded, receipt, "Readers ignore extensions")
        XCTAssertNoThrow(try decoded.validate())
    }

    func testReceiptValidationEnforcesTimeAndSubsetRules() throws {
        var unplaced = Self.receipt()
        unplaced.time = .init(basis: .unplaced)
        XCTAssertThrowsError(try unplaced.sealed().validate(), "Unplaced usage can't enter windowed totals")
        unplaced.includedInTotals = false
        XCTAssertNoThrow(try unplaced.sealed().validate())
        var reasoning = Self.receipt()
        reasoning.usage.reasoning = TokenQuantity("9")
        XCTAssertThrowsError(try reasoning.sealed().validate(), "Reasoning is a subset of output")
        var provider = Self.receipt()
        provider.provider = "Claude"
        XCTAssertThrowsError(try provider.sealed().validate())
    }

    func testRubricTurnsSizesIntoHoursPerBaselineAndStandard() throws {
        let rubric = EffortRubric(version: "test/1", sizes: ["xs", "s", "m", "l", "xl"].map {
            .init(id: $0, title: $0, description: $0, hours: EstimateRange(low: 10, base: 20, high: 40))
        }, standardFactors: ["prototype": ExactDecimal("0.5")!, "internal_tool": 1, "production": 2],
           contemporaryFactors: EstimateRange(low: ExactDecimal("0.5")!, base: ExactDecimal("0.8")!, high: ExactDecimal("1.1")!), notes: [])
        XCTAssertNoThrow(try rubric.validate())
        XCTAssertEqual(rubric.hours(size: "m", standard: .production, baseline: .historical), EstimateRange(low: 20, base: 40, high: 80))
        XCTAssertEqual(rubric.hours(size: "m", standard: .internalTool, baseline: .contemporary), EstimateRange(low: 5, base: 16, high: 44))
        XCTAssertNil(rubric.hours(size: "m", standard: .internalTool, baseline: .measuredComparable), "Measured work needs measurements")
        XCTAssertNil(rubric.hours(size: "xxl", standard: .internalTool, baseline: .historical))
    }

    static func receipt() -> WorkspaceReceipt {
        WorkspaceReceipt(eventID: "test:codex:s:t:1", observedAt: Date(timeIntervalSince1970: 1_767_603_600),
                         producer: .init(adapter: "test", adapterVersion: "1"), provider: "codex", sessionID: "codex:s", nativeTurnID: "t",
                         unit: .modelStep, time: .init(basis: .providerEvent, at: Date(timeIntervalSince1970: 1_767_603_000)),
                         model: "example-model", usage: .init(input: TokenQuantity("8"), cachedInput: TokenQuantity("5"), output: TokenQuantity("2"),
                                                              reasoning: TokenQuantity("1"), total: TokenQuantity("10"), inputIncludesCachedInput: true,
                                                              provenance: .providerReported, completeness: .complete),
                         evidence: "synthetic/1")
    }
}
