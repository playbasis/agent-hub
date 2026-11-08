import Foundation

public enum EventSource: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    case bridge
}

public enum AgentName: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    case none

    /// Deterministic fallback order used when the coordinator is unavailable.
    /// The decision engine still considers live capacity across every agent.
    public var other: AgentName {
        switch self {
        case .claude: return .codex
        case .codex: return .grok
        case .grok: return .claude
        case .none: return .none
        }
    }
}

public enum EventType: String, Codable, CaseIterable, Sendable {
    case sessionStart = "session_start"
    case turnComplete = "turn_complete"
    case toolUse = "tool_use"
    case rateLimit = "rate_limit"
    case error
    case userMessage = "user_message"
}

public enum TaskLabel: String, Codable, CaseIterable, Sendable {
    case architecture
    case implementation
    case debug
    case test
    case refactor
    case research
    case complete
}

public enum DecisionAction: String, Codable, CaseIterable, Sendable {
    case `continue`
    case handoff
    case pause
    case complete
}

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case idle
    case thinking
    case running
    case paused
    case parked
    case error
    case complete
    case stopped
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var text: String {
        switch self {
        case let .string(value):
            return value
        case .null:
            return ""
        default:
            guard let data = try? BridgeJSON.encoder.encode(self) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        numberValue.map(Int.init)
    }
}

public struct BridgeEvent: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = "1.0"
    public var id: UUID
    public var timestamp: Date
    public var source: EventSource
    public var type: EventType
    public var content: JSONValue
    public var sessionID: String
    public var projectPath: String
    public var metadata: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, timestamp, source, type, content
        case sessionID = "session_id"
        case projectPath = "project_path"
        case metadata
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: EventSource,
        type: EventType,
        content: JSONValue,
        sessionID: String,
        projectPath: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.type = type
        self.content = content
        self.sessionID = sessionID
        self.projectPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        self.metadata = metadata
    }
}

public struct Decision: Codable, Equatable, Sendable {
    public var schemaVersion = "1.0"
    public var label: TaskLabel
    public var confidence: Double
    public var nextAgent: AgentName
    public var action: DecisionAction
    public var refinedPrompt: String
    public var summaryForLog: String
    public var reason: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case label, confidence
        case nextAgent = "next_agent"
        case action
        case refinedPrompt = "refined_prompt"
        case summaryForLog = "summary_for_log"
        case reason
    }

    public init(
        label: TaskLabel,
        confidence: Double,
        nextAgent: AgentName,
        action: DecisionAction,
        refinedPrompt: String,
        summaryForLog: String,
        reason: String
    ) throws {
        guard (0 ... 1).contains(confidence) else {
            throw BridgeError.invalidDecision("confidence must be between 0 and 1")
        }
        if action == .pause || action == .complete {
            guard nextAgent == .none else {
                throw BridgeError.invalidDecision("terminal decisions require next_agent=none")
            }
        } else {
            guard nextAgent != .none, !refinedPrompt.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw BridgeError.invalidDecision("action requires an agent and refined prompt")
            }
        }
        guard action != .complete || label == .complete else {
            throw BridgeError.invalidDecision("complete action requires complete label")
        }
        self.label = label
        self.confidence = confidence
        self.nextAgent = nextAgent
        self.action = action
        self.refinedPrompt = refinedPrompt
        self.summaryForLog = summaryForLog
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .schemaVersion)
        guard version == "1.0" else {
            throw BridgeError.invalidDecision("unsupported schema version")
        }
        self = try Decision(
            label: container.decode(TaskLabel.self, forKey: .label),
            confidence: container.decode(Double.self, forKey: .confidence),
            nextAgent: container.decode(AgentName.self, forKey: .nextAgent),
            action: container.decode(DecisionAction.self, forKey: .action),
            refinedPrompt: container.decode(String.self, forKey: .refinedPrompt),
            summaryForLog: container.decode(String.self, forKey: .summaryForLog),
            reason: container.decode(String.self, forKey: .reason)
        )
    }

    static func routingFailure(_ reason: String) -> Decision {
        Decision(
            uncheckedLabel: .implementation,
            confidence: 1,
            nextAgent: .none,
            action: .pause,
            refinedPrompt: "",
            summaryForLog: "Routing validation failed.",
            reason: reason
        )
    }

    private init(
        uncheckedLabel label: TaskLabel,
        confidence: Double,
        nextAgent: AgentName,
        action: DecisionAction,
        refinedPrompt: String,
        summaryForLog: String,
        reason: String
    ) {
        self.label = label
        self.confidence = confidence
        self.nextAgent = nextAgent
        self.action = action
        self.refinedPrompt = refinedPrompt
        self.summaryForLog = summaryForLog
        self.reason = reason
    }
}

public struct SessionRequest: Codable, Equatable, Sendable {
    public var projectPath: String
    public var goal: String
    public var durationMinutes: Int
    public var startingAgent: AgentName

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case goal
        case durationMinutes = "duration_minutes"
        case startingAgent = "starting_agent"
    }

    public init(
        projectPath: String,
        goal: String,
        durationMinutes: Int = 240,
        startingAgent: AgentName = .claude
    ) throws {
        let path = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory),
              directory.boolValue
        else {
            throw BridgeError.invalidProject(path)
        }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              goal.count <= 20_000
        else {
            throw BridgeError.invalidRequest("goal must contain 1–20,000 characters")
        }
        guard (5 ... 1_440).contains(durationMinutes), startingAgent != .none else {
            throw BridgeError.invalidRequest("invalid duration or starting agent")
        }
        self.projectPath = path
        self.goal = goal
        self.durationMinutes = durationMinutes
        self.startingAgent = startingAgent
    }
}

public struct RuntimeSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var projectPath: String
    public var goal: String
    public var createdAt: Date
    public var deadline: Date
    public var state: SessionState
    public var activeAgent: AgentName
    public var preferredStartingAgent: AgentName
    public var agentSessionIDs: [String: String]
    public var lastEventID: String?
    public var lastError: String?
    public var wakeAt: Date?
    public var turnCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case projectPath = "project_path"
        case goal
        case createdAt = "created_at"
        case deadline, state
        case activeAgent = "active_agent"
        case preferredStartingAgent = "preferred_starting_agent"
        case agentSessionIDs = "agent_session_ids"
        case lastEventID = "last_event_id"
        case lastError = "last_error"
        case wakeAt = "wake_at"
        case turnCount = "turn_count"
    }

    public var isExpired: Bool { Date() >= deadline }
}

public enum QuotaSource: String, Codable, Equatable, Sendable {
    /// Provider-owned data returned by the signed-in CLI.
    case live
    /// A hard limit or reset was observed while running the provider.
    case observed
    /// The provider has not exposed usable plan data yet.
    case unavailable
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var usedRatio: Double
    public var resetAt: Date?
    public var durationMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id, label
        case usedRatio = "used_ratio"
        case resetAt = "reset_at"
        case durationMinutes = "duration_minutes"
    }

    public init(
        id: String,
        label: String,
        usedRatio: Double,
        resetAt: Date? = nil,
        durationMinutes: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.usedRatio = min(max(usedRatio, 0), 1)
        self.resetAt = resetAt
        self.durationMinutes = durationMinutes
    }
}

/// Provider-reported credits, not token counts, money or a plan-window ratio.
/// Optional flags distinguish an omitted field from an explicit false value.
public struct QuotaCredits: Codable, Equatable, Sendable {
    /// The provider's exact decimal text. Never round through Double or infer a
    /// currency/unit that the provider did not report.
    public var balance: String?
    public var hasCredits: Bool?
    public var unlimited: Bool?

    enum CodingKeys: String, CodingKey {
        case balance, unlimited
        case hasCredits = "has_credits"
    }

    public init(balance: String? = nil, hasCredits: Bool? = nil, unlimited: Bool? = nil) {
        self.balance = balance
        self.hasCredits = hasCredits
        self.unlimited = unlimited
    }

    public static func validatedBalance(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 128,
              raw.range(of: #"\A[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil else { return nil }
        return raw
    }
}

public struct QuotaEstimate: Codable, Equatable, Sendable {
    public var agent: AgentName
    public var available: Bool
    public var remainingRatio: Double
    public var limitedUntil: Date?
    public var observedTurns: Int
    public var observedLimits: Int
    public var windows: [QuotaWindow]
    public var source: QuotaSource
    public var fetchedAt: Date?
    public var planName: String?
    public var statusMessage: String?
    public var credits: QuotaCredits?
    /// The selected provider bucket. Credits and windows must share this scope.
    public var limitID: String?
    public var limitName: String?
    public var rateLimitReachedType: String?
    public var spendControlReached: Bool?
    /// Earned limit resets are not spendable credits and never form a balance.
    public var availableResetCredits: Int?
    /// Keeps a last-known reading visibly stale after an unsuccessful probe.
    public var refreshFailedAt: Date?
    /// A non-reversible scope marker; no account address or token is cached.
    public var accountIdentityHash: String?

    enum CodingKeys: String, CodingKey {
        case agent, available, windows, source
        case remainingRatio = "remaining_ratio"
        case limitedUntil = "limited_until"
        case observedTurns = "observed_turns"
        case observedLimits = "observed_limits"
        case fetchedAt = "fetched_at"
        case planName = "plan_name"
        case statusMessage = "status_message"
        case credits
        case limitID = "limit_id"
        case limitName = "limit_name"
        case rateLimitReachedType = "rate_limit_reached_type"
        case spendControlReached = "spend_control_reached"
        case availableResetCredits = "available_reset_credits"
        case refreshFailedAt = "refresh_failed_at"
        case accountIdentityHash = "account_identity_hash"
    }

    public init(
        agent: AgentName,
        available: Bool = true,
        remainingRatio: Double = 1,
        limitedUntil: Date? = nil,
        observedTurns: Int = 0,
        observedLimits: Int = 0,
        windows: [QuotaWindow] = [],
        source: QuotaSource = .unavailable,
        fetchedAt: Date? = nil,
        planName: String? = nil,
        statusMessage: String? = nil,
        credits: QuotaCredits? = nil,
        limitID: String? = nil,
        limitName: String? = nil,
        rateLimitReachedType: String? = nil,
        spendControlReached: Bool? = nil,
        availableResetCredits: Int? = nil,
        refreshFailedAt: Date? = nil,
        accountIdentityHash: String? = nil
    ) {
        self.agent = agent
        self.available = available
        self.remainingRatio = min(max(remainingRatio, 0), 1)
        self.limitedUntil = limitedUntil
        self.observedTurns = observedTurns
        self.observedLimits = observedLimits
        self.windows = windows
        self.source = source
        self.fetchedAt = fetchedAt
        self.planName = planName
        self.statusMessage = statusMessage
        self.credits = credits
        self.limitID = limitID
        self.limitName = limitName
        self.rateLimitReachedType = rateLimitReachedType
        self.spendControlReached = spendControlReached
        self.availableResetCredits = availableResetCredits
        self.refreshFailedAt = refreshFailedAt
        self.accountIdentityHash = accountIdentityHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(AgentName.self, forKey: .agent)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
        remainingRatio = try container.decodeIfPresent(
            Double.self,
            forKey: .remainingRatio
        ) ?? 1
        limitedUntil = try container.decodeIfPresent(Date.self, forKey: .limitedUntil)
        observedTurns = try container.decodeIfPresent(Int.self, forKey: .observedTurns) ?? 0
        observedLimits = try container.decodeIfPresent(Int.self, forKey: .observedLimits) ?? 0
        windows = try container.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? []
        source = try container.decodeIfPresent(QuotaSource.self, forKey: .source) ?? .unavailable
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        credits = try container.decodeIfPresent(QuotaCredits.self, forKey: .credits)
        limitID = try container.decodeIfPresent(String.self, forKey: .limitID)
        limitName = try container.decodeIfPresent(String.self, forKey: .limitName)
        rateLimitReachedType = try container.decodeIfPresent(String.self, forKey: .rateLimitReachedType)
        spendControlReached = try container.decodeIfPresent(Bool.self, forKey: .spendControlReached)
        availableResetCredits = try container.decodeIfPresent(Int.self, forKey: .availableResetCredits)
        refreshFailedAt = try container.decodeIfPresent(Date.self, forKey: .refreshFailedAt)
        accountIdentityHash = try container.decodeIfPresent(String.self, forKey: .accountIdentityHash)
    }
}

public enum ProviderState: String, Codable, Equatable, Sendable {
    case checking
    case ready
    case degraded
}

public struct ProviderHealth: Codable, Equatable, Sendable {
    public var provider: String
    public var state: ProviderState
    public var fallbackActive: Bool
    public var message: String?
    public var lastChecked: Date?

    enum CodingKeys: String, CodingKey {
        case provider, state
        case fallbackActive = "fallback_active"
        case message
        case lastChecked = "last_checked"
    }

    public init(
        provider: String,
        state: ProviderState,
        fallbackActive: Bool,
        message: String? = nil,
        lastChecked: Date? = nil
    ) {
        self.provider = provider
        self.state = state
        self.fallbackActive = fallbackActive
        self.message = message
        self.lastChecked = lastChecked
    }

    public static var rulesReady: ProviderHealth {
        ProviderHealth(
            provider: "rules",
            state: .ready,
            fallbackActive: false,
            message: "Deterministic on-device routing",
            lastChecked: Date()
        )
    }
}

public struct BridgeStatus: Codable, Equatable, Sendable {
    public var state: SessionState
    public var activeAgent: AgentName
    public var session: RuntimeSession?
    public var latestDecision: Decision?
    public var quota: [String: QuotaEstimate]
    public var provider: ProviderHealth
    public var serviceVersion = "0.1.0"

    enum CodingKeys: String, CodingKey {
        case state
        case activeAgent = "active_agent"
        case session
        case latestDecision = "latest_decision"
        case quota
        case provider
        case serviceVersion = "service_version"
    }

    public init(
        state: SessionState,
        activeAgent: AgentName,
        session: RuntimeSession?,
        latestDecision: Decision?,
        quota: [String: QuotaEstimate],
        provider: ProviderHealth = .rulesReady,
        serviceVersion: String = "0.1.0"
    ) {
        self.state = state
        self.activeAgent = activeAgent
        self.session = session
        self.latestDecision = latestDecision
        self.quota = quota
        self.provider = provider
        self.serviceVersion = serviceVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(SessionState.self, forKey: .state)
        activeAgent = try container.decode(AgentName.self, forKey: .activeAgent)
        session = try container.decodeIfPresent(RuntimeSession.self, forKey: .session)
        latestDecision = try container.decodeIfPresent(Decision.self, forKey: .latestDecision)
        quota = try container.decodeIfPresent(
            [String: QuotaEstimate].self,
            forKey: .quota
        ) ?? [:]
        provider = try container.decodeIfPresent(
            ProviderHealth.self,
            forKey: .provider
        ) ?? .rulesReady
        serviceVersion = try container.decodeIfPresent(
            String.self,
            forKey: .serviceVersion
        ) ?? "0.1.0"
    }
}

public struct ForceHandoffRequest: Codable, Equatable, Sendable {
    public var agent: AgentName
    public var reason: String
}

public enum CoordinatorMode: String, Codable, Equatable, Sendable {
    case rules
    case grok
    /// Historical configuration compatibility only. New requests must use Grok.
    case gemini
}

public struct CoordinatorConfigurationRequest: Codable, Equatable, Sendable {
    public var mode: CoordinatorMode
    public var apiKey: String?
    public var model: String?
    public var endpoint: String?
    public var forgetKey: Bool

    enum CodingKeys: String, CodingKey {
        case mode, model, endpoint
        case apiKey = "api_key"
        case forgetKey = "forget_key"
    }

    public init(
        mode: CoordinatorMode,
        apiKey: String? = nil,
        model: String? = nil,
        endpoint: String? = nil,
        forgetKey: Bool = false
    ) {
        self.mode = mode
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.forgetKey = forgetKey
    }
}

public struct CoordinatorConfigurationStatus: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var endpoint: String
    public var credentialStored: Bool
    public var restartRequired: Bool

    enum CodingKeys: String, CodingKey {
        case provider, model, endpoint
        case credentialStored = "credential_stored"
        case restartRequired = "restart_required"
    }
}

public struct AgentResult: Equatable, Sendable {
    public var agent: AgentName
    public var success: Bool
    public var output: String
    public var sessionID: String?
    public var rateLimited: Bool
    public var resetAt: Date?
    public var error: String?
    public var diagnostics: [String: JSONValue]
    public var telemetry: AgentTelemetry = AgentTelemetry()
}

public enum BridgeError: Error, LocalizedError, Equatable {
    case invalidProject(String)
    case invalidRequest(String)
    case invalidDecision(String)
    case invalidEvent(String)
    case noActiveSession
    case sessionAlreadyActive
    case unauthorized
    case payloadTooLarge
    case processFailed(String)
    case configuration(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidProject(path): "Invalid project directory: \(path)"
        case let .invalidRequest(message): "Invalid request: \(message)"
        case let .invalidDecision(message): "Invalid decision: \(message)"
        case let .invalidEvent(message): "Invalid event: \(message)"
        case .noActiveSession: "There is no active bridge session."
        case .sessionAlreadyActive: "A bridge session is already active."
        case .unauthorized: "The bridge bearer token was rejected."
        case .payloadTooLarge: "The request payload exceeds the configured limit."
        case let .processFailed(message): "Agent process failed: \(message)"
        case let .configuration(message): "Configuration error: \(message)"
        case let .network(message): "Network error: \(message)"
        }
    }
}
