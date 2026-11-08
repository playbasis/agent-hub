@testable import BridgeCore
import Foundation
import XCTest

final class ProjectStepsTests: XCTestCase {
    private let base = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    private func usage(_ total: Int?) -> TokenUsage {
        TokenUsage(input: total, output: 0, cachedInput: 0, cacheWriteInput: 0, reasoning: 0, total: total,
                   provenance: total == nil ? .unavailable : .providerReported)
    }
    private func step(_ id: String, at seconds: Double) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: date(seconds), model: "gpt-6.1-terra", usage: usage(10), usageIsPartial: false)
    }
    private func turn(_ id: String, start: Double, end: Double?, steps: [ActivityModelStep]) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: date(start), completedAt: end.map(date), status: end == nil ? "running" : "completed",
                     usage: usage(nil), modelSteps: steps, modelStepsComplete: true)
    }
    private func session(_ id: String, project: String?, parent: String? = nil, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: .codex, nativeID: id, title: id, projectPath: project,
                        createdAt: date(-86_400), updatedAt: date(10_000), observedAt: date(10_000),
                        parentSessionID: parent, turns: turns, historyComplete: true, source: "fixture")
    }

    func testProjectBarsAddUpToTheSeriesAndKeepUnknownBucketsApart() throws {
        let alpha = turn("alpha-native", start: 0, end: 7_000, steps: [step("a1", at: 100), step("a2", at: 200), step("a3", at: 7_200)])
        let beta = turn("beta-native", start: 3_700, end: 3_900, steps: [step("b1", at: 3_800)])
        let unattributed = turn("none-native", start: 7_300, end: 7_400, steps: [step("n1", at: 7_350)])
        let shared = turn("shared-native", start: 100, end: 300, steps: [step("s1", at: 150)])
        let snapshot = ActivityOverview(generatedAt: date(10_800), sessions: [
            session("alpha", project: "/alpha", turns: [alpha, shared]),
            session("copy", project: "/copy", parent: "alpha", turns: [shared]),
            session("beta", project: "/beta", turns: [beta]),
            session("none", project: nil, turns: [unattributed]),
        ], sources: [ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: date(10_800), message: "Fixture")])
        let report = ActivityAccounting.build(overview: snapshot, from: date(0), to: date(10_800))
        let series = report.series(granularity: .hour, timeZone: utc)
        let projects = ActivityAccounting.modelStepsByProject(report, series: series)

        XCTAssertEqual(series.points.count, 3)
        for index in series.points.indices {
            XCTAssertEqual(projects.values.reduce(0) { $0 + $1.steps[index] }, series.points[index].modelStepCount,
                           "per-project bars must reconcile with the canonical series in every bucket")
        }
        XCTAssertEqual(projects["/alpha"]?.steps, [3, 0, 1], "copied history is owned once, by its original session")
        XCTAssertNil(projects["/copy"], "a child that only copied parent history has no work of its own")
        XCTAssertEqual(projects["/beta"]?.steps, [0, 1, 0])
        XCTAssertEqual(projects["/beta"]?.hasRecords, [false, true, false], "a bucket without records is unknown, not zero")
        XCTAssertEqual(projects["/alpha"]?.hasRecords, [true, true, true], "a running request spanning the hour is a record there")
        XCTAssertEqual(projects[""]?.steps, [0, 0, 1], "no recorded folder stays a separate empty key, never a guessed project")
        let sessions = ActivityAccounting.modelStepsBySession(report, series: series)
        for index in series.points.indices {
            XCTAssertEqual(sessions.values.reduce(0) { $0 + $1.steps[index] }, series.points[index].modelStepCount)
        }
        XCTAssertEqual(sessions["alpha"]?.steps, [3, 0, 1])
        XCTAssertNil(sessions["copy"], "copied parent history is not the child's work")
    }

    func testAnEmptySeriesHasNoProjects() {
        let snapshot = ActivityOverview(generatedAt: date(10), sessions: [], sources: [])
        let report = ActivityAccounting.build(overview: snapshot, from: date(0), to: date(10))
        XCTAssertTrue(ActivityAccounting.modelStepsByProject(report, series: report.series(granularity: .hour, timeZone: utc)).values
            .allSatisfy { $0.steps.allSatisfy { $0 == 0 } })
    }
}
