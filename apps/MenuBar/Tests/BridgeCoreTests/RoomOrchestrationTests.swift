import Foundation
import XCTest
@testable import BridgeCore

final class RoomOrchestrationTests: XCTestCase {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-team-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func wait(_ service: TeamRoomService) async throws -> TeamRoom {
        for _ in 0..<150 {
            let room = try await service.list()[0]
            if !room.busy { return room }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Team round did not finish")
        return try await service.list()[0]
    }

    private func work(_ id: String, kind: RoomWorkKind = .inspect, deps: [String] = []) -> RoomWork {
        RoomWork(id: id, owner: id == "frontend" ? "Claude" : "Codex", kind: kind, title: id, prompt: "Complete \(id) and report evidence", dependsOn: deps)
    }

    func testSettingsArePerRoomPersistedAndImmutableDuringRound() async throws {
        let root = try temp()
        let fake = TeamFake(plan: RoomPlan(mode: .discuss, message: "Let's talk", contract: "", tasks: []))
        let service = TeamRoomService(directory: root, provider: fake)
        let room = try await service.create(RoomCommand())
        var settings = RoomSettings(); settings.claudeModel = "claude-fable-5-1"; settings.codexModel = "gpt-6-astra"
        _ = try await service.configure(RoomCommand(roomID: room.id, settings: settings))
        let loaded = TeamRoomService(directory: root, provider: fake)
        let after = try await loaded.list()[0]
        XCTAssertEqual(after.settings, settings)
        _ = try await service.activate(RoomCommand(roomID: room.id))
        _ = try await service.send(RoomCommand(roomID: room.id, text: "Hello"))
        do { _ = try await service.configure(RoomCommand(roomID: room.id, settings: RoomSettings())); XCTFail("Changed models during active round") } catch {}
        let done = try await wait(service)
        XCTAssertEqual(done.settings?.codexModel, "gpt-6-astra")
    }

    func testPlanRejectsCyclesUnknownOwnersAndWriteInDiscussionOrReview() throws {
        let badPlans = [
            RoomPlan(mode: .implement, message: "bad", contract: "", tasks: [work("a", deps: ["b"]), work("b", deps: ["a"])]),
            RoomPlan(mode: .discuss, message: "bad", contract: "", tasks: [work("a", kind: .implement)]),
            RoomPlan(mode: .review, message: "bad", contract: "", tasks: [work("a", kind: .implement)]),
            RoomPlan(mode: .implement, message: "bad", contract: "", tasks: [RoomWork(id: "a", owner: "Gemini", kind: .implement, title: "a", prompt: "edit", dependsOn: [])])
        ]
        for plan in badPlans { XCTAssertThrowsError(try plan.validate(project: "/project", discussionOnly: false)) }
        let valid = RoomPlan(mode: .implement, message: "build", contract: "API", tasks: [work("backend", kind: .implement), work("frontend", kind: .implement, deps: ["backend"])])
        XCTAssertThrowsError(try valid.validate(project: nil, discussionOnly: false))
        XCTAssertThrowsError(try valid.validate(project: "/project", discussionOnly: true))
    }

    func testParallelScoutsAndSerializedWritesWithActivityAndDependencies() async throws {
        let plan = RoomPlan(mode: .implement, message: "Build together", contract: "GET /api/items", tasks: [work("scout-a"), work("scout-b"), work("backend", kind: .implement, deps: ["scout-a", "scout-b"]), work("frontend", kind: .implement, deps: ["backend"]), work("checks", kind: .verify, deps: ["frontend"])])
        let fake = TeamFake(plan: plan)
        let service = TeamRoomService(directory: try temp(), provider: fake)
        let room = try await service.create(RoomCommand())
        _ = try await service.configure(RoomCommand(roomID: room.id, projectPath: try temp().path))
        _ = try await service.activate(RoomCommand(roomID: room.id))
        _ = try await service.send(RoomCommand(roomID: room.id, text: "Build the app"))
        let done = try await wait(service)
        XCTAssertEqual(done.work?.count, 5)
        XCTAssertTrue(done.work?.allSatisfy { $0.state == "complete" && $0.sessionID != nil && !$0.activities.isEmpty } == true)
        let stats = await fake.stats()
        XCTAssertEqual(stats.0, 2)
        XCTAssertEqual(stats.1, 1)
        XCTAssertEqual(stats.2.suffix(3), ["backend", "frontend", "checks"])
    }

    func testFailedDependencyBlocksDownstreamWork() async throws {
        let fake = TeamFake(plan: RoomPlan(mode: .implement, message: "Build", contract: "", tasks: [work("backend", kind: .implement), work("frontend", kind: .implement, deps: ["backend"])]), fail: "backend")
        let service = TeamRoomService(directory: try temp(), provider: fake)
        let room = try await service.create(RoomCommand())
        _ = try await service.configure(RoomCommand(roomID: room.id, projectPath: try temp().path))
        _ = try await service.activate(RoomCommand(roomID: room.id))
        _ = try await service.send(RoomCommand(roomID: room.id, text: "Build"))
        let done = try await wait(service)
        XCTAssertEqual(done.work?.map(\.state), ["failed", "blocked"])
        let stats = await fake.stats()
        XCTAssertEqual(stats.2.count, 1)
    }

    func testLegacyRoomsDecodeAndEventParserOmitsReasoningAndArguments() throws {
        let room = TeamRoom(title: "Legacy room")
        let decoded = try BridgeJSON.decoder.decode(TeamRoom.self, from: BridgeJSON.encoder.encode(room))
        XCTAssertNil(decoded.settings)
        let reasoning = #"{"type":"item.completed","item":{"type":"reasoning","text":"private reasoning"}}"#
        XCTAssertTrue(RoomEventParser.activities(line: reasoning, claude: false).isEmpty)
        let tool = #"{"type":"assistant","parent_tool_use_id":"parent","message":{"content":[{"type":"tool_use","id":"child","name":"Agent","input":{"prompt":"private text"}}]}}"#
        let events = RoomEventParser.activities(line: tool, claude: true)
        XCTAssertEqual(events.first?.kind, "subagent")
        XCTAssertEqual(events.first?.parentID, "parent")
        XCTAssertFalse(events.first?.label.contains("private text") == true)
    }

    func testNewRoomsLeadWithClaudeWhenGeminiHasNoKey() throws {
        let config = try BridgeConfiguration.makeDefault()
        let keyless = RoomSettings(configuration: config, geminiAvailable: false)
        XCTAssertEqual(keyless.leadName, "Claude")
        XCTAssertEqual(keyless.selectedLeadModel, config.agents.claudeModel)
        XCTAssertNoThrow(try keyless.validate())
        XCTAssertEqual(RoomSettings(configuration: config, geminiAvailable: true).leadName, "Gemini")
        // Rooms saved before a lead was chosen keep their Gemini lead.
        XCTAssertEqual(try BridgeJSON.decoder.decode(RoomSettings.self, from: BridgeJSON.encoder.encode(RoomSettings())).leadName, "Gemini")
    }

    func testModelIDsCanBeConfiguredWithoutChangingOtherRoles() throws {
        var settings = RoomSettings()
        for model in ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-6-astra", "custom-provider-id"] {
            settings.codexModel = model
            XCTAssertNoThrow(try settings.validate())
        }
        settings.claudeModel = "claude-fable-5-1"
        XCTAssertNoThrow(try settings.validate())
        settings.codexModel = ""
        XCTAssertThrowsError(try settings.validate())
        for name in ["room-coordinator-v1", "room-frontend-v1", "room-backend-v1", "room-review-v1"] { XCTAssertFalse(try RoomPrompts.resource(name).isEmpty) }
    }

    func testLeadIsIndependentOfEconomicalWorkersAndPersists() throws {
        var settings = RoomSettings()
        settings.leadProvider = "Codex"; settings.leadModel = "gpt-6-astra"
        settings.codexModel = "gpt-5.6-luna"; settings.helpLimit = 3
        try settings.validate()
        let restored = try BridgeJSON.decoder.decode(RoomSettings.self, from: BridgeJSON.encoder.encode(settings))
        XCTAssertEqual(restored.selectedLeadModel, "gpt-6-astra")
        XCTAssertEqual(restored.codexModel, "gpt-5.6-luna")
        XCTAssertEqual(restored.helpLimit, 3)
        settings.leadProvider = "Claude"; settings.leadModel = "claude-fable-5-1"
        XCTAssertNoThrow(try settings.validate())
        settings.leadProvider = "invalid"
        XCTAssertThrowsError(try settings.validate())
    }

    func testLiveSelectableLeads() async throws {
        guard ProcessInfo.processInfo.environment["BRIDGE_LEAD_PROOF"] == "1" else { throw XCTSkip("Opt-in native lead planning checks") }
        let config = try ConfigurationStore.load(create: false)
        for (owner, model) in [("Codex", "gpt-6-astra"), ("Codex", "gpt-5.6-sol"), ("Claude", "claude-fable-5-1")] {
            var settings = RoomSettings(configuration: config)
            settings.leadProvider = owner; settings.leadModel = model
            settings.claudeEffort = "low"; settings.codexEffort = "low"
            let live = LiveRoomProvider(configuration: config, settings: settings)
            let plan = try await live.plan(messages: [RoomMessage(author: "You", text: "Hello. Discuss how we can coordinate frontend and backend work. Do not implement anything.")], project: nil, discussionOnly: true)
            try plan.validate(project: nil, discussionOnly: true)
            XCTAssertTrue([RoomMode.discuss, .clarify].contains(plan.mode))
            XCTAssertTrue(plan.tasks.isEmpty)
            print("LEAD PROOF \(model): \(plan.mode.rawValue) / \(plan.message)")
        }
    }

    func testConfiguredModelsAndEffortReachWorkerCLIUnchanged() async throws {
        let root = try temp()
        let shim = root.appendingPathComponent("provider-shim")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > args.txt
        cat > prompt.txt
        printf '%s\\n' '{"type":"thread.started","thread_id":"native-test"}' '{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}' '{"type":"result","is_error":false,"result":"hello"}'
        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        var config = try BridgeConfiguration.makeDefault()
        config.agents.codexCommand = shim.path; config.agents.claudeCommand = shim.path
        for model in ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-6-astra"] {
            var settings = RoomSettings(); settings.codexModel = model; settings.codexEffort = "xhigh"
            let live = LiveRoomProvider(configuration: config, settings: settings)
            let result = try await live.execute(task: work("backend", kind: .implement), contract: "", history: [], project: root, progress: { _ in })
            XCTAssertEqual(result.model, model)
            let arguments = try String(contentsOf: root.appendingPathComponent("args.txt"))
            XCTAssertTrue(arguments.contains("--model\n\(model)\n"))
            XCTAssertTrue(arguments.contains("model_reasoning_effort=\"xhigh\""))
            for forbidden in ["--ignore-user-config", "--ignore-rules", "--sandbox", "developer_instructions=", "agents.enabled=", "agents.max_", "agents.default_subagent_model="] {
                XCTAssertFalse(arguments.contains(forbidden), "Native harness was overridden: \(forbidden)")
            }
            XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("prompt.txt")).contains("Bridge team coordination"))
        }
        var settings = RoomSettings(); settings.claudeModel = "claude-fable-5-1"; settings.claudeEffort = "max"
        let live = LiveRoomProvider(configuration: config, settings: settings)
        _ = try await live.execute(task: work("frontend", kind: .implement), contract: "", history: [], project: root, progress: { _ in })
        let arguments = try String(contentsOf: root.appendingPathComponent("args.txt"))
        XCTAssertTrue(arguments.contains("--model\nclaude-fable-5-1\n"))
        XCTAssertTrue(arguments.contains("--effort\nmax\n"))
        for forbidden in ["--safe-mode", "--restricted", "--strict-mcp-config", "--no-chrome", "--permission-mode", "--tools", "--system-prompt"] {
            XCTAssertFalse(arguments.contains(forbidden), "Native harness was overridden: \(forbidden)")
        }
    }

    func testLiveModelSelections() async throws {
        guard ProcessInfo.processInfo.environment["BRIDGE_ROOM_MODELS_PROOF"] == "1" else { throw XCTSkip("Opt-in actual account model checks") }
        let config = try ConfigurationStore.load(create: false)
        let root = try temp()
        for (owner, model) in [("Codex", "gpt-5.6-terra"), ("Codex", "gpt-6-astra"), ("Claude", "claude-fable-5-1")] {
            var settings = RoomSettings(configuration: config)
            settings.codexModel = owner == "Codex" ? model : "gpt-5.6-luna"
            settings.claudeModel = owner == "Claude" ? model : config.agents.claudeModel
            settings.codexEffort = "low"; settings.claudeEffort = "low"
            do {
                let reply = try await LiveRoomProvider(configuration: config, settings: settings).reply(as: owner, messages: [RoomMessage(author: "You", text: "Room connectivity check. Reply with exactly the word connected. Do not use tools.")], workspace: root)
                print("MODEL CHECK \(model): \(reply.text)")
                XCTAssertEqual(reply.model, model)
                XCTAssertTrue(reply.text.lowercased().contains("connected"))
            } catch { XCTFail("MODEL CHECK \(model): \(error.localizedDescription)") }
        }
    }

    func testLiveGeminiRoutesAndTeamBuildsAnApp() async throws {
        guard ProcessInfo.processInfo.environment["BRIDGE_TEAM_BUILD_PROOF"] == "1" else { throw XCTSkip("Opt-in real implementation proof") }
        let config = try ConfigurationStore.load(create: false)
        let project = try temp(), journal = try temp()
        try """
        # Project instructions
        Small Node.js application using built-in modules only. No dependencies or package installation.
        Backend: server.cjs must export createServer(), which returns an unstarted http.Server.
        GET /api/health returns JSON {"ok":true,"team":"bridge"}.
        GET / serves index.html. No external services. Do not deploy or publish.
        Frontend: index.html titled Team notes and a Refresh button calling /api/health.
        """.write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        var settings = RoomSettings(configuration: config)
        settings.codexModel = "gpt-5.6-luna"; settings.codexEffort = "low"; settings.claudeEffort = "low"
        let service = TeamRoomService(directory: journal, provider: LiveRoomProvider(configuration: config, settings: settings))
        let room = try await service.create(RoomCommand(text: "App building proof"))
        _ = try await service.configure(RoomCommand(roomID: room.id, projectPath: project.path, settings: settings))
        _ = try await service.activate(RoomCommand(roomID: room.id))
        _ = try await service.send(RoomCommand(roomID: room.id, text: "Build the small Team notes app described by AGENTS.md now. First fan out two independent read-only scouts: Claude inspects the frontend requirements; Codex inspects the backend requirements. Then Codex implements server.cjs, Claude implements index.html, then Codex verifies the integrated app. Keep it minimal: no packages, no external services, no deployment. Use the exact server export and health response from AGENTS.md. Return real files and test results."))
        var result: TeamRoom?
        for step in 0..<1200 {
            let current = try await service.list()[0]
            if step % 10 == 0 { print("BUILD PROOF \(current.plan?.mode.rawValue ?? "routing"): \((current.work ?? []).map { "\($0.task.id)=\($0.state)" }.joined(separator: ", "))") }
            if !current.busy { result = current; break }
            try await Task.sleep(for: .seconds(1))
        }
        let finished = try XCTUnwrap(result)
        print("BUILD HANDOFF " + finished.messages.map { "\($0.author) [\($0.state)] \($0.text)" }.joined(separator: "\n"))
        XCTAssertEqual(finished.plan?.mode, .implement)
        XCTAssertTrue(finished.work?.contains { $0.task.owner == "Claude" && $0.task.kind == .implement && $0.state == "complete" } == true)
        XCTAssertTrue(finished.work?.contains { $0.task.owner == "Codex" && $0.task.kind == .implement && $0.state == "complete" && $0.model == "gpt-5.6-luna" } == true)
        XCTAssertTrue(finished.work?.allSatisfy { $0.state == "complete" && $0.sessionID != nil } == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("index.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("server.cjs").path))
        let check = try await ProcessRunner.run(executable: "node", arguments: ["-e", "const assert=require('node:assert'); const {createServer}=require('./server.cjs'); const server=createServer(); server.listen(0,'127.0.0.1',async()=>{try {const base='http://127.0.0.1:'+server.address().port; const response=await fetch(base+'/api/health'); assert.equal(response.status,200); const health=await response.json(); assert.equal(health.ok,true); assert.equal(health.team,'bridge'); const html=await (await fetch(base+'/')).text(); assert.match(html,/Team notes/i); assert.match(html,/api\\/health/); console.log('INDEPENDENT APP CHECK PASSED'); }catch(error){console.error(error);process.exitCode=1;}finally{server.close();}});"], currentDirectory: project, stdin: "", timeoutSeconds: 20, maximumOutputCharacters: 3000)
        print(check.stdout + check.stderr)
        XCTAssertEqual(check.status, 0)
        XCTAssertFalse(check.timedOut)
        let reopened = TeamRoomService(directory: journal, provider: LiveRoomProvider(configuration: config))
        let restored = try await reopened.list()[0]
        XCTAssertEqual(restored.work, finished.work)
        XCTAssertEqual(restored.settings, settings)
    }

    func testLiveNativeSubagentEvents() async throws {
        guard ProcessInfo.processInfo.environment["BRIDGE_NATIVE_CHILD_PROOF"] == "1" else { throw XCTSkip("Opt-in native subagent proof") }
        let root = try temp()
        try "# Fixture\nThis project is named Amber. Inspect only.\n".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let configuration = try ConfigurationStore.load(create: false)
        var settings = RoomSettings(configuration: configuration)
        settings.codexEffort = "low"; settings.claudeEffort = "low"
        for owner in ["Claude", "Codex"] {
            let recorder = RoomActivityRecorder()
            let task = RoomWork(id: "native-scout", owner: owner, kind: .inspect, title: "Native child proof", prompt: "Use exactly one native read-only subagent to read AGENTS.md and tell you the project name. You MUST delegate this small check for the harness proof, wait for the child, and report the name plus the child's result. Do not edit, run tests or recurse.", dependsOn: [])
            let result = try await LiveRoomProvider(configuration: configuration, settings: settings).execute(task: task, contract: "Read-only child invocation", history: [], project: root) { event in await recorder.add(event) }
            let events = await recorder.events
            print("NATIVE CHILD \(owner): \(result.text)\nEVENTS: \(events)")
            XCTAssertTrue(result.text.contains("Amber"))
            XCTAssertTrue(events.contains { $0.kind == "session" && $0.nativeID != nil })
            XCTAssertTrue(events.contains { $0.kind == "subagent" })
        }
    }
}

private actor RoomActivityRecorder {
    var events: [RoomActivity] = []
    func add(_ event: RoomActivity) { events.append(event) }
}

private actor TeamFake: RoomTeamProvider {
    let selectedPlan: RoomPlan
    let fail: String?
    var activeScouts = 0, maximumScouts = 0, activeWriters = 0, maximumWriters = 0
    var completed: [String] = []
    init(plan: RoomPlan, fail: String? = nil) { selectedPlan = plan; self.fail = fail }
    func plan(messages: [RoomMessage], project: String?, discussionOnly: Bool) async throws -> RoomPlan { selectedPlan }
    func reply(as participant: String, messages: [RoomMessage], workspace: URL) async throws -> RoomReply {
        try await Task.sleep(for: .milliseconds(20))
        return RoomReply(text: "Review complete", model: "fake")
    }
    func execute(task: RoomWork, contract: String, history: [RoomMessage], project: URL, progress: @escaping @Sendable (RoomActivity) async -> Void) async throws -> RoomReply {
        if task.kind == .inspect { activeScouts += 1; maximumScouts = max(maximumScouts, activeScouts) }
        else { activeWriters += 1; maximumWriters = max(maximumWriters, activeWriters) }
        defer { if task.kind == .inspect { activeScouts -= 1 } else { activeWriters -= 1 }; completed.append(task.id) }
        await progress(RoomActivity(kind: "session", label: "Connected", nativeID: "session-\(task.id)"))
        await progress(RoomActivity(kind: "subagent", label: "Inspecting", nativeID: "child", parentID: "session-\(task.id)"))
        try await Task.sleep(for: .milliseconds(80))
        if fail == task.id { throw BridgeError.processFailed("worker failed") }
        return RoomReply(text: "Reported evidence for \(task.id)", model: "fake")
    }
    func stats() -> (Int, Int, [String]) { (maximumScouts, maximumWriters, completed) }
}
