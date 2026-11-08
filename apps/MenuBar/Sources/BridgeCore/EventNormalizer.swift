import Foundation

public enum EventNormalizer {
    public static let supportedClaudeHooks: Set<String> = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "StopFailure",
        "Notification",
        "PreCompact",
        "PostCompact",
        "SessionEnd",
    ]

    public static func normalizeClaudeHook(
        name: String,
        payload: [String: JSONValue],
        bridgeSessionID: String? = nil
    ) throws -> BridgeEvent {
        guard supportedClaudeHooks.contains(name) else {
            throw BridgeError.invalidEvent("unsupported Claude hook: \(name)")
        }
        let nativeSession = payload["session_id"]?.stringValue ?? "unknown"
        guard let project = payload["cwd"]?.stringValue
            ?? payload["project_path"]?.stringValue,
            !project.isEmpty
        else {
            throw BridgeError.invalidEvent("Claude hook is missing cwd")
        }

        var type: EventType
        switch name {
        case "SessionStart": type = .sessionStart
        case "UserPromptSubmit": type = .userMessage
        case "Stop", "SessionEnd": type = .turnComplete
        case "PostToolUseFailure", "StopFailure": type = .error
        default: type = .toolUse
        }

        let content: JSONValue
        switch name {
        case "UserPromptSubmit":
            content = payload["prompt"] ?? .string("")
        case "Stop":
            content = payload["last_assistant_message"]
                ?? payload["message"]
                ?? .object(payload)
        case "StopFailure":
            content = payload["error"]
                ?? payload["message"]
                ?? .object(payload)
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            content = .object([
                "tool_name": payload["tool_name"] ?? .null,
                "tool_input": payload["tool_input"] ?? .null,
                "tool_response": payload["tool_response"] ?? .null,
                "error": payload["error"] ?? .null,
            ])
        default:
            content = .object(payload)
        }
        if type == .error, containsRateLimit(content.text) {
            type = .rateLimit
        }
        return BridgeEvent(
            source: .claude,
            type: type,
            content: content,
            sessionID: bridgeSessionID ?? nativeSession,
            projectPath: project,
            metadata: [
                "native_hook": .string(name),
                "native_session_id": .string(nativeSession),
                "bridge_managed": .bool(false),
            ]
        )
    }

    public static func containsRateLimit(_ value: String) -> Bool {
        let text = value.lowercased()
        return [
            "rate limit",
            "rate_limit",
            "usage limit",
            "quota exceeded",
            "too many requests",
            "limit reached",
            "resets at",
            "try again in",
        ].contains { text.contains($0) }
    }
}

