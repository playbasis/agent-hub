import Foundation

public enum MCPServer {
    public static func run(configuration: BridgeConfiguration) async {
        let client = BridgeAPIClient(configuration: configuration)
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                write(response(id: NSNull(), error: "Invalid JSON-RPC request"))
                continue
            }
            let method = request["method"] as? String ?? ""
            let id = request["id"] ?? NSNull()
            if method == "notifications/initialized" { continue }
            do {
                let result = try await handle(method: method, request: request, client: client)
                write(["jsonrpc": "2.0", "id": id, "result": result])
            } catch {
                write(response(id: id, error: error.localizedDescription))
            }
        }
    }

    private static func handle(
        method: String,
        request: [String: Any],
        client: BridgeAPIClient
    ) async throws -> [String: Any] {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "claude-codex-bridge", "version": "0.1.0"],
            ]
        case "tools/list":
            return ["tools": toolDefinitions]
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let text = try await call(name: name, arguments: arguments, client: client)
            return ["content": [["type": "text", "text": text]], "isError": false]
        default:
            throw BridgeError.invalidRequest("Unsupported MCP method: \(method)")
        }
    }

    private static func call(
        name: String,
        arguments: [String: Any],
        client: BridgeAPIClient
    ) async throws -> String {
        switch name {
        case "bridge_get_status":
            return jsonString(try await client.status())
        case "bridge_start_session":
            guard let project = arguments["project_path"] as? String,
                  let goal = arguments["goal"] as? String
            else {
                throw BridgeError.invalidRequest("project_path and goal are required")
            }
            let duration = arguments["duration_minutes"] as? Int ?? 240
            let agent = AgentName(rawValue: arguments["starting_agent"] as? String ?? "claude")
                ?? .claude
            let session = try await client.start(
                try SessionRequest(
                    projectPath: project,
                    goal: goal,
                    durationMinutes: duration,
                    startingAgent: agent
                )
            )
            return jsonString(session)
        case "bridge_emit_event":
            guard let raw = arguments["event"],
                  JSONSerialization.isValidJSONObject(raw)
            else {
                throw BridgeError.invalidRequest("event object is required")
            }
            let data = try JSONSerialization.data(withJSONObject: raw)
            let event = try BridgeJSON.decoder.decode(BridgeEvent.self, from: data)
            try await client.submit(event)
            return #"{"accepted":true}"#
        case "bridge_force_handoff":
            let agent = AgentName(rawValue: arguments["agent"] as? String ?? "") ?? .none
            let reason = arguments["reason"] as? String ?? "MCP requested hand-off"
            return jsonString(try await client.handoff(agent: agent, reason: reason))
        default:
            throw BridgeError.invalidRequest("Unknown MCP tool: \(name)")
        }
    }

    private static var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "bridge_get_status",
                "description": "Read the current ClaudeCodexBridge session and routing status.",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "bridge_start_session",
                "description": "Start a bounded autonomous bridge session.",
                "inputSchema": [
                    "type": "object",
                    "required": ["project_path", "goal"],
                    "properties": [
                        "project_path": ["type": "string"],
                        "goal": ["type": "string"],
                        "duration_minutes": ["type": "integer", "minimum": 5, "maximum": 1_440],
                        "starting_agent": [
                            "type": "string",
                            "enum": ["claude", "codex"],
                        ],
                    ],
                ],
            ],
            [
                "name": "bridge_emit_event",
                "description": "Submit one canonical v1 bridge event.",
                "inputSchema": [
                    "type": "object",
                    "required": ["event"],
                    "properties": ["event": ["type": "object"]],
                ],
            ],
            [
                "name": "bridge_force_handoff",
                "description": "Force the active session to Claude or Codex.",
                "inputSchema": [
                    "type": "object",
                    "required": ["agent"],
                    "properties": [
                        "agent": ["type": "string", "enum": ["claude", "codex"]],
                        "reason": ["type": "string"],
                    ],
                ],
            ],
        ]
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? BridgeJSON.compactEncoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func response(id: Any, error: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32_000, "message": error],
        ]
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

