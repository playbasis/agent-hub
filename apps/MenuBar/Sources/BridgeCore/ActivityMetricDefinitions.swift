import Foundation

public enum ActivityMetricUnit: String, Codable, Sendable {
    case observedModelSteps = "observed_model_steps"
    case nativeRecords = "native_records"
    case tokens
    case seconds
    case sessions
    case submittedPrompts = "submitted_prompts"
    case confirmedHumanPrompts = "confirmed_human_prompts"
    case observedToolCalls = "observed_tool_calls"
    case providerGoalTokens = "provider_goal_token_counter"
    case fraction
}

public struct ActivityMetricDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var unit: ActivityMetricUnit
    public var scope: ActivityMetricScope
    public var definition: String
    public var additiveAcrossTimeBuckets: Bool
}

/// Machine-readable definitions shared by app, CLI, API and documentation.
/// A similar-looking provider counter is not interchangeable with local usage.
public enum ActivityMetricDefinitions {
    public static let version = "activity-metrics/1"
    public static let all: [ActivityMetricDefinition] = [
        .init(id: "local.model_steps", label: "Model steps", unit: .observedModelSteps, scope: .localNativeHistory,
              definition: "Deduplicated observed model responses or validated native usage advances. Not human prompts, retries or exact billable API attempts.", additiveAcrossTimeBuckets: true),
        .init(id: "local.native_records", label: "Saved records", unit: .nativeRecords, scope: .localNativeHistory,
              definition: "Distinct owned native records supporting the window. Codex turns and Claude response records are different native units; a record can span several buckets, so counts must be unioned, not added.", additiveAcrossTimeBuckets: false),
        .init(id: "local.tokens", label: "Tokens", unit: .tokens, scope: .localNativeHistory,
              definition: "Known normalized local usage in the exact reporting window. Cache and reasoning subsets are not added twice. Unplaced interval usage is explicit. Missing usage is unknown, not zero.", additiveAcrossTimeBuckets: true),
        .init(id: "local.active_seconds", label: "Recorded active time", unit: .seconds, scope: .localNativeHistory,
              definition: "Union of recorded closed intervals, clipped to the window. Includes waits and is not a measurement of human productivity or model CPU time.", additiveAcrossTimeBuckets: true),
        .init(id: "local.agent_seconds", label: "Recorded agent time", unit: .seconds, scope: .localNativeHistory,
              definition: "Closed intervals unioned within each session, then summed across sessions. Parallel sessions count separately; overlapping records in one session do not.", additiveAcrossTimeBuckets: true),
        .init(id: "local.sessions", label: "Sessions", unit: .sessions, scope: .localNativeHistory,
              definition: "Distinct sessions with supporting evidence or an open goal in scope. Per-bucket session counts are not additive.", additiveAcrossTimeBuckets: false),
        .init(id: "local.submitted_prompts", label: "Submitted prompts", unit: .submittedPrompts, scope: .localNativeHistory,
              definition: "Recorded submissions with verified temporal placement. May include agent-origin messages. Unallocated native counters remain separate.", additiveAcrossTimeBuckets: true),
        .init(id: "local.human_prompts", label: "Confirmed human prompts", unit: .confirmedHumanPrompts, scope: .localNativeHistory,
              definition: "Only submissions whose source establishes human origin. Missing origin is not treated as human or as zero.", additiveAcrossTimeBuckets: true),
        .init(id: "local.tool_calls", label: "Recorded tool calls", unit: .observedToolCalls, scope: .localNativeHistory,
              definition: "Provider-observed tool calls that can be placed in the selected window. Categories are inferred from tools, not inferred token spending.", additiveAcrossTimeBuckets: true),
        .init(id: "provider.account_tokens", label: "Provider account tokens", unit: .tokens, scope: .providerAccount,
              definition: "The provider's account-wide counter with its own coverage and date labels. Never added to local native usage.", additiveAcrossTimeBuckets: false),
        .init(id: "provider.goal_tokens", label: "Provider goal counter", unit: .providerGoalTokens, scope: .nativeGoal,
              definition: "The native harness's goal-specific counter. Its accounting convention is not assumed equal to the local raw-token ledger.", additiveAcrossTimeBuckets: false),
        .init(id: "provider.plan_usage", label: "Provider plan usage", unit: .fraction, scope: .providerPlanWindow,
              definition: "Provider-reported subscription usage fraction in that provider window. It is not a token quantity or an invented dollar cost.", additiveAcrossTimeBuckets: false),
    ]

    public static func definition(_ id: String) -> ActivityMetricDefinition? { all.first { $0.id == id } }
}
