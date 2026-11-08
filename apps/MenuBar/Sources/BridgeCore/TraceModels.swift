import CryptoKit
import Foundation

public enum TraceCapturePolicy: String, Codable, Sendable {
    case metadataRedacted = "metadata_redacted"
    case fullLocal = "full_local"
}

public enum TraceProvider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    /// Historical receipts only. The runtime no longer emits Gemini records.
    case gemini
    case rules
}

public enum MetricProvenance: String, Codable, Sendable {
    case providerReported = "provider_reported"
    case derived
    case estimated
    case unavailable
}

public enum TraceCompleteness: String, Codable, Sendable {
    case complete
    case partial
    case legacy
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int?
    public var output: Int?
    public var cachedInput: Int?
    public var cacheWriteInput: Int?
    public var reasoning: Int?
    public var total: Int?
    public var provenance: MetricProvenance
    /// Eligibility for known totals, not a substitute for measurement
    /// validation or the stricter provider-reported budget policy. Derived
    /// measurements must retain authoritative input lineage in adapters.
    public var hasAuthoritativeProvenance: Bool { provenance == .providerReported || provenance == .derived }

    enum CodingKeys: String, CodingKey {
        case input, output, reasoning, total, provenance
        case cachedInput = "cached_input"
        case cacheWriteInput = "cache_write_input"
    }

    public init(
        input: Int? = nil,
        output: Int? = nil,
        cachedInput: Int? = nil,
        cacheWriteInput: Int? = nil,
        reasoning: Int? = nil,
        total: Int? = nil,
        provenance: MetricProvenance = .unavailable
    ) {
        self.input = input
        self.output = output
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.reasoning = reasoning
        self.total = total
        self.provenance = provenance
    }
}

public struct ToolReceipt: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: String?
    public var status: String
    public var durationMilliseconds: Int?
    public var exitCode: Int?
    public var redactedSummary: String?
    public var contentDigest: String?

    enum CodingKeys: String, CodingKey {
        case id, name, category, status
        case durationMilliseconds = "duration_ms"
        case exitCode = "exit_code"
        case redactedSummary = "redacted_summary"
        case contentDigest = "content_digest"
    }

    public init(
        id: String,
        name: String,
        category: String? = nil,
        status: String = "observed",
        durationMilliseconds: Int? = nil,
        exitCode: Int? = nil,
        redactedSummary: String? = nil,
        contentDigest: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.status = status
        self.durationMilliseconds = durationMilliseconds
        self.exitCode = exitCode
        self.redactedSummary = redactedSummary
        self.contentDigest = contentDigest
    }
}

public struct ProviderIdentity: Codable, Equatable, Sendable {
    public var requestedModel: String?
    public var resolvedModel: String?
    public var requestedEffort: String?
    public var resolvedEffort: String?
    public var modelProvider: String?
    public var serviceTier: String?
    public var contextWindow: Int?
    public var sandbox: String?
    public var permissionMode: String?

    enum CodingKeys: String, CodingKey {
        case requestedModel = "requested_model"
        case resolvedModel = "resolved_model"
        case requestedEffort = "requested_effort"
        case resolvedEffort = "resolved_effort"
        case modelProvider = "model_provider"
        case serviceTier = "service_tier"
        case contextWindow = "context_window"
        case sandbox
        case permissionMode = "permission_mode"
    }

    public init(
        requestedModel: String? = nil,
        resolvedModel: String? = nil,
        requestedEffort: String? = nil,
        resolvedEffort: String? = nil,
        modelProvider: String? = nil,
        serviceTier: String? = nil,
        contextWindow: Int? = nil,
        sandbox: String? = nil,
        permissionMode: String? = nil
    ) {
        self.requestedModel = requestedModel
        self.resolvedModel = resolvedModel
        self.requestedEffort = requestedEffort
        self.resolvedEffort = resolvedEffort
        self.modelProvider = modelProvider
        self.serviceTier = serviceTier
        self.contextWindow = contextWindow
        self.sandbox = sandbox
        self.permissionMode = permissionMode
    }

    public var hasMismatch: Bool {
        guard let requestedModel, let resolvedModel else { return false }
        return !resolvedModel.localizedCaseInsensitiveContains(requestedModel)
            && !requestedModel.localizedCaseInsensitiveContains(resolvedModel)
    }
}

public struct TraceRecord: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = "1.0"
    public var id: String
    public var sequence: Int
    public var timestamp: Date
    public var bridgeSessionID: String
    public var turnID: String
    public var eventID: String?
    public var provider: TraceProvider
    public var evidenceProviders: [TraceProvider]? = nil
    public var nativeSessionID: String?
    public var nativeTurnID: String?
    public var identity: ProviderIdentity
    public var usage: TokenUsage
    public var tools: [ToolReceipt]
    public var durationMilliseconds: Int?
    public var timeToFirstTokenMilliseconds: Int?
    public var outcome: String
    public var exitCode: Int?
    public var completeness: TraceCompleteness
    public var warnings: [String]
    public var budgetReserved: Int?
    public var budgetRemaining: Int?
    public var estimatedCostUSD: Double?
    public var costProvenance: MetricProvenance
    public var adapterVersion: String
    public var previousHash: String?
    public var recordHash: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, sequence, timestamp, provider, identity, usage, tools, outcome
        case evidenceProviders = "evidence_providers"
        case bridgeSessionID = "bridge_session_id"
        case turnID = "turn_id"
        case eventID = "event_id"
        case nativeSessionID = "native_session_id"
        case nativeTurnID = "native_turn_id"
        case durationMilliseconds = "duration_ms"
        case timeToFirstTokenMilliseconds = "time_to_first_token_ms"
        case exitCode = "exit_code"
        case completeness, warnings
        case budgetReserved = "budget_reserved"
        case budgetRemaining = "budget_remaining"
        case estimatedCostUSD = "estimated_cost_usd"
        case costProvenance = "cost_provenance"
        case adapterVersion = "adapter_version"
        case previousHash = "previous_hash"
        case recordHash = "record_hash"
    }
}

public struct TraceSummary: Codable, Equatable, Sendable {
    public var schemaVersion = "1.0"
    public var bridgeSessionID: String?
    public var records: Int
    public var providers: [String: Int]
    public var successfulProviders: [String]
    public var totalTokens: Int?
    public var toolCalls: Int
    public var budgetRemaining: Int?
    public var threeProviderVerified: Bool
    public var dualProviderVerified: Bool
    public var traceVerified: Bool
    public var completeness: TraceCompleteness
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bridgeSessionID = "bridge_session_id"
        case records, providers
        case successfulProviders = "successful_providers"
        case totalTokens = "total_tokens"
        case toolCalls = "tool_calls"
        case budgetRemaining = "budget_remaining"
        case threeProviderVerified = "three_provider_verified"
        case dualProviderVerified = "dual_provider_verified"
        case traceVerified = "trace_verified"
        case completeness
        case updatedAt = "updated_at"
    }

    public init(
        schemaVersion: String = "1.0",
        bridgeSessionID: String?,
        records: Int,
        providers: [String: Int],
        successfulProviders: [String],
        totalTokens: Int?,
        toolCalls: Int,
        budgetRemaining: Int?,
        threeProviderVerified: Bool = false,
        dualProviderVerified: Bool,
        traceVerified: Bool,
        completeness: TraceCompleteness,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.bridgeSessionID = bridgeSessionID
        self.records = records
        self.providers = providers
        self.successfulProviders = successfulProviders
        self.totalTokens = totalTokens
        self.toolCalls = toolCalls
        self.budgetRemaining = budgetRemaining
        self.threeProviderVerified = threeProviderVerified
        self.dualProviderVerified = dualProviderVerified
        self.traceVerified = traceVerified
        self.completeness = completeness
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            String.self, forKey: .schemaVersion
        ) ?? "1.0"
        bridgeSessionID = try container.decodeIfPresent(
            String.self, forKey: .bridgeSessionID
        )
        records = try container.decode(Int.self, forKey: .records)
        providers = try container.decode([String: Int].self, forKey: .providers)
        successfulProviders = try container.decode(
            [String].self, forKey: .successfulProviders
        )
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        toolCalls = try container.decode(Int.self, forKey: .toolCalls)
        budgetRemaining = try container.decodeIfPresent(
            Int.self, forKey: .budgetRemaining
        )
        threeProviderVerified = try container.decodeIfPresent(
            Bool.self, forKey: .threeProviderVerified
        ) ?? false
        dualProviderVerified = try container.decodeIfPresent(
            Bool.self, forKey: .dualProviderVerified
        ) ?? false
        traceVerified = try container.decodeIfPresent(
            Bool.self, forKey: .traceVerified
        ) ?? false
        completeness = try container.decodeIfPresent(
            TraceCompleteness.self, forKey: .completeness
        ) ?? .legacy
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? .distantPast
    }
}

public struct AgentTelemetry: Equatable, Sendable {
    public var identity: ProviderIdentity
    public var usage: TokenUsage
    public var tools: [ToolReceipt]
    public var nativeTurnID: String?
    public var durationMilliseconds: Int?
    public var timeToFirstTokenMilliseconds: Int?
    public var completeness: TraceCompleteness
    public var warnings: [String]

    public init(
        identity: ProviderIdentity = ProviderIdentity(),
        usage: TokenUsage = TokenUsage(),
        tools: [ToolReceipt] = [],
        nativeTurnID: String? = nil,
        durationMilliseconds: Int? = nil,
        timeToFirstTokenMilliseconds: Int? = nil,
        completeness: TraceCompleteness = .partial,
        warnings: [String] = []
    ) {
        self.identity = identity
        self.usage = usage
        self.tools = tools
        self.nativeTurnID = nativeTurnID
        self.durationMilliseconds = durationMilliseconds
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.completeness = completeness
        self.warnings = warnings
    }
}

public enum TraceCrypto {
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ text: String) -> String {
        digest(Data(text.utf8))
    }
}

public enum TraceRedactor {
    private static let patterns = [
        #"(?i)bearer\s+[a-z0-9._~+/\-=]+"#,
        #"(?i)(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*[^\s,;]+"#,
        #"sk-[a-zA-Z0-9_-]{16,}"#,
    ]

    public static func redact(_ value: String, maximumCharacters: Int = 240) -> String {
        var output = value
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: .regularExpression
            )
        }
        output = output.replacingOccurrences(
            of: #"/Users/[^/\s]+"#,
            with: "/Users/[REDACTED]",
            options: .regularExpression
        )
        if output.count > maximumCharacters {
            output = String(output.prefix(maximumCharacters)) + "…"
        }
        return output
    }
}
