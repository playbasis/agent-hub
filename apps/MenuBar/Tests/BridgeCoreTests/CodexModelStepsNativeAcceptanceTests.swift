import Foundation
import XCTest
@testable import BridgeCore

/// Explicit local acceptance only. Reads known rollout paths supplied by the
/// operator; never discovers credentials, resumes a thread or invokes a model.
final class CodexModelStepsNativeAcceptanceTests: XCTestCase {
    func testKnownNativeRolloutsProduceBoundedCheckpointEvidence() throws {
        guard let input = ProcessInfo.processInfo.environment["HUB_NATIVE_MODEL_AUDIT_PATHS"], !input.isEmpty else {
            throw XCTSkip("Set HUB_NATIVE_MODEL_AUDIT_PATHS to newline-separated already-known rollout paths for passive acceptance.")
        }
        let end = ProcessInfo.processInfo.environment["HUB_NATIVE_MODEL_AUDIT_END_EPOCH"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let start = end.addingTimeInterval(-86_400)
        let store = CodexModelStepReader.Store()
        for path in input.split(separator: "\n").map(String.init).prefix(3) {
            var result = CodexModelStepReader.Result()
            var passes = 0
            repeat {
                result = store.read(path: path, deadline: Date().addingTimeInterval(10))
                passes += 1
            } while !result.finished && !result.hitLimit && passes < 12
            XCTAssertTrue(result.finished, "Known history must finish through resumable bounded passes")
            XCTAssertFalse(result.hitLimit)
            var seen = Set<String>(), counts: [String: Int] = [:], tokens: [String: Int] = [:]
            for turn in result.turns.values {
                for step in turn.modelSteps {
                    guard let at = step.timestamp, at >= start, at < end, seen.insert(step.id).inserted else { continue }
                    let model = step.model ?? "unrecorded"
                    counts[model, default: 0] += 1
                    tokens[model, default: 0] += step.usage.total ?? 0
                }
            }
            let audit: [String: Any] = ["native_rollout": URL(fileURLWithPath: path).lastPathComponent,
                "end_epoch": end.timeIntervalSince1970, "passes": passes, "read_offset": result.readOffset,
                "native_turns": result.turns.count, "observed_steps_24h": counts, "known_tokens_24h": tokens,
                "warnings": result.warnings]
            let json = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
            print("MODEL_STEP_NATIVE_ACCEPTANCE " + String(decoding: json, as: UTF8.self))
        }
    }
}
