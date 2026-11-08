@testable import BridgeCore
import Foundation
import XCTest

final class FastISO8601Tests: XCTestCase {
    func testFastPathMatchesTheFormatterAndDefersUnusualForms() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 20_000 {
            let date = Date(timeIntervalSince1970: Double.random(in: -1_000_000_000 ... 4_000_000_000, using: &generator))
            for text in [ISO8601.withFractional.string(from: date), ISO8601.withoutFractional.string(from: date)] {
                let expected = text.count == 24 ? ISO8601.withFractional.date(from: text) : ISO8601.withoutFractional.date(from: text)
                XCTAssertEqual(ISO8601.fastDate(text), expected, text)
            }
        }
        // Zone offsets, other fraction lengths and lenient calendar dates use the formatter.
        for text in ["2026-11-06T07:12:34+07:00", "2026-11-06T07:12:34.5Z", "2026-02-29T00:00:00Z", "2026-11-06 07:12:34Z"] {
            XCTAssertNil(ISO8601.fastDate(text), text)
            XCTAssertEqual(ISO8601.date(text), ISO8601.withFractional.date(from: text) ?? ISO8601.withoutFractional.date(from: text), text)
        }
        XCTAssertEqual(ISO8601.fastDate("1969-12-31T23:59:59.999Z"), ISO8601.withFractional.date(from: "1969-12-31T23:59:59.999Z"))
    }
}

final class ActivityReadCacheTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ id: String, turns: Int, observed: Double) -> ActivitySession {
        let values = (0 ..< turns).map { index in
            ActivityTurn(id: "\(id):\(index)", startedAt: base.addingTimeInterval(Double(index) * 60), completedAt: base.addingTimeInterval(Double(index) * 60 + 30),
                         status: "completed", usage: TokenUsage(total: 10, provenance: .providerReported))
        }
        return ActivitySession(id: id, provider: .codex, nativeID: id, title: id, projectPath: "/p", createdAt: base,
                               updatedAt: base.addingTimeInterval(Double(turns) * 60), observedAt: base.addingTimeInterval(observed),
                               turns: values, historyComplete: true, source: "fixture")
    }

    func testOverviewReusesUnchangedSessionsAndSeesEveryWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("read-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.sqlite")
        let health = ActivitySourceHealth(id: "codex", status: "ready", message: "Fixture")
        let app = try ActivityDatabase(url: url)
        try app.merge([ActivityCollection(sessions: [session("a", turns: 1, observed: 1), session("b", turns: 1, observed: 1)], health: health)], now: base)
        XCTAssertEqual(try app.overview().sessions.first { $0.id == "a" }?.turns.count, 1)

        // This connection's own write is seen.
        try app.merge([ActivityCollection(sessions: [session("a", turns: 2, observed: 2)], health: health)], now: base)
        let afterOwnWrite = try app.overview()
        XCTAssertEqual(afterOwnWrite.sessions.first { $0.id == "a" }?.turns.count, 2)
        XCTAssertEqual(afterOwnWrite.sessions.first { $0.id == "b" }?.turns.count, 1)

        // Another connection's write (the CLI) is seen too.
        let cli = try ActivityDatabase(url: url)
        try cli.merge([ActivityCollection(sessions: [session("b", turns: 3, observed: 3), session("c", turns: 1, observed: 3)], health: health)], now: base)
        let afterOtherWrite = try app.overview()
        XCTAssertEqual(afterOtherWrite.sessions.first { $0.id == "b" }?.turns.count, 3)
        XCTAssertNotNil(afterOtherWrite.sessions.first { $0.id == "c" })
        XCTAssertEqual(try app.overview(), afterOtherWrite, "An unchanged database reads back identically")
    }
}

final class AccountingDigestTests: XCTestCase {
    func testFingerprintIsTakenWhenTheReportIsAssembled() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let usage = TokenUsage(total: 42, provenance: .providerReported)
        let step = ActivityModelStep(id: "digest-step", timestamp: now.addingTimeInterval(-5), model: "fixture-model", usage: usage)
        let turn = ActivityTurn(id: "digest-turn", startedAt: now.addingTimeInterval(-10), completedAt: now.addingTimeInterval(-1),
                                usage: usage, modelSteps: [step], modelStepsComplete: true)
        let session = ActivitySession(id: "digest-session", provider: .codex, nativeID: "n", title: "t", projectPath: "/p",
                                      createdAt: now.addingTimeInterval(-10), updatedAt: now, observedAt: now, turns: [turn],
                                      historyComplete: true, source: "fixture")
        let overview = ActivityOverview(generatedAt: now, sessions: [session])
        let report = ActivityAccounting.build(overview: overview, from: now.addingTimeInterval(-3_600), to: now)
        var edited = ActivityAccounting.build(overview: overview, from: now.addingTimeInterval(-3_600), to: now)
        edited.warnings.append("A later note")
        XCTAssertEqual(edited.evidenceDigest, report.evidenceDigest, "Later edits don't change the assembled fingerprint")
        XCTAssertEqual(report.evidenceDigest.count, 64)
        let decoded = try BridgeJSON.decoder.decode(ActivityAccounting.Report.self, from: BridgeJSON.compactEncoder.encode(report))
        XCTAssertEqual(decoded.evidenceDigest, report.evidenceDigest)
        let json = try XCTUnwrap(String(data: BridgeJSON.compactEncoder.encode(report), encoding: .utf8))
        XCTAssertTrue(json.contains("\"evidenceDigest\":\"\(report.evidenceDigest)\""))
        var fixed = report
        fixed.evidenceDigest = "custom"
        XCTAssertEqual(fixed.evidenceDigest, "custom")
        XCTAssertEqual(report.evidenceDigest.count, 64, "Copies don't share an override")
    }
}
