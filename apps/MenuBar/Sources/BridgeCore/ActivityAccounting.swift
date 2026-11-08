import Foundation

/// Accounting compares timestamps at the exact precision of its public wire
/// codec. Legacy trace serialization is unchanged.
public enum ActivityAccountingPrecision {
    public static let timestampPrecision = "millisecond"

    public static func date(_ value: Date) -> Date? {
        guard value.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let milliseconds = value.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite else { return nil }
        let candidate = Date(timeIntervalSince1970: milliseconds.rounded() / 1_000)
        // Persisted timestamps are already on this grid. Avoid formatter work
        // for every checkpoint on every UI refresh. Half-millisecond ties and
        // arbitrary in-memory dates use the actual serializer, not a guess.
        if abs(candidate.timeIntervalSince(value)) <= 0.000_001 { return candidate }
        guard let decoded = ISO8601.withFractional.date(from: ISO8601.withFractional.string(from: value)) else { return nil }
        return Date(timeIntervalSince1970: (decoded.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    public static func metadataSessions(_ values: [ActivitySession]) -> [ActivitySession] {
        values.compactMap { original in
            guard let created = date(original.createdAt), let updated = date(original.updatedAt), let observed = date(original.observedAt) else { return nil }
            var value = original
            value.createdAt = created; value.updatedAt = updated; value.observedAt = observed
            if var goal = value.goal {
                if let created = date(goal.createdAt), let updated = date(goal.updatedAt) {
                    goal.createdAt = created; goal.updatedAt = updated; value.goal = goal
                } else { value.goal = nil }
            }
            return value
        }
    }

    /// Context normalization is done once before ownership or date filtering.
    /// Invalid optional event times stay nil; invalid required session dates
    /// cause that malformed observation to be omitted rather than re-dated.
    public static func sessions(_ values: [ActivitySession]) -> [ActivitySession] {
        metadataSessions(values).map { original in
            var value = original
            value.turns = original.turns.map { original in
                var turn = original
                turn.startedAt = original.startedAt.flatMap(date); turn.completedAt = original.completedAt.flatMap(date)
                turn.modelSteps = original.modelSteps.map { steps in steps.map { original in
                    var step = original; step.timestamp = original.timestamp.flatMap(date); return step
                } }
                return turn
            }
            return value
        }
    }
}

/// The shared, passive accounting projection for UI, API, exports and briefs.
/// Provider account/plan/goal counters are deliberately outside this scope.
public enum ActivityAccounting {
    public typealias Scope = ActivityAccountingScope

    public struct Breakdown: Codable, Equatable, Sendable {
        public var freshInput: Int
        public var rereadContext: Int
        public var cacheWrites: Int
        public var output: Int
        public var receipts: Int
        public var isComplete: Bool
        public var total: Int? {
            let values = [freshInput, rereadContext, cacheWrites, output]
            guard receipts >= 0, values.allSatisfy({ $0 >= 0 }) else { return nil }
            var total = 0
            for value in values {
                let next = total.addingReportingOverflow(value)
                guard !next.overflow else { return nil }
                total = next.partialValue
            }
            return total
        }
    }

    public struct UsageTotals: Codable, Equatable, Sendable {
        public var modelStepCount: Int
        public var tokensKnown: Int?
        public var outputKnown: Int?
        public var usageRecords: Int
        public var tokenReceipts: Int
        public var outputReceipts: Int
        public var partialUsageRecords: Int
        public var partialTokenReceipts: Int
        public var partialOutputTokenReceipts: Int
        public var tokensArePartial: Bool
        public var outputIsPartial: Bool
        public var tokenOverflow: Bool
        public var outputOverflow: Bool
        public var composition: Breakdown?
        /// A versioned comparison heuristic, never a price or plan allowance.
        fileprivate var weightedHint: Double?
        public var weightedEquivalent: Double? {
            guard weightingVersion == "fresh-input-equivalent/1", let composition, composition.isComplete, composition.total != nil else { return nil }
            let value = Double(composition.freshInput) + Double(composition.rereadContext) * 0.1 + Double(composition.cacheWrites) * 1.25 + Double(composition.output) * 5
            return value.isFinite && value >= 0 ? value : nil
        }
        public var weightingVersion = "fresh-input-equivalent/1"
        public var provenance: MetricProvenance = .derived
        public var tokenCoverage: Double? { usageRecords > 0 && (0...usageRecords).contains(tokenReceipts) ? Double(tokenReceipts) / Double(usageRecords) : nil }
        public var outputCoverage: Double? { usageRecords > 0 && (0...usageRecords).contains(outputReceipts) ? Double(outputReceipts) / Double(usageRecords) : nil }

        private enum CodingKeys: String, CodingKey {
            case modelStepCount, tokensKnown, outputKnown, usageRecords, tokenReceipts, outputReceipts, partialUsageRecords
            case partialTokenReceipts, partialOutputTokenReceipts, tokensArePartial, outputIsPartial, tokenOverflow, outputOverflow
            case composition, weightingVersion, provenance
            case weightedHint = "weightedEquivalent"
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(modelStepCount, forKey: .modelStepCount)
            try c.encode(tokensKnown, forKey: .tokensKnown); try c.encode(outputKnown, forKey: .outputKnown)
            try c.encode(usageRecords, forKey: .usageRecords); try c.encode(tokenReceipts, forKey: .tokenReceipts)
            try c.encode(outputReceipts, forKey: .outputReceipts); try c.encode(partialUsageRecords, forKey: .partialUsageRecords)
            try c.encode(partialTokenReceipts, forKey: .partialTokenReceipts); try c.encode(partialOutputTokenReceipts, forKey: .partialOutputTokenReceipts)
            try c.encode(tokensArePartial, forKey: .tokensArePartial); try c.encode(outputIsPartial, forKey: .outputIsPartial)
            try c.encode(tokenOverflow, forKey: .tokenOverflow); try c.encode(outputOverflow, forKey: .outputOverflow)
            try c.encode(composition, forKey: .composition); try c.encode(weightedEquivalent, forKey: .weightedHint)
            try c.encode(weightingVersion, forKey: .weightingVersion); try c.encode(provenance, forKey: .provenance)
        }
    }

    public struct Totals: Codable, Sendable {
        public var observedModelSteps: Int
        /// Unique native records supporting selected receipts, dated native
        /// facts or closed interval overlap. These are not model-call counts.
        public var nativeRecords: Int
        public var sessions: Int
        public var usage: UsageTotals
        public var activeSeconds: Double?
        public var agentSeconds: Double?
        public var submittedPrompts: Int?
        public var confirmedHumanPrompts: Int?
        public var toolCalls: Int?
        public var unallocatedNativeCounters: NativeCounters
        public var nativeCountersArePartial: Bool
        public var tokensKnown: Int? { usage.tokensKnown }
        public var outputKnown: Int? { usage.outputKnown }
        public var tokenReceipts: Int { usage.tokenReceipts }
        public var outputReceipts: Int { usage.outputReceipts }
        public var outputTokenReceipts: Int { usage.outputReceipts }
        public var usageRecords: Int { usage.usageRecords }
        public var partialUsageRecords: Int { usage.partialUsageRecords }
        public var tokensArePartial: Bool { usage.tokensArePartial }
        public var outputIsPartial: Bool { usage.outputIsPartial }
        public var outputArePartial: Bool { usage.outputIsPartial }
        public var modelStepsArePartial: Bool
        public var modelIdentities: Int
        public var timedSessions: Int
        public var meanSessionSeconds: Double?
        public var medianSessionSeconds: Double?
        public var tokenCoverage: Double? { usage.tokenCoverage }
        public var composition: Breakdown? { usage.composition }
        public var weightedEquivalent: Double? { usage.weightedEquivalent }
    }

    public struct NativeCounters: Codable, Sendable {
        public var submittedPrompts: Int?
        public var confirmedHumanPrompts: Int?
        public var toolCalls: Int?
        public var records: Int
        public var isPartial: Bool
        public var timeBasis: String
    }

    /// Metadata for non-token metrics. No raw native token pool is retained
    /// here: tokens enter exclusively through normalized accounting receipts.
    public struct NativeObservation: Codable, Sendable {
        public var id: String
        public var provider: AgentName
        public var sessionID: String
        public var timestamp: Date?
        public var startedAt: Date?
        public var completedAt: Date?
        public var submittedPrompts: Int?
        public var confirmedHumanPrompts: Int?
        public var toolCalls: Int?
        public var categories: [String: Int]
        public var artifacts: [ActivityArtifact]
        public var status: String
        public var countedInWindow: Bool
        public var countersIncludedInWindow: Bool
        public var timeBasis = "native_completion_else_start/1"
    }

    public struct Report: Codable, Sendable {
        public var schemaVersion = "accounting/1"
        public var metricDefinitionsVersion = ActivityMetricDefinitions.version
        /// Scoped reproduction fingerprint, not a security/tamper-proof claim.
        /// Computed on first read from the facts as assembled: encoding every
        /// receipt is the costliest part of a report, and most per-session and
        /// per-project projections are never fingerprinted.
        public var evidenceDigest: String {
            get { digest.value }
            set { digest = DigestSlot(fixed: newValue) }
        }
        fileprivate var digest = DigestSlot(fixed: "")
        public var scope: Scope
        public var modelRows: [ActivityModelAccounting.Row]
        public var summary: ActivityModelAccounting.Summary
        public var receipts: [ActivityAccountingReceipt]
        public var nativeObservations: [NativeObservation]
        public var totals: Totals
        public var warnings: [String]
        public var isValid: Bool
        public var sourceHealth: [ActivitySourceHealth]
        public var sourceCoverageIsPartial: Bool
        /// Per-session union of recorded closed native spans, clipped to scope.
        /// Missing durations are omitted; a reported zero remains zero.
        public var sessionWorkSeconds: [String: Double]
        public var openGoalSessionIDs: [String]
        public var participatingSessionIDs: [String]
        public var sessionProjects: [String: String]
        public var averageStepsPerHour: Double? {
            guard totals.observedModelSteps >= 0, let from = scope.from, scope.to > from else { return nil }
            let hours = scope.to.timeIntervalSince(from) / 3_600
            guard hours.isFinite, hours > 0 else { return nil }
            let result = Double(totals.observedModelSteps) / hours
            return result.isFinite ? result : nil
        }
        public var composition: ActivityAnalytics.Composition? {
            totals.composition.flatMap { value in
                guard value.total != nil else { return nil }
                return ActivityAnalytics.Composition(freshInput: value.freshInput, rereadContext: value.rereadContext, cacheWrites: value.cacheWrites, output: value.output, receipts: value.receipts)
            }
        }
        public var categoryMix: [ActivityAnalytics.Share] {
            ActivityAnalytics.categoryMix(nativeObservations.filter(\.countersIncludedInWindow).map { ActivityTurn(id: $0.id, categories: $0.categories) })
        }
        public var artifacts: [ActivityArtifact] {
            var result: [String: ActivityArtifact] = [:]
            for observation in nativeObservations.filter(\.countersIncludedInWindow) {
                for artifact in observation.artifacts {
                    var projected = artifact
                    projected.id = observation.provider.rawValue + ":" + artifact.id
                    result[projected.id] = projected
                }
            }
            return result.values.sorted { $0.path == $1.path ? $0.id < $1.id : $0.path < $1.path }
        }

        public func series(granularity: ActivityAnalytics.Granularity, timeZone: TimeZone = ActivityAnalytics.reportingTimeZone) -> Series {
            ActivityAccounting.series(self, granularity: granularity, timeZone: timeZone)
        }

        /// Cohort projection of already-normalized facts. Ownership, receipt
        /// identity and window allocation are never re-decided in a row view.
        public func projected(sessionIDs: Set<String>) -> Report {
            let ids = Set(scope.sessionIDs).intersection(sessionIDs)
            var scope = scope; scope.sessionIDs = ids.sorted()
            return ActivityAccounting.assemble(scope: scope,
                accounting: ActivityModelAccounting.summarize(receipts: receipts.filter { ids.contains($0.sessionID) }),
                native: nativeObservations.filter { ids.contains($0.sessionID) },
                sourceHealth: sourceHealth, valid: isValid, openGoals: Set(openGoalSessionIDs).intersection(ids),
                sessionProjects: sessionProjects.filter { ids.contains($0.key) }, sourceCoverageOverride: sourceCoverageIsPartial)
        }

        /// Prepare the roster once in O(facts), rather than re-normalizing the
        /// full snapshot for every visible session.
        public func bySession() -> [String: Report] {
            let receiptsBySession = Dictionary(grouping: receipts, by: \.sessionID)
            let nativeBySession = Dictionary(grouping: nativeObservations, by: \.sessionID)
            let goals = Set(openGoalSessionIDs)
            var result: [String: Report] = [:]
            for id in scope.sessionIDs {
                var scope = scope; scope.sessionIDs = [id]
                result[id] = ActivityAccounting.assemble(scope: scope,
                    accounting: ActivityModelAccounting.summarize(receipts: receiptsBySession[id] ?? []),
                    native: nativeBySession[id] ?? [], sourceHealth: sourceHealth, valid: isValid,
                    openGoals: goals.contains(id) ? [id] : [], sessionProjects: sessionProjects[id].map { [id: $0] } ?? [:], sourceCoverageOverride: sourceCoverageIsPartial)
            }
            return result
        }

        /// Empty key means no project folder was reported, not a guessed repo.
        public func byProject() -> [String: Report] {
            let sessionGroups = Dictionary(grouping: scope.sessionIDs, by: { sessionProjects[$0] ?? "" })
            let receiptGroups = Dictionary(grouping: receipts, by: { sessionProjects[$0.sessionID] ?? "" })
            let nativeGroups = Dictionary(grouping: nativeObservations, by: { sessionProjects[$0.sessionID] ?? "" })
            let goals = Set(openGoalSessionIDs)
            var result: [String: Report] = [:]
            for project in sessionGroups.keys.sorted() {
                let ids = Set(sessionGroups[project] ?? [])
                var scope = scope; scope.sessionIDs = ids.sorted()
                result[project] = ActivityAccounting.assemble(scope: scope,
                    accounting: ActivityModelAccounting.summarize(receipts: receiptGroups[project] ?? []),
                    native: nativeGroups[project] ?? [], sourceHealth: sourceHealth, valid: isValid,
                    openGoals: goals.intersection(ids), sessionProjects: sessionProjects.filter { ids.contains($0.key) }, sourceCoverageOverride: sourceCoverageIsPartial)
            }
            return result
        }

        /// Fingerprint the report as it stands now, on first read.
        fileprivate mutating func fingerprintLater() { digest = DigestSlot(pending: self) }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, metricDefinitionsVersion, evidenceDigest, scope, modelRows, summary, receipts, nativeObservations, totals
            case warnings, isValid, sourceHealth, sourceCoverageIsPartial, sessionWorkSeconds, openGoalSessionIDs, participatingSessionIDs, sessionProjects
        }

        fileprivate init(scope: Scope, modelRows: [ActivityModelAccounting.Row], summary: ActivityModelAccounting.Summary,
                         receipts: [ActivityAccountingReceipt], nativeObservations: [NativeObservation], totals: Totals, warnings: [String],
                         isValid: Bool, sourceHealth: [ActivitySourceHealth], sourceCoverageIsPartial: Bool, sessionWorkSeconds: [String: Double],
                         openGoalSessionIDs: [String], participatingSessionIDs: [String], sessionProjects: [String: String]) {
            self.scope = scope; self.modelRows = modelRows; self.summary = summary; self.receipts = receipts
            self.nativeObservations = nativeObservations; self.totals = totals; self.warnings = warnings; self.isValid = isValid
            self.sourceHealth = sourceHealth; self.sourceCoverageIsPartial = sourceCoverageIsPartial; self.sessionWorkSeconds = sessionWorkSeconds
            self.openGoalSessionIDs = openGoalSessionIDs; self.participatingSessionIDs = participatingSessionIDs; self.sessionProjects = sessionProjects
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(String.self, forKey: .schemaVersion)
            metricDefinitionsVersion = try c.decode(String.self, forKey: .metricDefinitionsVersion)
            digest = DigestSlot(fixed: try c.decode(String.self, forKey: .evidenceDigest))
            scope = try c.decode(Scope.self, forKey: .scope)
            modelRows = try c.decode([ActivityModelAccounting.Row].self, forKey: .modelRows)
            summary = try c.decode(ActivityModelAccounting.Summary.self, forKey: .summary)
            receipts = try c.decode([ActivityAccountingReceipt].self, forKey: .receipts)
            nativeObservations = try c.decode([NativeObservation].self, forKey: .nativeObservations)
            totals = try c.decode(Totals.self, forKey: .totals)
            warnings = try c.decode([String].self, forKey: .warnings)
            isValid = try c.decode(Bool.self, forKey: .isValid)
            sourceHealth = try c.decode([ActivitySourceHealth].self, forKey: .sourceHealth)
            sourceCoverageIsPartial = try c.decode(Bool.self, forKey: .sourceCoverageIsPartial)
            sessionWorkSeconds = try c.decode([String: Double].self, forKey: .sessionWorkSeconds)
            openGoalSessionIDs = try c.decode([String].self, forKey: .openGoalSessionIDs)
            participatingSessionIDs = try c.decode([String].self, forKey: .participatingSessionIDs)
            sessionProjects = try c.decode([String: String].self, forKey: .sessionProjects)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(metricDefinitionsVersion, forKey: .metricDefinitionsVersion)
            try c.encode(evidenceDigest, forKey: .evidenceDigest)
            try c.encode(scope, forKey: .scope)
            try c.encode(modelRows, forKey: .modelRows)
            try c.encode(summary, forKey: .summary)
            try c.encode(receipts, forKey: .receipts)
            try c.encode(nativeObservations, forKey: .nativeObservations)
            try c.encode(totals, forKey: .totals)
            try c.encode(warnings, forKey: .warnings)
            try c.encode(isValid, forKey: .isValid)
            try c.encode(sourceHealth, forKey: .sourceHealth)
            try c.encode(sourceCoverageIsPartial, forKey: .sourceCoverageIsPartial)
            try c.encode(sessionWorkSeconds, forKey: .sessionWorkSeconds)
            try c.encode(openGoalSessionIDs, forKey: .openGoalSessionIDs)
            try c.encode(participatingSessionIDs, forKey: .participatingSessionIDs)
            try c.encode(sessionProjects, forKey: .sessionProjects)
        }
    }

    /// A report's fingerprint, fixed or computed once from a snapshot of the
    /// report taken when it was assembled. Copies share the result.
    fileprivate final class DigestSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var value_: String?
        private var source: Report?

        init(fixed: String) { value_ = fixed }
        init(pending report: Report) { source = report }

        var value: String {
            lock.lock(); defer { lock.unlock() }
            if let value_ { return value_ }
            let computed = source.map(ActivityAccounting.reconciliationDigest) ?? ""
            value_ = computed
            source = nil
            return computed
        }
    }

    public struct Point: Codable, Identifiable, Sendable {
        public var start: Date
        public var windowStart: Date
        public var end: Date
        public var usage: UsageTotals
        public var nativeRecords: Int
        /// Distinct IDs support union reconciliation; native record counts are
        /// not additive when one turn contributes to several time buckets.
        public var nativeRecordIDs: [String]
        public var sessionIDs: [String]
        public var activeSeconds: Double?
        public var agentSeconds: Double?
        public var byProvider: [String: UsageTotals]
        public var id: Date { start }
        public var day: Date { start }
        public var modelStepCount: Int { usage.modelStepCount }
        public var tokensKnown: Int? { usage.tokensKnown }
        public var outputKnown: Int? { usage.outputKnown }
        public var measuredTokens: Int? { usage.tokensKnown }
        public var measuredOutputTokens: Int? { usage.outputKnown }
        public var measuredActiveSeconds: Double? { activeSeconds }
        public var turns: Int { nativeRecords }
        public var tokenReceipts: Int { usage.tokenReceipts }
        public var outputTokenReceipts: Int { usage.outputReceipts }
        public var usageRecords: Int { usage.usageRecords }
        public var partialUsageRecords: Int { usage.partialUsageRecords }
        public var composition: Breakdown? { usage.composition }
        public var partialTokenReceipts: Int { usage.partialTokenReceipts }
        public var partialOutputTokenReceipts: Int { usage.partialOutputTokenReceipts }
        public var tokenOverflow: Bool { usage.tokenOverflow }
        public var outputOverflow: Bool { usage.outputOverflow }
        public var closedIntervalReceipts: Int
        public var averageAgents: Double? {
            guard let agentSeconds, agentSeconds.isFinite, agentSeconds >= 0, end > windowStart else { return nil }
            let duration = end.timeIntervalSince(windowStart)
            guard duration.isFinite, duration > 0 else { return nil }
            let value = agentSeconds / duration
            return value.isFinite ? value : nil
        }
    }

    public struct Series: Codable, Sendable {
        public typealias Point = ActivityAccounting.Point
        public var schemaVersion = "accounting/1"
        public var scope: Scope
        public var granularity: String
        public var timeZone: String
        public var points: [Point]
        public var total: UsageTotals
        /// Included usage that cannot truthfully be dated to a single bucket.
        public var unallocated: UsageTotals
        public var unallocatedByProvider: [String: UsageTotals]
        public var unallocatedNativeRecordIDs: [String]
        public var unallocatedSessionIDs: [String]
        public var warnings: [String]
    }

    public static func build(overview: ActivityOverview, sessionIDs: Set<String>? = nil, from: Date?, to: Date) -> Report {
        let normalizedTo = ActivityAccountingPrecision.date(to)
        let normalizedFrom = from.flatMap(ActivityAccountingPrecision.date)
        let normalizedAsOf = ActivityAccountingPrecision.date(overview.generatedAt)
        let valid = normalizedAsOf != nil && normalizedTo != nil && (from == nil || normalizedFrom != nil)
            && (normalizedFrom.map { start in normalizedTo.map { end in start < end && end.timeIntervalSince(start).isFinite } ?? false } ?? true)
        let from = normalizedFrom, to = normalizedTo ?? Date(timeIntervalSince1970: 0)
        let metadata = ActivityAccountingPrecision.metadataSessions(overview.sessions)
        let health = overview.sources.compactMap { original -> ActivitySourceHealth? in
            guard let checked = ActivityAccountingPrecision.date(original.checkedAt) else { return nil }
            var source = original; source.checkedAt = checked
            source.lastSuccessAt = original.lastSuccessAt.flatMap(ActivityAccountingPrecision.date)
            return source
        }
        var canonicalSessions: [String: ActivitySession] = [:]
        for session in metadata {
            if let prior = canonicalSessions[session.id], session.observedAt < prior.observedAt || (session.observedAt == prior.observedAt && session.updatedAt < prior.updatedAt) { continue }
            canonicalSessions[session.id] = session
        }
        let selected = canonicalSessions.values.filter { sessionIDs?.contains($0.id) ?? true }
        let selectedIDs = Set(selected.map(\.id))
        let scope = Scope(from: from.flatMap { finite($0) ? $0 : nil }, to: finite(to) ? to : Date(timeIntervalSince1970: 0),
                          asOf: normalizedAsOf ?? Date(timeIntervalSince1970: 0), sessionIDs: Array(selectedIDs))
        let accounting = ActivityModelAccounting.inspect(sessions: valid ? selected : [], ownershipContext: metadata, from: from, to: to)
        let receipts = valid ? accounting.receipts : []
        let receiptNativeIDs = Set(receipts.filter { $0.includedInTotals || $0.timestamp.map { inWindow($0, from: from, to: to) } == true }
            .map { $0.provider.rawValue + ":" + $0.nativeTurnID })
        let native = valid ? nativeObservations(metadata, selectedIDs: selectedIDs, supportingIDs: receiptNativeIDs, from: from, to: to) : []
        let openGoals = valid ? Set(selected.filter { $0.goal.map { $0.isOpen && finite($0.createdAt) && $0.createdAt < to } == true }.map(\.id)) : []
        let projects = Dictionary(uniqueKeysWithValues: selected.compactMap { session in session.projectPath.map { (session.id, $0) } })
        var report = assemble(scope: scope, accounting: accounting, native: native, sourceHealth: health,
                              valid: valid, openGoals: openGoals, sessionProjects: projects)
        if normalizedAsOf == nil { report.warnings.append("The snapshot as-of timestamp is invalid.") }
        if metadata.count != overview.sessions.count || health.count != overview.sources.count {
            report.warnings.append("Malformed session or source date metadata was omitted; coverage is partial.")
            report.sourceCoverageIsPartial = true
            report.fingerprintLater()
        }
        return report
    }

    private static func assemble(scope: Scope, accounting: ActivityModelAccounting.Result, native: [NativeObservation], sourceHealth: [ActivitySourceHealth], valid: Bool,
                                 openGoals: Set<String>, sessionProjects: [String: String], sourceCoverageOverride: Bool? = nil) -> Report {
        let from = scope.from, to = scope.to
        let receipts = accounting.receipts
        let receiptNativeIDs = Set(receipts.filter { $0.includedInTotals || $0.timestamp.map { inWindow($0, from: from, to: to) } == true }
            .map { $0.provider.rawValue + ":" + $0.nativeTurnID })
        let clocks = nativePeriod(native, from: from, to: to)
        let allocatedNative = native.filter { nativeCounterFits($0, from: from, to: to) }
        let unallocatedNative = native.filter { !nativeCounterFits($0, from: from, to: to) }
        var participating = Set(receipts.filter { receipt in
            receipt.includedInTotals || receipt.timestamp.map { inWindow($0, from: from, to: to) } == true
        }.map(\.sessionID))
        for item in native { participating.insert(item.sessionID) }
        if valid { participating.formUnion(openGoals) }
        let usage = usageTotals(receipts)
        let nativeIDs = Set(native.map(\.id)).union(receiptNativeIDs)
        let counters = nativeCounters(allocatedNative, timeBasis: "native_interval_or_response_event/1")
        let unallocatedCounters = nativeCounters(unallocatedNative, timeBasis: "whole_native_observation_unallocated/1")
        let sessionGroups = Dictionary(grouping: native, by: \.sessionID)
        var sessionWork: [String: Double] = [:]
        for id in sessionGroups.keys.sorted() {
            if let seconds = nativePeriod(sessionGroups[id] ?? [], from: from, to: to).activeSeconds, seconds.isFinite { sessionWork[id] = seconds }
        }
        let durations = sessionWork.keys.sorted().compactMap { sessionWork[$0] }
        let totals = Totals(observedModelSteps: accounting.summary.totalObservedSteps, nativeRecords: nativeIDs.count, sessions: participating.count,
                            usage: usage, activeSeconds: clocks.activeSeconds, agentSeconds: clocks.agentSeconds,
                            submittedPrompts: counters.submittedPrompts, confirmedHumanPrompts: counters.confirmedHumanPrompts, toolCalls: counters.toolCalls,
                            unallocatedNativeCounters: unallocatedCounters, nativeCountersArePartial: counters.isPartial || !unallocatedNative.isEmpty,
                            modelStepsArePartial: accounting.summary.unmeasuredTurns > 0 || receipts.contains(where: { $0.countIsPartial }),
                            modelIdentities: accounting.rows.filter { $0.name != nil && $0.requests > 0 }.count,
                            timedSessions: sessionWork.count, meanSessionSeconds: ActivityMetrics.mean(durations), medianSessionSeconds: ActivityMetrics.median(durations))
        var warnings: [String] = []
        if !valid { warnings.append("The accounting window or snapshot is invalid; no measurements were included.") }
        if receipts.contains(where: { !$0.includedInTotals && $0.kind == .unplacedNativeUsage }) {
            warnings.append("Some known native usage cannot be placed inside this window; it remains in the receipt ledger, not the totals.")
        }
        if usage.tokenOverflow || usage.outputOverflow { warnings.append("A token aggregate exceeds the supported integer range and is unavailable.") }
        let sourcePartial = sourceCoverageOverride ?? (sourceHealth.isEmpty || sourceHealth.contains { !["ok", "ready"].contains($0.status.lowercased()) })
        if sourcePartial { warnings.append("Saved native history has partial or unspecified source coverage; it is not an account-wide total.") }
        var report = Report(scope: scope, modelRows: accounting.rows, summary: accounting.summary, receipts: receipts,
                      nativeObservations: native, totals: totals, warnings: warnings, isValid: valid,
                      sourceHealth: sourceHealth.sorted { $0.id < $1.id }, sourceCoverageIsPartial: sourcePartial, sessionWorkSeconds: sessionWork,
                      openGoalSessionIDs: openGoals.sorted(), participatingSessionIDs: participating.sorted(), sessionProjects: sessionProjects)
        report.fingerprintLater()
        return report
    }

    private struct QualityEvidence: Encodable {
        var id: String
        var status: String
        var checkedAt: Date?
        var lastSuccessAt: Date?
    }
    private struct ReconciliationEvidence: Encodable {
        var version = "accounting-evidence/1"
        var schemaVersion: String
        var metricDefinitionsVersion: String
        var scope: Scope
        var receipts: [ActivityAccountingReceipt]
        var nativeObservations: [NativeObservation]
        var openGoalSessionIDs: [String]
        var sessionProjects: [String: String]
        var sourceQuality: [QualityEvidence]
        var sourceCoverageIsPartial: Bool
        var valid: Bool
    }
    fileprivate static func reconciliationDigest(_ report: Report) -> String {
        let native = report.nativeObservations.sorted { $0.id < $1.id }.map { original -> NativeObservation in
            var value = original; value.artifacts.sort { $0.id < $1.id }; return value
        }
        let quality = report.sourceHealth.sorted { $0.id < $1.id }.map {
            QualityEvidence(id: $0.id, status: $0.status, checkedAt: ActivityAccountingPrecision.date($0.checkedAt),
                            lastSuccessAt: $0.lastSuccessAt.flatMap(ActivityAccountingPrecision.date))
        }
        let evidence = ReconciliationEvidence(schemaVersion: report.schemaVersion, metricDefinitionsVersion: report.metricDefinitionsVersion,
            scope: report.scope, receipts: report.receipts.sorted { $0.id < $1.id }, nativeObservations: native,
            openGoalSessionIDs: report.openGoalSessionIDs.sorted(), sessionProjects: report.sessionProjects,
            sourceQuality: quality, sourceCoverageIsPartial: report.sourceCoverageIsPartial, valid: report.isValid)
        return (try? BridgeJSON.compactEncoder.encode(evidence)).map(TraceCrypto.digest) ?? ""
    }

    private static func series(_ report: Report, granularity: ActivityAnalytics.Granularity, timeZone: TimeZone) -> Series {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let component: Calendar.Component = granularity == .hour ? .hour : .day
        let candidates = report.receipts.flatMap { [$0.timestamp, $0.intervalStart].compactMap { $0 } }
            + report.nativeObservations.flatMap { [$0.timestamp, $0.startedAt].compactMap { $0 } }
        let start = report.scope.from ?? candidates.filter(finite).min() ?? report.scope.to
        var bounds: [(Date, Date, Date)] = []
        var warnings = report.warnings
        if report.isValid, start < report.scope.to, let first = calendar.dateInterval(of: component, for: start)?.start {
            var cursor = first
            let limit = granularity == .hour ? 24 * 366 : 36_600
            while cursor < report.scope.to, bounds.count < limit {
                guard let interval = calendar.dateInterval(of: component, for: cursor), interval.end > cursor else { break }
                bounds.append((cursor, max(cursor, start), min(interval.end, report.scope.to)))
                cursor = interval.end
            }
            if cursor < report.scope.to { bounds.removeAll(); warnings.append("The requested series exceeds its bounded calendar range.") }
        }
        var assigned = [[ActivityAccountingReceipt]](repeating: [], count: bounds.count)
        var unallocated: [ActivityAccountingReceipt] = []
        let windows = bounds.map { (from: $0.1, to: $0.2) }
        for receipt in report.receipts {
            if let bucket = bucketIndex(receipt, in: windows) { assigned[bucket].append(receipt) } else { unallocated.append(receipt) }
        }
        let points = bounds.enumerated().map { index, bound -> Point in
            let native = report.nativeObservations.filter { item in
                item.timestamp.map { $0 >= bound.1 && $0 < bound.2 } == true || overlaps(item, from: bound.1, to: bound.2)
            }
            let clocks = nativePeriod(native, from: bound.1, to: bound.2)
            let nativeIDs = Set(native.map(\.id)).union(assigned[index].map { $0.provider.rawValue + ":" + $0.nativeTurnID })
            let sessionIDs = Set(native.map(\.sessionID)).union(assigned[index].map(\.sessionID))
            return Point(start: bound.0, windowStart: bound.1, end: bound.2, usage: usageTotals(assigned[index]),
                         nativeRecords: nativeIDs.count, nativeRecordIDs: nativeIDs.sorted(), sessionIDs: sessionIDs.sorted(),
                         activeSeconds: clocks.activeSeconds, agentSeconds: clocks.agentSeconds,
                         byProvider: Dictionary(grouping: assigned[index], by: { $0.provider.rawValue }).mapValues(usageTotals),
                         closedIntervalReceipts: native.filter { overlaps($0, from: bound.1, to: bound.2) }.count)
        }
        let allNativeIDs = Set(report.nativeObservations.map(\.id)).union(report.receipts.filter(\.includedInTotals).map { $0.provider.rawValue + ":" + $0.nativeTurnID })
        let plottedNativeIDs = Set(points.flatMap(\.nativeRecordIDs))
        let plottedSessions = Set(points.flatMap(\.sessionIDs))
        return Series(scope: report.scope, granularity: granularity == .hour ? "hour" : "day", timeZone: timeZone.identifier,
                      points: points, total: report.totals.usage, unallocated: usageTotals(unallocated),
                      unallocatedByProvider: Dictionary(grouping: unallocated, by: { $0.provider.rawValue }).mapValues(usageTotals),
                      unallocatedNativeRecordIDs: allNativeIDs.subtracting(plottedNativeIDs).sorted(),
                      unallocatedSessionIDs: Set(report.participatingSessionIDs).subtracting(plottedSessions).sorted(), warnings: warnings)
    }

    /// The one rule that dates a receipt into a series bucket: a provider
    /// event by its own time, a native interval only when it fits one bucket.
    private static func bucketIndex(_ receipt: ActivityAccountingReceipt, in windows: [(from: Date, to: Date)]) -> Int? {
        switch receipt.timeBasis {
        case .providerEvent:
            return receipt.timestamp.flatMap { stamp in windows.firstIndex { stamp >= $0.from && stamp < $0.to } }
        case .nativeInterval:
            guard let a = receipt.intervalStart, let b = receipt.intervalEnd, finite(a), finite(b), b >= a else { return nil }
            return windows.firstIndex { a >= $0.from && b <= $0.to && a < $0.to }
        case .unplaced:
            return nil
        }
    }

    /// Observed model steps per series bucket, for one project or session.
    public struct BucketSteps: Equatable, Sendable {
        public var steps: [Int]
        /// Whether there is any dated record in each bucket. A bucket without
        /// records is unknown, never a measured zero.
        public var hasRecords: [Bool]
    }

    /// Per-project step counts on `series`' own buckets, dated by the same
    /// rule, so a project's bars add up with the others to the series' bars.
    /// Empty key: no project folder was reported.
    public static func modelStepsByProject(_ report: Report, series: Series) -> [String: BucketSteps] {
        modelSteps(report, series: series) { report.sessionProjects[$0] ?? "" }
    }

    /// Per-session step counts on `series`' own buckets. Copied history stays
    /// with the session that owns it, as everywhere else in accounting.
    public static func modelStepsBySession(_ report: Report, series: Series) -> [String: BucketSteps] {
        modelSteps(report, series: series) { $0 }
    }

    /// O(receipts × buckets), no re-normalization; cheap enough to prepare
    /// with every report.
    private static func modelSteps(_ report: Report, series: Series, key: (String) -> String) -> [String: BucketSteps] {
        let windows = series.points.map { (from: $0.windowStart, to: $0.end) }
        guard !windows.isEmpty else { return [:] }
        var result: [String: BucketSteps] = [:]
        func entry(_ key: String) -> BucketSteps {
            result[key] ?? BucketSteps(steps: Array(repeating: 0, count: windows.count), hasRecords: Array(repeating: false, count: windows.count))
        }
        for receipt in report.receipts {
            guard let bucket = bucketIndex(receipt, in: windows) else { continue }
            let owner = key(receipt.sessionID)
            var value = entry(owner)
            if receipt.countsAsModelStep { value.steps[bucket] += 1 }
            value.hasRecords[bucket] = true
            result[owner] = value
        }
        for item in report.nativeObservations {
            let owner = key(item.sessionID)
            var value = entry(owner)
            var touched = false
            for (index, window) in windows.enumerated()
            where item.timestamp.map({ $0 >= window.from && $0 < window.to }) == true || overlaps(item, from: window.from, to: window.to) {
                value.hasRecords[index] = true; touched = true
            }
            if touched { result[owner] = value }
        }
        return result
    }

    private static func usageTotals(_ receipts: [ActivityAccountingReceipt]) -> UsageTotals {
        let records = receipts.filter { $0.includedInTotals && ($0.kind == .modelStep || $0.kind == .nativeUsageRemainder) }
        func authoritative(_ receipt: ActivityAccountingReceipt) -> Bool { receipt.usage.hasAuthoritativeProvenance }
        let tokenValues = records.map { authoritative($0) ? nonnegative($0.usage.total) : nil }
        let outputValues = records.map { authoritative($0) ? nonnegative($0.usage.output) : nil }
        let tokens = knownTotal(tokenValues), output = knownTotal(outputValues)
        let partial = records.filter { $0.usageIsPartial == true || !authoritative($0) || hasNegative($0.usage) }.count
        let incompleteness = receipts.contains { $0.countIsPartial || $0.kind == .unplacedNativeUsage }
        let composition = ActivityAnalytics.composition(usages: records.lazy.filter(authoritative).map(\.usage)).map {
            Breakdown(freshInput: $0.freshInput, rereadContext: $0.rereadContext, cacheWrites: $0.cacheWrites, output: $0.output,
                      receipts: $0.receipts, isComplete: $0.receipts == tokenValues.compactMap { $0 }.count && tokens.value == $0.total && !tokens.overflow)
        }
        let weighted = composition.flatMap { value -> Double? in
            guard value.isComplete else { return nil }
            let result = Double(value.freshInput) + Double(value.rereadContext) * 0.1 + Double(value.cacheWrites) * 1.25 + Double(value.output) * 5
            return result.isFinite ? result : nil
        }
        return UsageTotals(modelStepCount: receipts.filter(\.countsAsModelStep).count, tokensKnown: tokens.value, outputKnown: output.value,
                           usageRecords: records.count, tokenReceipts: tokenValues.compactMap { $0 }.count,
                           outputReceipts: outputValues.compactMap { $0 }.count, partialUsageRecords: partial,
                           partialTokenReceipts: records.filter { authoritative($0) && nonnegative($0.usage.total) != nil && ($0.usageIsPartial == true || $0.countIsPartial) }.count,
                           partialOutputTokenReceipts: records.filter { authoritative($0) && nonnegative($0.usage.output) != nil && ($0.usageIsPartial == true || $0.countIsPartial) }.count,
                           tokensArePartial: incompleteness || partial > 0 || tokenValues.contains(where: { $0 == nil }) || tokens.overflow,
                           outputIsPartial: incompleteness || partial > 0 || outputValues.contains(where: { $0 == nil }) || output.overflow,
                           tokenOverflow: tokens.overflow, outputOverflow: output.overflow, composition: composition, weightedHint: weighted)
    }

    private static func nativeObservations(_ sessions: [ActivitySession], selectedIDs: Set<String>, supportingIDs: Set<String>, from: Date?, to: Date) -> [NativeObservation] {
        let owned = ActivityAnalytics.ownedTurnsBySession(in: sessions)
        let parents = ActivityAnalytics.sessionParents(in: sessions)
        func depth(_ id: String) -> Int {
            var current = parents[id], seen: Set<String> = [id]
            while let parent = current, seen.insert(parent).inserted { current = parents[parent] }
            return seen.count
        }
        let ordered = sessions.sorted {
            let a = depth($0.id), b = depth($1.id)
            if a != b { return a < b }
            return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        var seen = Set<String>(), values: [NativeObservation] = []
        for session in ordered {
            for turn in owned[session.id] ?? [] {
                let identity = session.provider.rawValue + ":" + turn.id
                guard seen.insert(identity).inserted, selectedIDs.contains(session.id) else { continue }
                let stamp = ActivityAnalytics.timestamp(turn).flatMap(ActivityAccountingPrecision.date)
                let counted = stamp.map { inWindow($0, from: from, to: to) } ?? (from == nil && turn.startedAt == nil && turn.completedAt == nil)
                var observation = NativeObservation(id: identity, provider: session.provider, sessionID: session.id, timestamp: stamp,
                    startedAt: turn.startedAt.flatMap(ActivityAccountingPrecision.date), completedAt: turn.completedAt.flatMap(ActivityAccountingPrecision.date),
                    submittedPrompts: nonnegative(turn.promptCount), confirmedHumanPrompts: nonnegative(turn.humanPromptCount),
                    toolCalls: nonnegative(turn.toolCount), categories: turn.categories, artifacts: turn.artifacts, status: turn.status,
                    countedInWindow: counted, countersIncludedInWindow: false)
                observation.countedInWindow = counted || overlaps(observation, from: from, to: to) || supportingIDs.contains(identity)
                observation.countersIncludedInWindow = nativeCounterFits(observation, from: from, to: to)
                if observation.countedInWindow { values.append(observation) }
            }
        }
        return values.sorted { $0.id < $1.id }
    }

    private static func nativeCounterFits(_ value: NativeObservation, from: Date?, to: Date) -> Bool {
        if value.provider == .claude { return value.timestamp.map { inWindow($0, from: from, to: to) } ?? false }
        guard let a = value.startedAt, let b = value.completedAt, b >= a else { return false }
        return (from.map { a >= $0 } ?? true) && b < to && a < to
    }

    private static func nativeCounters(_ values: [NativeObservation], timeBasis: String) -> NativeCounters {
        let submitted = knownTotal(values.map(\.submittedPrompts)), human = knownTotal(values.map(\.confirmedHumanPrompts)), tools = knownTotal(values.map(\.toolCalls))
        let missing = values.contains { $0.submittedPrompts == nil || $0.confirmedHumanPrompts == nil || $0.toolCalls == nil }
        return NativeCounters(submittedPrompts: submitted.value, confirmedHumanPrompts: human.value, toolCalls: tools.value,
                              records: values.count, isPartial: missing || submitted.overflow || human.overflow || tools.overflow, timeBasis: timeBasis)
    }

    private static func nativePeriod(_ observations: [NativeObservation], from: Date?, to: Date) -> ActivityAnalytics.Period {
        let turns = observations.map { ActivityTurn(id: $0.id, startedAt: $0.startedAt, completedAt: $0.completedAt) }
        var value = ActivityAnalytics.period(turns, sessions: 0, from: from, to: to)
        if let active = value.activeSeconds, !active.isFinite || active < 0 { value.activeSeconds = nil }
        let groups = Dictionary(grouping: observations, by: \.sessionID)
        let perSession = groups.keys.sorted().compactMap { id -> Double? in
            let group = groups[id] ?? []
            return ActivityAnalytics.period(group.map { ActivityTurn(id: $0.id, startedAt: $0.startedAt, completedAt: $0.completedAt) }, sessions: 1, from: from, to: to).activeSeconds
        }
        let sum = perSession.reduce(0, +)
        value.agentSeconds = perSession.isEmpty || !sum.isFinite ? nil : sum
        return value
    }

    private static func overlaps(_ value: NativeObservation, from: Date?, to: Date) -> Bool {
        guard let a = value.startedAt, let b = value.completedAt, b >= a else { return false }
        if a == b { return inWindow(a, from: from, to: to) }
        return b > (from ?? .distantPast) && a < to
    }
    private static func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
    private static func inWindow(_ date: Date, from: Date?, to: Date) -> Bool { finite(date) && (from.map { date >= $0 } ?? true) && date < to }
    private static func nonnegative(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
    private static func hasNegative(_ usage: TokenUsage) -> Bool {
        [usage.input, usage.output, usage.cachedInput, usage.cacheWriteInput, usage.reasoning, usage.total].contains { ($0 ?? 0) < 0 }
    }
    private static func knownTotal(_ values: [Int?]) -> (value: Int?, overflow: Bool) {
        let known = values.compactMap(nonnegative)
        guard !known.isEmpty else { return (nil, false) }
        var total = 0
        for value in known {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return (nil, true) }
            total = next.partialValue
        }
        return (total, false)
    }
}

// New accounting DTOs explicitly encode unknown measurements as JSON null.
// This deliberately does not change legacy TokenUsage/trace serialization.
extension ActivityAccounting.Totals {
    private enum CodingKeys: String, CodingKey {
        case observedModelSteps, nativeRecords, sessions, usage, activeSeconds, agentSeconds
        case submittedPrompts, confirmedHumanPrompts, toolCalls, unallocatedNativeCounters, nativeCountersArePartial
        case modelStepsArePartial, modelIdentities, timedSessions, meanSessionSeconds, medianSessionSeconds
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observedModelSteps, forKey: .observedModelSteps); try c.encode(nativeRecords, forKey: .nativeRecords)
        try c.encode(sessions, forKey: .sessions); try c.encode(usage, forKey: .usage)
        try c.encode(activeSeconds, forKey: .activeSeconds); try c.encode(agentSeconds, forKey: .agentSeconds)
        try c.encode(submittedPrompts, forKey: .submittedPrompts); try c.encode(confirmedHumanPrompts, forKey: .confirmedHumanPrompts)
        try c.encode(toolCalls, forKey: .toolCalls); try c.encode(unallocatedNativeCounters, forKey: .unallocatedNativeCounters)
        try c.encode(nativeCountersArePartial, forKey: .nativeCountersArePartial); try c.encode(modelStepsArePartial, forKey: .modelStepsArePartial)
        try c.encode(modelIdentities, forKey: .modelIdentities); try c.encode(timedSessions, forKey: .timedSessions)
        try c.encode(meanSessionSeconds, forKey: .meanSessionSeconds); try c.encode(medianSessionSeconds, forKey: .medianSessionSeconds)
    }
}

extension ActivityAccounting.NativeCounters {
    private enum CodingKeys: String, CodingKey { case submittedPrompts, confirmedHumanPrompts, toolCalls, records, isPartial, timeBasis }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(submittedPrompts, forKey: .submittedPrompts); try c.encode(confirmedHumanPrompts, forKey: .confirmedHumanPrompts)
        try c.encode(toolCalls, forKey: .toolCalls); try c.encode(records, forKey: .records)
        try c.encode(isPartial, forKey: .isPartial); try c.encode(timeBasis, forKey: .timeBasis)
    }
}

extension ActivityAccounting.NativeObservation {
    private enum CodingKeys: String, CodingKey {
        case id, provider, sessionID, timestamp, startedAt, completedAt, submittedPrompts, confirmedHumanPrompts, toolCalls
        case categories, artifacts, status, countedInWindow, countersIncludedInWindow, timeBasis
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(provider, forKey: .provider); try c.encode(sessionID, forKey: .sessionID)
        try c.encode(timestamp, forKey: .timestamp); try c.encode(startedAt, forKey: .startedAt); try c.encode(completedAt, forKey: .completedAt)
        try c.encode(submittedPrompts, forKey: .submittedPrompts); try c.encode(confirmedHumanPrompts, forKey: .confirmedHumanPrompts)
        try c.encode(toolCalls, forKey: .toolCalls); try c.encode(categories, forKey: .categories); try c.encode(artifacts, forKey: .artifacts)
        try c.encode(status, forKey: .status); try c.encode(countedInWindow, forKey: .countedInWindow)
        try c.encode(countersIncludedInWindow, forKey: .countersIncludedInWindow); try c.encode(timeBasis, forKey: .timeBasis)
    }
}

extension ActivityAccounting.Point {
    private enum CodingKeys: String, CodingKey {
        case start, windowStart, end, usage, nativeRecords, nativeRecordIDs, sessionIDs, activeSeconds, agentSeconds, byProvider, closedIntervalReceipts
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start); try c.encode(windowStart, forKey: .windowStart); try c.encode(end, forKey: .end)
        try c.encode(usage, forKey: .usage); try c.encode(nativeRecords, forKey: .nativeRecords); try c.encode(nativeRecordIDs, forKey: .nativeRecordIDs)
        try c.encode(sessionIDs, forKey: .sessionIDs); try c.encode(activeSeconds, forKey: .activeSeconds); try c.encode(agentSeconds, forKey: .agentSeconds)
        try c.encode(byProvider, forKey: .byProvider); try c.encode(closedIntervalReceipts, forKey: .closedIntervalReceipts)
    }
}
