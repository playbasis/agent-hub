import Foundation
import XCTest
@testable import BridgeCore

final class ModelStepPersistenceTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private func step(_ id: String, model: String? = "gpt-6-astra", tokens: Int = 10) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: at, model: model, effort: "ultra",
                          usage: TokenUsage(input: tokens - 2, output: 2, total: tokens, provenance: .providerReported), usageIsPartial: false)
    }

    func testLegacyTurnDecodesWithoutInventingModelSteps() throws {
        let value = ActivityTurn(id: "legacy", model: "gpt-6.1-sol")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BridgeJSON.encoder.encode(value)) as? [String: Any])
        object.removeValue(forKey: "modelSteps"); object.removeValue(forKey: "modelStepsComplete")
        let legacy = try BridgeJSON.decoder.decode(ActivityTurn.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.modelSteps)
        XCTAssertNil(legacy.modelStepsComplete)
    }

    func testPartialReplayUnionsStepIdentitiesWithoutLosingEarlierModel() {
        let initial = ActivityTurn(id: "turn", modelSteps: [step("one")], modelStepsComplete: false)
        let next = ActivityTurn(id: "turn", modelSteps: [step("two", model: "gpt-6.1-sol"), step("one", model: nil)], modelStepsComplete: false)
        let merged = initial.merging(next)
        XCTAssertEqual(merged.modelSteps?.count, 2)
        XCTAssertEqual(merged.modelSteps?.first { $0.id == "one" }?.model, "gpt-6-astra")
        XCTAssertEqual(merged.modelSteps?.first { $0.id == "two" }?.model, "gpt-6.1-sol")
        XCTAssertEqual(merged.modelStepsComplete, false)
    }

    func testCompleteReplayMustContainEarlierEvidenceAndOldClientCannotEraseIt() {
        let initial = ActivityTurn(id: "turn", modelSteps: [step("one"), step("two")], modelStepsComplete: true)
        let incompleteCorrection = initial.merging(ActivityTurn(id: "turn", modelSteps: [step("two")], modelStepsComplete: true))
        XCTAssertEqual(incompleteCorrection.modelSteps?.count, 2)
        XCTAssertEqual(incompleteCorrection.modelStepsComplete, false)
        let complete = incompleteCorrection.merging(ActivityTurn(id: "turn", modelSteps: [step("one"), step("two"), step("three")], modelStepsComplete: true))
        XCTAssertEqual(complete.modelStepsComplete, true)
        let legacy = complete.merging(ActivityTurn(id: "turn"))
        XCTAssertEqual(legacy.modelSteps?.count, 3)
        XCTAssertEqual(legacy.modelStepsComplete, true)
    }

    func testPartialStepCannotReplaceCompleteUsageAndMissingComponentsStayKnown() {
        let prior = step("one")
        let partial = ActivityModelStep(id: "one", timestamp: nil, model: nil,
            usage: TokenUsage(total: 1, provenance: .providerReported), usageIsPartial: true)
        let merged = prior.merging(partial)
        XCTAssertEqual(merged.model, prior.model)
        XCTAssertEqual(merged.timestamp, at)
        XCTAssertEqual(merged.usage.total, 10)
        XCTAssertEqual(merged.usage.output, 2)
        XCTAssertEqual(merged.usageIsPartial, false)
    }

    func testReplayedCheckpointDoesNotMoveOldWorkIntoANewReportingDay() {
        let prior = step("one")
        var replay = prior
        replay.timestamp = at.addingTimeInterval(86_400)
        XCTAssertEqual(prior.merging(replay).timestamp, at)
        XCTAssertEqual(replay.merging(prior).timestamp, at)
    }

    func testMovingBackfillDoesNotInvalidatePreviouslyCompleteClosedStepEvidence() {
        let complete = ActivityTurn(id: "turn", startedAt: at, completedAt: at.addingTimeInterval(3), status: "completed",
            modelSteps: [step("a"), step("b")], modelStepsComplete: true)
        let subset = ActivityTurn(id: "turn", status: "completed", modelSteps: [step("b")], modelStepsComplete: false)
        XCTAssertEqual(complete.merging(subset).modelStepsComplete, true)
        let added = ActivityTurn(id: "turn", status: "running", modelSteps: [step("c")], modelStepsComplete: false)
        XCTAssertEqual(complete.merging(added).modelStepsComplete, false)
        XCTAssertEqual(complete.merging(added).modelSteps?.count, 3)
    }

    func testUnspecifiedCoverageCannotEraseAKnownStepGap() {
        var partial = step("known-gap"); partial.usageIsPartial = true
        var unspecified = partial; unspecified.usageIsPartial = nil
        XCTAssertEqual(partial.merging(unspecified).usageIsPartial, true)
        unspecified.usageIsPartial = false
        XCTAssertEqual(partial.merging(unspecified).usageIsPartial, false)
    }

    func testReportedMeasurementsOutrankCompleteEstimatesWithoutLaunderingComponents() {
        var estimate = step("authority"); estimate.usage = TokenUsage(input: 100, total: 100, provenance: .estimated)
        let reported = ActivityModelStep(id: "authority", timestamp: at, model: "gpt-6-astra",
            usage: TokenUsage(output: 80, total: 80, provenance: .providerReported), usageIsPartial: true)
        let forward = estimate.merging(reported)
        XCTAssertEqual(forward.usage.total, 80)
        XCTAssertEqual(forward.usage.provenance, .providerReported)
        XCTAssertNil(forward.usage.input, "Estimated inputs cannot fill reported-but-missing components")
        let reverse = reported.merging(estimate)
        XCTAssertEqual(reverse.usage.total, 80)
        XCTAssertNil(reverse.usage.input)
        let oldTurn = ActivityTurn(id: "authority-turn", usage: estimate.usage, usageIsPartial: false)
        let freshTurn = ActivityTurn(id: "authority-turn", usage: reported.usage, usageIsPartial: true)
        XCTAssertEqual(oldTurn.merging(freshTurn).usage.total, 80)
        XCTAssertNil(oldTurn.merging(freshTurn).usage.input)
        XCTAssertEqual(freshTurn.merging(oldTurn).usage.total, 80)
    }
}
