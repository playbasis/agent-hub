import Foundation

/// Additive stdio MCP server bound to one active room worker. No shell or
/// project mutation tools; native harness MCP configuration remains loaded.
public enum RoomMCPServer {
    public static func run(configuration: BridgeConfiguration, context: RoomExecutionContext) async {
        let client = BridgeAPIClient(configuration: configuration)
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? BridgeJSON.decoder.decode([String: JSONValue].self, from: data),
                  let method = request["method"]?.stringValue else { continue }
            guard let id = request["id"] else { continue }
            var response: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
            do {
                switch method {
                case "initialize":
                    response["result"] = .object([
                        "protocolVersion": request["params"]?.objectValue?["protocolVersion"] ?? .string("2024-11-05"),
                        "capabilities": .object(["tools": .object([:])]),
                        "serverInfo": .object(["name": .string("bridge-team"), "version": .string("1.0")])
                    ])
                case "ping": response["result"] = .object([:])
                case "tools/list":
                    let fields: [String: JSONValue] = ["text": .object(["type": .string("string")]), "kind": .object(["type": .string("string")]), "to": .object(["type": .string("string")])]
                    let tools = [
                        ("room_read", "Read the team's shared goal, conversation, contract and work status."),
                        ("room_post", "Share an update, ownership, question, blocker, subagent result or handoff. Recipient: team, Claude, Codex or Gemini. Use update for a confirmation."),
                        ("room_ask", "Ask Lead, Claude, Codex or Gemini for help or missing context. Defaults to Lead. Question and answer are saved in the room.")
                    ].map { name, description in JSONValue.object([
                        "name": .string(name), "description": .string(description),
                        "inputSchema": .object(["type": .string("object"), "properties": .object(name == "room_read" ? [:] : fields), "required": .array(name == "room_read" ? [] : [.string("text")]), "additionalProperties": .bool(false)])
                    ]) }
                    response["result"] = .object(["tools": .array(tools)])
                case "tools/call":
                    let params = request["params"]?.objectValue ?? [:]
                    let name = params["name"]?.stringValue ?? ""
                    let args = params["arguments"]?.objectValue ?? [:]
                    let output: Data
                    if name == "room_read" {
                        output = try BridgeJSON.compactEncoder.encode(try await client.teamContext(roomID: context.roomID))
                    } else if ["room_post", "room_ask"].contains(name) {
                        let note = RoomTeamNote(roomID: context.roomID, roundID: context.roundID, workID: context.workID,
                                               kind: name == "room_ask" ? "question" : args["kind"]?.stringValue ?? "update",
                                               to: args["to"]?.stringValue ?? (name == "room_ask" ? "Lead" : "team"),
                                               text: args["text"]?.stringValue ?? "")
                        output = try BridgeJSON.compactEncoder.encode(try await client.teamNote(note, ask: name == "room_ask"))
                    } else { throw BridgeError.invalidRequest("Unknown room tool") }
                    let content = JSONValue.object(["type": .string("text"), "text": .string(String(decoding: output, as: UTF8.self))])
                    response["result"] = .object(["content": .array([content])])
                default:
                    response["error"] = .object(["code": .number(-32601), "message": .string("Method not found")])
                }
            } catch {
                let content = JSONValue.object(["type": .string("text"), "text": .string(error.localizedDescription)])
                response["result"] = .object(["isError": .bool(true), "content": .array([content])])
            }
            if let data = try? BridgeJSON.compactEncoder.encode(response) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
    }
}
