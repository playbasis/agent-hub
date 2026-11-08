@testable import BridgeCore
import Foundation
import XCTest

final class StoreAndHookTests: XCTestCase {
    func testCoordinatorCredentialFileIsPrivateAndRoundTrips() throws {
        let directory = try temporaryProject()
        let credentialFile = directory.appendingPathComponent(
            "coordinator-credentials.json"
        )

        try CoordinatorSecretStore.save(
            "test-secret",
            account: "TEST_COORDINATOR_KEY",
            to: credentialFile
        )

        XCTAssertEqual(
            try CoordinatorSecretStore.load(
                account: "TEST_COORDINATOR_KEY",
                from: credentialFile
            ),
            "test-secret"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: credentialFile.path
        )
        let mode = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(mode & 0o777, 0o600)

        try CoordinatorSecretStore.remove(
            account: "TEST_COORDINATOR_KEY",
            from: credentialFile
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: credentialFile.path)
        )
    }

    func testCoordinationReviewPassAcceptsMarkdownEmphasis() {
        XCTAssertTrue(
            CoordinationProjectVerifier.hasExplicitPass(
                "# Verdict\n\n**PASS**\n"
            )
        )
        XCTAssertTrue(
            CoordinationProjectVerifier.hasExplicitPass(
                "## Result\n\n**Verdict: PASS**\n"
            )
        )
        XCTAssertFalse(
            CoordinationProjectVerifier.hasExplicitPass(
                "**PASS WITH WARNINGS**\n"
            )
        )
    }

    func testStoreIsAppendOnlyAndDeduplicatesEvents() throws {
        let project = try temporaryProject()
        let store = try ProjectStore(projectPath: project.path)
        let session = runtime(project: project)
        try store.initialize(session: session)
        let event = BridgeEvent(
            source: .bridge,
            type: .userMessage,
            content: .string("goal"),
            sessionID: session.id,
            projectPath: project.path
        )
        XCTAssertTrue(try store.append(event: event))
        XCTAssertFalse(try store.append(event: event))
        XCTAssertEqual(store.recentEvents(limit: 20).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.bridgeFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.changesFile.path))
    }

    func testHookInstallerPreservesExistingSettingsAndCreatesBackup() throws {
        let project = try temporaryProject()
        let claude = project.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let settings = claude.appendingPathComponent("settings.local.json")
        try Data(#"{"permissions":{"allow":["Read"]}}"#.utf8).write(to: settings)
        var configuration = try BridgeConfiguration.makeDefault()
        configuration.server.bearerToken = String(repeating: "x", count: 43)

        let result = try HookInstaller.install(
            projectPath: project.path,
            configuration: configuration
        )
        XCTAssertNotNil(result.backupURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        )
        XCTAssertNotNil(object["permissions"])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Stop"])
    }

    func testBridgeLogReaderTailsAndParsesJSONLines() throws {
        let directory = try temporaryProject()
        let log = directory.appendingPathComponent("bridge.jsonl")
        let contents = """
        {"fields":{},"level":"INFO","message":"first","timestamp":"2026-07-26T07:00:00.000Z"}
        {"fields":{"port":8742},"level":"WARN","message":"second","timestamp":"2026-07-26T07:00:01.000Z"}
        legacy unstructured line

        """
        try Data(contents.utf8).write(to: log)

        let snapshot = try BridgeLogReader.read(
            file: log,
            maxBytes: 1_024,
            maxEntries: 2
        )

        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.entries[0].level, "WARN")
        XCTAssertEqual(snapshot.entries[0].message, "second")
        XCTAssertEqual(snapshot.entries[0].fieldsSummary, #"{"port":8742}"#)
        XCTAssertTrue(snapshot.entries[0].isStructured)
        XCTAssertEqual(snapshot.entries[1].level, "RAW")
        XCTAssertFalse(snapshot.entries[1].isStructured)
        XCTAssertTrue(snapshot.wasTruncated)
    }

    func testDecisionRecordProvesCoordinatorAndFallbackState() throws {
        let project = try temporaryProject()
        let store = try ProjectStore(projectPath: project.path)
        let session = runtime(project: project)
        try store.initialize(session: session)
        let event = BridgeEvent(
            source: .claude,
            type: .turnComplete,
            content: .string("Architecture complete. <bridge:continue>"),
            sessionID: session.id,
            projectPath: project.path
        )
        try store.append(event: event)
        let decision = try Decision(
            label: .implementation,
            confidence: 0.93,
            nextAgent: .codex,
            action: .handoff,
            refinedPrompt: "Implement the agreed design and run its tests.",
            summaryForLog: "Claude designed; Codex should implement.",
            reason: "The task moved from architecture to implementation."
        )
        try store.appendDecision(
            event: event,
            decision: decision,
            fromAgent: .claude,
            coordinator: ProviderHealth(
                provider: "gemini",
                state: .ready,
                fallbackActive: false,
                message: "Provider response validated",
                lastChecked: Date(timeIntervalSince1970: 1)
            )
        )

        let value = try XCTUnwrap(store.recentDecisionValues(limit: 1).first)
        let coordinator = try XCTUnwrap(
            value.objectValue?["coordinator"]?.objectValue
        )
        XCTAssertEqual(coordinator["provider"]?.stringValue, "gemini")
        XCTAssertEqual(coordinator["fallback_active"]?.boolValue, false)
        let changes = try String(contentsOf: store.changesFile)
        XCTAssertTrue(changes.contains("- Coordinator: `gemini`"))
    }

    func testCoordinationAuditorRequiresGeminiToHearBothAgents() throws {
        let project = try temporaryProject()
        let store = try ProjectStore(projectPath: project.path)
        var session = runtime(project: project)
        session.state = .complete
        session.turnCount = 3
        try store.initialize(session: session)
        let coordinator = ProviderHealth(
            provider: "gemini",
            state: .ready,
            fallbackActive: false,
            message: "Provider response validated",
            lastChecked: Date()
        )

        func record(
            source: EventSource,
            from: AgentName,
            to: AgentName,
            action: DecisionAction,
            marker: String
        ) throws {
            let event = BridgeEvent(
                source: source,
                type: source == .bridge ? .userMessage : .turnComplete,
                content: .string(marker),
                sessionID: session.id,
                projectPath: project.path
            )
            try store.append(event: event)
            let decision = try Decision(
                label: action == .complete ? .complete : .implementation,
                confidence: 0.95,
                nextAgent: to,
                action: action,
                refinedPrompt: to == .none ? "" : "Continue the staged proof.",
                summaryForLog: "Recorded staged proof decision.",
                reason: "The next required role is \(to.rawValue)."
            )
            try store.appendDecision(
                event: event,
                decision: decision,
                fromAgent: from,
                coordinator: coordinator
            )
        }

        try record(
            source: .bridge,
            from: .none,
            to: .claude,
            action: .handoff,
            marker: "Start proof"
        )
        try record(
            source: .claude,
            from: .claude,
            to: .codex,
            action: .handoff,
            marker: "Design ready <bridge:continue>"
        )
        try record(
            source: .codex,
            from: .codex,
            to: .claude,
            action: .handoff,
            marker: "Implementation tested <bridge:continue>"
        )
        try record(
            source: .claude,
            from: .claude,
            to: .none,
            action: .complete,
            marker: "Independent review passed <bridge:complete>"
        )

        let report = CoordinationProofAuditor.audit(
            status: BridgeStatus(
                state: .complete,
                activeAgent: .none,
                session: session,
                latestDecision: nil,
                quota: [:],
                provider: coordinator
            ),
            store: store,
            projectVerification: CoordinationProjectVerification(
                packagePresent: true,
                designPresent: true,
                implementationPresent: true,
                reviewPresent: true,
                reviewDeclaredPass: true,
                swiftTestPassed: true,
                swiftTestExitCode: 0,
                swiftTestTimedOut: false,
                swiftTestOutputTail: "All tests passed."
            )
        )
        XCTAssertTrue(report.passed)
        XCTAssertGreaterThanOrEqual(report.geminiHeardClaudeEvents, 1)
        XCTAssertGreaterThanOrEqual(report.geminiHeardCodexEvents, 1)
        XCTAssertEqual(report.fallbackDecisions, 0)
        XCTAssertEqual(report.crossAgentHandoffs, 2)
    }

    func testCoordinationAuditorFailsWithoutIndependentProjectEvidence() throws {
        let project = try temporaryProject()
        let store = try ProjectStore(projectPath: project.path)
        var session = runtime(project: project)
        session.state = .complete
        session.turnCount = 3
        try store.initialize(session: session)
        let report = CoordinationProofAuditor.audit(
            status: BridgeStatus(
                state: .complete,
                activeAgent: .none,
                session: session,
                latestDecision: nil,
                quota: [:],
                provider: ProviderHealth(
                    provider: "gemini",
                    state: .ready,
                    fallbackActive: false
                )
            ),
            store: store,
            projectVerification: CoordinationProjectVerification(
                packagePresent: false,
                designPresent: false,
                implementationPresent: false,
                reviewPresent: false,
                reviewDeclaredPass: false,
                swiftTestPassed: false,
                swiftTestExitCode: nil,
                swiftTestTimedOut: false,
                swiftTestOutputTail: nil
            )
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.schemaVersion, "1.1")
        XCTAssertEqual(
            report.requirements.first { $0.id == "independent-swift-test" }?.passed,
            false
        )
    }

    private func temporaryProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func runtime(project: URL) -> RuntimeSession {
        RuntimeSession(
            id: UUID().uuidString,
            projectPath: project.path,
            goal: "Test the bridge",
            createdAt: Date(),
            deadline: Date().addingTimeInterval(600),
            state: .idle,
            activeAgent: .none,
            preferredStartingAgent: .claude,
            agentSessionIDs: [:],
            lastEventID: nil,
            lastError: nil,
            wakeAt: nil,
            turnCount: 0
        )
    }
}
