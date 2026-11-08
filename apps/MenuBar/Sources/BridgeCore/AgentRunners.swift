import Foundation

public protocol AgentRunner: Sendable {
    func run(
        project: URL,
        prompt: String,
        nativeSessionID: String?,
        bridgeSessionID: String
    ) async throws -> AgentResult
}

public struct ClaudeRunner: AgentRunner {
    private let configuration: AgentConfiguration

    public init(configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    public func run(
        project: URL,
        prompt: String,
        nativeSessionID: String?,
        bridgeSessionID: String
    ) async throws -> AgentResult {
        var arguments = [
            "-p",
            "--input-format", "text",
            // Claude 2.1.x can leave print-mode requests running indefinitely
            // after an expired OAuth token when stream-json is selected. The
            // single-result JSON contract returns the same session/result
            // fields and surfaces authentication failures promptly.
            "--output-format", "json",
            // Do not inherit a user-wide `[1m]` model preference. Extended
            // context can require usage credits even when a normal Max-plan
            // turn is included.
            "--model", configuration.claudeModel,
            "--effort", configuration.claudeEffort,
            "--permission-mode", configuration.claudePermissionMode,
        ]
        if configuration.claudeIsolatedMode {
            arguments += [
                // Managed turns must not inherit user-wide hooks, MCP servers,
                // browser integrations, plugins, or folder-discovery behavior.
                // OAuth, built-in tools, model selection, and permissions
                // remain available in Claude's safe mode.
                "--safe-mode",
                "--no-chrome",
            ]
        }
        if let nativeSessionID {
            arguments += ["--resume", nativeSessionID]
        } else {
            arguments += ["--name", bridgeTitle(
                bridgeSessionID: bridgeSessionID,
                project: project,
                provider: "Claude"
            )]
        }
        let startedAt = Date()
        let process = try await ProcessRunner.run(
            executable: configuration.claudeCommand,
            arguments: arguments,
            currentDirectory: project,
            stdin: prompt,
            timeoutSeconds: configuration.subprocessTimeoutSeconds,
            maximumOutputCharacters: configuration.maxOutputCharacters
        )
        let parsed = parse(stdout: process.stdout)
        var telemetry = parsed.telemetry
        telemetry.durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        if let sessionID = parsed.sessionID ?? nativeSessionID {
            let transcript = ClaudeTranscriptReader.telemetry(sessionID: sessionID)
            telemetry = telemetry.merging(transcript)
        }
        let combined = process.stderr + "\n" + parsed.output
        let rateLimited = EventNormalizer.containsRateLimit(combined)
        let error: String? =
            process.status == 0 && !parsed.isError
                ? nil
                : nonEmpty(process.stderr) ?? nonEmpty(parsed.output) ?? "Claude Code failed"
        return AgentResult(
            agent: .claude,
            success: process.status == 0 && !parsed.isError,
            output: parsed.output,
            sessionID: parsed.sessionID ?? nativeSessionID,
            rateLimited: rateLimited,
            resetAt: nil,
            error: error,
            diagnostics: [
                "returncode": .number(Double(process.status)),
                "timed_out": .bool(process.timedOut),
                "parsed_jsonl_events": .number(Double(parsed.count)),
            ],
            telemetry: telemetry
        )
    }

    private func parse(stdout: String) -> (
        output: String,
        sessionID: String?,
        isError: Bool,
        count: Int,
        telemetry: AgentTelemetry
    ) {
        var result = ""
        var sessionID: String?
        var isError = false
        var count = 0
        var identity = ProviderIdentity(
            requestedModel: configuration.claudeModel,
            requestedEffort: configuration.claudeEffort,
            sandbox: configuration.claudeIsolatedMode ? "safe-mode" : nil,
            permissionMode: configuration.claudePermissionMode
        )
        var usage = TokenUsage()
        for line in stdout.split(separator: "\n") {
            guard let value = try? BridgeJSON.decoder.decode(JSONValue.self, from: Data(line.utf8)),
                  let object = value.objectValue
            else { continue }
            count += 1
            sessionID = object["session_id"]?.stringValue ?? sessionID
            if object["type"]?.stringValue == "result" {
                result = object["result"]?.stringValue ?? result
                isError = object["is_error"]?.boolValue ?? false
                identity.resolvedModel = object["model"]?.stringValue ?? identity.resolvedModel
                if let value = object["usage"]?.objectValue {
                    usage = parseUsage(value)
                    identity.serviceTier = value["service_tier"]?.stringValue
                }
            }
        }
        return (result.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : result,
                sessionID,
                isError,
                count,
                AgentTelemetry(
                    identity: identity,
                    usage: usage,
                    completeness: usage.total == nil ? .partial : .complete,
                    warnings: usage.total == nil ? ["Claude did not report authoritative usage."] : []
                ))
    }
}

public struct CodexRunner: AgentRunner {
    private let configuration: AgentConfiguration

    public init(configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    public func run(
        project: URL,
        prompt: String,
        nativeSessionID: String?,
        bridgeSessionID: String
    ) async throws -> AgentResult {
        let context = project.appendingPathComponent("CONTEXT", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        let lastMessage = context.appendingPathComponent(".codex-last-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: lastMessage) }

        let arguments: [String]
        if let nativeSessionID {
            var resumed = [
                "exec", "resume",
                "--json",
                "--output-last-message", lastMessage.path,
                "--model", configuration.codexModel,
                "-c", "model_reasoning_effort=\"\(configuration.codexReasoningEffort)\"",
            ]
            if configuration.codexIsolatedMode {
                resumed += ["--ignore-user-config", "--ignore-rules"]
            }
            resumed += [nativeSessionID, "-"]
            arguments = resumed
        } else {
            var initial = [
                "exec",
                "--json",
                "--color", "never",
                "--sandbox", configuration.codexSandbox,
                "--model", configuration.codexModel,
                "-c", "model_reasoning_effort=\"\(configuration.codexReasoningEffort)\"",
                "--cd", project.path,
                "--output-last-message", lastMessage.path,
            ]
            if configuration.codexIsolatedMode {
                initial += ["--ignore-user-config", "--ignore-rules"]
            }
            if configuration.codexSkipGitRepositoryCheck {
                initial.append("--skip-git-repo-check")
            }
            initial.append("-")
            arguments = initial
        }
        let startedAt = Date()
        let process = try await ProcessRunner.run(
            executable: configuration.codexCommand,
            arguments: arguments,
            currentDirectory: project,
            stdin: prompt,
            timeoutSeconds: configuration.subprocessTimeoutSeconds,
            maximumOutputCharacters: configuration.maxOutputCharacters
        )
        let parsed = parse(stdout: process.stdout)
        var telemetry = parsed.telemetry
        telemetry.durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let title = bridgeTitle(
            bridgeSessionID: bridgeSessionID,
            project: project,
            provider: "Codex"
        )
        if nativeSessionID == nil, let threadID = parsed.sessionID {
            do {
                try await CodexThreadNamer.setName(
                    threadID: threadID,
                    name: title,
                    configuration: configuration,
                    project: project
                )
            } catch {
                telemetry.warnings.append(
                    "Codex thread was created, but its Bridge title could not be set: "
                        + TraceRedactor.redact(error.localizedDescription)
                )
                telemetry.completeness = .partial
            }
        }
        if let sessionID = parsed.sessionID ?? nativeSessionID {
            telemetry = telemetry.merging(
                CodexTranscriptReader.telemetry(sessionID: sessionID)
            )
        }
        let output: String
        if let data = try? Data(contentsOf: lastMessage),
           let message = String(data: data, encoding: .utf8),
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            output = message.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            output = parsed.lastMessage
        }
        let combined = process.stderr + "\n" + output
        let error: String? =
            process.status == 0
                ? nil
                : nonEmpty(process.stderr) ?? nonEmpty(output) ?? "Codex CLI failed"
        return AgentResult(
            agent: .codex,
            success: process.status == 0,
            output: output,
            sessionID: parsed.sessionID ?? nativeSessionID,
            rateLimited: EventNormalizer.containsRateLimit(combined),
            resetAt: nil,
            error: error,
            diagnostics: [
                "returncode": .number(Double(process.status)),
                "timed_out": .bool(process.timedOut),
                "parsed_jsonl_events": .number(Double(parsed.count)),
                "thread_title": .string(title),
            ],
            telemetry: telemetry
        )
    }

    private func parse(stdout: String) -> (
        sessionID: String?,
        lastMessage: String,
        count: Int,
        telemetry: AgentTelemetry
    ) {
        var sessionID: String?
        var lastMessage = ""
        var count = 0
        var identity = ProviderIdentity(
            requestedModel: configuration.codexModel,
            requestedEffort: configuration.codexReasoningEffort,
            sandbox: configuration.codexSandbox
        )
        var usage = TokenUsage()
        var tools: [ToolReceipt] = []
        var nativeTurnID: String?
        for line in stdout.split(separator: "\n") {
            guard let value = try? BridgeJSON.decoder.decode(JSONValue.self, from: Data(line.utf8)),
                  let object = value.objectValue
            else { continue }
            count += 1
            if object["type"]?.stringValue == "thread.started" {
                sessionID = object["thread_id"]?.stringValue ?? sessionID
            }
            if object["type"]?.stringValue == "turn.started" {
                nativeTurnID = object["turn_id"]?.stringValue ?? nativeTurnID
            }
            collectCodexTelemetry(
                object,
                identity: &identity,
                usage: &usage,
                tools: &tools
            )
            if let item = object["item"]?.objectValue,
               item["type"]?.stringValue == "agent_message",
               let text = item["text"]?.stringValue
            {
                lastMessage = text
            }
        }
        if lastMessage.isEmpty {
            lastMessage = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (
            sessionID,
            lastMessage,
            count,
            AgentTelemetry(
                identity: identity,
                usage: usage,
                tools: tools,
                nativeTurnID: nativeTurnID,
                completeness: usage.total == nil ? .partial : .complete,
                warnings: usage.total == nil ? ["Codex did not report authoritative usage."] : []
            )
        )
    }
}

/// Grok Build's machine-readable headless protocol. The adapter deliberately
/// uses provider-owned authentication and sessions, never Grok credential
/// files or an independently implemented xAI HTTP client.
public struct GrokRunner: AgentRunner {
    private let configuration: AgentConfiguration
    private let apiKey: String?

    public init(
        configuration: AgentConfiguration,
        apiKey: String? = CoordinatorSecretStore.resolve(
            environmentVariable: "XAI_API_KEY"
        )
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
    }

    public func run(
        project: URL,
        prompt: String,
        nativeSessionID: String?,
        bridgeSessionID: String
    ) async throws -> AgentResult {
        let sessionID = nativeSessionID ?? bridgeSessionID
        var arguments = [
            "--no-auto-update",
            "--cwd", project.path,
            "--model", configuration.grokModel,
            "--effort", configuration.grokReasoningEffort,
            "--output-format", "streaming-json",
            "--permission-mode", configuration.grokPermissionMode,
            "--sandbox", configuration.grokSandbox,
            "--no-plan",
            "--no-memory",
            "--single", prompt,
        ]
        if configuration.grokIsolatedMode {
            arguments += [
                "--no-subagents",
                "--disable-web-search",
            ]
        }
        if nativeSessionID != nil {
            arguments += ["--resume", sessionID]
        } else {
            arguments += ["--session-id", sessionID]
        }

        let startedAt = Date()
        let process = try await ProcessRunner.run(
            executable: configuration.grokCommand,
            arguments: arguments,
            currentDirectory: project,
            stdin: "",
            timeoutSeconds: configuration.subprocessTimeoutSeconds,
            maximumOutputCharacters: configuration.maxOutputCharacters,
            environment: apiKey.map { ["XAI_API_KEY": $0] } ?? [:]
        )
        var parsed = GrokJSONParser.parse(
            process.stdout,
            requestedModel: configuration.grokModel,
            requestedEffort: configuration.grokReasoningEffort,
            sandbox: configuration.grokSandbox,
            permissionMode: configuration.grokPermissionMode
        )
        parsed.telemetry.durationMilliseconds = Int(
            Date().timeIntervalSince(startedAt) * 1_000
        )
        let combined = process.stderr + "\n" + parsed.output
        let permissionBlocked = parsed.permissionRequired
            || combined.localizedCaseInsensitiveContains("permission denied")
            || combined.localizedCaseInsensitiveContains("approval required")
        let error: String? = process.status == 0 && !permissionBlocked
            ? nil
            : nonEmpty(process.stderr)
                ?? nonEmpty(parsed.output)
                ?? (permissionBlocked
                    ? "Grok paused for a tool permission decision."
                    : "Grok Build failed")
        return AgentResult(
            agent: .grok,
            success: process.status == 0 && !permissionBlocked,
            output: parsed.output,
            sessionID: parsed.sessionID ?? sessionID,
            rateLimited: EventNormalizer.containsRateLimit(combined),
            resetAt: nil,
            error: error,
            diagnostics: [
                "returncode": .number(Double(process.status)),
                "timed_out": .bool(process.timedOut),
                "parsed_jsonl_events": .number(Double(parsed.count)),
                "permission_required": .bool(permissionBlocked),
                "session_title": .string(bridgeTitle(
                    bridgeSessionID: bridgeSessionID,
                    project: project,
                    provider: "Grok"
                )),
            ],
            telemetry: parsed.telemetry
        )
    }
}

public enum GrokJSONParser {
    public struct Parsed: Sendable {
        public var output: String
        public var sessionID: String?
        public var count: Int
        public var permissionRequired: Bool
        public var telemetry: AgentTelemetry
    }

    public static func parse(
        _ stdout: String,
        requestedModel: String,
        requestedEffort: String,
        sandbox: String?,
        permissionMode: String?
    ) -> Parsed {
        var outputParts: [String] = []
        var sessionID: String?
        var nativeTurnID: String?
        var count = 0
        var permissionRequired = false
        var identity = ProviderIdentity(
            requestedModel: requestedModel,
            requestedEffort: requestedEffort,
            modelProvider: "xai",
            sandbox: sandbox,
            permissionMode: permissionMode
        )
        var usage = TokenUsage()
        var tools: [ToolReceipt] = []

        for line in stdout.split(separator: "\n") {
            guard let value = try? BridgeJSON.decoder.decode(
                JSONValue.self, from: Data(line.utf8)
            ), let object = value.objectValue else { continue }
            count += 1
            sessionID = firstString(
                in: object,
                keys: ["session_id", "sessionId"]
            ) ?? sessionID
            nativeTurnID = firstString(
                in: object,
                keys: ["turn_id", "turnId", "response_id", "responseId"]
            ) ?? nativeTurnID
            identity.resolvedModel = firstString(
                in: object,
                keys: ["model", "model_id", "modelId"]
            ) ?? identity.resolvedModel
            identity.resolvedEffort = firstString(
                in: object,
                keys: ["effort", "reasoning_effort", "reasoningEffort"]
            ) ?? identity.resolvedEffort

            if let usageObject = recursiveObject(named: "usage", in: value) {
                usage = parseUsage(usageObject)
            }
            let type = (
                firstString(in: object, keys: ["type", "method", "event"]) ?? ""
            ).lowercased()
            if type.contains("permission") || type.contains("approval") {
                permissionRequired = true
            }
            if type.contains("tool"),
               let tool = toolReceipt(from: object, fallbackType: type)
            {
                if !tools.contains(where: { $0.id == tool.id }) {
                    tools.append(tool)
                }
            }
            if type.contains("assistant") || type.contains("message")
                || type.contains("result") || type.contains("complete")
            {
                if let text = recursiveText(in: value), !text.isEmpty {
                    outputParts.append(text)
                }
            }
        }
        let output = outputParts.last
            ?? recursiveText(
                in: (try? BridgeJSON.decoder.decode(
                    JSONValue.self, from: Data(stdout.utf8)
                )) ?? .string(stdout)
            )
            ?? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let completeness: TraceCompleteness = usage.total == nil ? .partial : .complete
        var warnings: [String] = []
        if usage.total == nil {
            warnings.append("Grok Build did not report authoritative token usage.")
        }
        if permissionRequired {
            warnings.append("Grok requested a tool permission that requires user review.")
        }
        return Parsed(
            output: output,
            sessionID: sessionID,
            count: count,
            permissionRequired: permissionRequired,
            telemetry: AgentTelemetry(
                identity: identity,
                usage: usage,
                tools: tools,
                nativeTurnID: nativeTurnID,
                completeness: completeness,
                warnings: warnings
            )
        )
    }

    private static func firstString(
        in object: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue { return value }
        }
        return nil
    }

    private static func recursiveObject(
        named name: String,
        in value: JSONValue
    ) -> [String: JSONValue]? {
        switch value {
        case let .object(object):
            if let found = object[name]?.objectValue { return found }
            for child in object.values {
                if let found = recursiveObject(named: name, in: child) { return found }
            }
        case let .array(array):
            for child in array {
                if let found = recursiveObject(named: name, in: child) { return found }
            }
        default:
            break
        }
        return nil
    }

    private static func recursiveText(in value: JSONValue) -> String? {
        switch value {
        case let .string(text):
            return text
        case let .object(object):
            for key in ["output_text", "result", "text", "content", "message"] {
                if let text = object[key]?.stringValue, !text.isEmpty { return text }
                if let child = object[key], let text = recursiveText(in: child), !text.isEmpty {
                    return text
                }
            }
            for child in object.values {
                if let text = recursiveText(in: child), !text.isEmpty { return text }
            }
        case let .array(array):
            for child in array.reversed() {
                if let text = recursiveText(in: child), !text.isEmpty { return text }
            }
        default:
            break
        }
        return nil
    }

    private static func toolReceipt(
        from object: [String: JSONValue],
        fallbackType: String
    ) -> ToolReceipt? {
        let id = firstString(in: object, keys: ["tool_call_id", "toolCallId", "id"])
            ?? UUID().uuidString
        let name = firstString(in: object, keys: ["tool_name", "toolName", "name"])
            ?? fallbackType
        guard !name.isEmpty else { return nil }
        return ToolReceipt(
            id: id,
            name: name,
            category: "grok_tool",
            status: firstString(in: object, keys: ["status", "outcome"]) ?? "observed",
            exitCode: object["exit_code"]?.intValue ?? object["exitCode"]?.intValue,
            redactedSummary: firstString(
                in: object, keys: ["summary", "description"]
            ).map { TraceRedactor.redact($0) }
        )
    }
}

private func parseUsage(_ object: [String: JSONValue]) -> TokenUsage {
    let input = object["input_tokens"]?.intValue
    let output = object["output_tokens"]?.intValue
    let cached = object["cache_read_input_tokens"]?.intValue
        ?? object["cached_input_tokens"]?.intValue
        ?? object["cached_tokens"]?.intValue
    let cacheWrite = object["cache_creation_input_tokens"]?.intValue
        ?? object["cache_write_input_tokens"]?.intValue
    let reasoning = object["reasoning_tokens"]?.intValue
    let reportedTotal = object["total_tokens"]?.intValue
    let derivedTotal: Int? = {
        guard let input, let output else { return nil }
        // Claude reports cache read/write outside input_tokens. Codex/Gemini
        // report cached tokens as an input subset and normally supply total.
        if reportedTotal == nil, cacheWrite != nil || object["cache_read_input_tokens"] != nil {
            return input + output + (cached ?? 0) + (cacheWrite ?? 0)
        }
        return input + output
    }()
    return TokenUsage(
        input: input,
        output: output,
        cachedInput: cached,
        cacheWriteInput: cacheWrite,
        reasoning: reasoning,
        total: reportedTotal ?? derivedTotal,
        provenance: reportedTotal == nil
            ? (derivedTotal == nil ? .unavailable : .derived)
            : .providerReported
    )
}

private func collectCodexTelemetry(
    _ object: [String: JSONValue],
    identity: inout ProviderIdentity,
    usage: inout TokenUsage,
    tools: inout [ToolReceipt]
) {
    identity.resolvedModel = object["model"]?.stringValue ?? identity.resolvedModel
    identity.resolvedEffort = object["reasoning_effort"]?.stringValue ?? identity.resolvedEffort
    identity.modelProvider = object["model_provider"]?.stringValue ?? identity.modelProvider
    identity.contextWindow = object["model_context_window"]?.intValue ?? identity.contextWindow
    if let value = object["usage"]?.objectValue {
        let parsed = parseUsage(value)
        if parsed.total != nil { usage = parsed }
    }
    if let value = object["token_usage"]?.objectValue {
        let parsed = parseUsage(value)
        if parsed.total != nil { usage = parsed }
    }
    if let item = object["item"]?.objectValue {
        let type = item["type"]?.stringValue ?? ""
        if ["command_execution", "mcp_tool_call", "function_call", "custom_tool_call"].contains(type) {
            let id = item["id"]?.stringValue ?? UUID().uuidString
            let name = item["name"]?.stringValue
                ?? item["command"]?.stringValue.map { TraceRedactor.redact($0, maximumCharacters: 80) }
                ?? type
            if !tools.contains(where: { $0.id == id }) {
                tools.append(ToolReceipt(
                    id: id,
                    name: name,
                    category: type,
                    status: item["status"]?.stringValue ?? "observed",
                    exitCode: item["exit_code"]?.intValue,
                    redactedSummary: nil,
                    contentDigest: item["command"]?.stringValue.map(TraceCrypto.digest)
                ))
            }
        }
    }
    for value in object.values {
        if let nested = value.objectValue {
            collectCodexTelemetry(nested, identity: &identity, usage: &usage, tools: &tools)
        } else if case let .array(values) = value {
            for child in values {
                if let nested = child.objectValue {
                    collectCodexTelemetry(
                        nested,
                        identity: &identity,
                        usage: &usage,
                        tools: &tools
                    )
                }
            }
        }
    }
}

enum ClaudeTranscriptReader {
    static func telemetry(sessionID: String) -> AgentTelemetry {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return AgentTelemetry(warnings: ["Claude transcript was unavailable."])
        }
        var transcript: URL?
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == "\(sessionID).jsonl" {
                transcript = url
                break
            }
        }
        guard let transcript,
              let text = try? String(contentsOf: transcript, encoding: .utf8)
        else {
            return AgentTelemetry(warnings: ["Claude transcript was unavailable."])
        }
        var identity = ProviderIdentity()
        var usage = TokenUsage()
        var tools: [ToolReceipt] = []
        for line in text.split(separator: "\n") {
            guard let value = try? BridgeJSON.decoder.decode(
                JSONValue.self,
                from: Data(line.utf8)
            ), let object = value.objectValue else { continue }
            identity.resolvedEffort = object["effort"]?.stringValue ?? identity.resolvedEffort
            guard let message = object["message"]?.objectValue else { continue }
            identity.resolvedModel = message["model"]?.stringValue ?? identity.resolvedModel
            if let rawUsage = message["usage"]?.objectValue {
                let parsed = parseUsage(rawUsage)
                if parsed.total != nil { usage = parsed }
                identity.serviceTier = rawUsage["service_tier"]?.stringValue
            }
            guard case let .array(blocks) = message["content"] else { continue }
            for block in blocks {
                guard let content = block.objectValue,
                      content["type"]?.stringValue == "tool_use"
                else { continue }
                let id = content["id"]?.stringValue ?? UUID().uuidString
                if !tools.contains(where: { $0.id == id }) {
                    tools.append(ToolReceipt(
                        id: id,
                        name: content["name"]?.stringValue ?? "tool",
                        category: "tool_use",
                        contentDigest: content["input"].map {
                            TraceCrypto.digest($0.text)
                        }
                    ))
                }
            }
        }
        return AgentTelemetry(
            identity: identity,
            usage: usage,
            tools: tools,
            completeness: usage.total == nil ? .partial : .complete
        )
    }
}

enum CodexTranscriptReader {
    static func telemetry(sessionID: String) -> AgentTelemetry {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return AgentTelemetry(warnings: ["Codex transcript was unavailable."])
        }
        var transcript: URL?
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "jsonl", url.lastPathComponent.contains(sessionID) {
                transcript = url
                break
            }
        }
        guard let transcript,
              let text = try? String(contentsOf: transcript, encoding: .utf8)
        else {
            return AgentTelemetry(warnings: ["Codex transcript was unavailable."])
        }
        var identity = ProviderIdentity()
        var usage = TokenUsage()
        var tools: [ToolReceipt] = []
        for line in text.split(separator: "\n") {
            guard let value = try? BridgeJSON.decoder.decode(
                JSONValue.self,
                from: Data(line.utf8)
            ), let object = value.objectValue,
                  let payload = object["payload"]?.objectValue
            else { continue }
            switch object["type"]?.stringValue {
            case "session_meta":
                identity.modelProvider = payload["model_provider"]?.stringValue
                    ?? identity.modelProvider
            case "turn_context":
                identity.resolvedModel = payload["model"]?.stringValue
                    ?? identity.resolvedModel
                identity.contextWindow = payload["model_context_window"]?.intValue
                    ?? identity.contextWindow
                identity.resolvedEffort =
                    payload["collaboration_mode"]?.objectValue?["settings"]?
                        .objectValue?["reasoning_effort"]?.stringValue
                    ?? identity.resolvedEffort
            case "event_msg":
                if payload["type"]?.stringValue == "token_count",
                   let info = payload["info"]?.objectValue
                {
                    let source = info["last_token_usage"]?.objectValue
                        ?? info["total_token_usage"]?.objectValue
                    if let source {
                        let parsed = parseCodexNativeUsage(source)
                        if parsed.total != nil { usage = parsed }
                    }
                    identity.contextWindow = info["model_context_window"]?.intValue
                        ?? identity.contextWindow
                }
            case "response_item":
                let type = payload["type"]?.stringValue ?? ""
                if ["function_call", "custom_tool_call"].contains(type) {
                    let id = payload["call_id"]?.stringValue
                        ?? payload["id"]?.stringValue
                        ?? UUID().uuidString
                    if !tools.contains(where: { $0.id == id }) {
                        let raw = payload["arguments"]?.stringValue
                            ?? payload["input"]?.stringValue
                        tools.append(ToolReceipt(
                            id: id,
                            name: payload["name"]?.stringValue ?? type,
                            category: type,
                            contentDigest: raw.map(TraceCrypto.digest)
                        ))
                    }
                }
            default:
                break
            }
        }
        return AgentTelemetry(
            identity: identity,
            usage: usage,
            tools: tools,
            completeness: usage.total == nil ? .partial : .complete
        )
    }

    private static func parseCodexNativeUsage(
        _ object: [String: JSONValue]
    ) -> TokenUsage {
        let input = object["input_tokens"]?.intValue
        let output = object["output_tokens"]?.intValue
        return TokenUsage(
            input: input,
            output: output,
            cachedInput: object["cached_input_tokens"]?.intValue,
            cacheWriteInput: object["cache_write_input_tokens"]?.intValue,
            reasoning: object["reasoning_output_tokens"]?.intValue,
            total: object["total_tokens"]?.intValue
                ?? (input != nil && output != nil ? input! + output! : nil),
            provenance: object["total_tokens"] == nil ? .derived : .providerReported
        )
    }
}

private extension AgentTelemetry {
    func merging(_ other: AgentTelemetry) -> AgentTelemetry {
        AgentTelemetry(
            identity: ProviderIdentity(
                requestedModel: identity.requestedModel,
                resolvedModel: other.identity.resolvedModel ?? identity.resolvedModel,
                requestedEffort: identity.requestedEffort,
                resolvedEffort: other.identity.resolvedEffort ?? identity.resolvedEffort,
                modelProvider: other.identity.modelProvider ?? identity.modelProvider,
                serviceTier: other.identity.serviceTier ?? identity.serviceTier,
                contextWindow: other.identity.contextWindow ?? identity.contextWindow,
                sandbox: identity.sandbox,
                permissionMode: identity.permissionMode
            ),
            usage: other.usage.total == nil ? usage : other.usage,
            tools: other.tools.isEmpty ? tools : other.tools,
            nativeTurnID: other.nativeTurnID ?? nativeTurnID,
            durationMilliseconds: durationMilliseconds,
            timeToFirstTokenMilliseconds: timeToFirstTokenMilliseconds,
            completeness: other.usage.total == nil && usage.total == nil ? .partial : .complete,
            warnings: warnings + other.warnings
        )
    }
}

private func bridgeTitle(
    bridgeSessionID: String,
    project: URL,
    provider: String
) -> String {
    "[Bridge \(bridgeSessionID.prefix(8))] \(project.lastPathComponent) — \(provider)"
}

private enum CodexThreadNamer {
    static func setName(
        threadID: String,
        name: String,
        configuration: AgentConfiguration,
        project: URL
    ) async throws {
        let request = [
            """
            {"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-codex-bridge","version":"0.2.0"},"capabilities":{"experimentalApi":true}}}
            """,
            #"{"method":"initialized"}"#,
            String(
                decoding: try JSONSerialization.data(withJSONObject: [
                    "id": 2,
                    "method": "thread/name/set",
                    "params": ["threadId": threadID, "name": name],
                ]),
                as: UTF8.self
            ),
        ].joined(separator: "\n") + "\n"
        let process = try await ProcessRunner.run(
            executable: configuration.codexCommand,
            arguments: ["app-server", "--stdio"],
            currentDirectory: project,
            stdin: request,
            timeoutSeconds: 8,
            maximumOutputCharacters: 50_000
        )
        guard process.status == 0,
              process.stdout.split(separator: "\n").contains(where: { line in
                  guard let value = try? BridgeJSON.decoder.decode(
                      JSONValue.self,
                      from: Data(line.utf8)
                  ), let object = value.objectValue
                  else { return false }
                  return object["id"]?.intValue == 2 && object["error"] == nil
              })
        else {
            throw BridgeError.processFailed(
                nonEmpty(process.stderr) ?? "Codex thread/name/set returned no success response."
            )
        }
    }
}

private func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
