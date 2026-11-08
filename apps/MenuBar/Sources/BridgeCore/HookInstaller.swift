import Foundation

public struct HookInstallResult: Sendable {
    public var settingsURL: URL
    public var backupURL: URL?
    public var renderedJSON: String
}

public enum HookInstaller {
    public static func install(
        projectPath: String,
        configuration: BridgeConfiguration,
        dryRun: Bool = false
    ) throws -> HookInstallResult {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &directory),
              directory.boolValue
        else {
            throw BridgeError.invalidProject(project.path)
        }
        let claude = project.appendingPathComponent(".claude", isDirectory: true)
        let settings = claude.appendingPathComponent("settings.local.json")
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settings.path) {
            let data = try Data(contentsOf: settings)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw BridgeError.configuration("Claude settings must be a JSON object")
            }
            root = existing
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let hookNames = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PostToolUseFailure", "Stop", "StopFailure", "Notification",
            "PreCompact", "PostCompact", "SessionEnd",
        ]
        let base = "http://\(configuration.server.host):\(configuration.server.port)"
        for name in hookNames {
            var groups = hooks[name] as? [[String: Any]] ?? []
            groups.removeAll { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains { handler in
                    (handler["url"] as? String)?.contains("/hooks/claude/") == true
                }
            }
            groups.append([
                "matcher": "",
                "hooks": [[
                    "type": "http",
                    "url": "\(base)/hooks/claude/\(name)",
                    "headers": [
                        "Authorization": "Bearer \(configuration.server.bearerToken)",
                    ],
                    "timeout": 30,
                ]],
            ])
            hooks[name] = groups
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let rendered = String(decoding: data, as: UTF8.self) + "\n"
        guard !dryRun else {
            return HookInstallResult(
                settingsURL: settings,
                backupURL: nil,
                renderedJSON: rendered
            )
        }
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        var backup: URL?
        if FileManager.default.fileExists(atPath: settings.path) {
            let stamp = ISO8601.withoutFractional
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let candidate = claude.appendingPathComponent(
                "settings.local.bridge-backup-\(stamp)-\(UUID().uuidString.prefix(8)).json"
            )
            try FileManager.default.copyItem(at: settings, to: candidate)
            backup = candidate
        }
        try Data(rendered.utf8).write(to: settings, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: settings.path
        )
        return HookInstallResult(
            settingsURL: settings,
            backupURL: backup,
            renderedJSON: rendered
        )
    }
}
