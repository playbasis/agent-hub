import Foundation

/// One observed model-usage advance, not a human prompt, native turn, tool call,
/// or an exact billable API attempt. No prompt/output/reasoning payload is kept.
public struct ActivityModelStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var timestamp: Date?
    public var model: String?
    public var effort: String?
    public var usage: TokenUsage
    public var usageIsPartial: Bool?
    public var evidence: String
    public init(id: String, timestamp: Date?, model: String?, effort: String? = nil,
                usage: TokenUsage = TokenUsage(), evidence: String = "codex-usage-advance/1", usageIsPartial: Bool? = nil) {
        self.id = id; self.timestamp = timestamp; self.model = model; self.effort = effort
        self.usage = usage; self.evidence = evidence
        self.usageIsPartial = usageIsPartial
    }

    /// Later bounded observations may fill identity or omit measurements;
    /// neither a moving window nor a schema omission erases prior evidence.
    public func merging(_ incoming: Self) -> Self {
        var value = incoming
        // A replay can re-date the same cumulative checkpoint. Its earliest
        // provider event time owns the consumption, not the later import.
        value.timestamp = [timestamp, incoming.timestamp].compactMap { $0 }.min()
        value.model = incoming.model ?? model
        value.effort = incoming.effort ?? effort
        value.usageIsPartial = incoming.usageIsPartial ?? usageIsPartial
        if incoming.usage.hasAuthoritativeProvenance && !usage.hasAuthoritativeProvenance {
            // Do not fill missing reported components with estimated values.
            value.usage = incoming.usage
            value.usageIsPartial = incoming.usageIsPartial
        } else if usage.hasAuthoritativeProvenance && !incoming.usage.hasAuthoritativeProvenance {
            value.usage = usage
            value.usageIsPartial = usageIsPartial
        } else if incoming.usage.provenance == .unavailable ||
            (incoming.usageIsPartial == true && usageIsPartial == false) {
            value.usage = usage
            value.usageIsPartial = usageIsPartial
        } else {
            value.usage.input = incoming.usage.input ?? usage.input
            value.usage.output = incoming.usage.output ?? usage.output
            value.usage.cachedInput = incoming.usage.cachedInput ?? usage.cachedInput
            value.usage.cacheWriteInput = incoming.usage.cacheWriteInput ?? usage.cacheWriteInput
            value.usage.reasoning = incoming.usage.reasoning ?? usage.reasoning
            value.usage.total = incoming.usage.total ?? usage.total
        }
        return value
    }
}
