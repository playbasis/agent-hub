import Foundation

public struct RuleBasedClassifier: Sendable {
    public init() {}

    public func classify(
        event: BridgeEvent,
        session: RuntimeSession,
        quota: inout QuotaTracker
    ) throws -> Decision {
        let text = event.content.text
        let lowered = text.lowercased()
        let label = label(for: lowered)

        let agentReportedCompletion =
            event.source != .bridge
                && event.type == .turnComplete
                && (
                    lowered.contains("<bridge:complete>")
                        || event.metadata["task_complete"]?.boolValue == true
                )
        if agentReportedCompletion
        {
            return try Decision(
                label: .complete,
                confidence: 1,
                nextAgent: .none,
                action: .complete,
                refinedPrompt: "",
                summaryForLog: "Agent reported verified completion.",
                reason: "The explicit bridge completion protocol was satisfied."
            )
        }

        if event.source != .bridge,
           event.type == .turnComplete,
           lowered.contains("<bridge:blocked>")
        {
            return try Decision(
                label: label,
                confidence: 0.98,
                nextAgent: .none,
                action: .pause,
                refinedPrompt: "",
                summaryForLog: "Agent reported a blocker requiring user action.",
                reason: "The explicit bridge blocked protocol was emitted."
            )
        }

        if event.type == .toolUse {
            return try Decision(
                label: label,
                confidence: 1,
                nextAgent: .none,
                action: .pause,
                refinedPrompt: "",
                summaryForLog: "Recorded agent progress without scheduling a hand-off.",
                reason: "Tool-use events are audit-only while a turn is running."
            )
        }

        let current = sourceAgent(event.source)
        var preferred = session.preferredStartingAgent
        if event.type == .rateLimit, current != .none {
            preferred = current.other
        } else if [.turnComplete, .error].contains(event.type), current != .none {
            preferred = current.other
        }
        let target = quota.bestAvailable(preferred: preferred)
        guard target != .none else {
            return try Decision(
                label: label,
                confidence: 1,
                nextAgent: .none,
                action: .pause,
                refinedPrompt: "",
                summaryForLog: "No agent has estimated capacity.",
                reason: "Both agents are rate-limited; park until the earliest reset."
            )
        }
        let action: DecisionAction =
            current == target && event.type != .error ? .continue : .handoff
        let summary = summarize(text, eventType: event.type)
        return try Decision(
            label: label,
            confidence: 0.78,
            nextAgent: target,
            action: action,
            refinedPrompt: prompt(
                session: session,
                event: event,
                target: target,
                summary: summary
            ),
            summaryForLog: summary,
            reason: reason(event: event, current: current, target: target)
        )
    }

    private func sourceAgent(_ source: EventSource) -> AgentName {
        switch source {
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .bridge: .none
        }
    }

    private func label(for text: String) -> TaskLabel {
        let groups: [(TaskLabel, [String])] = [
            (.test, ["test", "pytest", "spec", "coverage"]),
            (.debug, ["bug", "error", "failure", "traceback", "debug"]),
            (.refactor, ["refactor", "cleanup", "restructure"]),
            (.architecture, ["architecture", "design", "plan", "tradeoff"]),
            (.research, ["research", "investigate", "compare", "documentation"]),
        ]
        return groups.first { _, words in words.contains { text.contains($0) } }?.0
            ?? .implementation
    }

    private func summarize(_ text: String, eventType: EventType) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else {
            return "Processed \(eventType.rawValue) event with no textual output."
        }
        return String(compact.prefix(500)) + (compact.count > 500 ? "…" : "")
    }

    private func prompt(
        session: RuntimeSession,
        event: BridgeEvent,
        target: AgentName,
        summary: String
    ) -> String {
        """
        Continue the shared bridge session as the \(target.rawValue) agent.

        Goal:
        \(session.goal)

        Latest event:
        - Source: \(event.source.rawValue)
        - Type: \(event.type.rawValue)
        - Summary: \(summary)

        Read BRIDGE.md and recent CHANGES.log entries before acting. Inspect the
        working tree; do not assume the previous summary is complete. Advance
        the goal with concrete edits or verification. Stay inside the project
        and preserve unrelated user changes.

        Finish with `<bridge:complete>` only when the goal is fully implemented
        and verification passes. Otherwise use `<bridge:continue>`. If only the
        user can unblock progress, use the blocked marker in BRIDGE.md.
        """
    }

    private func reason(
        event: BridgeEvent,
        current: AgentName,
        target: AgentName
    ) -> String {
        if event.type == .rateLimit {
            return "\(current.rawValue) reported a limit; \(target.rawValue) is available."
        }
        if event.type == .error {
            return "Switching from failed \(current.rawValue) execution to \(target.rawValue)."
        }
        if current == .none {
            return "Starting with the preferred available agent, \(target.rawValue)."
        }
        if current == target {
            return "\(target.rawValue) remains the best available agent."
        }
        return "Alternating from \(current.rawValue) to \(target.rawValue) for independent context."
    }
}

public struct DecisionOutcome: Sendable {
    public var decision: Decision
    public var provider: ProviderHealth
    public var telemetry: AgentTelemetry?
}

public struct DecisionEngine: Sendable {
    private let configuration: BridgeConfiguration
    private let rules = RuleBasedClassifier()

    public init(configuration: BridgeConfiguration) {
        self.configuration = configuration
    }

    public func decide(
        event: BridgeEvent,
        session: RuntimeSession,
        store: ProjectStore,
        quota: inout QuotaTracker
    ) async -> DecisionOutcome {
        let fallback: Decision
        do {
            fallback = try rules.classify(event: event, session: session, quota: &quota)
        } catch {
            return DecisionOutcome(
                decision: Decision.routingFailure(error.localizedDescription),
                provider: ProviderHealth(
                    provider: configuration.meta.coordinatorIdentifier,
                    state: .degraded,
                    fallbackActive: false,
                    message: boundedMessage(error),
                    lastChecked: Date()
                ),
                telemetry: nil
            )
        }
        guard configuration.meta.provider != .rules, event.type != .toolUse else {
            return DecisionOutcome(decision: fallback, provider: .rulesReady, telemetry: nil)
        }
        do {
            let startAtHighEffort =
                event.type == .rateLimit
                    || event.type == .error
                    || event.content.text.localizedCaseInsensitiveContains(
                        "<bridge:complete>"
                    )
            let initialEffort = startAtHighEffort
                ? configuration.meta.escalationEffort
                : configuration.meta.routineEffort
            var remote: RemoteDecision
            do {
                remote = try await remoteDecision(
                    event: event,
                    session: session,
                    store: store,
                    quota: &quota,
                    effort: initialEffort
                )
            } catch {
                guard configuration.meta.provider == .grokCLI,
                      initialEffort != configuration.meta.escalationEffort
                else { throw error }
                remote = try await remoteDecision(
                    event: event,
                    session: session,
                    store: store,
                    quota: &quota,
                    effort: configuration.meta.escalationEffort
                )
            }
            var decision = remote.decision
            if configuration.meta.provider == .grokCLI,
               decision.confidence < configuration.meta.confidenceThreshold,
               initialEffort != configuration.meta.escalationEffort
            {
                remote = try await remoteDecision(
                    event: event,
                    session: session,
                    store: store,
                    quota: &quota,
                    effort: configuration.meta.escalationEffort
                )
                decision = remote.decision
            }
            guard decision.confidence >= configuration.meta.confidenceThreshold else {
                return DecisionOutcome(
                    decision: fallback,
                    provider: ProviderHealth(
                        provider: configuration.meta.coordinatorIdentifier,
                        state: .degraded,
                        fallbackActive: true,
                        message: "Provider confidence was below the configured threshold; rules handled this turn.",
                        lastChecked: Date()
                    ),
                    telemetry: remote.telemetry
                )
            }
            return DecisionOutcome(
                decision: try decision.validated(),
                provider: ProviderHealth(
                    provider: configuration.meta.coordinatorIdentifier,
                    state: .ready,
                    fallbackActive: false,
                    message: "Provider response validated",
                    lastChecked: Date()
                ),
                telemetry: remote.telemetry
            )
        } catch {
            return DecisionOutcome(
                decision: fallback,
                provider: ProviderHealth(
                    provider: configuration.meta.coordinatorIdentifier,
                    state: .degraded,
                    fallbackActive: true,
                    message: "\(boundedMessage(error)) Rules handled this turn.",
                    lastChecked: Date()
                ),
                telemetry: nil
            )
        }
    }

    public func probeProvider(
        requireGeneration: Bool = false
    ) async -> ProviderHealth {
        switch configuration.meta.provider {
        case .rules:
            return .rulesReady
        case .ollama:
            guard let base = URL(string: configuration.meta.endpoint) else {
                return degraded("The Ollama endpoint is not a valid URL.")
            }
            var request = URLRequest(url: base.appendingPathComponent("api/tags"))
            request.timeoutInterval = configuration.meta.timeoutSeconds
            request.httpMethod = "GET"
            return await probe(request)
        case .grokCLI:
            do {
                let executable = try ExecutableLocator.resolve(
                    configuration.agents.grokCommand
                )
                if !requireGeneration {
                    let version = try await ProcessRunner.run(
                        executable: executable.path,
                        arguments: ["version"],
                        currentDirectory: BridgePaths.providerProbeDirectory,
                        stdin: "",
                        timeoutSeconds: 6,
                        maximumOutputCharacters: 10_000
                    )
                    guard version.status == 0 else {
                        return degraded(
                            nonEmptyString(version.stderr)
                                ?? "Grok Build is installed but did not start."
                        )
                    }
                    return ProviderHealth(
                        provider: "grok",
                        state: .ready,
                        fallbackActive: false,
                        message: "Grok Build installed; authentication is verified on use.",
                        lastChecked: Date()
                    )
                }
                let probe = try await callGrokCoordinator(
                    systemPrompt: "Return exactly one valid Bridge decision JSON object.",
                    userPayload: """
                    {"schema_version":"1.0","label":"test","confidence":1,\
                    "next_agent":"none","action":"pause","refined_prompt":"",\
                    "summary_for_log":"Grok coordinator probe passed.",\
                    "reason":"The JSON decision contract was requested."}
                    """,
                    effort: configuration.meta.routineEffort
                )
                _ = try probe.decision.validated()
                return ProviderHealth(
                    provider: "grok",
                    state: .ready,
                    fallbackActive: false,
                    message: "Grok Build entitlement and decision contract validated.",
                    lastChecked: Date()
                )
            } catch {
                let message = boundedMessage(error)
                return degraded(
                    message.localizedCaseInsensitiveContains("entitlement")
                        || message.localizedCaseInsensitiveContains("upgrade")
                        ? "Grok Build is installed, but this account is not entitled. "
                            + "Use SuperGrok, X Premium+, or an XAI_API_KEY."
                        : message
                )
            }
        case .openAICompatible:
            guard let endpoint = URL(string: configuration.meta.endpoint) else {
                return degraded("The compatible-provider endpoint is not a valid URL.")
            }
            guard let key = CoordinatorSecretStore.resolve(
                environmentVariable: configuration.meta.apiKeyEnvironmentVariable
            ) else {
                return degraded(
                    "No coordinator API key is available in the environment "
                        + "or private credential store."
                )
            }
            guard endpoint.path.hasSuffix("/chat/completions")
                    || endpoint.scheme == "http"
                    || endpoint.scheme == "https"
            else {
                return degraded("The compatible-provider endpoint is not valid.")
            }
            if configuration.meta.coordinatorIdentifier == "gemini",
               !requireGeneration
            {
                return await probeGeminiModel(endpoint: endpoint, key: key)
            }
            do {
                let decision = try await callOpenAICompatible(
                    systemPrompt: "Return exactly one JSON object matching the requested values.",
                    userPayload: """
                    Return exactly:
                    {"schema_version":"1.0","label":"test","confidence":1,\
                    "next_agent":"none","action":"pause","refined_prompt":"",\
                    "summary_for_log":"Coordinator probe passed.",\
                    "reason":"The JSON decision contract was requested."}
                    """
                )
                _ = try decision.decision.validated()
                return ProviderHealth(
                    provider: configuration.meta.coordinatorIdentifier,
                    state: .ready,
                    fallbackActive: false,
                    message: "Coordinator credentials and JSON contract validated",
                    lastChecked: Date()
                )
            } catch {
                return degraded(boundedMessage(error))
            }
        }
    }

    private func probeGeminiModel(
        endpoint: URL,
        key: String
    ) async -> ProviderHealth {
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        let model = configuration.meta.model
            .replacingOccurrences(of: "models/", with: "")
        components.path = "/v1beta/models/\(model)"
        guard let url = components.url else {
            return degraded("The Gemini model probe URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.meta.timeoutSeconds
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return degraded("Gemini returned no HTTP response.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                let detail = Self.providerErrorSummary(data)
                    .map { ": \($0)" }
                    ?? ""
                return degraded(
                    "Gemini model check failed (HTTP \(http.statusCode))\(detail)"
                )
            }
            return ProviderHealth(
                provider: "gemini",
                state: .ready,
                fallbackActive: false,
                message: "Credentials and model availability validated",
                lastChecked: Date()
            )
        } catch {
            return degraded(boundedMessage(error))
        }
    }

    private func remoteDecision(
        event: BridgeEvent,
        session: RuntimeSession,
        store: ProjectStore,
        quota: inout QuotaTracker,
        effort: String? = nil
    ) async throws -> RemoteDecision {
        // Packaged macOS apps keep the canonical prompt in
        // Contents/Resources. SwiftPM's Bundle.module remains the development
        // and test fallback, but must not be evaluated first in an installed
        // app because its generated build path is not portable.
        let promptURL = Bundle.main.url(
            forResource: "meta_classifier_v1",
            withExtension: "txt"
        ) ?? Bundle.module.url(
            forResource: "meta_classifier_v1",
            withExtension: "txt"
        )
        let systemPrompt = try String(
            contentsOf: promptURL
                ?? { throw BridgeError.configuration("Missing classifier prompt") }(),
            encoding: .utf8
        )
        let payload = MetaPayload(
            event: event,
            session: session,
            quota: quota.snapshot(),
            recentHandoffs: store.recentDecisionValues(
                limit: configuration.session.recentContextEntries
            )
        )
        let userPayload = String(
            decoding: try BridgeJSON.compactEncoder.encode(payload),
            as: UTF8.self
        )
        switch configuration.meta.provider {
        case .rules:
            throw BridgeError.configuration("Rules provider has no remote endpoint")
        case .ollama:
            return try await callOllama(systemPrompt: systemPrompt, userPayload: userPayload)
        case .grokCLI:
            return try await callGrokCoordinator(
                systemPrompt: systemPrompt,
                userPayload: userPayload,
                effort: effort ?? configuration.meta.routineEffort
            )
        case .openAICompatible:
            return try await callOpenAICompatible(
                systemPrompt: systemPrompt,
                userPayload: userPayload
            )
        }
    }

    private func callGrokCoordinator(
        systemPrompt: String,
        userPayload: String,
        effort: String
    ) async throws -> RemoteDecision {
        try FileManager.default.createDirectory(
            at: BridgePaths.providerProbeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let prompt = """
        \(systemPrompt)

        You are the tool-free routing coordinator. Do not inspect files, run
        commands, search, or call tools. Return exactly one JSON object.

        \(userPayload)
        """
        let apiKey = CoordinatorSecretStore.resolve(
            environmentVariable: configuration.meta.apiKeyEnvironmentVariable
        )
        let startedAt = Date()
        let process = try await ProcessRunner.run(
            executable: configuration.agents.grokCommand,
            arguments: [
                "--no-auto-update",
                "--cwd", BridgePaths.providerProbeDirectory.path,
                "--model", configuration.meta.model,
                "--effort", effort,
                "--output-format", "json",
                "--permission-mode", "dontAsk",
                "--sandbox", "strict",
                "--no-plan",
                "--no-subagents",
                "--no-memory",
                "--disable-web-search",
                "--disallowed-tools", "*",
                "--single", prompt,
            ],
            currentDirectory: BridgePaths.providerProbeDirectory,
            stdin: "",
            timeoutSeconds: Int(configuration.meta.timeoutSeconds),
            maximumOutputCharacters: configuration.agents.maxOutputCharacters,
            environment: apiKey.map {
                [configuration.meta.apiKeyEnvironmentVariable: $0]
            } ?? [:]
        )
        guard process.status == 0 else {
            throw BridgeError.processFailed(
                nonEmptyString(process.stderr)
                    ?? nonEmptyString(process.stdout)
                    ?? "Grok coordinator failed."
            )
        }
        let parsed = GrokJSONParser.parse(
            process.stdout,
            requestedModel: configuration.meta.model,
            requestedEffort: effort,
            sandbox: "strict",
            permissionMode: "dontAsk"
        )
        var telemetry = parsed.telemetry
        telemetry.durationMilliseconds = Int(
            Date().timeIntervalSince(startedAt) * 1_000
        )
        return RemoteDecision(
            decision: try decodeDecision(parsed.output),
            telemetry: telemetry
        )
    }

    private func callOllama(
        systemPrompt: String,
        userPayload: String
    ) async throws -> RemoteDecision {
        let url = URL(string: configuration.meta.endpoint)?
            .appendingPathComponent("api/chat")
        guard let url else { throw BridgeError.configuration("Invalid Ollama endpoint") }
        let body = OllamaRequest(
            model: configuration.meta.model,
            stream: false,
            format: "json",
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPayload),
            ]
        )
        let data = try await post(url: url, body: body, authorization: nil)
        let response = try BridgeJSON.decoder.decode(OllamaResponse.self, from: data)
        return RemoteDecision(
            decision: try decodeDecision(response.message.content),
            telemetry: AgentTelemetry(
                identity: ProviderIdentity(
                    requestedModel: configuration.meta.model,
                    resolvedModel: configuration.meta.model,
                    modelProvider: "ollama"
                ),
                warnings: ["Ollama did not expose normalized usage in this adapter."]
            )
        )
    }

    private func callOpenAICompatible(
        systemPrompt: String,
        userPayload: String
    ) async throws -> RemoteDecision {
        guard var url = URL(string: configuration.meta.endpoint) else {
            throw BridgeError.configuration("Invalid OpenAI-compatible endpoint")
        }
        if !url.path.hasSuffix("/chat/completions") {
            url.append(path: "v1/chat/completions")
        }
        let body = ChatRequest(
            model: configuration.meta.model,
            temperature: 0,
            responseFormat: ["type": "json_object"],
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPayload),
            ]
        )
        guard let key = CoordinatorSecretStore.resolve(
            environmentVariable: configuration.meta.apiKeyEnvironmentVariable
        ) else {
            throw BridgeError.configuration(
                "Missing coordinator API key in the environment and private credential store"
            )
        }
        let startedAt = Date()
        let data = try await post(url: url, body: body, authorization: key)
        let response = try BridgeJSON.decoder.decode(ChatResponse.self, from: data)
        guard let content = response.choices.first?.message.content else {
            throw BridgeError.network("Classifier returned no choices")
        }
        let usage = response.usage.map {
            TokenUsage(
                input: $0.promptTokens,
                output: $0.completionTokens,
                cachedInput: $0.promptTokensDetails?.cachedTokens,
                reasoning: $0.completionTokensDetails?.reasoningTokens,
                total: $0.totalTokens,
                provenance: $0.totalTokens == nil ? .unavailable : .providerReported
            )
        } ?? TokenUsage()
        return RemoteDecision(
            decision: try decodeDecision(content),
            telemetry: AgentTelemetry(
                identity: ProviderIdentity(
                    requestedModel: configuration.meta.model,
                    resolvedModel: response.model,
                    modelProvider: configuration.meta.coordinatorIdentifier == "gemini"
                        ? "google" : "openai_compatible"
                ),
                usage: usage,
                nativeTurnID: response.id,
                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                completeness: usage.total == nil ? .partial : .complete,
                warnings: usage.total == nil
                    ? ["Coordinator did not report authoritative token usage."] : []
            )
        )
    }

    private func post<T: Encodable>(
        url: URL,
        body: T,
        authorization: String?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.meta.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization, !authorization.isEmpty {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try BridgeJSON.compactEncoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.network("Classifier returned no HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let detail = Self.providerErrorSummary(data)
                .map { ": \($0)" }
                ?? ""
            throw BridgeError.network(
                "Classifier request failed (HTTP \(http.statusCode))\(detail)"
            )
        }
        return data
    }

    static func providerErrorSummary(_ data: Data) -> String? {
        guard let value = try? BridgeJSON.decoder.decode(JSONValue.self, from: data),
              let error = findProviderError(in: value)
        else { return nil }
        let status = error["status"]?.stringValue
        let message = error["message"]?.stringValue
        let combined = [status, message]
            .compactMap { $0 }
            .joined(separator: ": ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return combined.isEmpty ? nil : String(combined.prefix(320))
    }

    private static func findProviderError(
        in value: JSONValue
    ) -> [String: JSONValue]? {
        switch value {
        case let .object(object):
            if let error = object["error"]?.objectValue {
                return error
            }
            for child in object.values {
                if let error = findProviderError(in: child) {
                    return error
                }
            }
        case let .array(values):
            for child in values {
                if let error = findProviderError(in: child) {
                    return error
                }
            }
        case .string, .number, .bool, .null:
            break
        }
        return nil
    }

    private func decodeDecision(_ content: String) throws -> Decision {
        try Self.decodeDecisionContent(content)
    }

    static func decodeDecisionContent(_ content: String) throws -> Decision {
        let candidates = topLevelJSONObjects(in: content)
        guard !candidates.isEmpty else {
            throw BridgeError.invalidDecision("Classifier returned no JSON object")
        }

        var lastFailure: (Error, String)?
        for candidate in candidates {
            do {
                return try BridgeJSON.decoder.decode(
                    Decision.self,
                    from: Data(candidate.utf8)
                )
            } catch {
                lastFailure = (error, candidate)
            }
        }
        let failure = lastFailure!
        throw BridgeError.invalidDecision(
            "\(decodingDiagnostic(failure.0)); provider JSON: "
                + String(failure.1.prefix(600))
        )
    }

    /// Extracts balanced top-level JSON objects while respecting quoted
    /// strings and escapes. Some compatible providers append a self-correction
    /// after already returning one complete schema-valid object. Accepting that
    /// object is safe because `Decision` decoding still rejects unknown shapes
    /// and enforces all routing invariants.
    private static func topLevelJSONObjects(in content: String) -> [String] {
        var objects: [String] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false

        for index in content.indices {
            let character = content[index]
            guard start != nil else {
                if character == "{" {
                    start = index
                    depth = 1
                }
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let objectStart = start {
                    objects.append(String(content[objectStart ... index]))
                    start = nil
                }
            default:
                break
            }
        }
        return objects
    }

    private static func decodingDiagnostic(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "missing key \(key.stringValue) at \(codingPath(context.codingPath))"
        case let DecodingError.typeMismatch(type, context):
            return "expected \(type) at \(codingPath(context.codingPath)): "
                + context.debugDescription
        case let DecodingError.valueNotFound(type, context):
            return "missing \(type) value at \(codingPath(context.codingPath))"
        case let DecodingError.dataCorrupted(context):
            return "invalid value at \(codingPath(context.codingPath)): "
                + context.debugDescription
        default:
            return error.localizedDescription
        }
    }

    private static func codingPath(_ path: [any CodingKey]) -> String {
        path.isEmpty ? "<root>" : path.map(\.stringValue).joined(separator: ".")
    }

    private func probe(_ request: URLRequest) async -> ProviderHealth {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return degraded("The provider returned no HTTP response.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return degraded("The provider rejected its configured credentials.")
            }
            if http.statusCode >= 500 {
                return degraded("The provider is currently unavailable (HTTP \(http.statusCode)).")
            }
            return ProviderHealth(
                provider: configuration.meta.provider.rawValue,
                state: .ready,
                fallbackActive: false,
                message: "Provider reachable",
                lastChecked: Date()
            )
        } catch {
            return degraded(boundedMessage(error))
        }
    }

    private func degraded(_ message: String) -> ProviderHealth {
        ProviderHealth(
            provider: configuration.meta.coordinatorIdentifier,
            state: .degraded,
            fallbackActive: true,
            message: message,
            lastChecked: Date()
        )
    }

    private func boundedMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        return String(message.prefix(400))
    }

    private func nonEmptyString(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private struct MetaPayload: Encodable {
    var event: BridgeEvent
    var session: RuntimeSession
    var quota: [String: QuotaEstimate]
    var recentHandoffs: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case event, session, quota
        case recentHandoffs = "recent_handoffs"
    }
}

private struct ChatMessage: Codable {
    var role: String
    var content: String
}

private struct OllamaRequest: Encodable {
    var model: String
    var stream: Bool
    var format: String
    var messages: [ChatMessage]
}

private struct OllamaResponse: Decodable {
    var message: ChatMessage
}

private struct ChatRequest: Encodable {
    var model: String
    var temperature: Double
    var responseFormat: [String: String]
    var messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case model, temperature
        case responseFormat = "response_format"
        case messages
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        var message: ChatMessage
    }

    var choices: [Choice]
    var id: String?
    var model: String?
    var usage: ChatUsage?
}

private struct ChatUsage: Decodable {
    struct PromptDetails: Decodable {
        var cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    struct CompletionDetails: Decodable {
        var reasoningTokens: Int?

        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var promptTokensDetails: PromptDetails?
    var completionTokensDetails: CompletionDetails?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
    }
}

private struct RemoteDecision {
    var decision: Decision
    var telemetry: AgentTelemetry
}

extension Decision {
    func validated() throws -> Decision {
        try Decision(
            label: label,
            confidence: confidence,
            nextAgent: nextAgent,
            action: action,
            refinedPrompt: refinedPrompt,
            summaryForLog: summaryForLog,
            reason: reason
        )
    }
}
