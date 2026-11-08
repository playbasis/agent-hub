import Foundation
import XCTest
@testable import BridgeCore

final class TeamRoomTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-room-test-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    private func settled(_ service: TeamRoomService, timeout: Int = 100) async throws -> TeamRoom {
        for _ in 0..<timeout {
            if let room = try await service.list().first, !room.busy { return room }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Room did not settle")
        return try await service.list()[0]
    }

    func testRoundPersistsAndRetryDoesNotDuplicate() async throws {
        let root = try directory(), provider = RecordingRoomProvider()
        let service = TeamRoomService(directory: root, provider: provider)
        let create = RoomCommand(text: "Lobby proof")
        let room = try await service.create(create)
        let duplicate = try await service.create(create)
        XCTAssertEqual(room.id, duplicate.id)
        _ = try await service.activate(RoomCommand(roomID: room.id))
        let message = RoomCommand(roomID: room.id, text: "Hello, team")
        _ = try await service.send(message)
        _ = try await service.send(message)
        let finished = try await settled(service)
        XCTAssertEqual(finished.messages.filter { $0.author == "You" }.count, 1)
        XCTAssertEqual(finished.messages.filter { $0.author == "Gemini" }.count, 2)
        XCTAssertEqual(finished.messages.filter { $0.author == "Claude" }.count, 1)
        XCTAssertEqual(finished.messages.filter { $0.author == "Codex" }.count, 1)
        let contexts = await provider.contexts
        XCTAssertEqual(contexts["Claude"]?.first, contexts["Codex"]?.first)
        XCTAssertTrue(contexts["Gemini"]?.last?.contains("Claude: hello") == true)
        XCTAssertTrue(contexts["Gemini"]?.last?.contains("Codex: hello") == true)
        let restored = TeamRoomService(directory: root, provider: provider)
        let reloaded = try await restored.list()[0]
        XCTAssertEqual(reloaded.messages, finished.messages)
        XCTAssertFalse(reloaded.busy)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("rooms.jsonl").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRestartInterruptsAndPreservesTornSuffix() async throws {
        let root = try directory()
        var room = TeamRoom(title: "Recover me")
        room.active = true; room.round = UUID()
        room.messages = [RoomMessage(author: "You", text: "persist me"), RoomMessage(author: "Claude", text: "Thinking…", state: "thinking")]
        var data = try BridgeJSON.compactEncoder.encode(room)
        data.append(Data("\n{torn".utf8))
        try data.write(to: root.appendingPathComponent("rooms.jsonl"))
        let provider = RecordingRoomProvider()
        let service = TeamRoomService(directory: root, provider: provider)
        let restored = try await service.list()[0]
        XCTAssertFalse(restored.busy)
        XCTAssertEqual(restored.messages[1].state, "interrupted")
        XCTAssertEqual(restored.messages[0].text, "persist me")
        let calls = await provider.contexts
        XCTAssertTrue(calls.isEmpty)
        let again = TeamRoomService(directory: root, provider: provider)
        let stable = try await again.list()[0]
        XCTAssertEqual(stable.messages, restored.messages)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("torn-") })
    }

    func testFailureIsVisibleAndOtherParticipantsStillReply() async throws {
        let service = TeamRoomService(directory: try directory(), provider: RecordingRoomProvider(failing: "Claude"))
        let room = try await service.create(RoomCommand())
        do { _ = try await service.send(RoomCommand(roomID: room.id, text: "Hello")); XCTFail("Inactive room accepted a message") } catch {}
        _ = try await service.activate(RoomCommand(roomID: room.id))
        _ = try await service.send(RoomCommand(roomID: room.id, text: "Hello"))
        let result = try await settled(service)
        XCTAssertEqual(result.messages.first { $0.author == "Claude" }?.state, "failed")
        XCTAssertEqual(result.messages.first { $0.author == "Codex" }?.state, "complete")
    }

    func testStopRejectsLateRepliesAndConcurrentSend() async throws {
        let service = TeamRoomService(directory: try directory(), provider: RecordingRoomProvider(delay: true))
        let room = try await service.create(RoomCommand())
        _ = try await service.activate(RoomCommand(roomID: room.id))
        _ = try await service.send(RoomCommand(roomID: room.id, text: "Hello"))
        try await Task.sleep(for: .milliseconds(30))
        do { _ = try await service.send(RoomCommand(roomID: room.id, text: "duplicate round")); XCTFail("Concurrent round accepted") } catch {}
        _ = try await service.stop(RoomCommand(roomID: room.id))
        try await Task.sleep(for: .milliseconds(300))
        let stopped = try await service.list()[0]
        XCTAssertFalse(stopped.busy)
        XCTAssertFalse(stopped.messages.contains { $0.state == "thinking" })
        XCTAssertFalse(stopped.messages.contains { $0.text == "hello" })
    }

    func testRoomRoutesRequireAuthentication() async throws {
        let configuration = try BridgeConfiguration.makeDefault()
        let router = BridgeRouter(configuration: configuration, orchestrator: Orchestrator(configuration: configuration), teamRooms: TeamRoomService(directory: try directory(), provider: RecordingRoomProvider()))
        for path in ["/rooms", "/rooms/messages", "/rooms/activate", "/rooms/stop"] {
            let response = await router.handle(HTTPRequest(method: "POST", target: path, headers: [:], body: Data()))
            XCTAssertEqual(response.status, 401)
        }
    }

    func testLiveConversationAndReload() async throws {
        guard ProcessInfo.processInfo.environment["BRIDGE_ROOM_LIVE_PROOF"] == "1" else { throw XCTSkip("Explicit opt-in: invokes the three real providers") }
        let configuration = try ConfigurationStore.load(create: false)
        let root = try directory()
        let service = TeamRoomService(directory: root, provider: LiveRoomProvider(configuration: configuration))
        let room = try await service.create(RoomCommand(text: "Live team room proof"))
        _ = try await service.activate(RoomCommand(roomID: room.id))
        _ = try await service.send(RoomCommand(roomID: room.id, text: "Hello team. We are proving a shared chat room. Reply in one short sentence with your role and acknowledge the discussion. Our shared check word is apricot. Do not use tools."))
        let result = try await settled(service, timeout: 2500)
        for name in ["Claude", "Codex", "Gemini"] {
            let replies = result.messages.filter { $0.author == name }
            XCTAssertFalse(replies.isEmpty)
            for reply in replies {
                print("LIVE ROOM \(name) [\(reply.state)] \(reply.model ?? "no model"): \(reply.text)")
                XCTAssertEqual(reply.state, "complete")
                XCTAssertTrue(reply.text.lowercased().contains("apricot"))
            }
        }
        let reopened = TeamRoomService(directory: root, provider: LiveRoomProvider(configuration: configuration))
        let restored = try await reopened.list()[0]
        XCTAssertEqual(restored.messages, result.messages)
        _ = try await reopened.send(RoomCommand(roomID: restored.id, text: "What was our shared check word? Each of you reply with that word and one short acknowledgment of a teammate. Use only the conversation."))
        let continued = try await settled(reopened, timeout: 2500)
        let newReplies = continued.messages.dropFirst(restored.messages.count).filter { $0.author != "You" }
        XCTAssertEqual(newReplies.count, 4)
        for reply in newReplies {
            print("REOPENED ROOM \(reply.author) [\(reply.state)]: \(reply.text)")
            XCTAssertEqual(reply.state, "complete")
            XCTAssertTrue(reply.text.lowercased().contains("apricot"))
        }
    }
}

private actor RecordingRoomProvider: RoomProvider {
    var contexts: [String: [String]] = [:]
    let failing: String?
    let delay: Bool
    init(failing: String? = nil, delay: Bool = false) { self.failing = failing; self.delay = delay }
    func reply(as participant: String, messages: [RoomMessage], workspace: URL) async throws -> RoomReply {
        contexts[participant, default: []].append(messages.map { "\($0.author): \($0.text)" }.joined(separator: "\n"))
        if delay { try? await Task.sleep(for: .milliseconds(200)) }
        if participant == failing { throw BridgeError.processFailed("Provider unavailable") }
        return RoomReply(text: "hello", model: "test-model")
    }
}
