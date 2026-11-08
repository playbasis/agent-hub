import Foundation
import XCTest
@testable import WorkspaceContracts

/// The shared fixtures in tests/fixtures/workspace-economics/v1 are the
/// cross-platform contract: every reader (this package, the app,
/// scripts/check-workspace-contracts.py) must reach the same results.
/// Regenerate with WORKSPACE_CONTRACTS_WRITE_FIXTURES=1.
final class ContractFixtureTests: XCTestCase {
    static let root = (0 ..< 5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
    static let fixtures = root.appendingPathComponent("tests/fixtures/workspace-economics/v1")
    static let schemas = root.appendingPathComponent("schemas")
    static let base = Date(timeIntervalSince1970: 1_767_603_600) // 2026-01-05T09:00:00Z, a Monday

    func testFixturesFoldToTheExpectedTotals() throws {
        if ProcessInfo.processInfo.environment["WORKSPACE_CONTRACTS_WRITE_FIXTURES"] == "1" { try Self.writeFixtures() }
        let expected = try XCTUnwrap(try ContractJSONValue.parse(Data(contentsOf: Self.fixtures.appendingPathComponent("expected.json"))).objectValue)
        XCTAssertEqual(Set(expected.keys), Set(Self.cases.map(\.name)))
        for (name, _) in Self.cases {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".jsonl"))
            let lines = WorkspaceReceiptLines.decode(data)
            XCTAssertEqual(lines.errors, [], name)
            var ledger = WorkspaceReceiptLedger()
            let ingest = ledger.ingest(lines.receipts)
            XCTAssertEqual(try Self.summary(name, ingest: ingest, ledger: ledger), expected[name], name)
            // Replaying the whole file again changes nothing.
            let replay = ledger.ingest(lines.receipts)
            XCTAssertEqual(replay.accepted + replay.superseded, 0, "\(name) replay")
            XCTAssertEqual(try Self.summary(name, ingest: ingest, ledger: ledger), expected[name], "\(name) after replay")
        }
    }

    func testFixtureLinesConformToTheReceiptSchema() throws {
        var check = JSONSchemaCheck(directory: Self.schemas)
        for (name, _) in Self.cases {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".jsonl"))
            for (number, line) in data.split(separator: UInt8(ascii: "\n")).enumerated() {
                let failures = try check.validate(Data(line), against: "workspace-receipt-v1.schema.json")
                XCTAssertEqual(failures, [], "\(name) line \(number + 1)")
            }
        }
        // The schema rejects what readers must refuse.
        var object = try XCTUnwrap(try ContractJSONValue.parse(ContractJSON.encoder.encode(ContractPrimitiveTests.receipt().sealed())).objectValue)
        object["unexpected"] = .bool(true)
        XCTAssertFalse(try check.validate(.object(object), against: "workspace-receipt-v1.schema.json").isEmpty)
        object.removeValue(forKey: "unexpected")
        object["x-allowed"] = .bool(true)
        XCTAssertEqual(try check.validate(.object(object), against: "workspace-receipt-v1.schema.json"), [])
        var usage = try XCTUnwrap(object["usage"]?.objectValue)
        usage["total"] = .number("10")
        object["usage"] = .object(usage)
        XCTAssertFalse(try check.validate(.object(object), against: "workspace-receipt-v1.schema.json").isEmpty, "Token counts are strings")
    }

    func testRecordsConformToTheirSchemasAndValidationRules() throws {
        var check = JSONSchemaCheck(directory: Self.schemas)
        let outcome = Self.outcome()
        XCTAssertNoThrow(try outcome.validate())
        XCTAssertEqual(try check.validate(ContractJSON.encoder.encode(outcome), against: "accepted-outcome-v1.schema.json"), [])
        let assessment = Self.assessment(outcome)
        XCTAssertNoThrow(try assessment.validate())
        XCTAssertEqual(try check.validate(ContractJSON.encoder.encode(assessment), against: "effort-assessment-v1.schema.json"), [])

        var withdrawn = outcome
        withdrawn.decision = .withdrawn
        XCTAssertThrowsError(try withdrawn.validate(), "A first revision can't withdraw")
        XCTAssertFalse(try check.validate(ContractJSON.encoder.encode(withdrawn), against: "accepted-outcome-v1.schema.json").isEmpty)
        var badCommit = outcome
        badCommit.evidence = [OutcomeEvidence(kind: .commit, repositoryID: nil, ref: "a26e5a7")]
        XCTAssertThrowsError(try badCommit.validate(), "Commits name their repository")
        XCTAssertFalse(try check.validate(ContractJSON.encoder.encode(badCommit), against: "accepted-outcome-v1.schema.json").isEmpty)
        var unknownTime = outcome
        unknownTime.operatorTime = OperatorTime(state: .unknown, lowHours: 1, highHours: 2, basis: .userEstimate)
        XCTAssertThrowsError(try unknownTime.validate(), "Unknown time carries no hours")
        XCTAssertFalse(try check.validate(ContractJSON.encoder.encode(unknownTime), against: "accepted-outcome-v1.schema.json").isEmpty)

        var model = assessment
        model.assessor = .init(kind: .model, identity: "example-model", rubricVersion: nil)
        model.method = .expertJudgment; model.sizeClass = nil
        XCTAssertThrowsError(try model.validate(), "Model assessments name their rubric")
        XCTAssertFalse(try check.validate(ContractJSON.encoder.encode(model), against: "effort-assessment-v1.schema.json").isEmpty)
        var inverted = assessment
        inverted.hours = EstimateRange(low: 10, base: 5, high: 20)
        XCTAssertThrowsError(try inverted.validate())
    }

    func testBundleVerificationRefusesTamperedExtraAndLinkedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = Data(#"{"schemaVersion":"economic-report/1"}"#.utf8), briefing = Data("# Briefing\n".utf8)
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let manifest = ReportBundleManifest(reportID: digest, createdAt: Self.base, contentLevel: .local, producer: .init(name: "test", version: "1"),
                                            files: [ReportBundleManifest.entry(path: "report.json", data: report), ReportBundleManifest.entry(path: "briefing.md", data: briefing)])
        try report.write(to: folder.appendingPathComponent("report.json"))
        try briefing.write(to: folder.appendingPathComponent("briefing.md"))
        try ContractJSON.encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try ReportBundleManifest.verify(directory: folder), manifest)
        var check = JSONSchemaCheck(directory: Self.schemas)
        XCTAssertEqual(try check.validate(ContractJSON.encoder.encode(manifest), against: "report-bundle-v1.schema.json"), [])

        try Data("# Changed\n".utf8).write(to: folder.appendingPathComponent("briefing.md"))
        XCTAssertThrowsError(try ReportBundleManifest.verify(directory: folder))
        try briefing.write(to: folder.appendingPathComponent("briefing.md"))
        try Data().write(to: folder.appendingPathComponent("run-me.sh"))
        XCTAssertThrowsError(try ReportBundleManifest.verify(directory: folder), "Unlisted files are refused")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("run-me.sh"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("briefing.md"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("briefing.md"), withDestinationURL: folder.appendingPathComponent("report.json"))
        XCTAssertThrowsError(try ReportBundleManifest.verify(directory: folder), "Links are never followed")

        var traversal = manifest
        traversal.files.append(ReportBundleManifest.File(path: "../outside.json", bytes: 1, sha256: digest, schemaVersion: "unknown"))
        XCTAssertThrowsError(try traversal.validate())
    }

    // MARK: Fixture cases

    static let cases: [(name: String, totals: [(label: String, scope: WorkspaceReceipt.Scope, from: TimeInterval?, to: TimeInterval?)])] = [
        ("codex-cumulative-usage", [("all", .localNativeHistory, nil, nil), ("window", .localNativeHistory, 60, 200)]),
        ("claude-partial-history", [("all", .localNativeHistory, nil, nil)]),
        ("concurrent-agents", [("all", .localNativeHistory, nil, nil), ("window", .localNativeHistory, 300, 900)]),
        ("duplicate-imports-and-corrections", [("all", .localNativeHistory, nil, nil)]),
        ("workspaceops-receipts", [("all", .localNativeHistory, nil, nil), ("account", .providerAccount, nil, nil)]),
    ]

    static func summary(_ fixture: String, ingest: WorkspaceReceiptLedger.IngestResult, ledger: WorkspaceReceiptLedger) throws -> ContractJSONValue {
        var object: [String: ContractJSONValue] = [
            "ingest": .object([
                "accepted": .number(String(ingest.accepted)), "duplicates": .number(String(ingest.duplicates)),
                "superseded": .number(String(ingest.superseded)), "stale": .number(String(ingest.stale)),
                "conflicts": .number(String(ingest.conflicts.count)), "rejected": .number(String(ingest.rejected.count)),
            ]),
        ]
        for total in cases.first(where: { $0.name == fixture })!.totals {
            let value = ledger.totals(scope: total.scope, from: total.from.map { base.addingTimeInterval($0) }, to: total.to.map { base.addingTimeInterval($0) })
            func optional(_ text: String?) -> ContractJSONValue { text.map(ContractJSONValue.string) ?? .null }
            func optionalNumber(_ number: Int64?) -> ContractJSONValue { number.map { .number(String($0)) } ?? .null }
            object[total.label] = .object([
                "receipts": .number(String(value.receipts)), "tokens": optional(value.tokens?.description), "output": optional(value.output?.description),
                "partialReceipts": .number(String(value.partialReceipts)), "tokensArePartial": .bool(value.tokensArePartial),
                "seriesResets": .number(String(value.seriesResets)), "wallClockSpanSeconds": optionalNumber(value.wallClockSpanSeconds),
                "activeSeconds": optionalNumber(value.activeSeconds), "agentSeconds": optionalNumber(value.agentSeconds),
                "toolCalls": value.toolCalls.map { .number(String($0)) } ?? .null, "sessions": .number(String(value.sessions)),
            ])
        }
        return .object(object)
    }

    static func outcome() -> AcceptedOutcomeRecord {
        let id = "6f9a3b52-1d4e-4c7a-9b1e-2f3a4b5c6d7e"
        return AcceptedOutcomeRecord(id: id, outcomeID: id, createdAt: base, decision: .accepted, title: "Example capability",
                                     deliveryStandard: .internalTool,
                                     evidence: [.init(kind: .commit, repositoryID: "repo-1", ref: "a26e5a7"), .init(kind: .session, ref: "claude:example")],
                                     landedAt: base, operatorTime: .known(low: ExactDecimal("1.5")!, high: 3), candidateID: "cand-0123456789abcdef")
    }

    static func assessment(_ outcome: AcceptedOutcomeRecord) -> EffortAssessmentRecord {
        EffortAssessmentRecord(id: "0d1e2f3a-4b5c-4d6e-8f70-8192a3b4c5d6", outcomeID: outcome.outcomeID, outcomeRevisionID: outcome.id, createdAt: base,
                               assessor: .init(kind: .human, identity: "user", rubricVersion: "hub-size-rubric/1"), baseline: .historical,
                               deliveryStandard: .internalTool, method: .sizeClass, sizeClass: "m", hours: EstimateRange(low: 16, base: 28, high: 48),
                               assumptions: ["Comparable developer knows Swift"], rationale: "Three components and a schema.", confidence: .medium)
    }

    // MARK: Generator

    static func writeFixtures() throws {
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
        func q(_ value: String?) -> TokenQuantity? { value.flatMap(TokenQuantity.init) }
        func receipt(_ fixture: String, _ id: String, revision: Int = 1, observed: TimeInterval = 3_600, provider: String, session: String,
                     unit: WorkspaceReceipt.Unit, accumulation: WorkspaceReceipt.Accumulation = .incremental, scope: WorkspaceReceipt.Scope = .localNativeHistory,
                     time: WorkspaceReceipt.Time, total: String?, output: String?, provenance: WorkspaceReceipt.Provenance = .providerReported,
                     completeness: WorkspaceReceipt.Completeness = .complete, tools: Int? = nil, producer: String = "fixture") -> WorkspaceReceipt {
            var value = WorkspaceReceipt(eventID: "fixture:\(fixture):\(id)", revision: revision, observedAt: at(observed),
                                         producer: .init(adapter: producer, adapterVersion: "1"), provider: provider, sessionID: session,
                                         nativeTurnID: id, unit: unit, accumulation: accumulation, scope: scope, time: time,
                                         model: "example-model", usage: .init(output: q(output), total: q(total), provenance: provenance, completeness: completeness),
                                         aggregates: tools.map { WorkspaceReceipt.Aggregates(toolCalls: $0) }, evidence: "synthetic-fixture/1")
            value.contentDigest = (try? value.computedDigest()) ?? ""
            return value
        }
        func event(_ seconds: TimeInterval) -> WorkspaceReceipt.Time { .init(basis: .providerEvent, at: at(seconds)) }
        func span(_ start: TimeInterval, _ end: TimeInterval) -> WorkspaceReceipt.Time { .init(basis: .nativeInterval, start: at(start), end: at(end)) }
        func line(_ value: WorkspaceReceipt, extensions: [String: ContractJSONValue] = [:]) throws -> String {
            var object = try XCTUnwrap(try ContractJSONValue.parse(ContractJSON.encoder.encode(value)).objectValue)
            for (key, value) in extensions { object[key] = value }
            return String(decoding: try CanonicalJSON.data(.object(object)), as: UTF8.self)
        }

        let c = "codex-cumulative-usage"
        let e2 = receipt(c, "e2", provider: "codex", session: "codex:session-a", unit: .modelStep, accumulation: .cumulative, time: event(60), total: "2500", output: "220")
        let codex = [
            receipt(c, "e1", provider: "codex", session: "codex:session-a", unit: .modelStep, accumulation: .cumulative, time: event(0), total: "1000", output: "100"),
            e2, e2,
            receipt(c, "e3", provider: "codex", session: "codex:session-a", unit: .modelStep, accumulation: .cumulative, time: event(120), total: "2500", output: "220"),
            receipt(c, "e4", provider: "codex", session: "codex:session-a", unit: .modelStep, accumulation: .cumulative, time: event(180), total: "4000", output: "400"),
            receipt(c, "e5", provider: "codex", session: "codex:session-a", unit: .modelStep, accumulation: .cumulative, time: event(240), total: "600", output: "50"),
        ]
        let p = "claude-partial-history"
        let claude = [
            receipt(p, "s1", provider: "claude", session: "claude:session-b", unit: .modelStep, time: event(0), total: "300", output: "40"),
            receipt(p, "s2", provider: "claude", session: "claude:session-b", unit: .modelStep, time: event(30), total: "500", output: "60", completeness: .partial),
            receipt(p, "s3", provider: "claude", session: "claude:session-b", unit: .modelStep, time: event(60), total: nil, output: nil, provenance: .unavailable, completeness: .unknown),
            receipt(p, "s4", provider: "claude", session: "claude:session-b", unit: .modelStep, time: event(90), total: "200", output: "20", provenance: .estimated),
        ]
        let a = "concurrent-agents"
        let concurrent = [
            receipt(a, "c1-t1", provider: "codex", session: "codex:c1", unit: .conversationTurn, time: span(0, 600), total: "100", output: "10", tools: 3),
            receipt(a, "c1-t2", provider: "codex", session: "codex:c1", unit: .conversationTurn, time: span(300, 900), total: "50", output: "5", tools: 2),
            receipt(a, "c2-t1", provider: "claude", session: "claude:c2", unit: .conversationTurn, time: span(600, 1_200), total: "70", output: "7"),
        ]
        let d = "duplicate-imports-and-corrections"
        let d1 = receipt(d, "d1", provider: "codex", session: "codex:d", unit: .modelStep, time: event(0), total: "100", output: "10")
        let d1r2 = receipt(d, "d1", revision: 2, observed: 7_200, provider: "codex", session: "codex:d", unit: .modelStep, time: event(0), total: "120", output: "12")
        var d1r2Later = d1r2
        d1r2Later.observedAt = at(10_800)
        let d2 = receipt(d, "d2", provider: "codex", session: "codex:d", unit: .modelStep, time: event(10), total: "50", output: "5")
        let d2Conflict = receipt(d, "d2", provider: "codex", session: "codex:d", unit: .modelStep, time: event(10), total: "55", output: "5")
        var d3 = receipt(d, "d3", provider: "codex", session: "codex:d", unit: .modelStep, time: event(20), total: "70", output: "7")
        d3.contentDigest = "sha256:" + String(repeating: "0", count: 64)
        let duplicates = [d1, d1, d1r2, d1, d2, d2Conflict, d3, d1r2Later]
        let w = "workspaceops-receipts"
        let ops = [
            receipt(w, "r1", provider: "gemini", session: "gemini:run-7", unit: .requestAttempt, time: event(0), total: "1000", output: "100", tools: 4, producer: "workspaceops"),
            receipt(w, "r2", provider: "gemini", session: "gemini:run-7", unit: .requestAttempt, time: event(30), total: "2000", output: "150", tools: 1, producer: "workspaceops"),
            receipt(w, "acct", provider: "gemini", session: "gemini:account", unit: .session, scope: .providerAccount, time: event(60),
                    total: "9223372036854775807", output: "9223372036854775807", producer: "workspaceops"),
        ]
        let files: [(String, [String])] = [
            (c, try codex.map { try line($0) }),
            (p, try claude.map { try line($0) }),
            (a, try concurrent.map { try line($0) }),
            (d, try duplicates.map { try line($0) }),
            (w, try ops.enumerated().map { index, value in
                try line(value, extensions: index == 0 ? ["x-workspaceops-run": .string("run-7"), "x-workspaceops-cost-note": .string("ignored by readers")] : [:])
            }),
        ]
        var expected: [String: ContractJSONValue] = [:]
        for (name, lines) in files {
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            try data.write(to: fixtures.appendingPathComponent(name + ".jsonl"))
            var ledger = WorkspaceReceiptLedger()
            let ingest = ledger.ingest(WorkspaceReceiptLines.decode(data).receipts)
            expected[name] = try summary(name, ingest: ingest, ledger: ledger)
        }
        let pretty = try ContractJSON.prettyEncoder.encode(JSONPassthrough(.object(expected)))
        try pretty.write(to: fixtures.appendingPathComponent("expected.json"))
    }
}

/// Encodes a parsed JSON value as it is (for the expected-results file).
private struct JSONPassthrough: Encodable {
    let value: ContractJSONValue
    init(_ value: ContractJSONValue) { self.value = value }
    func encode(to encoder: Encoder) throws {
        switch value {
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let flag): var c = encoder.singleValueContainer(); try c.encode(flag)
        case .number(let text): var c = encoder.singleValueContainer(); try c.encode(Int64(text)!)
        case .string(let text): var c = encoder.singleValueContainer(); try c.encode(text)
        case .array(let items): var c = encoder.unkeyedContainer(); for item in items { try c.encode(JSONPassthrough(item)) }
        case .object(let fields):
            var c = encoder.container(keyedBy: Key.self)
            for (key, item) in fields { try c.encode(JSONPassthrough(item), forKey: Key(stringValue: key)!) }
        }
    }
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
