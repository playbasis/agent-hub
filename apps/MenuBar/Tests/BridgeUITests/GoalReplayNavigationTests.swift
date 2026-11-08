import AppKit
import XCTest
import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class GoalReplayNavigationTests: XCTestCase {
    func testStandalonePreviewsUseTheSamePrivatePreferenceAndNoNativeActionsGate() {
        for key in ["BRIDGE_GOAL_REPLAY_PREVIEW", "BRIDGE_HYDRATION_PREVIEW", "BRIDGE_REFRESH_ACCEPTANCE"] {
            let value = key == "BRIDGE_HYDRATION_PREVIEW" ? "overview" : key == "BRIDGE_REFRESH_ACCEPTANCE" ? "/tmp/fixture.json" : "1"
            XCTAssertTrue(AcceptanceProbe.requested(environment: ["BRIDGE_UI_PREVIEW": "1", key: value]))
            XCTAssertFalse(AcceptanceProbe.requested(environment: [key: value]))
        }
        XCTAssertFalse(AcceptanceProbe.requested(environment: ["BRIDGE_UI_PREVIEW": "1"]))
        XCTAssertFalse(AcceptanceProbe.requested(environment: ["BRIDGE_UI_PREVIEW": "1", "BRIDGE_GOAL_REPLAY_PREVIEW": "0"]))
    }
    private let now = Date(timeIntervalSince1970: 1_793_750_400)
    private func snapshot() -> ActivityOverview {
        let goal = ActivityGoal(id: "goal", sessionID: "root", objective: "Verify a synthetic feature", status: "complete",
                                createdAt: now.addingTimeInterval(-100), updatedAt: now.addingTimeInterval(-1))
        let root = ActivitySession(id: "root", provider: .codex, nativeID: "native-root", title: "Lead", createdAt: now.addingTimeInterval(-200), updatedAt: now,
                                   observedAt: now, goal: goal, source: "fixture")
        let child = ActivitySession(id: "child", provider: .codex, nativeID: "native-child", title: "Helper", createdAt: now.addingTimeInterval(-80), updatedAt: now,
                                    observedAt: now, parentSessionID: "native-root", source: "fixture")
        return ActivityOverview(generatedAt: now, sessions: [root, child])
    }
    @MainActor func testHelperReplayCanReachAnExplicitCompletedGoal() {
        XCTAssertEqual(ActivityReportsController.replayRoot(in: snapshot(), selectedID: "child"), "root")
    }
    @MainActor func testCopiedGoalMetadataDoesNotMakeTheHelperItsOwner() {
        var value = snapshot()
        value.sessions[1].goal = value.sessions[0].goal
        XCTAssertEqual(ActivityReportsController.replayRoot(in: value, selectedID: "child"), "root")
    }
    @MainActor func testCrossProviderAmbiguousAndCyclicParentsNeverManufactureGoalLinks() {
        var value = snapshot()
        value.sessions[1].provider = .claude
        XCTAssertEqual(ActivityReportsController.replayRoot(in: value, selectedID: "child"), "child")
        value = snapshot(); value.sessions.append(value.sessions[0])
        XCTAssertEqual(ActivityReportsController.replayRoot(in: value, selectedID: "child"), "child")
        value = snapshot(); value.sessions[0].goal = nil; value.sessions[0].parentSessionID = "child"
        XCTAssertEqual(ActivityReportsController.replayRoot(in: value, selectedID: "child"), "child")
    }
    @MainActor func testReplayUsesTheCommonWindowAndBackForwardPreserveFrozenSelection() throws {
        let suite = "ReplayNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ActivityReportsController(defaults: defaults, presentsWindows: false)
        let model = BridgeViewModel(automaticallyConnect: false, workspaceController: controller)
        model.openPage(.goals)
        let window = controller.windowIdentity
        controller.openReplay(overview: snapshot(), sessionID: "child", focusTurnIDs: ["turn"])
        let selected = try XCTUnwrap(controller.replaySelection)
        XCTAssertEqual(selected.rootSessionID, "root")
        XCTAssertEqual(selected.focusSessionID, "child")
        XCTAssertTrue(controller.canGoBack)
        XCTAssertEqual(controller.page, .goals)
        controller.goBack()
        XCTAssertNil(controller.replaySelection)
        XCTAssertTrue(controller.canGoForward)
        controller.goForward()
        XCTAssertEqual(controller.replaySelection?.id, selected.id)
        XCTAssertEqual(controller.replaySelection?.overview.generatedAt, now)
        XCTAssertEqual(controller.windowIdentity, window)
        XCTAssertEqual(controller.windowCreationCount, 1)
        controller.navigate(to: .settings)
        XCTAssertNil(controller.replaySelection)
        controller.close()
    }
    @MainActor func testCloseReopenDoesNotReplaceTheInspectedSnapshot() throws {
        let suite = "ReplayReopen.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ActivityReportsController(defaults: defaults, presentsWindows: false)
        let model = BridgeViewModel(automaticallyConnect: false, workspaceController: controller)
        model.openPage(.goals)
        controller.openReplay(overview: snapshot(), sessionID: "root")
        let selected = controller.replaySelection?.id
        controller.close(); controller.show(model: model)
        XCTAssertEqual(controller.replaySelection?.id, selected)
        XCTAssertFalse(controller.isWindowVisible)
        controller.close()
    }
    @MainActor func testReplayKeepsOriginPageAndItsBackHistory() throws {
        let suite = "ReplayOrigin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ActivityReportsController(defaults: defaults, presentsWindows: false)
        let model = BridgeViewModel(automaticallyConnect: false, workspaceController: controller)
        model.openPage(.now)
        let previousHistory = controller.navigation.backHistory
        controller.openReplay(overview: snapshot(), sessionID: "root")
        XCTAssertEqual(controller.page, .now)
        XCTAssertEqual(controller.navigation.backHistory, previousHistory)
        controller.goBack()
        XCTAssertEqual(controller.page, .now)
        XCTAssertNil(controller.replaySelection)
        controller.goForward()
        XCTAssertNotNil(controller.replaySelection)
        XCTAssertEqual(controller.page, .now)
        controller.close()
    }
    @MainActor func testFollowNeverSilentlySwitchesToADifferentGoal() async throws {
        let selection = GoalReplaySelection(overview: snapshot(), rootSessionID: "root")
        let replay = GoalReplayModel(selection: selection)
        replay.prepare(snapshot()); await replay.waitUntilIdle()
        XCTAssertEqual(replay.prepared?.index.goalID, "goal")
        let publication = replay.publication
        var next = snapshot(); next.generatedAt = now.addingTimeInterval(10)
        next.sessions[0].goal?.id = "different-goal"
        replay.prepare(next); await replay.waitUntilIdle()
        XCTAssertEqual(replay.prepared?.index.goalID, "goal")
        XCTAssertEqual(replay.publication, publication)
        XCTAssertTrue(replay.needsNewReplay)
        XCTAssertNotNil(replay.error)
        replay.deactivate()
    }

    @MainActor func testOpenedPageProjectionPublishesCoverageWithItsOwnReadMetadata() async throws {
        var value = snapshot()
        value.sessions[0].turns = [ActivityTurn(id: "turn", startedAt: now.addingTimeInterval(-20), status: "completed")]
        let replay = GoalReplayModel(selection: GoalReplaySelection(overview: value, rootSessionID: "root"))
        replay.prepare(value)
        await replay.waitUntilIdle()
        await replay.waitUntilSignalsIdle()
        let result = try XCTUnwrap(replay.incidentProjection)
        XCTAssertEqual(result.timeline.indexedTurnCount, 1)
        XCTAssertEqual(result.timeline.inspectedPageCount, 0)
        XCTAssertEqual(result.timeline.uninspectedTurnCount, 1)
        XCTAssertTrue(result.readAt.isEmpty)
        XCTAssertTrue(result.snapshots.isEmpty)
        replay.deactivate()
    }

    func testSignalNavigationSelectsSourcePageAndClearsErrorFilterEachTime() throws {
        var value = snapshot()
        value.sessions[0].turns = (0..<205).map { index in
            ActivityTurn(id: "turn-\(index)", startedAt: now.addingTimeInterval(-90 + Double(index) * 0.3), status: "completed")
        }
        let index = GoalReplayIndex.build(overview: value, rootSessionID: "root")
        XCTAssertEqual(index.rows.count, 205)
        let rowID = index.rows[204].id
        let first = try XCTUnwrap(GoalReplaySignalNavigation.make(rowID: rowID, index: index))
        let second = try XCTUnwrap(GoalReplaySignalNavigation.make(rowID: rowID, index: index))
        XCTAssertEqual(first.rowID, rowID)
        XCTAssertEqual(first.offset, 200)
        XCTAssertFalse(first.showOnlyErrors)
        XCTAssertNotEqual(first.requestID, second.requestID)
        XCTAssertNil(GoalReplaySignalNavigation.make(rowID: "missing", index: index))
    }
}
