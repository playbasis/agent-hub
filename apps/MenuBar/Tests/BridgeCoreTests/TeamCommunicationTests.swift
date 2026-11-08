import Foundation
import XCTest
@testable import BridgeCore

final class TeamCommunicationTests: XCTestCase {
    func testWorkerMessagesAdviceIdentityDeduplicationAndStaleRound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-comm-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = CommunicatingFake()
        let service = TeamRoomService(directory: root.appendingPathComponent("journal"), provider: fake)
        let room = try await service.create(RoomCommand(text: "Communication proof"))
        var settings = RoomSettings(); settings.helpLimit = 2
        _ = try await service.configure(RoomCommand(roomID: room.id, projectPath: root.path, settings: settings))
        _ = try await service.activate(RoomCommand(roomID: room.id))
        _ = try await service.send(RoomCommand(roomID: room.id, text: "Build"))
        var record: RoomWorkRecord?
        for _ in 0..<100 {
            record = try await service.list()[0].work?.first { $0.state == "running" }
            if record != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let work = try XCTUnwrap(record)
        XCTAssertEqual(work.task.context?.roomID, room.id)
        XCTAssertEqual(work.task.context?.workID, work.id)
        let note = RoomTeamNote(roomID: room.id, roundID: work.round, workID: work.id, kind: "ownership", to: "Claude", text: "Backend owns server.cjs; GET /api/items returns items.")
        let sent = try await service.post(note)
        let retried = try await service.post(note)
        XCTAssertEqual(sent.id, retried.id)
        XCTAssertEqual(sent.author, "Codex")
        XCTAssertEqual(sent.recipient, "Claude")
        let question = RoomTeamNote(roomID: room.id, roundID: work.round, workID: work.id, kind: "question", to: "Gemini", text: "Keep the existing cursor field?")
        let answer = try await service.ask(question)
        let repeated = try await service.ask(question)
        XCTAssertEqual(answer.id, repeated.id)
        XCTAssertEqual(answer.author, "Gemini")
        XCTAssertEqual(answer.state, "complete")
        XCTAssertEqual(answer.replyTo, question.requestID)
        let calls = await fake.adviceCalls
        XCTAssertEqual(calls, 1)
        let peer = RoomTeamNote(roomID: room.id, roundID: work.round, workID: work.id, kind: "question", to: "Claude", text: "Which field does the UI need?")
        let peerAnswer = try await service.ask(peer)
        XCTAssertEqual(peerAnswer.author, "Claude")
        let overBudget = RoomTeamNote(roomID: room.id, roundID: work.round, workID: work.id, kind: "question", to: "Lead", text: "One more question")
        do { _ = try await service.ask(overBudget); XCTFail("Consultation budget not enforced") } catch {}
        let finalCalls = await fake.adviceCalls
        XCTAssertEqual(finalCalls, 2)
        let context = try await service.context(roomID: room.id)
        XCTAssertEqual(context.messages.filter { $0.id == note.requestID }.count, 1)
        XCTAssertEqual(context.messages.filter { $0.replyTo == question.requestID }.count, 1)
        let wrongWorker = RoomTeamNote(roomID: room.id, roundID: work.round, workID: UUID(), text: "spoof")
        do { _ = try await service.post(wrongWorker); XCTFail("Unknown worker could post") } catch {}
        _ = try await service.stop(RoomCommand(roomID: room.id))
        do { _ = try await service.post(note); XCTFail("Stopped worker could post") } catch {}
        await service.shutdown()
    }

    func testCommunicationEndpointsRequireAuthentication() async throws {
        let config = try BridgeConfiguration.makeDefault()
        let router = BridgeRouter(configuration: config, orchestrator: Orchestrator(configuration: config))
        for (method, path) in [("GET", "/rooms/context?room=\(UUID())"), ("POST", "/rooms/post"), ("POST", "/rooms/ask")] {
            let response = await router.handle(HTTPRequest(method: method, target: path, headers: [:], body: Data()))
            XCTAssertEqual(response.status, 401)
        }
    }
}

private actor CommunicatingFake: RoomTeamProvider {
    var adviceCalls = 0
    func plan(messages: [RoomMessage], project: String?, discussionOnly: Bool) async throws -> RoomPlan {
        RoomPlan(mode: .implement, message: "Backend will work", contract: "GET /api/items", tasks: [RoomWork(id: "backend", owner: "Codex", kind: .implement, title: "Backend", prompt: "Build", dependsOn: [])])
    }
    func reply(as participant: String, messages: [RoomMessage], workspace: URL) async throws -> RoomReply {
        adviceCalls += 1
        return RoomReply(text: "Yes, preserve the cursor contract.", model: "fake")
    }
    func execute(task: RoomWork, contract: String, history: [RoomMessage], project: URL, progress: @escaping @Sendable (RoomActivity) async -> Void) async throws -> RoomReply {
        try await Task.sleep(for: .seconds(5))
        return RoomReply(text: "Done", model: "fake")
    }
}
