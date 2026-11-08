import Foundation

/// A model name alone is not an identity: two provider adapters may report
/// the same name. Keep row totals, session counts and coverage on one scope.
public enum ActivityModelAccounting {
    public struct Key: Codable, Hashable, Sendable {
        public var provider: AgentName
        public var model: String?
        public init(provider: AgentName, model: String?) { self.provider = provider; self.model = model }
        private enum CodingKeys: String, CodingKey { case provider, model }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(provider, forKey: .provider)
            try container.encode(model, forKey: .model)
        }
    }

    public struct Row: Codable, Equatable, Identifiable, Sendable {
        public var key: Key
        /// Observed step coordinate only; zero does not imply a legacy turn
        /// made no model calls. requestCount preserves that distinction.
        public var requests: Int
        public var requestsArePartial: Bool
        public var usageRecords: Int
        /// Share uses observed model steps only. A legacy turn with an unknown
        /// step count has no share, rather than an invented zero percent.
        public var shareOfObservedSteps: Double? = nil
        fileprivate var nativeIDs: Set<NativeID>
        fileprivate var unmeasuredIDs: Set<NativeID>
        fileprivate var unallocatedIDs: Set<NativeID>
        fileprivate var unallocatedAmounts: [NativeID: Int]
        public var tokens: Int?
        public var output: Int?
        public var tokenReceipts: Int
        public var outputReceipts: Int
        public var partialReceipts: Int
        public var breakdownReceipts: Int
        public var reread: Double?
        public var efforts: [EffortCount]
        public var sessions: Int
        public var lastUsed: Date?
        public var id: Key { key }
        public var name: String? { key.model }
        public var provider: AgentName { key.provider }
        public var observedModelSteps: Int { requests }
        public var observedStepCount: Int? { requestCount }
        public var stepsArePartial: Bool { requestsArePartial }
        public var requestCount: Int? { requests > 0 ? requests : (unmeasuredTurns > 0 ? nil : 0) }
        public var nativeTurns: Int { nativeIDs.count }
        public var unmeasuredTurns: Int { unmeasuredIDs.count }
        public var tokensArePartial: Bool { tokenReceipts < usageRecords || partialReceipts > 0 || requestsArePartial }
        public var outputIsPartial: Bool { outputReceipts < usageRecords || partialReceipts > 0 || requestsArePartial }
        public var tokenCoverage: String {
            if usageRecords == 0 { return "No dated model-step usage records. Missing usage is not zero.\(unmeasuredTurns > 0 ? " Step counts are unmeasured for \(unmeasuredTurns) native turns." : "")" }
            if tokens == nil, tokenReceipts > 0 { return "Reported totals exceed the supported range; no combined total is shown." }
            return "Totals reported for \(tokenReceipts) of \(usageRecords) usage records\(tokensArePartial ? "; coverage is partial" : ""). Records are observed model steps plus legacy turn records, not an implied request count.\(unmeasuredTurns > 0 ? " Legacy turn totals have incomplete model-step attribution." : "") Missing usage is not zero."
        }
        public var outputCoverage: String {
            if usageRecords == 0 { return "No output usage records in this row; output is not assumed to be zero." }
            if output == nil, outputReceipts > 0 { return "Reported output exceeds the supported range; no combined total is shown." }
            return "Output reported for \(outputReceipts) of \(usageRecords) usage records\(outputIsPartial ? "; coverage is partial" : ""). May include reasoning subsets."
        }
        public var accessibilitySummary: String {
            let tokenValue = tokens.map { $0.formatted() } ?? "unavailable"
            let outputValue = output.map { $0.formatted() } ?? "unavailable"
            return "\(sessions) sessions, \(nativeTurns) native turns, \(requests) observed model steps, \(unmeasuredTurns) turns with unmeasured step counts. Known tokens: \(tokenValue). \(tokenCoverage) Known output: \(outputValue). \(outputCoverage)"
        }
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var totalObservedSteps: Int
        public var unmeasuredTurns: Int
        public var nativeTurns: Int
        /// Known native usage that cannot be dated to this report window.
        /// This is metadata about omitted allocation, never a period total.
        public var unallocatedTokens: Int?
        public var unallocatedTurns: Int
        public init(totalObservedSteps: Int, unmeasuredTurns: Int, nativeTurns: Int, unallocatedTokens: Int?, unallocatedTurns: Int) {
            self.totalObservedSteps = totalObservedSteps; self.unmeasuredTurns = unmeasuredTurns; self.nativeTurns = nativeTurns
            self.unallocatedTokens = unallocatedTokens; self.unallocatedTurns = unallocatedTurns
        }
    }

    public struct EffortCount: Codable, Equatable, Sendable {
        public var name: String
        public var count: Int
        public init(name: String, count: Int) { self.name = name; self.count = count }
    }

    public struct Result: Codable, Equatable, Sendable {
        public var rows: [Row]
        public var summary: Summary
        public var receipts: [ActivityAccountingReceipt]
        public init(rows: [Row], summary: Summary, receipts: [ActivityAccountingReceipt]) {
            self.rows = rows; self.summary = summary; self.receipts = receipts
        }
    }

    fileprivate struct NativeID: Codable, Hashable, Sendable { var provider: AgentName; var id: String }
    private struct StepOwner {
        var session: String
        var native: NativeID
        var partial: Bool
        var intervalStart: Date?
        var intervalEnd: Date?
    }
    private struct UsageRecord {
        var usage: TokenUsage
        var effort: String?
        var usageIsPartial: Bool
    }
    private struct Bucket {
        var steps = 0
        var partial = false
        var records: [UsageRecord] = []
        var nativeIDs: Set<NativeID> = []
        var unmeasuredIDs: Set<NativeID> = []
        var unallocatedIDs: Set<NativeID> = []
        var unallocatedAmounts: [NativeID: Int] = [:]
        var sessionIDs: Set<String> = []
        var lastUsed: Date?

        mutating func add(owner: StepOwner, date: Date?, usage: TokenUsage?, effort: String?, observed: Bool, unmeasured: Bool, partial: Bool, usagePartial: Bool) {
            nativeIDs.insert(owner.native); sessionIDs.insert(owner.session)
            if observed { steps += 1 }
            if unmeasured { unmeasuredIDs.insert(owner.native) }
            self.partial = self.partial || partial || unmeasured
            if let usage {
                records.append(UsageRecord(usage: usage, effort: effort, usageIsPartial: usagePartial))
            }
            if let date, lastUsed.map({ date > $0 }) ?? true { lastUsed = date }
        }
    }

    public static func summary(_ rows: [Row]) -> Summary {
        var amounts: [NativeID: Int] = [:]
        for row in rows {
            for (id, value) in row.unallocatedAmounts { amounts[id] = max(amounts[id] ?? 0, value) }
        }
        return Summary(totalObservedSteps: rows.reduce(0) { $0 + $1.requests },
            unmeasuredTurns: Set(rows.flatMap { $0.unmeasuredIDs }).count,
            nativeTurns: Set(rows.flatMap { $0.nativeIDs }).count,
            unallocatedTokens: ActivityMetrics.knownTotal(amounts.values.map { Optional($0) }),
            unallocatedTurns: Set(rows.flatMap { $0.unallocatedIDs }).count)
    }

    /// The sole row/totals reducer. Consumers can project an already-owned
    /// normalized receipt set without re-reading or re-attributing raw history.
    public static func summarize(receipts input: [ActivityAccountingReceipt]) -> Result {
        var unique: [NativeID: ActivityAccountingReceipt] = [:]
        for incoming in input {
            var receipt = incoming
            // The public ledger is normalized evidence, not a raw-provider dump.
            // Invalid measurements must agree with the nullable wire contract
            // and cannot survive in exports after being rejected by totals.
            let quantities: [WritableKeyPath<TokenUsage, Int?>] = [
                \.input, \.output, \.cachedInput, \.cacheWriteInput, \.reasoning, \.total,
            ]
            for field in quantities {
                if let value = receipt.usage[keyPath: field], value < 0 {
                    receipt.usage[keyPath: field] = nil
                    receipt.usageIsPartial = true
                }
            }
            if receipt.kind != .unmeasured && !authoritative(receipt.usage) { receipt.usageIsPartial = true }
            let identity = NativeID(provider: receipt.provider, id: receipt.id)
            if let prior = unique[identity], prior.observedAt > receipt.observedAt { continue }
            unique[identity] = receipt
        }
        let receipts = unique.values.sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            if $0.id != $1.id { return $0.id < $1.id }
            return ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast)
        }
        var buckets: [Key: Bucket] = [:]
        for receipt in receipts {
            if receipt.kind == .modelStep && !receipt.includedInTotals { continue }
            let native = NativeID(provider: receipt.provider, id: receipt.nativeTurnID)
            let owner = StepOwner(session: receipt.sessionID, native: native, partial: receipt.countIsPartial,
                intervalStart: receipt.intervalStart, intervalEnd: receipt.intervalEnd)
            let observed = receipt.countsAsModelStep
            let unmeasured = receipt.kind == .unplacedNativeUsage || (receipt.kind == .unmeasured && receipt.countIsPartial)
                || (receipt.kind == .nativeUsageRemainder && receipt.countIsPartial)
            let hasUsage = receipt.includedInTotals && (receipt.kind == .modelStep || receipt.kind == .nativeUsageRemainder)
            let date: Date?
            switch receipt.kind {
            case .modelStep: date = receipt.timestamp
            case .nativeUsageRemainder: date = receipt.intervalEnd ?? receipt.observedAt
            case .unmeasured: date = receipt.intervalEnd ?? receipt.intervalStart
            case .unplacedNativeUsage: date = nil
            }
            let identity = Key(provider: receipt.provider, model: normalized(receipt.model))
            buckets[identity, default: Bucket()].add(owner: owner, date: date, usage: hasUsage ? receipt.usage : nil,
                effort: receipt.effort, observed: observed, unmeasured: unmeasured,
                partial: receipt.countIsPartial, usagePartial: receipt.usageIsPartial == true)
            if receipt.kind == .unplacedNativeUsage {
                buckets[identity, default: Bucket()].unallocatedIDs.insert(native)
                if authoritative(receipt.usage), let amount = receipt.usage.total, amount >= 0 {
                    buckets[identity, default: Bucket()].unallocatedAmounts[native] = amount
                }
            }
        }
        var rows = buckets.map { makeRow(key: $0.key, bucket: $0.value) }
        rows.sort {
            if ($0.name == nil) != ($1.name == nil) { return $1.name == nil }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            if $0.name != $1.name { return ($0.name ?? "") < ($1.name ?? "") }
            return $0.provider.rawValue < $1.provider.rawValue
        }
        let observed = rows.reduce(0) { $0 + $1.requests }
        if observed > 0 {
            for index in rows.indices where rows[index].requestCount != nil {
                rows[index].shareOfObservedSteps = Double(rows[index].requests) / Double(observed)
            }
        }
        return Result(rows: rows, summary: summary(rows), receipts: receipts)
    }

    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func build(sessions: [ActivitySession], ownershipContext: [ActivitySession]? = nil, from: Date?, to: Date?) -> [Row] {
        inspect(sessions: sessions, ownershipContext: ownershipContext, from: from, to: to).rows
    }

    public static func inspect(sessions: [ActivitySession], ownershipContext: [ActivitySession]? = nil, from: Date?, to: Date?) -> Result {
        let normalizedFrom = from.flatMap(ActivityAccountingPrecision.date)
        let normalizedTo = to.flatMap(ActivityAccountingPrecision.date)
        guard (from == nil || normalizedFrom != nil), (to == nil || normalizedTo != nil) else {
            return Result(rows: [], summary: summary([]), receipts: [])
        }
        let from = normalizedFrom, to = normalizedTo
        if let from, !from.timeIntervalSinceReferenceDate.isFinite { return Result(rows: [], summary: summary([]), receipts: []) }
        if let to, !to.timeIntervalSinceReferenceDate.isFinite { return Result(rows: [], summary: summary([]), receipts: []) }
        if let from, let to, from >= to { return Result(rows: [], summary: summary([]), receipts: []) }
        var context = ownershipContext ?? sessions
        let contextIDs = Set(context.map(\.id))
        context.append(contentsOf: sessions.filter { !contextIDs.contains($0.id) })
        // Normalize the combined ownership context once, before either
        // lineage selection or half-open timestamp comparisons. Public JSON
        // consumers then reproduce the exact same millisecond decisions.
        context = ActivityAccountingPrecision.sessions(context)
        let owned = ActivityAnalytics.ownedTurnsBySession(in: context)
        var byID: [String: ActivitySession] = [:]
        for session in context.sorted(by: {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.id == $1.id ? $0.updatedAt < $1.updatedAt : $0.id < $1.id
        }) { byID[session.id] = session }
        let parents = ActivityAnalytics.sessionParents(in: Array(byID.values))
        func depth(_ id: String) -> Int {
            var visited: Set<String> = [id], next = parents[id]
            while let parent = next, visited.insert(parent).inserted { next = parents[parent] }
            return visited.count
        }
        let ordered = byID.values.sorted {
            let lhs = depth($0.id), rhs = depth($1.id)
            if lhs != rhs { return lhs < rhs }
            return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        let selected = Set(sessions.map(\.id))
        func inWindow(_ date: Date?) -> Bool {
            guard let date else { return from == nil && to == nil }
            return date.timeIntervalSinceReferenceDate.isFinite && (from.map { date >= $0 } ?? true) && (to.map { date < $0 } ?? true)
        }
        func synthetic(_ turn: ActivityTurn) -> Bool {
            turn.usage.provenance == .unavailable && (turn.status == "submission_observed" || turn.id.hasSuffix(":pending-prompts"))
        }
        func steps(_ turn: ActivityTurn, provider: AgentName) -> [ActivityModelStep]? {
            if let values = turn.modelSteps { return values }
            guard provider == .claude, !synthetic(turn) else { return nil }
            return [ActivityModelStep(id: turn.id, timestamp: ActivityAnalytics.timestamp(turn), model: turn.model, effort: turn.effort,
                usage: turn.usage, evidence: "claude-request/legacy", usageIsPartial: turn.usageIsPartial)]
        }
        func relevant(_ turn: ActivityTurn, session: ActivitySession) -> Bool {
            if inWindow(ActivityAnalytics.timestamp(turn)) { return true }
            guard let start = turn.startedAt, start.timeIntervalSinceReferenceDate.isFinite else { return false }
            if let end = turn.completedAt, end.timeIntervalSinceReferenceDate.isFinite, end >= start {
                return (to.map { start < $0 } ?? true) && (from.map { end > $0 } ?? true)
            }
            let open = ["running", "inprogress", "in_progress", "active", "thinking"].contains(turn.status.lowercased())
            return open && turn.completedAt == nil && (to.map { start < $0 && session.observedAt <= $0 } ?? true)
                && (from.map { session.observedAt >= $0 } ?? true)
        }
        func safeAllocationDate(_ turn: ActivityTurn, session: ActivitySession) -> Date? {
            if from == nil {
                let observation = session.observedAt
                guard observation.timeIntervalSinceReferenceDate.isFinite, to.map({ observation <= $0 }) ?? true else { return nil }
                return observation
            }
            guard let start = turn.startedAt, let end = turn.completedAt,
                  start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
                  end >= start, from.map({ start >= $0 }) ?? true, to.map({ end < $0 }) ?? true else { return nil }
            return end
        }
        // Identity corrections from a newer copy enrich the canonical receipt,
        // but never transfer its ownership to a copied child/project.
        var canonical: [NativeID: ActivityModelStep] = [:]
        for session in byID.values.sorted(by: { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }) {
            for turn in owned[session.id] ?? [] {
                for step in steps(turn, provider: session.provider) ?? [] where normalized(step.id) != nil {
                    let identity = NativeID(provider: session.provider, id: step.id)
                    canonical[identity] = canonical[identity].map { merging($0, step) } ?? step
                }
            }
        }
        var owners: [NativeID: StepOwner] = [:], seenTurns: Set<NativeID> = []
        var receipts: [ActivityAccountingReceipt] = []
        func record(_ key: Key, owner: StepOwner, date: Date?, usage: TokenUsage?, effort: String?, unmeasured: Bool, partial: Bool,
                    kind: ActivityAccountingReceiptKind = .unmeasured,
                    stepID: String? = nil, evidence: String = "native-turn-metadata/1", metadataUsage: TokenUsage? = nil,
                    receiptUsagePartial: Bool? = nil) {
            guard let source = byID[owner.session] else { return }
            // Emit one canonical fact at the allocation decision. The same
            // summarize reducer feeds every row, projection, API and export.
            let identity = kind == .modelStep
                ? "\(key.provider.rawValue):model-step:\(stepID ?? "")"
                : "\(key.provider.rawValue):turn:\(owner.native.id):\(kind.rawValue)"
            let included = kind == .modelStep || kind == .nativeUsageRemainder
            receipts.append(ActivityAccountingReceipt(id: identity, provider: key.provider, sessionID: owner.session,
                nativeTurnID: owner.native.id, projectPath: source.projectPath, kind: kind,
                timestamp: kind == .modelStep ? date : nil,
                intervalStart: owner.intervalStart, intervalEnd: owner.intervalEnd, observedAt: source.observedAt,
                model: key.model, effort: effort, usage: metadataUsage ?? usage ?? TokenUsage(),
                usageIsPartial: receiptUsagePartial, countIsPartial: partial || unmeasured,
                evidence: evidence, includedInTotals: included,
                timeBasis: kind == .modelStep ? .providerEvent : (kind == .nativeUsageRemainder ? .nativeInterval : .unplaced)))
        }
        func allocate(_ usage: TokenUsage?, owner: StepOwner, turn: ActivityTurn, session: ActivitySession) {
            let unknown = Key(provider: owner.native.provider, model: nil)
            if let date = safeAllocationDate(turn, session: session) {
                record(unknown, owner: owner, date: date, usage: usage, effort: nil,
                    unmeasured: true, partial: true, kind: usage == nil ? .unmeasured : .nativeUsageRemainder,
                    evidence: "native-turn-usage-allocation/1", receiptUsagePartial: turn.usageIsPartial)
            } else {
                record(unknown, owner: owner, date: nil, usage: nil, effort: nil, unmeasured: true, partial: true,
                    kind: .unplacedNativeUsage, evidence: "native-turn-usage-unplaced/1", metadataUsage: usage,
                    receiptUsagePartial: turn.usageIsPartial)
            }
        }
        for session in ordered {
            for turn in owned[session.id] ?? [] {
                let native = NativeID(provider: session.provider, id: turn.id)
                guard seenTurns.insert(native).inserted else { continue }
                let values = steps(turn, provider: session.provider)
                let unplaceable = values?.contains { normalized($0.id) == nil || ($0.timestamp == nil && (from != nil || to != nil)) } == true
                let partial = (turn.modelSteps != nil ? turn.modelStepsComplete != true : turn.usageIsPartial == true)
                    || unplaceable || (turn.modelSteps == nil && session.provider == .claude && !session.historyComplete)
                let owner = StepOwner(session: session.id, native: native, partial: partial,
                    intervalStart: turn.startedAt, intervalEnd: turn.completedAt)
                if let values {
                    for step in values where normalized(step.id) != nil {
                        let identity = NativeID(provider: session.provider, id: step.id)
                        if owners[identity] == nil { owners[identity] = owner }
                    }
                    let hasDatedStep = values.contains { inWindow($0.timestamp) }
                    let nativeRelevant = relevant(turn, session: session) || hasDatedStep
                    var seenStepIDs: Set<String> = []
                    let completeStepUsage = values.filter { normalized($0.id) != nil && seenStepIDs.insert($0.id).inserted }
                        .map { canonical[NativeID(provider: session.provider, id: $0.id)] ?? $0 }
                    let residual = remainder(turn.usage, after: completeStepUsage.map(\.usage))
                    if selected.contains(session.id), nativeRelevant, let residual {
                        allocate(residual, owner: owner, turn: turn, session: session)
                    } else if values.isEmpty, selected.contains(session.id), nativeRelevant {
                        record(Key(provider: session.provider, model: normalized(turn.model)), owner: owner, date: ActivityAnalytics.timestamp(turn),
                            usage: nil, effort: nil, unmeasured: partial, partial: partial)
                    } else if !values.isEmpty, unplaceable, selected.contains(session.id), nativeRelevant {
                        // Do not borrow the native turn's date/model to place
                        // an undated call. Only expose the missing count.
                        record(Key(provider: session.provider, model: nil), owner: owner, date: ActivityAnalytics.timestamp(turn),
                            usage: nil, effort: nil, unmeasured: true, partial: true,
                            evidence: "model-step-date-unavailable/1")
                    }
                } else if selected.contains(session.id), relevant(turn, session: session) {
                    allocate(synthetic(turn) ? nil : turn.usage, owner: owner, turn: turn, session: session)
                }
            }
        }
        for (identity, owner) in owners where selected.contains(owner.session) {
            guard let step = canonical[identity], inWindow(step.timestamp) else { continue }
            record(Key(provider: identity.provider, model: normalized(step.model)), owner: owner, date: step.timestamp,
                usage: step.usage, effort: step.effort, unmeasured: false,
                partial: owner.partial || step.usageIsPartial == true,
                kind: .modelStep, stepID: step.id, evidence: step.evidence, receiptUsagePartial: step.usageIsPartial)
        }
        return summarize(receipts: receipts)
    }

    private static func makeRow(key: Key, bucket: Bucket) -> Row {
        let turns = bucket.records
        var effortCounts: [String: Int] = [:]
        var tokenReceipts = 0, outputReceipts = 0, partialReceipts = 0
        for turn in turns {
            if let effort = normalized(turn.effort) { effortCounts[effort, default: 0] += 1 }
            if authoritative(turn.usage), let value = turn.usage.total, value >= 0 { tokenReceipts += 1 }
            if authoritative(turn.usage), let value = turn.usage.output, value >= 0 { outputReceipts += 1 }
            if turn.usageIsPartial == true || !authoritative(turn.usage) { partialReceipts += 1 }
        }
        var efforts: [EffortCount] = []
        for (name, count) in effortCounts { efforts.append(EffortCount(name: name, count: count)) }
        efforts.sort { lhs, rhs in lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count }
        let composition = ActivityAnalytics.composition(usages: turns.lazy.filter { authoritative($0.usage) }.map(\.usage))
        var reread: Double?
        if let composition, composition.total > 0 { reread = Double(composition.rereadContext) / Double(composition.total) }
        let totals: [Int?] = turns.map { authoritative($0.usage) ? $0.usage.total : nil }
        let outputs: [Int?] = turns.map { authoritative($0.usage) ? $0.usage.output : nil }
        return Row(key: key, requests: bucket.steps, requestsArePartial: bucket.partial, usageRecords: turns.count,
                   nativeIDs: bucket.nativeIDs, unmeasuredIDs: bucket.unmeasuredIDs,
                   unallocatedIDs: bucket.unallocatedIDs, unallocatedAmounts: bucket.unallocatedAmounts,
                   tokens: ActivityMetrics.knownTotal(totals),
                   output: ActivityMetrics.knownTotal(outputs), tokenReceipts: tokenReceipts,
                   outputReceipts: outputReceipts, partialReceipts: partialReceipts,
                   breakdownReceipts: composition?.receipts ?? 0, reread: reread,
                   efforts: efforts, sessions: bucket.sessionIDs.count, lastUsed: bucket.lastUsed)
    }

    /// Keep a known native total conserved without assigning its unknown
    /// portion to the native turn's last configured model. Full step history,
    /// not just this window's calls, must be subtracted to avoid double credit.
    private static func remainder(_ native: TokenUsage, after steps: [TokenUsage]) -> TokenUsage? {
        func difference(_ field: KeyPath<TokenUsage, Int?>) -> Int? {
            guard let amount = native[keyPath: field], amount >= 0 else { return nil }
            // An estimate cannot consume part of an authoritative native pool;
            // that portion remains a known but unattributed native remainder.
            let measured = steps.filter(authoritative).compactMap { $0[keyPath: field] }.filter { $0 >= 0 }
            let used = measured.isEmpty ? 0 : ActivityMetrics.knownTotal(measured.map { Optional($0) })
            guard let used, used <= amount else { return nil }
            return amount - used
        }
        let result = TokenUsage(input: difference(\.input), output: difference(\.output), cachedInput: difference(\.cachedInput),
            cacheWriteInput: difference(\.cacheWriteInput), reasoning: difference(\.reasoning), total: difference(\.total),
            provenance: authoritative(native) ? .derived : native.provenance)
        // Missing component splits are not additional tokens when the total
        // already reconciles. An invalid/overflowing total difference is not
        // a license to invent an allocation from unrelated components either.
        if native.total != nil, result.total == nil || result.total == 0 { return nil }
        return [result.input, result.output, result.cachedInput, result.cacheWriteInput, result.reasoning, result.total].contains { ($0 ?? 0) > 0 } ? result : nil
    }

    private static func authoritative(_ usage: TokenUsage) -> Bool {
        usage.hasAuthoritativeProvenance
    }

    private static func merging(_ prior: ActivityModelStep, _ incoming: ActivityModelStep) -> ActivityModelStep {
        var value = incoming
        value.model = normalized(incoming.model)
        value.effort = normalized(incoming.effort)
        return prior.merging(value)
    }

    /// Segment widths consume exactly the available width. A minimum width or
    /// external spacing would inflate tiny shares and clip the final segment.
    public static func segmentWidths(counts: [Int], width: Double) -> [Double] {
        guard width.isFinite, width >= 0, counts.allSatisfy({ $0 >= 0 }) else { return counts.map { _ in 0 } }
        let total = counts.reduce(0.0) { $0 + Double($1) }
        guard total.isFinite, total > 0 else { return counts.map { _ in 0 } }
        return counts.map { width * (Double($0) / total) }
    }
}


// Row identity collections are encoded in a canonical order. Synthesized
// Codable for Set or dictionaries with structured keys would make otherwise
// identical audit exports depend on hash/random iteration order.
extension ActivityModelAccounting.Row {
    private enum CodingKeys: String, CodingKey {
        case key, requests, requestsArePartial, usageRecords, shareOfObservedSteps, tokens, output, tokenReceipts, outputReceipts, partialReceipts, breakdownReceipts, reread, efforts, sessions, lastUsed, nativeIDs, unmeasuredIDs, unallocatedIDs, unallocatedAmounts, requestCount, nativeTurns, unmeasuredTurns, tokensArePartial, outputIsPartial
        case observedModelSteps, observedStepCount, stepsArePartial
    }
    private struct AmountRecord: Codable {
        var nativeID: ActivityModelAccounting.NativeID
        var tokens: Int
    }
    private static func nativeOrder(_ lhs: ActivityModelAccounting.NativeID, _ rhs: ActivityModelAccounting.NativeID) -> Bool {
        lhs.provider == rhs.provider ? lhs.id < rhs.id : lhs.provider.rawValue < rhs.provider.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(ActivityModelAccounting.Key.self, forKey: .key)
        requests = try container.decode(Int.self, forKey: .requests)
        requestsArePartial = try container.decode(Bool.self, forKey: .requestsArePartial)
        usageRecords = try container.decode(Int.self, forKey: .usageRecords)
        shareOfObservedSteps = try container.decodeIfPresent(Double.self, forKey: .shareOfObservedSteps)
        tokens = try container.decodeIfPresent(Int.self, forKey: .tokens)
        output = try container.decodeIfPresent(Int.self, forKey: .output)
        tokenReceipts = try container.decode(Int.self, forKey: .tokenReceipts)
        outputReceipts = try container.decode(Int.self, forKey: .outputReceipts)
        partialReceipts = try container.decode(Int.self, forKey: .partialReceipts)
        breakdownReceipts = try container.decode(Int.self, forKey: .breakdownReceipts)
        reread = try container.decodeIfPresent(Double.self, forKey: .reread)
        efforts = try container.decode([ActivityModelAccounting.EffortCount].self, forKey: .efforts)
        sessions = try container.decode(Int.self, forKey: .sessions)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        nativeIDs = Set(try container.decode([ActivityModelAccounting.NativeID].self, forKey: .nativeIDs))
        unmeasuredIDs = Set(try container.decode([ActivityModelAccounting.NativeID].self, forKey: .unmeasuredIDs))
        unallocatedIDs = Set(try container.decode([ActivityModelAccounting.NativeID].self, forKey: .unallocatedIDs))
        let amounts = try container.decode([AmountRecord].self, forKey: .unallocatedAmounts)
        unallocatedAmounts = Dictionary(amounts.map { ($0.nativeID, $0.tokens) }, uniquingKeysWith: max)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(requests, forKey: .requests)
        try container.encode(requestsArePartial, forKey: .requestsArePartial)
        try container.encode(observedModelSteps, forKey: .observedModelSteps)
        try container.encode(observedStepCount, forKey: .observedStepCount)
        try container.encode(stepsArePartial, forKey: .stepsArePartial)
        try container.encode(usageRecords, forKey: .usageRecords)
        try container.encode(shareOfObservedSteps, forKey: .shareOfObservedSteps)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(output, forKey: .output)
        try container.encode(tokenReceipts, forKey: .tokenReceipts)
        try container.encode(outputReceipts, forKey: .outputReceipts)
        try container.encode(partialReceipts, forKey: .partialReceipts)
        try container.encode(breakdownReceipts, forKey: .breakdownReceipts)
        try container.encode(reread, forKey: .reread)
        try container.encode(efforts, forKey: .efforts)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(lastUsed, forKey: .lastUsed)
        try container.encode(nativeIDs.sorted(by: Self.nativeOrder), forKey: .nativeIDs)
        try container.encode(unmeasuredIDs.sorted(by: Self.nativeOrder), forKey: .unmeasuredIDs)
        try container.encode(unallocatedIDs.sorted(by: Self.nativeOrder), forKey: .unallocatedIDs)
        let amounts = unallocatedAmounts.map { AmountRecord(nativeID: $0.key, tokens: $0.value) }
            .sorted { Self.nativeOrder($0.nativeID, $1.nativeID) }
        try container.encode(amounts, forKey: .unallocatedAmounts)
        try container.encode(requestCount, forKey: .requestCount)
        try container.encode(nativeTurns, forKey: .nativeTurns)
        try container.encode(unmeasuredTurns, forKey: .unmeasuredTurns)
        try container.encode(tokensArePartial, forKey: .tokensArePartial)
        try container.encode(outputIsPartial, forKey: .outputIsPartial)
    }
}

extension ActivityModelAccounting.Summary {
    private enum CodingKeys: String, CodingKey {
        case totalObservedSteps, unmeasuredTurns, nativeTurns, unallocatedTokens, unallocatedTurns
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalObservedSteps, forKey: .totalObservedSteps)
        try container.encode(unmeasuredTurns, forKey: .unmeasuredTurns)
        try container.encode(nativeTurns, forKey: .nativeTurns)
        try container.encode(unallocatedTokens, forKey: .unallocatedTokens)
        try container.encode(unallocatedTurns, forKey: .unallocatedTurns)
    }
}
