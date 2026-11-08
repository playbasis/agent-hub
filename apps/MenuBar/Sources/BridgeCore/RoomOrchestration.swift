import Foundation

public struct RoomSettings: Codable, Sendable, Equatable {
    public var claudeModel = "sonnet"
    public var codexModel = "gpt-5.6-luna"
    public var geminiModel = "gemini-3.5-flash"
    public var claudeEffort = "high"
    public var codexEffort = "high"
    public var maxParallelScouts = 3
    public var workerTimeoutSeconds = 600
    public var codexCommand: String?
    public var claudeCommand: String?
    public var leadProvider: String?
    public var leadModel: String?
    public var helpLimit: Int?
    public var leadName: String { leadProvider ?? "Gemini" }
    public var selectedLeadModel: String {
        leadModel ?? (leadName == "Claude" ? claudeModel : leadName == "Codex" ? codexModel : geminiModel)
    }
    public var delegationGuidance: String {
        "Use the smallest capable model for each child: cheap models for extraction and inspection, medium models for implementation and tests, premium models for architecture, hard blockers and final synthesis. Keep the selected lead at \(selectedLeadModel). Do not copy that premium model to every child. Use at most \(maxParallelScouts) simultaneous top-level scouts and \(helpLimit ?? 6) consultation calls this round. Reserve roughly a third of the available allowance for integration, fixes and final verification. Avoid duplicate research; reuse posted evidence. These are routing heuristics and launch limits, not measured token-budget enforcement. Native tools and skills remain available."
    }
    public init() {}
    public init(configuration: BridgeConfiguration) {
        claudeModel = configuration.agents.claudeModel
        geminiModel = configuration.meta.model
        claudeEffort = configuration.agents.claudeEffort
    }
    /// New rooms lead with Gemini only when its key is configured; Claude and
    /// Codex sign in through their own CLIs, so a keyless setup still works.
    public init(configuration: BridgeConfiguration, geminiAvailable: Bool) {
        self.init(configuration: configuration)
        if !geminiAvailable { leadProvider = "Claude" }
    }
    public func validate() throws {
        guard ["Gemini", "Claude", "Codex"].contains(leadName), (1...12).contains(helpLimit ?? 6) else { throw BridgeError.configuration("Invalid lead or consultation limit.") }
        if let leadModel, leadModel.isEmpty || leadModel.count > 160 || leadModel.contains("\n") { throw BridgeError.configuration("Invalid lead model ID.") }
        for value in [claudeModel, codexModel, geminiModel] {
            guard !value.isEmpty, value.count <= 160, value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.contains("\n") else {
                throw BridgeError.configuration("Enter a valid provider model ID.")
            }
        }
        for command in [codexCommand, claudeCommand].compactMap({ $0 }) {
            guard !command.isEmpty, command.count <= 1024, !command.contains("\n") else { throw BridgeError.configuration("Enter an executable path or command name, not a shell command.") }
        }
        guard ["low", "medium", "high", "xhigh", "max"].contains(claudeEffort),
              ["low", "medium", "high", "xhigh", "max"].contains(codexEffort),
              (1...3).contains(maxParallelScouts), (30...900).contains(workerTimeoutSeconds) else {
            throw BridgeError.configuration("Unsupported effort, concurrency or timeout setting.")
        }
    }
}

public enum RoomMode: String, Codable, Sendable { case discuss, clarify, implement, review }
public enum RoomWorkKind: String, Codable, Sendable { case inspect, implement, verify }

public struct RoomWork: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var owner: String
    public var kind: RoomWorkKind
    public var title: String
    public var prompt: String
    public var dependsOn: [String]
    public var context: RoomExecutionContext?
}

public struct RoomExecutionContext: Codable, Equatable, Sendable {
    public var roomID: UUID
    public var roundID: UUID
    public var workID: UUID
    public var helper: String
    public init(roomID: UUID, roundID: UUID, workID: UUID, helper: String) {
        self.roomID = roomID; self.roundID = roundID; self.workID = workID; self.helper = helper
    }
    public var environment: [String: String] {
        ["BRIDGE_TEAM_ROOM": roomID.uuidString, "BRIDGE_TEAM_ROUND": roundID.uuidString,
         "BRIDGE_TEAM_WORK": workID.uuidString, "BRIDGE_TEAM_CLI": helper]
    }
}

public struct RoomTeamNote: Codable, Sendable {
    public var roomID: UUID
    public var roundID: UUID
    public var workID: UUID
    public var requestID: UUID
    public var kind: String
    public var to: String
    public var text: String
    public init(roomID: UUID, roundID: UUID, workID: UUID, requestID: UUID = UUID(), kind: String = "update", to: String = "team", text: String) {
        self.roomID = roomID; self.roundID = roundID; self.workID = workID
        self.requestID = requestID; self.kind = kind; self.to = to; self.text = text
    }
}

public struct RoomPlan: Codable, Sendable, Equatable {
    public var mode: RoomMode
    public var message: String
    public var contract: String
    public var tasks: [RoomWork]

    public func validate(project: String?, discussionOnly: Bool) throws {
        guard !message.isEmpty, message.count <= 8_000, contract.count <= 16_000, tasks.count <= 6 else { throw BridgeError.configuration("Coordinator plan exceeds room limits.") }
        if mode == .discuss || mode == .clarify {
            guard tasks.isEmpty else { throw BridgeError.configuration("Conversation cannot dispatch project tasks.") }
        } else {
            guard !discussionOnly, project != nil, !tasks.isEmpty else { throw BridgeError.configuration("Attach a project and use Auto mode before dispatching work.") }
        }
        var seen = Set<String>()
        for task in tasks {
            guard !task.id.isEmpty, task.id.count <= 80, !seen.contains(task.id),
                  ["Claude", "Codex"].contains(task.owner), !task.prompt.isEmpty, task.prompt.count <= 12_000,
                  !task.title.isEmpty, task.title.count <= 160,
                  task.dependsOn.allSatisfy({ seen.contains($0) }),
                  mode == .implement || task.kind != .implement else {
                throw BridgeError.configuration("Invalid task ownership, scope or dependencies in coordinator plan.")
            }
            seen.insert(task.id)
        }
    }
}

public struct RoomActivity: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: String
    public var label: String
    public var nativeID: String?
    public var parentID: String?
    public var date = Date()
}

public struct RoomWorkRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var round: UUID
    public var task: RoomWork
    public var state = "queued"
    public var sessionID: String?
    public var activities: [RoomActivity] = []
    public var result: String?
    public var model: String?
}

public protocol RoomTeamProvider: RoomProvider {
    func plan(messages: [RoomMessage], project: String?, discussionOnly: Bool) async throws -> RoomPlan
    func execute(task: RoomWork, contract: String, history: [RoomMessage], project: URL, progress: @escaping @Sendable (RoomActivity) async -> Void) async throws -> RoomReply
}

public struct RoomRoleCard: Codable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var model: String
    public var instructions: String
}

public enum RoomPrompts {
    public static let backendModel = "gpt-5.6-luna"
    public static func resource(_ name: String) throws -> String {
        // Packaged apps and their helper must not depend on an absolute .build
        // fallback generated by SwiftPM on the developer's machine.
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name + ".md"),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/" + name + ".md")
        ].compactMap { $0 }
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        if let executable = Bundle.main.executableURL,
           ["bridge", "ClaudeCodexBridgeMenuBar"].contains(executable.lastPathComponent),
           executable.path.contains(".app/Contents/") {
            throw BridgeError.configuration("Missing packaged team playbook: \(name). Reinstall the complete app bundle.")
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "md") else { throw BridgeError.configuration("Missing team playbook: \(name)") }
        return try String(contentsOf: url, encoding: .utf8)
    }
    public static func cards(configuration: BridgeConfiguration) throws -> [RoomRoleCard] {
        try [
            RoomRoleCard(id: "team", role: "Shared · native team coordination", model: "All teammates", instructions: resource("bridge-team")),
            RoomRoleCard(id: "coordinator", role: "Selected lead · coordinate", model: "Per-room lead selection", instructions: resource("room-coordinator-v1")),
            RoomRoleCard(id: "frontend", role: "Claude · frontend", model: configuration.agents.claudeModel, instructions: resource("room-frontend-v1")),
            RoomRoleCard(id: "backend", role: "Codex · backend", model: backendModel, instructions: resource("room-backend-v1")),
            RoomRoleCard(id: "review", role: "Shared · inspect and verify", model: "Assigned worker", instructions: resource("room-review-v1"))
        ]
    }
}

public enum RoomRuntime {
    public static func helper() -> String {
        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("bridge")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling.path }
            let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/bridge")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ClaudeCodexBridge.app/Contents/Helpers/bridge").path
    }
    public static func codex(configuration: BridgeConfiguration, settings: RoomSettings) -> String {
        if let command = settings.codexCommand { return command }
        if configuration.agents.codexCommand != "codex" { return configuration.agents.codexCommand }
        // Use the maintained desktop runtime when present. The npm CLI can lag
        // model availability; never change the global installation or model.
        for path in ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"] where FileManager.default.isExecutableFile(atPath: path) { return path }
        return configuration.agents.codexCommand
    }
}

/// Visible metadata only: never forward chain-of-thought or raw tool arguments.
public enum RoomEventParser {
    public static func failure(_ output: ProcessOutput) -> String {
        var messages: [String] = []
        for line in output.stdout.split(separator: "\n") {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = root["error"] as? [String: Any], let message = error["message"] as? String { messages.append(message) }
            else if root["type"] as? String == "error", let message = root["message"] as? String { messages.append(message) }
            else if root["is_error"] as? Bool == true, let result = root["result"] as? String { messages.append(result) }
        }
        return TraceRedactor.redact(messages.last ?? String(output.stderr.suffix(1000)), maximumCharacters: 500)
    }
    public static func activities(line: String, claude: Bool) -> [RoomActivity] {
        guard let data = line.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let type = root["type"] as? String ?? ""
        if claude {
            if type == "system", root["subtype"] as? String == "init", let id = root["session_id"] as? String {
                return [RoomActivity(kind: "session", label: "Claude child session connected", nativeID: id)]
            }
            if type == "assistant", let message = root["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] {
                return blocks.compactMap { block in
                    guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                    return RoomActivity(kind: ["Agent", "Task"].contains(name) ? "subagent" : "tool", label: "Using \(name)", nativeID: block["id"] as? String, parentID: root["parent_tool_use_id"] as? String)
                }
            }
            if type == "system", let subtype = root["subtype"] as? String, ["task_started", "task_progress", "task_notification"].contains(subtype) {
                return [RoomActivity(kind: "subagent", label: "Subagent · \(root["status"] as? String ?? subtype)", nativeID: root["task_id"] as? String, parentID: root["tool_use_id"] as? String)]
            }
        } else {
            if type == "thread.started", let id = root["thread_id"] as? String {
                return [RoomActivity(kind: "session", label: "Codex child session connected", nativeID: id)]
            }
            if ["item.started", "item.completed", "item.updated"].contains(type), let item = root["item"] as? [String: Any], let kind = item["type"] as? String {
                if kind.hasPrefix("collab"), let children = item["receiver_thread_ids"] as? [String], !children.isEmpty {
                    return children.map { RoomActivity(kind: "subagent", label: "Subagent \(item["tool"] as? String ?? "activity") · \(item["status"] as? String ?? type)", nativeID: $0, parentID: item["sender_thread_id"] as? String) }
                }
                let label: String
                switch kind {
                case "command_execution": label = "Command \(type == "item.completed" ? "finished" : "running")"
                case "file_change": label = "File change recorded"
                case "mcp_tool_call": label = "Tool activity"
                case "collab_agent_tool_call", "collab_tool_call": label = "Subagent \(item["tool"] as? String ?? "activity") · \(item["status"] as? String ?? type)"
                default: return []
                }
                return [RoomActivity(kind: kind.hasPrefix("collab") ? "subagent" : "tool", label: label, nativeID: item["id"] as? String, parentID: item["sender_thread_id"] as? String)]
            }
        }
        return []
    }
}
