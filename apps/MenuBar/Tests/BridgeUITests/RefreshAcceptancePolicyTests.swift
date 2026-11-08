import Foundation
import XCTest
import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class RefreshAcceptancePolicyTests: XCTestCase {
    func testServicePendingLoadIsNotMistakenForSettledEmptyData() {
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness([:]), .pending)
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness(["transient.ready": "false", "transient.hasData": "false"]), .pending)
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness(["transient.loading": "true", "transient.ready": "true", "transient.hasData": "true"]), .loading, "Old cached data cannot bypass an active metadata read")
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness(["transient.loading": "false", "transient.ready": "true", "transient.hasData": "false"]), .empty)
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness(["transient.loading": "false", "transient.ready": "true", "transient.hasData": "true"]), .ready)
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness(["transient.error": "true", "transient.hasData": "true"]), .error)
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness(["transient.unsupported": "true"]), .unsupported)
    }

    @MainActor
    func testServiceTransientAcknowledgementsAreExcludedFromPreservedState() async {
        let loading = AcceptanceProbe.serviceFields(loading: true, ready: false, hasData: false, itemCount: 0)
        var ready = AcceptanceProbe.serviceFields(loading: false, ready: true, hasData: true, itemCount: 5)
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness(loading), .loading)
        XCTAssertEqual(RefreshAcceptancePolicy.serviceReadiness(ready), .ready)
        ready["expanded"] = "safe-fixture-id"
        XCTAssertEqual(ready.filter { !$0.key.hasPrefix("transient.") }, ["expanded": "safe-fixture-id"])
        XCTAssertEqual(ready["transient.itemCount"], "5")
    }

    func testExactCapturedTargetDoesNotAcceptOldRenderingOrChaseInterference() {
        let at = Date(timeIntervalSince1970: 1_793_686_620)
        let target = RefreshAcceptancePolicy.Target(revision: 4, asOf: at)
        XCTAssertEqual(RefreshAcceptancePolicy.renderState(target: target, revision: 4, asOf: at, projectionBusy: false,
            renderedRevision: "3", preparedMatches: false, preparing: true), .waiting)
        XCTAssertEqual(RefreshAcceptancePolicy.renderState(target: target, revision: 4, asOf: at, projectionBusy: true,
            renderedRevision: "4", preparedMatches: true, preparing: false), .waiting)
        XCTAssertEqual(RefreshAcceptancePolicy.renderState(target: target, revision: 4, asOf: at, projectionBusy: false,
            renderedRevision: "4", preparedMatches: true, preparing: false), .complete)
        XCTAssertEqual(RefreshAcceptancePolicy.renderState(target: target, revision: 5, asOf: at, projectionBusy: false,
            renderedRevision: "5", preparedMatches: true, preparing: false), .interference, "Same-time corrections are still different captured inputs")
        XCTAssertEqual(RefreshAcceptancePolicy.renderState(target: target, revision: 4, asOf: at.addingTimeInterval(1), projectionBusy: false,
            renderedRevision: "4", preparedMatches: true, preparing: false), .interference)
    }

    func testSourceAndRenderPhasesHaveIndependentBoundsInsideOneRunBudget() {
        XCTAssertEqual(RefreshAcceptancePolicy.phaseDeadline(start: 100, overallEnd: 1000), 280)
        XCTAssertEqual(RefreshAcceptancePolicy.phaseDeadline(start: 260, overallEnd: 1000), 440)
        XCTAssertEqual(RefreshAcceptancePolicy.phaseDeadline(start: 260, overallEnd: 300), 300)
    }

    func testInspectorSetupRequiresTheCurrentFilteredRenderedRevision() {
        XCTAssertFalse(RefreshAcceptancePolicy.renderedCurrent([:], revision: 4))
        XCTAssertFalse(RefreshAcceptancePolicy.renderedCurrent(["preparing": "false", "preparedMatchesInputs": "true", "renderedRevision": "3"], revision: 4))
        XCTAssertFalse(RefreshAcceptancePolicy.renderedCurrent(["preparing": "true", "preparedMatchesInputs": "false", "renderedRevision": "4"], revision: 4))
        XCTAssertTrue(RefreshAcceptancePolicy.renderedCurrent(["preparing": "false", "preparedMatchesInputs": "true", "renderedRevision": "4"], revision: 4))
    }
    func testDefaultMatrixIncludesAllPagesAndGLMWithBoundedReplay() throws {
        let value = try RefreshAcceptancePolicy.Configuration(environment: [:])
        XCTAssertEqual(value.mode, .replay)
        XCTAssertEqual(value.cycles, 3)
        XCTAssertEqual(Set(value.pages).count, 15)
        XCTAssertTrue(value.pages.contains("credits"))
        XCTAssertTrue(value.pages.contains("glm-chat"))
        XCTAssertTrue(value.pages.contains("panel"))
        XCTAssertEqual(value.warmupCycles, 1)
        XCTAssertLessThanOrEqual(value.budgetSeconds, 1800)
    }

    func testInvalidZeroUnboundedAndUnknownConfigurationIsRejected() {
        for environment in [
            ["BRIDGE_REFRESH_CYCLES": "0"], ["BRIDGE_REFRESH_CYCLES": "999"],
            ["BRIDGE_REFRESH_CYCLES": "not-a-number"], ["BRIDGE_REFRESH_MODE": "generate"],
            ["BRIDGE_REFRESH_PAGES": "overview,missing"], ["BRIDGE_REFRESH_PAGES": "overview,overview"],
            ["BRIDGE_REFRESH_PAGES": ""], ["BRIDGE_REFRESH_TIMEOUT": "nan"],
            ["BRIDGE_REFRESH_TIMEOUT": "999999"], ["BRIDGE_REFRESH_MEMORY_MB": "inf"],
            ["BRIDGE_REFRESH_MAX_LIVE": "0"], ["BRIDGE_REFRESH_WARMUP_CYCLES": "99"],
        ] {
            XCTAssertThrowsError(try RefreshAcceptancePolicy.Configuration(environment: environment))
        }
    }

    func testLiveModeMustBeExplicitAndRemainsBudgeted() throws {
        let value = try RefreshAcceptancePolicy.Configuration(environment: ["BRIDGE_REFRESH_MODE": "live", "BRIDGE_REFRESH_PAGES": "overview,panel", "BRIDGE_REFRESH_MAX_LIVE": "6"])
        XCTAssertEqual(value.mode, .live)
        XCTAssertEqual(value.maximumLiveRefreshes, 6)
        XCTAssertEqual(value.pages, ["overview", "panel"])
        let long = try RefreshAcceptancePolicy.Configuration(environment: ["BRIDGE_REFRESH_MODE": "live", "BRIDGE_REFRESH_TIMEOUT": "2700"])
        XCTAssertEqual(long.budgetSeconds, 2700)
        XCTAssertThrowsError(try RefreshAcceptancePolicy.Configuration(environment: ["BRIDGE_REFRESH_TIMEOUT": "3601"]))
    }

    func testNoVacuousSuccessForMissingCyclesTimeoutOrUnsupportedHooks() {
        XCTAssertEqual(RefreshAcceptancePolicy.outcome(cyclesRequested: 0, completed: 0, failed: false, requiredUnsupported: false), .unsupported)
        XCTAssertEqual(RefreshAcceptancePolicy.outcome(cyclesRequested: 3, completed: 2, failed: false, requiredUnsupported: false), .partial)
        XCTAssertEqual(RefreshAcceptancePolicy.outcome(cyclesRequested: 3, completed: 3, failed: true, requiredUnsupported: false), .failed)
        XCTAssertEqual(RefreshAcceptancePolicy.outcome(cyclesRequested: 3, completed: 3, failed: false, requiredUnsupported: true), .partial)
        XCTAssertEqual(RefreshAcceptancePolicy.outcome(cyclesRequested: 3, completed: 3, failed: false, requiredUnsupported: false), .complete)
    }

    func testTransientDatasetFieldsDoNotMaskLostPersistentState() {
        let before = ["provider": "codex", "query": "Acceptance", "renderedRevision": "1"]
        let after = ["provider": "codex", "query": "Acceptance", "renderedRevision": "2"]
        XCTAssertTrue(RefreshAcceptancePolicy.preserved(before, after, keys: ["provider", "query"]))
        XCTAssertFalse(RefreshAcceptancePolicy.preserved(before, ["provider": "all", "query": "Acceptance"], keys: ["provider", "query"]))
        XCTAssertFalse(RefreshAcceptancePolicy.preserved(before, [:], keys: ["provider"]))
        XCTAssertFalse(RefreshAcceptancePolicy.preserved([:], [:], keys: []), "An empty state capture is not proof of persistence")
    }

    func testMemoryRequiresTwoValidPostWarmupSamplesAndExcludesWarmupPeak() {
        let value = RefreshAcceptancePolicy.memory(samples: [(0, 500), (1, 600), (2, 200), (3, 205)], warmup: 1, limit: 10)
        XCTAssertEqual(value.status, .complete)
        XCTAssertEqual(value.peakMB, 600)
        XCTAssertEqual(value.steadyFirstMB, 200)
        XCTAssertEqual(value.steadyLastMB, 205)
        XCTAssertEqual(value.steadyGrowthMB, 5)
        let insufficient = RefreshAcceptancePolicy.memory(samples: [(0, nil), (1, -1), (2, .nan), (3, 100)], warmup: 1, limit: 10)
        XCTAssertEqual(insufficient.status, .partial)
        XCTAssertNil(insufficient.steadyGrowthMB)
    }

    func testMemoryGrowthOverLimitIsFailureNotOnlyANote() {
        let value = RefreshAcceptancePolicy.memory(samples: [(0, 100), (1, 100), (2, 120), (3, 145)], warmup: 1, limit: 20)
        XCTAssertEqual(value.status, .failed)
        XCTAssertEqual(value.steadyGrowthMB, 25)
    }

    func testMemorySettlementKeepsRawPeakButUsesStableTerminalMedian() {
        let samples = (0 ... 16).map { index in
            RefreshAcceptancePolicy.IdleReading(seconds: Double(index) * 0.25,
                footprintMB: index == 0 ? 500 : (index < 4 ? 450 : 315), processLifetimePeakMB: 648.9, idle: true)
        }
        let value = RefreshAcceptancePolicy.settlement(samples)
        XCTAssertTrue(value.stable)
        XCTAssertEqual(value.postIdleMB, 315)
        XCTAssertEqual(value.observedPeakMB, 500)
        XCTAssertEqual(value.processLifetimePeakMB, 648.9)
        XCTAssertEqual(value.readings, samples)
        XCTAssertFalse(RefreshAcceptancePolicy.settlement(Array(samples.prefix(8))).stable, "A short flat period before three idle seconds is insufficient")
    }

    func testSettlementNeverChoosesMinimumOrTurnsUnstableGrowthIntoAPass() {
        let high = (0 ... 16).map { index in
            RefreshAcceptancePolicy.IdleReading(seconds: Double(index) * 0.25, footprintMB: index == 0 ? 200 : 500, processLifetimePeakMB: nil, idle: true)
        }
        let settled = RefreshAcceptancePolicy.settlement(high)
        XCTAssertEqual(settled.postIdleMB, 500, "Do not cherry-pick the earlier minimum")
        let strict = RefreshAcceptancePolicy.memory(samples: [(2, 398), (3, settled.postIdleMB)], warmup: 1, limit: 48)
        XCTAssertEqual(strict.status, .failed)
        let rising = (0 ... 32).map { index in
            RefreshAcceptancePolicy.IdleReading(seconds: Double(index) * 0.25, footprintMB: 300 + Double(index) * 5, processLifetimePeakMB: nil, idle: true)
        }
        let unstable = RefreshAcceptancePolicy.settlement(rising)
        XCTAssertFalse(unstable.stable)
        XCTAssertNil(unstable.postIdleMB)
        var busy = high
        busy[busy.count - 2].idle = false
        XCTAssertFalse(RefreshAcceptancePolicy.settlement(busy).stable)
    }

    @MainActor
    func testReadyManifestUsesLoadedFixtureRatherThanStartupPlaceholder() async {
        var report = RefreshAcceptance.Report()
        report.fixture = "loading-replay-fixture"
        report.markReady(mode: .replay, fixtureLabel: "saved-local-fixture", overview: .empty)
        XCTAssertEqual(report.fixture, "saved-local-fixture")
        XCTAssertEqual(report.sessionCount, 0)
        XCTAssertEqual(report.inputSize?.storedModelSteps, 0)
        report.markReady(mode: .live, fixtureLabel: "synthetic", overview: .empty)
        XCTAssertEqual(report.fixture, "live-passive-metadata")
    }

    @MainActor
    func testInputSizesDescribeStoredWorkloadWithoutClaimingDeduplicatedCalls() async {
        let now = Date(timeIntervalSince1970: 1_793_686_620)
        let step = ActivityModelStep(id: "same", timestamp: nil, model: nil)
        let turn = ActivityTurn(id: "same", modelSteps: [step, step])
        let session = ActivitySession(id: "same", provider: .codex, nativeID: "same", title: "Fixture", createdAt: now, updatedAt: now, turns: [turn], source: "fixture")
        let sizes = RefreshAcceptance.InputSize(ActivityOverview(generatedAt: now, sessions: [session, session]))
        XCTAssertEqual(sizes.sessions, 2)
        XCTAssertEqual(sizes.storedNativeRecords, 2)
        XCTAssertEqual(sizes.storedModelSteps, 4)
        XCTAssertEqual(RefreshAcceptance.InputSize(.empty).storedNativeRecords, 0)
    }

    @MainActor
    func testCheckpointsArePrivateReplaceOnlyOwnReportsAndRejectLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AcceptancePolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("report.json")
        var report = RefreshAcceptance.Report()
        try RefreshAcceptance.writePrivate(report, to: target)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        report.phase = "next-checkpoint"
        try RefreshAcceptance.writePrivate(report, to: target)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        XCTAssertEqual(object["phase"] as? String, "next-checkpoint")
        let unrelated = directory.appendingPathComponent("unrelated.json")
        try Data("{}".utf8).write(to: unrelated)
        XCTAssertThrowsError(try RefreshAcceptance.writePrivate(report, to: unrelated))
        XCTAssertEqual(try String(contentsOf: unrelated), "{}")
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try RefreshAcceptance.writePrivate(report, to: link))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".hub-acceptance-") })
    }
}
