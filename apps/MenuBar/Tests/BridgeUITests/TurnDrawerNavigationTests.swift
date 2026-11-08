import XCTest
import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class TurnDrawerNavigationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_750_400)

    private func snapshot(at time: Date? = nil, extraTurn: Bool = false) -> ActivityOverview {
        let at = time ?? now
        var turns = [ActivityTurn(id: "t1", startedAt: now.addingTimeInterval(-300), completedAt: now.addingTimeInterval(-200), status: "completed"),
                     ActivityTurn(id: "t2", startedAt: now.addingTimeInterval(-100), status: "running")]
        if extraTurn { turns.append(ActivityTurn(id: "t3", startedAt: now.addingTimeInterval(5), status: "running")) }
        let lead = ActivitySession(id: "lead", provider: .codex, nativeID: "lead", title: "Lead", createdAt: now.addingTimeInterval(-600),
                                   updatedAt: at, observedAt: at, turns: turns, source: "fixture")
        return ActivityOverview(generatedAt: at, sessions: [lead])
    }

    @MainActor private func controller() throws -> (ActivityReportsController, () -> Void) {
        let suite = "TurnDrawer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ActivityReportsController(defaults: defaults, presentsWindows: false), { defaults.removePersistentDomain(forName: suite) })
    }

    func testSelectionResolvesLatestTurnOnceAndPreservesExplicitUnknownTurns() {
        XCTAssertEqual(TurnInspectionSelection(overview: snapshot(), sessionID: "lead", turnID: nil).turnID, "t2")
        XCTAssertEqual(TurnInspectionSelection(overview: snapshot(), sessionID: "lead", turnID: "t1").turnID, "t1")
        XCTAssertEqual(TurnInspectionSelection(overview: snapshot(), sessionID: "lead", turnID: "missing").turnID, "missing")
    }

    func testRebasingKeepsTheSameDrawerAndTurnOnANewerSnapshotOnly() throws {
        let selection = TurnInspectionSelection(overview: snapshot(), sessionID: "lead", turnID: "t1")
        let newer = try XCTUnwrap(selection.rebased(on: snapshot(at: now.addingTimeInterval(30), extraTurn: true)))
        XCTAssertEqual(newer.id, selection.id)
        XCTAssertEqual(newer.turnID, "t1", "a refresh never jumps to the newest turn")
        XCTAssertNotEqual(newer, selection)
        XCTAssertNil(selection.rebased(on: snapshot()), "an equal or older snapshot is ignored")
        let sameClockCorrection = try XCTUnwrap(selection.rebased(on: snapshot(), revision: 1))
        XCTAssertEqual(sameClockCorrection.snapshotRevision, 1)
        XCTAssertNotEqual(sameClockCorrection, selection)
        var gone = snapshot(at: now.addingTimeInterval(30)); gone.sessions[0].turns.removeAll { $0.id == "t1" }
        XCTAssertNil(selection.rebased(on: gone))
    }

    func testLatestSelectionAndRebaseRetainCanonicalHistoryAcrossPartialTails() throws {
        var original = snapshot()
        original.sessions[0].observedAt = now.addingTimeInterval(-10)
        var tail = original.sessions[0]
        tail.observedAt = now
        tail.historyComplete = false
        tail.turns = []
        original.sessions.append(tail)
        let selected = TurnInspectionSelection(overview: original, sessionID: "lead", turnID: nil)
        XCTAssertEqual(selected.turnID, "t2", "A newer partial tail must not erase retained turns or leave Latest unfrozen")
        original.generatedAt = now.addingTimeInterval(30)
        let rebased = try XCTUnwrap(selected.rebased(on: original, revision: 2))
        XCTAssertEqual(rebased.turnID, "t2")
        XCTAssertEqual(rebased.id, selected.id)
    }

    @MainActor func testDrawerIsOneTrailingPanelAndBackClosesItFirst() throws {
        let (controller, cleanup) = try controller()
        defer { cleanup() }
        controller.navigate(to: .goals)
        controller.selectedSessionID = "lead"
        controller.inspectTurn(overview: snapshot(), sessionID: "lead")
        XCTAssertNil(controller.selectedSessionID, "the drawer replaces session details")
        XCTAssertEqual(controller.turnInspection?.turnID, "t2")
        XCTAssertTrue(controller.canGoBack)
        controller.focusTurn("t1")
        XCTAssertEqual(controller.turnInspection?.turnID, "t1")
        controller.goBack()
        XCTAssertNil(controller.turnInspection)
        XCTAssertEqual(controller.page, .goals, "Back closes the drawer before leaving the page")
        controller.inspectTurn(overview: snapshot(), sessionID: "lead", turnID: "t1")
        controller.selectedSessionID = "lead"
        XCTAssertNil(controller.turnInspection, "session details replace the drawer")
        controller.inspectTurn(overview: snapshot(), sessionID: "missing")
        XCTAssertNil(controller.turnInspection)
    }

    @MainActor func testNavigationAndReplayCloseTheDrawer() throws {
        let (controller, cleanup) = try controller()
        defer { cleanup() }
        controller.navigate(to: .now)
        controller.inspectTurn(overview: snapshot(), sessionID: "lead")
        controller.navigate(to: .goals)
        XCTAssertNil(controller.turnInspection)
        controller.inspectTurn(overview: snapshot(), sessionID: "lead")
        controller.openReplay(overview: snapshot(), sessionID: "lead", focusTurnIDs: ["t1"])
        XCTAssertNil(controller.turnInspection)
        controller.inspectTurn(overview: snapshot(), sessionID: "lead")
        XCTAssertNil(controller.turnInspection, "the drawer does not open over a replay")
    }

    @MainActor func testRebaseFollowsThePageSnapshot() throws {
        let (controller, cleanup) = try controller()
        defer { cleanup() }
        controller.navigate(to: .goals)
        controller.inspectTurn(overview: snapshot(), sessionID: "lead", turnID: "t2")
        controller.rebaseTurnInspection(on: snapshot(at: now.addingTimeInterval(60), extraTurn: true))
        XCTAssertEqual(controller.turnInspection?.overview.generatedAt, now.addingTimeInterval(60))
        XCTAssertEqual(controller.turnInspection?.turnID, "t2")
    }
}
