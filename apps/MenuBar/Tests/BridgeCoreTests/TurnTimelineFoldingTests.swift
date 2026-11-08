@testable import BridgeCore
import Foundation
import XCTest

final class TurnTimelineFoldingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func op(_ id: String, _ kind: WorkEvidenceItem.Kind, title: String, at seconds: Double,
                    outcome: WorkOutcomeSignals.Outcome? = nil) -> TurnTimeline.Entry {
        let item = WorkEvidenceItem(id: id, kind: kind, title: title, status: "completed", timestamp: base.addingTimeInterval(seconds))
        return .operation(.init(id: "op:" + id, kind: kind, title: title, timestamp: base.addingTimeInterval(seconds), outcome: outcome, records: [item]))
    }
    private func steps(_ id: String, count: Int, at seconds: Double) -> TurnTimeline.Entry {
        let list = (0 ..< count).map { ActivityModelStep(id: "\(id)-\($0)", timestamp: base.addingTimeInterval(seconds + Double($0)), model: "gpt-6.1-terra",
                                                        usage: TokenUsage(input: nil, output: nil, cachedInput: nil, cacheWriteInput: nil, reasoning: nil, total: nil, provenance: .unavailable),
                                                        usageIsPartial: false) }
        return .steps(.init(id: "steps:" + id, steps: list, first: list.first?.timestamp, last: list.last?.timestamp))
    }

    func testAlternatingHandOffsFoldIntoOneRunAndKeepEveryEntryInOrder() throws {
        let entries: [TurnTimeline.Entry] = [
            steps("lead", count: 208, at: 0),
            op("h1", .handoff, title: "Agent handoff", at: 300), steps("a", count: 1, at: 310),
            op("h2", .handoff, title: "Agent handoff", at: 320), steps("b", count: 1, at: 330),
            op("h3", .handoff, title: "Agent handoff", at: 340), steps("c", count: 3, at: 350),
            op("reply", .response, title: "Agent response", at: 360),
            op("h4", .handoff, title: "Agent handoff", at: 370),
        ]
        let folded = TurnTimeline.fold(entries)
        XCTAssertEqual(folded.map(\.id), ["steps:lead", "repeat:op:h1", "steps:c", "op:reply", "op:h4"],
                       "steps after the last hand-off of a run, a reply and a lone hand-off keep their own rows")
        guard case let .repeats(run) = folded[1] else { return XCTFail("expected a folded run") }
        XCTAssertEqual(run.operationCount, 3)
        XCTAssertEqual(run.stepCount, 2)
        XCTAssertEqual(run.entries.map(\.id), ["op:h1", "steps:a", "op:h2", "steps:b", "op:h3"])
        XCTAssertEqual(run.first, base.addingTimeInterval(300))
        XCTAssertEqual(run.last, base.addingTimeInterval(340))
        let flattened = folded.flatMap { item -> [String] in
            if case let .repeats(run) = item { return run.entries.map(\.id) }
            return [item.id]
        }
        XCTAssertEqual(flattened, entries.map(\.id), "folding never drops or reorders evidence")
    }

    func testToolCallsFailuresAndShortRunsNeverFold() {
        let tools: [TurnTimeline.Entry] = (0 ..< 5).map { op("t\($0)", .toolCall, title: "exec_command", at: Double($0), outcome: $0 == 2 ? .failure : .success) }
        XCTAssertEqual(TurnTimeline.fold(tools).map(\.id), tools.map(\.id), "tool executions carry outcomes and always keep their rows")
        let short: [TurnTimeline.Entry] = [op("h1", .handoff, title: "Agent handoff", at: 0), steps("a", count: 1, at: 1), op("h2", .handoff, title: "Agent handoff", at: 2)]
        XCTAssertEqual(TurnTimeline.fold(short).map(\.id), short.map(\.id))
        let mixed: [TurnTimeline.Entry] = [op("h1", .handoff, title: "Agent handoff", at: 0), op("n1", .notice, title: "Context compacted", at: 1),
                                           op("h2", .handoff, title: "Agent handoff", at: 2), op("h3", .handoff, title: "Agent handoff", at: 3)]
        XCTAssertEqual(TurnTimeline.fold(mixed).map(\.id), mixed.map(\.id), "different events break a run")
    }
}
