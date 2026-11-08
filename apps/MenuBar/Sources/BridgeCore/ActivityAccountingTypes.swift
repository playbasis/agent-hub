import Foundation

/// Scopes that must never be silently added together. Provider account and
/// goal counters can describe a different population and token convention.
public enum ActivityMetricScope: String, Codable, Sendable {
    case localNativeHistory = "local_native_history"
    case providerAccount = "provider_account"
    case providerPlanWindow = "provider_plan_window"
    case nativeGoal = "native_goal"
    case bridgeSession = "bridge_session"
    case directProviderResponse = "direct_provider_response"
    case repositoryHistory = "repository_history"
}

public struct ActivityAccountingScope: Codable, Equatable, Sendable {
    public var source: ActivityMetricScope
    public var from: Date?
    public var to: Date
    public var asOf: Date
    public var sessionIDs: [String]
    public init(from: Date?, to: Date, asOf: Date, sessionIDs: [String], source: ActivityMetricScope = .localNativeHistory) {
        self.source = source; self.from = from; self.to = to; self.asOf = asOf
        self.sessionIDs = Array(Set(sessionIDs)).sorted()
    }
    enum CodingKeys: String, CodingKey { case source, from, to, asOf, sessionIDs }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source); try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to); try c.encode(asOf, forKey: .asOf)
        try c.encode(Array(Set(sessionIDs)).sorted(), forKey: .sessionIDs)
    }
}

public enum ActivityAccountingReceiptKind: String, Codable, Sendable {
    case modelStep = "model_step"
    case nativeUsageRemainder = "native_usage_remainder"
    case unmeasured
    case unplacedNativeUsage = "unplaced_native_usage"
}

public enum ActivityAccountingTimeBasis: String, Codable, Sendable {
    case providerEvent = "provider_event"
    case nativeInterval = "native_interval"
    case unplaced
}

/// The canonical normalized fact used by model tables, totals, charts, briefs,
/// APIs and exports. A native usage remainder never invents a model-step count.
public struct ActivityAccountingReceipt: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: AgentName
    public var sessionID: String
    public var nativeTurnID: String
    public var projectPath: String?
    public var kind: ActivityAccountingReceiptKind
    public var timestamp: Date?
    public var intervalStart: Date?
    public var intervalEnd: Date?
    public var observedAt: Date
    public var model: String?
    public var effort: String?
    public var usage: TokenUsage
    public var usageIsPartial: Bool?
    public var countIsPartial: Bool
    public var evidence: String
    public var includedInTotals: Bool
    public var timeBasis: ActivityAccountingTimeBasis
    public var countsAsModelStep: Bool { kind == .modelStep && includedInTotals }

    public init(id: String, provider: AgentName, sessionID: String, nativeTurnID: String, projectPath: String? = nil,
                kind: ActivityAccountingReceiptKind, timestamp: Date? = nil, intervalStart: Date? = nil,
                intervalEnd: Date? = nil, observedAt: Date, model: String? = nil, effort: String? = nil,
                usage: TokenUsage = TokenUsage(), usageIsPartial: Bool? = nil, countIsPartial: Bool = false,
                evidence: String, includedInTotals: Bool, timeBasis: ActivityAccountingTimeBasis) {
        self.id = id; self.provider = provider; self.sessionID = sessionID; self.nativeTurnID = nativeTurnID
        self.projectPath = projectPath; self.kind = kind; self.timestamp = timestamp
        self.intervalStart = intervalStart; self.intervalEnd = intervalEnd; self.observedAt = observedAt
        self.model = model; self.effort = effort; self.usage = usage; self.usageIsPartial = usageIsPartial
        self.countIsPartial = countIsPartial; self.evidence = evidence; self.includedInTotals = includedInTotals
        self.timeBasis = timeBasis
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, sessionID, nativeTurnID, projectPath, kind, timestamp, intervalStart, intervalEnd
        case observedAt, model, effort, usage, usageIsPartial, countIsPartial, evidence, includedInTotals, timeBasis
    }
    private enum UsageKeys: String, CodingKey {
        case input, output, reasoning, total, provenance
        case cachedInput = "cached_input"
        case cacheWriteInput = "cache_write_input"
    }
    /// Explicit nulls are part of accounting/1. Keep this local: changing the
    /// legacy TokenUsage encoder would change historical audit hash inputs.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(provider, forKey: .provider)
        try c.encode(sessionID, forKey: .sessionID); try c.encode(nativeTurnID, forKey: .nativeTurnID)
        try c.encode(projectPath, forKey: .projectPath); try c.encode(kind, forKey: .kind)
        try c.encode(timestamp, forKey: .timestamp); try c.encode(intervalStart, forKey: .intervalStart)
        try c.encode(intervalEnd, forKey: .intervalEnd); try c.encode(observedAt, forKey: .observedAt)
        try c.encode(model, forKey: .model); try c.encode(effort, forKey: .effort)
        try c.encode(usageIsPartial, forKey: .usageIsPartial); try c.encode(countIsPartial, forKey: .countIsPartial)
        try c.encode(evidence, forKey: .evidence); try c.encode(includedInTotals, forKey: .includedInTotals)
        try c.encode(timeBasis, forKey: .timeBasis)
        var u = c.nestedContainer(keyedBy: UsageKeys.self, forKey: .usage)
        try u.encode(usage.input, forKey: .input); try u.encode(usage.output, forKey: .output)
        try u.encode(usage.cachedInput, forKey: .cachedInput); try u.encode(usage.cacheWriteInput, forKey: .cacheWriteInput)
        try u.encode(usage.reasoning, forKey: .reasoning); try u.encode(usage.total, forKey: .total)
        try u.encode(usage.provenance, forKey: .provenance)
    }
}
