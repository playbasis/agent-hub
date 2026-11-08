import Foundation
import Security

public struct ServerConfiguration: Codable, Equatable, Sendable {
    public var host = "127.0.0.1"
    public var port = 8_742
    public var bearerToken: String
    public var maxEventBytes = 1_048_576

    enum CodingKeys: String, CodingKey {
        case host, port
        case bearerToken = "bearer_token"
        case maxEventBytes = "max_event_bytes"
    }

    /// The control API can launch coding agents, so it only ever listens on
    /// this Mac, whatever config.json says.
    public var isLoopback: Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    }
}

public struct AgentConfiguration: Codable, Equatable, Sendable {
    public var claudeCommand = "claude"
    public var claudeModel = "sonnet"
    public var claudeEffort = "high"
    public var claudeIsolatedMode = true
    public var codexCommand = "codex"
    public var codexModel = "gpt-5.6-sol"
    public var codexReasoningEffort = "high"
    public var codexIsolatedMode = true
    public var grokCommand = "grok"
    public var grokModel = "grok-4.5"
    public var grokReasoningEffort = "high"
    public var grokPermissionMode = "auto"
    public var grokSandbox = "workspace"
    public var grokIsolatedMode = true
    public var subprocessTimeoutSeconds = 2_700
    public var maxOutputCharacters = 500_000
    public var claudePermissionMode = "auto"
    public var codexSandbox = "workspace-write"
    public var codexSkipGitRepositoryCheck = false

    enum CodingKeys: String, CodingKey {
        case claudeCommand = "claude_command"
        case claudeModel = "claude_model"
        case claudeEffort = "claude_effort"
        case claudeIsolatedMode = "claude_isolated_mode"
        case codexCommand = "codex_command"
        case codexModel = "codex_model"
        case codexReasoningEffort = "codex_reasoning_effort"
        case codexIsolatedMode = "codex_isolated_mode"
        case grokCommand = "grok_command"
        case grokModel = "grok_model"
        case grokReasoningEffort = "grok_reasoning_effort"
        case grokPermissionMode = "grok_permission_mode"
        case grokSandbox = "grok_sandbox"
        case grokIsolatedMode = "grok_isolated_mode"
        case subprocessTimeoutSeconds = "subprocess_timeout_seconds"
        case maxOutputCharacters = "max_output_characters"
        case claudePermissionMode = "claude_permission_mode"
        case codexSandbox = "codex_sandbox"
        case codexSkipGitRepositoryCheck = "codex_skip_git_repository_check"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCommand = try container.decodeIfPresent(
            String.self,
            forKey: .claudeCommand
        ) ?? "claude"
        claudeModel = try container.decodeIfPresent(
            String.self,
            forKey: .claudeModel
        ) ?? "sonnet"
        claudeEffort = try container.decodeIfPresent(
            String.self,
            forKey: .claudeEffort
        ) ?? "high"
        let hadClaudeIsolationSetting = container.contains(.claudeIsolatedMode)
        claudeIsolatedMode = try container.decodeIfPresent(
            Bool.self,
            forKey: .claudeIsolatedMode
        ) ?? true
        codexCommand = try container.decodeIfPresent(
            String.self,
            forKey: .codexCommand
        ) ?? "codex"
        codexModel = try container.decodeIfPresent(
            String.self,
            forKey: .codexModel
        ) ?? "gpt-5.6-sol"
        codexReasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .codexReasoningEffort
        ) ?? "high"
        codexIsolatedMode = try container.decodeIfPresent(
            Bool.self,
            forKey: .codexIsolatedMode
        ) ?? true
        grokCommand = try container.decodeIfPresent(
            String.self,
            forKey: .grokCommand
        ) ?? "grok"
        grokModel = try container.decodeIfPresent(
            String.self,
            forKey: .grokModel
        ) ?? "grok-4.5"
        grokReasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .grokReasoningEffort
        ) ?? "high"
        grokPermissionMode = try container.decodeIfPresent(
            String.self,
            forKey: .grokPermissionMode
        ) ?? "auto"
        grokSandbox = try container.decodeIfPresent(
            String.self,
            forKey: .grokSandbox
        ) ?? "workspace"
        grokIsolatedMode = try container.decodeIfPresent(
            Bool.self,
            forKey: .grokIsolatedMode
        ) ?? true
        subprocessTimeoutSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .subprocessTimeoutSeconds
        ) ?? 2_700
        maxOutputCharacters = try container.decodeIfPresent(
            Int.self,
            forKey: .maxOutputCharacters
        ) ?? 500_000
        let decodedClaudePermissionMode = try container.decodeIfPresent(
            String.self,
            forKey: .claudePermissionMode
        ) ?? "auto"
        // `acceptEdits` was the original unattended default, but it blocks
        // every shell command because print mode has no approval UI. Migrate
        // legacy configs when the new isolation setting is absent; preserve
        // any permission mode chosen in a current-format config.
        claudePermissionMode =
            !hadClaudeIsolationSetting && decodedClaudePermissionMode == "acceptEdits"
                ? "auto"
                : decodedClaudePermissionMode
        codexSandbox = try container.decodeIfPresent(
            String.self,
            forKey: .codexSandbox
        ) ?? "workspace-write"
        codexSkipGitRepositoryCheck = try container.decodeIfPresent(
            Bool.self,
            forKey: .codexSkipGitRepositoryCheck
        ) ?? false
    }
}

public struct TraceConfiguration: Codable, Equatable, Sendable {
    public var enabled = true
    public var capturePolicy: TraceCapturePolicy = .metadataRedacted
    public var requireDualProvider = true
    /// Off by default: the third coordinator provider is optional, so an
    /// install without it must still be able to complete a turn.
    public var requireThreeProvider = false
    public var totalTokenCeiling: Int?
    public var perTurnTokenReservation: Int?
    public var estimatedCostCeilingUSD: Double?

    enum CodingKeys: String, CodingKey {
        case enabled
        case capturePolicy = "capture_policy"
        case requireDualProvider = "require_dual_provider"
        case requireThreeProvider = "require_three_provider"
        case totalTokenCeiling = "total_token_ceiling"
        case perTurnTokenReservation = "per_turn_token_reservation"
        case estimatedCostCeilingUSD = "estimated_cost_ceiling_usd"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        capturePolicy = try container.decodeIfPresent(
            TraceCapturePolicy.self,
            forKey: .capturePolicy
        ) ?? .metadataRedacted
        requireDualProvider = try container.decodeIfPresent(
            Bool.self,
            forKey: .requireDualProvider
        ) ?? true
        requireThreeProvider = try container.decodeIfPresent(
            Bool.self,
            forKey: .requireThreeProvider
        ) ?? false
        totalTokenCeiling = try container.decodeIfPresent(Int.self, forKey: .totalTokenCeiling)
        perTurnTokenReservation = try container.decodeIfPresent(
            Int.self,
            forKey: .perTurnTokenReservation
        )
        estimatedCostCeilingUSD = try container.decodeIfPresent(
            Double.self,
            forKey: .estimatedCostCeilingUSD
        )
    }
}

public struct MetaConfiguration: Codable, Equatable, Sendable {
    public static let grokModel = "grok-4.5"
    public static let grokEndpoint = "grok://build/agent-stdio"
    public static let geminiModel = "gemini-3.6-flash"
    public static let geminiEndpoint =
        "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

    public enum Provider: String, Codable, Sendable {
        case rules
        case ollama
        case grokCLI = "grok_cli"
        case openAICompatible = "openai_compatible"
    }

    public var provider: Provider = .rules
    public var model = "qwen2.5-coder:3b"
    public var endpoint = "http://127.0.0.1:11434"
    public var apiKeyEnvironmentVariable = "CCB_META_API_KEY"
    public var timeoutSeconds = 30.0
    public var confidenceThreshold = 0.75
    public var routineEffort = "low"
    public var escalationEffort = "high"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case provider, model, endpoint
        case apiKeyEnvironmentVariable = "api_key_environment_variable"
        case timeoutSeconds = "timeout_seconds"
        case confidenceThreshold = "confidence_threshold"
        case routineEffort = "routine_effort"
        case escalationEffort = "escalation_effort"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedProvider = try container.decodeIfPresent(
            Provider.self, forKey: .provider
        ) ?? .rules
        // A configured coordinator is honoured as written. Rewriting it here
        // would silently repoint a working install at a provider that may not
        // be installed at all.
        provider = decodedProvider
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? (decodedProvider == .grokCLI ? Self.grokModel : "qwen2.5-coder:3b")
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
            ?? (decodedProvider == .grokCLI
                ? Self.grokEndpoint : "http://127.0.0.1:11434")
        apiKeyEnvironmentVariable = try container.decodeIfPresent(
            String.self, forKey: .apiKeyEnvironmentVariable
        ) ?? (decodedProvider == .grokCLI ? "XAI_API_KEY" : "CCB_META_API_KEY")
        timeoutSeconds = try container.decodeIfPresent(
            Double.self, forKey: .timeoutSeconds
        ) ?? 30
        confidenceThreshold = try container.decodeIfPresent(
            Double.self, forKey: .confidenceThreshold
        ) ?? 0.75
        routineEffort = try container.decodeIfPresent(
            String.self, forKey: .routineEffort
        ) ?? "low"
        escalationEffort = try container.decodeIfPresent(
            String.self, forKey: .escalationEffort
        ) ?? "high"
    }

    public var coordinatorIdentifier: String {
        switch provider {
        case .rules:
            return "rules"
        case .ollama:
            return "ollama"
        case .grokCLI:
            return "grok"
        case .openAICompatible:
            return endpoint.localizedCaseInsensitiveContains(
                "generativelanguage.googleapis.com"
            ) ? "gemini" : "openai_compatible"
        }
    }
}

public struct SessionConfiguration: Codable, Equatable, Sendable {
    public var defaultDurationMinutes = 240
    public var rateLimitCooldownMinutes = 60
    public var maximumTurns = 80
    public var recentContextEntries = 12

    public init() {}

    enum CodingKeys: String, CodingKey {
        case defaultDurationMinutes = "default_duration_minutes"
        case rateLimitCooldownMinutes = "rate_limit_cooldown_minutes"
        case maximumTurns = "maximum_turns"
        case recentContextEntries = "recent_context_entries"
    }
}

public struct BridgeConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = "1.0"
    public var server: ServerConfiguration
    public var agents = AgentConfiguration()
    public var meta = MetaConfiguration()
    public var session = SessionConfiguration()
    public var trace = TraceConfiguration()
    public var recentProjects: [String] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case server, agents, meta, session, trace
        case recentProjects = "recent_projects"
    }

    public static func makeDefault() throws -> BridgeConfiguration {
        BridgeConfiguration(
            server: ServerConfiguration(bearerToken: try SecureToken.generate())
        )
    }

    public init(
        schemaVersion: String = "1.0",
        server: ServerConfiguration,
        agents: AgentConfiguration = AgentConfiguration(),
        meta: MetaConfiguration = MetaConfiguration(),
        session: SessionConfiguration = SessionConfiguration(),
        trace: TraceConfiguration = TraceConfiguration(),
        recentProjects: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.server = server
        self.agents = agents
        self.meta = meta
        self.session = session
        self.trace = trace
        self.recentProjects = recentProjects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "1.0"
        server = try container.decode(ServerConfiguration.self, forKey: .server)
        agents = try container.decodeIfPresent(AgentConfiguration.self, forKey: .agents)
            ?? AgentConfiguration()
        meta = try container.decodeIfPresent(MetaConfiguration.self, forKey: .meta)
            ?? MetaConfiguration()
        session = try container.decodeIfPresent(SessionConfiguration.self, forKey: .session)
            ?? SessionConfiguration()
        trace = try container.decodeIfPresent(TraceConfiguration.self, forKey: .trace)
            ?? TraceConfiguration()
        recentProjects = try container.decodeIfPresent([String].self, forKey: .recentProjects) ?? []
    }

    public func redacted() -> BridgeConfiguration {
        var copy = self
        copy.server.bearerToken = "***redacted***"
        return copy
    }
}

public enum BridgePaths {
    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeCodexBridge")
    }

    public static var configuration: URL {
        if let override = ProcessInfo.processInfo.environment["CCB_CONFIG_FILE"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return applicationSupport.appendingPathComponent("config.json")
    }

    public static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeCodexBridge")
    }

    public static var planUsageCache: URL {
        applicationSupport.appendingPathComponent("plan-usage.json")
    }

    public static var tokenLedgerCache: URL {
        applicationSupport.appendingPathComponent("token-ledger.json")
    }

    public static var recoverySnapshot: URL {
        applicationSupport.appendingPathComponent("active-session.json")
    }

    public static var providerProbeDirectory: URL {
        applicationSupport.appendingPathComponent("ProviderProbe", isDirectory: true)
    }

    public static var coordinatorCredentials: URL {
        applicationSupport.appendingPathComponent("coordinator-credentials.json")
    }
}

public enum ConfigurationStore {
    public static func load(create: Bool = true) throws -> BridgeConfiguration {
        let url = BridgePaths.configuration
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard create else { throw BridgeError.configuration("No config at \(url.path)") }
            let configuration = try BridgeConfiguration.makeDefault()
            try save(configuration)
            return configuration
        }
        return try BridgeJSON.decoder.decode(
            BridgeConfiguration.self,
            from: Data(contentsOf: url)
        )
    }

    public static func save(_ configuration: BridgeConfiguration) throws {
        let url = BridgePaths.configuration
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        let data = try BridgeJSON.encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private enum SecureToken {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else {
            throw BridgeError.configuration("Could not generate a secure bearer token")
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
