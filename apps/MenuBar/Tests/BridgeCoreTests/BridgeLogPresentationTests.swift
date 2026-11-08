import Foundation
import XCTest
@testable import BridgeCore

final class BridgeLogPresentationTests: XCTestCase {
    func testLevelAliasesAndSearchIntersectWithoutChangingChronology() {
        let records = [entry("started", level: "INFO"), entry("slow provider", level: "WARN", fields: #"{"provider":"Claude"}"#), entry("failed", level: "FAULT")]
        XCTAssertEqual(BridgeLogPresentation.entries(records, query: " CLAUDE ", level: .warnings).map(\.message), ["slow provider"])
        XCTAssertEqual(BridgeLogPresentation.entries(records, level: .errors).map(\.message), ["failed"])
        XCTAssertEqual(BridgeLogPresentation.entries(records, query: " \n ").map(\.message), ["started", "slow provider", "failed"])
        XCTAssertTrue(BridgeLogPresentation.entries(records, query: "claude", level: .info).isEmpty)
        XCTAssertTrue(BridgeLogPresentation.Level.debug.includes("TRACE"))
        XCTAssertTrue(BridgeLogPresentation.Level.raw.includes("RAW"))
    }

    func testNestedSecretsRedactedButUsageCountersRemainIntact() throws {
        let raw = #"{"timestamp":"2026-11-02","level":"INFO","message":"Project /Users/alex/client","fields":{"api_key":"secret-value","nested":[{"refreshToken":"refresh-value","input_tokens":120,"output_tokens":7,"authorization":"Bearer auth-value"}],"cookie":"cookie-value","headers":{"X-Api-Key":"header-value","Set-Cookie":"set-cookie-value"}}}"#
        let original = entry("Project /Users/alex/client", fields: #"{"password":"pass-value","total_tokens":127}"#, raw: raw)
        let sanitized = BridgeLogPresentation.sanitized(original)
        for value in ["secret-value", "refresh-value", "auth-value", "cookie-value", "header-value", "set-cookie-value", "pass-value", "/Users/alex"] {
            XCTAssertFalse(sanitized.rawLine.contains(value))
            XCTAssertFalse(sanitized.fieldsSummary?.contains(value) ?? false)
            XCTAssertFalse(sanitized.message.contains(value))
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sanitized.rawLine.utf8)) as? [String: Any])
        let fields = try XCTUnwrap(object["fields"] as? [String: Any])
        let nested = try XCTUnwrap(fields["nested"] as? [[String: Any]])
        XCTAssertEqual(nested[0]["input_tokens"] as? Int, 120)
        XCTAssertEqual(nested[0]["output_tokens"] as? Int, 7)
        XCTAssertEqual(fields["api_key"] as? String, "[REDACTED]")
        XCTAssertEqual(original.rawLine, raw, "Presentation must never rewrite the audit source")
        XCTAssertFalse(sanitized.id.contains("secret"))
    }

    func testCopyBoundaryRedactsRawAndMalformedRecords() throws {
        let malformed = entry(#"password="hello world" authorization: BearerToken123 path=/Users/alex/repo"#, level: "RAW")
        let structured = entry("Connected", raw: #"{"message":"Connected","fields":{"client_secret":"private-client-value","tokens":25}}"#)
        let copy = BridgeLogPresentation.copyText([malformed, structured])
        for secret in ["hello world", "BearerToken123", "private-client-value", "/Users/alex"] { XCTAssertFalse(copy.contains(secret)) }
        let lines = copy.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)))
        XCTAssertEqual(BridgeLogPresentation.copyText([]), "")
    }

    func testOversizedAndDeeplyNestedFieldsHaveBoundedPresentation() throws {
        var nested: Any = "private leaf"
        for _ in 0 ..< 25 { nested = ["child": nested] }
        let source: [String: Any] = ["message": "large", "fields": ["long": String(repeating: "x", count: 20_000), "deep": nested]]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self)
        let sanitized = BridgeLogPresentation.sanitized(entry("large", raw: raw))
        XCTAssertLessThan(sanitized.rawLine.count, 6_000)
        XCTAssertTrue(sanitized.rawLine.contains("[TRUNCATED]"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(sanitized.rawLine.utf8)))
    }

    func testDisplayCannotSearchSecretThatWasRemoved() {
        let sanitized = BridgeLogPresentation.sanitized(entry("token=private-value"))
        XCTAssertTrue(BridgeLogPresentation.entries([sanitized], query: "private-value").isEmpty)
        XCTAssertEqual(BridgeLogPresentation.entries([sanitized], query: "REDACTED").count, 1)
    }

    func testLargeFieldSummaryRemainsValidJSONAndHasReadableDetails() throws {
        let fields = #"{"long":""# + String(repeating: "x", count: 20_000) + #"","output_tokens":17}"#
        let sanitized = BridgeLogPresentation.sanitized(entry("large fields", fields: fields))
        let summary = try XCTUnwrap(sanitized.fieldsSummary)
        XCTAssertLessThanOrEqual(summary.count, 4_096)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(summary.utf8)))
        XCTAssertFalse(BridgeLogPresentation.fieldPairs(summary).isEmpty, "Oversized fields must not silently hide every detail")
    }

    func testProviderPrefixedCredentialKeysAreRedactedWithoutHidingTokenCounts() throws {
        let fields = #"{"OPENAI_API_KEY":"private-key-value","ANTHROPIC_AUTH_TOKEN":"private-auth-value","GITHUB_TOKEN":"private-github-value","database_secret_value":"private-database-value","input_tokens":23,"reasoning_tokens":7,"total_tokens":30}"#
        let sanitized = BridgeLogPresentation.sanitized(entry("credentials", fields: fields, raw: fields))
        let summary = try XCTUnwrap(sanitized.fieldsSummary)
        for value in ["private-key-value", "private-auth-value", "private-github-value", "private-database-value"] {
            XCTAssertFalse(summary.contains(value))
            XCTAssertFalse(sanitized.rawLine.contains(value))
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
        XCTAssertEqual(object["input_tokens"] as? Int, 23)
        XCTAssertEqual(object["reasoning_tokens"] as? Int, 7)
        XCTAssertEqual(object["total_tokens"] as? Int, 30)
    }

    func testWideNestedObjectsAndEscapedValuesHaveBoundedValidPresentation() throws {
        let fields = Dictionary(uniqueKeysWithValues: (0..<500).map { ("field_\($0)", String(repeating: "\u{0001}", count: 100)) })
        let source = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let sanitized = BridgeLogPresentation.sanitized(entry("wide event", fields: source, raw: source))
        XCTAssertLessThanOrEqual(sanitized.rawLine.count, 16_384)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sanitized.fieldsSummary).count, 4_096)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(sanitized.rawLine.utf8)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(sanitized.fieldsSummary).utf8)))
        XCTAssertTrue(sanitized.rawLine.contains("TRUNCATED"))
    }

    private func entry(_ message: String, level: String = "INFO", fields: String? = nil, raw: String? = nil) -> BridgeLogEntry {
        BridgeLogEntry(id: "id-\(message)", timestamp: "2026-11-02T10:00:00Z", level: level, message: message, fieldsSummary: fields, rawLine: raw ?? message, isStructured: raw != nil)
    }
}
