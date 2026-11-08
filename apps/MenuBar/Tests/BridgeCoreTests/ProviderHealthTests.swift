@testable import BridgeCore
import Foundation
import XCTest

final class ProviderHealthTests: XCTestCase {
    func testRulesProviderIsImmediatelyReady() async throws {
        let configuration = try BridgeConfiguration.makeDefault()
        let health = await DecisionEngine(configuration: configuration).probeProvider()

        XCTAssertEqual(health.provider, "rules")
        XCTAssertEqual(health.state, .ready)
        XCTAssertFalse(health.fallbackActive)
    }

    func testUnreachableOllamaProviderActivatesRulesFallback() async throws {
        var configuration = try BridgeConfiguration.makeDefault()
        configuration.meta.provider = .ollama
        configuration.meta.endpoint = "http://127.0.0.1:1"
        configuration.meta.timeoutSeconds = 0.2

        let health = await DecisionEngine(configuration: configuration).probeProvider()

        XCTAssertEqual(health.provider, "ollama")
        XCTAssertEqual(health.state, .degraded)
        XCTAssertTrue(health.fallbackActive)
        XCTAssertNotNil(health.message)
        XCTAssertNotNil(health.lastChecked)
    }

    func testProviderFailureStillReturnsUsableRoutingDecision() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-provider-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }

        var configuration = try BridgeConfiguration.makeDefault()
        configuration.meta.provider = .ollama
        configuration.meta.endpoint = "http://127.0.0.1:1"
        configuration.meta.timeoutSeconds = 0.2
        let now = Date()
        let session = RuntimeSession(
            id: UUID().uuidString,
            projectPath: project.path,
            goal: "Implement and verify the bridge",
            createdAt: now,
            deadline: now.addingTimeInterval(300),
            state: .idle,
            activeAgent: .none,
            preferredStartingAgent: .claude,
            agentSessionIDs: [:],
            lastEventID: nil,
            lastError: nil,
            wakeAt: nil,
            turnCount: 0
        )
        let store = try ProjectStore(projectPath: project.path)
        try store.initialize(session: session)
        let event = BridgeEvent(
            source: .bridge,
            type: .userMessage,
            content: .string(session.goal),
            sessionID: session.id,
            projectPath: project.path,
            metadata: ["bridge_managed": .bool(true)]
        )
        var quota = QuotaTracker(
            cooldownMinutes: configuration.session.rateLimitCooldownMinutes
        )

        let outcome = await DecisionEngine(configuration: configuration).decide(
            event: event,
            session: session,
            store: store,
            quota: &quota
        )

        XCTAssertEqual(outcome.provider.state, .degraded)
        XCTAssertTrue(outcome.provider.fallbackActive)
        XCTAssertEqual(outcome.decision.nextAgent, .claude)
        XCTAssertTrue([.continue, .handoff].contains(outcome.decision.action))
    }

    func testRulesDoNotTreatProtocolExamplesInUserGoalAsCompletion() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-marker-safety-\(UUID().uuidString)")
        let now = Date()
        let goal = """
        Ask Claude to finish with <bridge:continue>, then Codex should finish \
        with <bridge:complete> only after tests pass.
        """
        let session = RuntimeSession(
            id: UUID().uuidString,
            projectPath: project.path,
            goal: goal,
            createdAt: now,
            deadline: now.addingTimeInterval(300),
            state: .idle,
            activeAgent: .none,
            preferredStartingAgent: .claude,
            agentSessionIDs: [:],
            lastEventID: nil,
            lastError: nil,
            wakeAt: nil,
            turnCount: 0
        )
        let event = BridgeEvent(
            source: .bridge,
            type: .userMessage,
            content: .string(goal),
            sessionID: session.id,
            projectPath: project.path,
            metadata: ["bridge_managed": .bool(true)]
        )
        var quota = QuotaTracker(cooldownMinutes: 60)

        let decision = try RuleBasedClassifier().classify(
            event: event,
            session: session,
            quota: &quota
        )

        XCTAssertNotEqual(decision.action, .complete)
        XCTAssertEqual(decision.nextAgent, .claude)
    }

    func testProviderErrorSummaryExtractsArrayWrappedQuotaMessage() {
        let data = Data(
            """
            [{
              "error": {
                "code": 429,
                "message": "Quota exceeded. Please retry later.",
                "status": "RESOURCE_EXHAUSTED"
              }
            }]
            """.utf8
        )

        XCTAssertEqual(
            DecisionEngine.providerErrorSummary(data),
            "RESOURCE_EXHAUSTED: Quota exceeded. Please retry later."
        )
    }

    func testDecisionDecoderAcceptsOneCompleteObjectBeforeProviderCommentary() throws {
        let content = """
        ```json
        {
          "schema_version": "1.0",
          "label": "test",
          "confidence": 1,
          "next_agent": "none",
          "action": "pause",
          "refined_prompt": "",
          "summary_for_log": "Probe {passed}.",
          "reason": "The JSON decision contract was requested."
        }
        ```
        No, wait, here is unrelated provider self-commentary.
        """

        let decision = try DecisionEngine.decodeDecisionContent(content)

        XCTAssertEqual(decision.action, .pause)
        XCTAssertEqual(decision.nextAgent, .none)
        XCTAssertEqual(decision.summaryForLog, "Probe {passed}.")
    }

    func testGeminiConfigurationHasFirstClassIdentityAndRequiresSecret() async throws {
        var configuration = try BridgeConfiguration.makeDefault()
        configuration.meta.provider = .openAICompatible
        configuration.meta.endpoint = MetaConfiguration.geminiEndpoint
        configuration.meta.model = MetaConfiguration.geminiModel
        configuration.meta.apiKeyEnvironmentVariable =
            "CCB_TEST_MISSING_\(UUID().uuidString)"

        XCTAssertEqual(configuration.meta.coordinatorIdentifier, "gemini")
        let health = await DecisionEngine(configuration: configuration).probeProvider()
        XCTAssertEqual(health.provider, "gemini")
        XCTAssertEqual(health.state, .degraded)
        XCTAssertTrue(health.fallbackActive)
        XCTAssertTrue(health.message?.contains("credential store") == true)
    }
}
