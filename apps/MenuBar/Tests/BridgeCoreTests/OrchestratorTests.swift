@testable import BridgeCore
import Foundation
import XCTest

final class OrchestratorTests: XCTestCase {
    func testRecoveryRestoresCentralSnapshotWithoutOpeningProject() async throws {
        let missingProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-project-must-stay-unopened-\(UUID().uuidString)")
        let snapshot = RuntimeSession(
            id: UUID().uuidString,
            projectPath: missingProject.path,
            goal: "Resume only after an explicit action",
            createdAt: Date(),
            deadline: Date().addingTimeInterval(300),
            state: .running,
            activeAgent: .claude,
            preferredStartingAgent: .claude,
            agentSessionIDs: [:],
            lastEventID: nil,
            lastError: nil,
            wakeAt: nil,
            turnCount: 2
        )
        let configuration = try BridgeConfiguration.makeDefault()
        let orchestrator = Orchestrator(
            configuration: configuration,
            claudeRunner: TestRunner(agent: .claude),
            codexRunner: TestRunner(agent: .codex),
            configurationSaver: { _ in },
            recoveryLoader: { snapshot },
            recoverySaver: { _ in }
        )

        let recovered = await orchestrator.recover()

        XCTAssertEqual(recovered?.state, .paused)
        XCTAssertEqual(recovered?.activeAgent, AgentName.none)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingProject.path),
            "Startup recovery must not touch or create the project directory"
        )
    }

    func testStatusDoesNotLaunchProviderUsageCLIsInBackground() async throws {
        let directory = try makeProject()
        let marker = directory.appendingPathComponent("usage-cli-was-launched")
        let executable = directory.appendingPathComponent("provider-cli")
        let script = """
        #!/bin/sh
        touch "\(marker.path)"
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        var configuration = try BridgeConfiguration.makeDefault()
        configuration.agents.claudeCommand = executable.path
        configuration.agents.codexCommand = executable.path
        let orchestrator = Orchestrator(
            configuration: configuration,
            claudeRunner: TestRunner(agent: .claude),
            codexRunner: TestRunner(agent: .codex),
            configurationSaver: { _ in }
        )

        _ = await orchestrator.status()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testManagedTurnCompletesWithoutPingPong() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-orchestrator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }

        var configuration = try BridgeConfiguration.makeDefault()
        configuration.session.maximumTurns = 4
        configuration.trace.requireDualProvider = false
        let orchestrator = Orchestrator(
            configuration: configuration,
            claudeRunner: TestRunner(agent: .claude),
            codexRunner: TestRunner(agent: .codex),
            configurationSaver: { _ in }
        )
        _ = try await orchestrator.start(
            try SessionRequest(
                projectPath: project.path,
                goal: "Complete a deterministic test",
                durationMinutes: 5,
                startingAgent: .claude
            )
        )

        for _ in 0 ..< 50 {
            if await orchestrator.status().state == .complete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let status = await orchestrator.status()
        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(status.session?.turnCount, 1)
        XCTAssertEqual(status.latestDecision?.action, .complete)
    }

    func testHookCompletionCannotRaceManagedRunner() async throws {
        let project = try makeProject()
        var configuration = try BridgeConfiguration.makeDefault()
        configuration.session.maximumTurns = 4
        let orchestrator = Orchestrator(
            configuration: configuration,
            claudeRunner: SlowRunner(agent: .claude),
            codexRunner: TestRunner(agent: .codex),
            configurationSaver: { _ in }
        )
        let session = try await orchestrator.start(
            try SessionRequest(
                projectPath: project.path,
                goal: "Do not let hooks duplicate dispatch",
                durationMinutes: 5,
                startingAgent: .claude
            )
        )
        for _ in 0 ..< 50 {
            if await orchestrator.status().state == .running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let hook = BridgeEvent(
            source: .claude,
            type: .turnComplete,
            content: .string("A native Stop hook fired <bridge:complete>"),
            sessionID: session.id,
            projectPath: project.path,
            metadata: ["bridge_managed": .bool(false)]
        )
        try await orchestrator.ingest(hook)
        let runningStatus = await orchestrator.status()
        XCTAssertEqual(runningStatus.state, .running)
        try await orchestrator.pause()
        let pausedStatus = await orchestrator.status()
        XCTAssertEqual(pausedStatus.state, .paused)
    }

    func testForceHandoffCancelsCurrentGeneration() async throws {
        let project = try makeProject()
        var configuration = try BridgeConfiguration.makeDefault()
        configuration.trace.requireDualProvider = false
        let orchestrator = Orchestrator(
            configuration: configuration,
            claudeRunner: SlowRunner(agent: .claude),
            codexRunner: TestRunner(agent: .codex),
            configurationSaver: { _ in }
        )
        _ = try await orchestrator.start(
            try SessionRequest(
                projectPath: project.path,
                goal: "Force a clean hand-off",
                durationMinutes: 5,
                startingAgent: .claude
            )
        )
        for _ in 0 ..< 50 {
            if await orchestrator.status().activeAgent == .claude { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await orchestrator.forceHandoff(
            ForceHandoffRequest(agent: .codex, reason: "Use Codex now")
        )
        for _ in 0 ..< 100 {
            if await orchestrator.status().state == .complete { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let status = await orchestrator.status()
        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(status.session?.turnCount, 1)
    }

    func testDefaultCompletionPausesUntilDualProviderProofExists() async throws {
        let project = try makeProject()
        let configuration = try BridgeConfiguration.makeDefault()
        let orchestrator = Orchestrator(
            configuration: configuration,
            claudeRunner: TestRunner(agent: .claude),
            codexRunner: TestRunner(agent: .codex),
            configurationSaver: { _ in }
        )
        _ = try await orchestrator.start(
            try SessionRequest(
                projectPath: project.path,
                goal: "Require both providers",
                durationMinutes: 5,
                startingAgent: .claude
            )
        )

        for _ in 0 ..< 100 {
            if await orchestrator.status().state == .paused { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let status = await orchestrator.status()
        XCTAssertEqual(status.state, .paused)
        XCTAssertEqual(
            status.session?.lastError,
            "Completion paused: dual-provider proof is incomplete."
        )
    }

    func testShutdownCancelsWorkAndPersistsResumablePause() async throws {
        let project = try makeProject()
        let configuration = try BridgeConfiguration.makeDefault()
        let orchestrator = Orchestrator(
            configuration: configuration,
            claudeRunner: SlowRunner(agent: .claude),
            codexRunner: TestRunner(agent: .codex),
            configurationSaver: { _ in }
        )
        _ = try await orchestrator.start(
            try SessionRequest(
                projectPath: project.path,
                goal: "Pause safely if the host app closes",
                durationMinutes: 5,
                startingAgent: .claude
            )
        )
        for _ in 0 ..< 50 {
            if await orchestrator.status().state == .running { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        await orchestrator.shutdown()

        let status = await orchestrator.status()
        XCTAssertEqual(status.state, .paused)
        XCTAssertEqual(status.activeAgent, .none)
        XCTAssertEqual(
            status.session?.lastError,
            "Paused when the bridge app closed; resume manually."
        )

        let persisted = try ProjectStore(projectPath: project.path).loadRuntime()
        XCTAssertEqual(persisted?.state, .paused)
        XCTAssertEqual(persisted?.activeAgent, AgentName.none)
    }

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-orchestrator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }
        return project
    }
}

private struct TestRunner: AgentRunner {
    var agent: AgentName

    func run(
        project _: URL,
        prompt _: String,
        nativeSessionID _: String?,
        bridgeSessionID _: String
    ) async throws -> AgentResult {
        AgentResult(
            agent: agent,
            success: true,
            output: "All requested verification passed. <bridge:complete>",
            sessionID: UUID().uuidString,
            rateLimited: false,
            resetAt: nil,
            error: nil,
            diagnostics: [:]
        )
    }
}

private struct SlowRunner: AgentRunner {
    var agent: AgentName

    func run(
        project _: URL,
        prompt _: String,
        nativeSessionID _: String?,
        bridgeSessionID _: String
    ) async throws -> AgentResult {
        try await Task.sleep(for: .seconds(2))
        return AgentResult(
            agent: agent,
            success: true,
            output: "Slow result <bridge:continue>",
            sessionID: UUID().uuidString,
            rateLimited: false,
            resetAt: nil,
            error: nil,
            diagnostics: [:]
        )
    }
}
