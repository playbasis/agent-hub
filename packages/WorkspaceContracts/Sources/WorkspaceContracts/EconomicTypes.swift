import Foundation

/// An hourly rate with its vintage and source. A wage benchmark is not a
/// contractor's billing rate or an employer's loaded cost; `basis` says which.
public struct LaborRate: Codable, Equatable, Sendable {
    public enum Basis: String, Codable, Sendable {
        case medianWage = "median_wage"
        case userRate = "user_rate"
        case contractorRate = "contractor_rate"
        case loadedCost = "loaded_cost"
    }

    public struct Source: Codable, Equatable, Sendable {
        public var publisher: String
        public var url: String?
        public var retrieved: String?
        public init(publisher: String, url: String? = nil, retrieved: String? = nil) {
            self.publisher = publisher; self.url = url; self.retrieved = retrieved
        }
    }

    public var id: String
    public var label: String
    public var hourly: MoneyAmount
    /// When the rate applied, such as "May 2025".
    public var vintage: String
    public var region: String?
    public var basis: Basis
    /// How the hourly figure was obtained, when it isn't published as such.
    public var derivation: String?
    public var source: Source?

    public init(id: String, label: String, hourly: MoneyAmount, vintage: String, region: String? = nil, basis: Basis,
                derivation: String? = nil, source: Source? = nil) {
        self.id = id; self.label = label; self.hourly = hourly; self.vintage = vintage; self.region = region
        self.basis = basis; self.derivation = derivation; self.source = source
    }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil else { throw ContractError("rate.id", "must be a lowercase slug") }
        guard ContractText.isLabel(label, maximum: 120), ContractText.isLabel(vintage, maximum: 40) else { throw ContractError("rate.label", "label and vintage are required") }
        try hourly.validate("rate.hourly")
        guard hourly.amount > 0 else { throw ContractError("rate.hourly", "must be positive") }
    }
}

/// A plan the person pays for. Its monthly price is spread over the days a
/// report covers; the same subscription is never counted twice.
public struct ToolSubscription: Codable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var label: String
    public var monthly: MoneyAmount
    public var from: Date?
    public var to: Date?

    public init(id: String, provider: String, label: String, monthly: MoneyAmount, from: Date? = nil, to: Date? = nil) {
        self.id = id; self.provider = provider; self.label = label; self.monthly = monthly; self.from = from; self.to = to
    }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil else { throw ContractError("subscription.id", "must be a lowercase slug") }
        guard provider.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else { throw ContractError("subscription.provider", "must be a lowercase slug") }
        guard ContractText.isLabel(label, maximum: 120) else { throw ContractError("subscription.label", "is required") }
        try monthly.validate("subscription.monthly")
        if let from, let to { guard from < to else { throw ContractError("subscription", "from must precede to") } }
    }
}

/// Everything a person chose that turns measurements into economics. A new
/// choice is a new revision and a new report; receipts never change.
public struct EconomicAssumptions: Codable, Equatable, Sendable {
    public var baseline: WorkingBaseline
    public var rateID: String
    /// Rate for the person's own hands-on time; nil uses `rateID`.
    public var operatorRateID: String?
    public var customRates: [LaborRate]
    public var hoursPerDay: ExactDecimal
    /// IANA zone for calendar periods (day, week, month, year).
    public var timeZone: String
    public var subscriptions: [ToolSubscription]

    public init(baseline: WorkingBaseline = .historical, rateID: String, operatorRateID: String? = nil, customRates: [LaborRate] = [],
                hoursPerDay: ExactDecimal = 8, timeZone: String, subscriptions: [ToolSubscription] = []) {
        self.baseline = baseline; self.rateID = rateID; self.operatorRateID = operatorRateID; self.customRates = customRates
        self.hoursPerDay = hoursPerDay; self.timeZone = timeZone; self.subscriptions = subscriptions
    }

    public func validate() throws {
        guard ContractText.isIdentifier(rateID, maximum: 64) else { throw ContractError("rateID", "is required") }
        guard hoursPerDay > 0, hoursPerDay <= 24 else { throw ContractError("hoursPerDay", "must be above 0 and at most 24") }
        guard TimeZone(identifier: timeZone) != nil else { throw ContractError("timeZone", "must be an IANA time zone") }
        guard customRates.count <= 32, subscriptions.count <= 32 else { throw ContractError("assumptions", "up to 32 rates and 32 subscriptions") }
        for rate in customRates { try rate.validate() }
        for subscription in subscriptions { try subscription.validate() }
        guard Set(customRates.map(\.id)).count == customRates.count, Set(subscriptions.map(\.id)).count == subscriptions.count else {
            throw ContractError("assumptions", "rate and subscription ids must be unique")
        }
    }
}

/// One revision of the assumptions, stored like outcomes: append-only.
public struct EconomicAssumptionsRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchema = "economic-assumptions/1"
    public var schemaVersion: String
    public var id: String
    public var revision: Int
    public var supersedesID: String?
    public var createdAt: Date
    public var assumptions: EconomicAssumptions

    public init(id: String, revision: Int, supersedesID: String?, createdAt: Date, assumptions: EconomicAssumptions) {
        schemaVersion = Self.currentSchema
        self.id = id; self.revision = revision; self.supersedesID = supersedesID; self.createdAt = createdAt; self.assumptions = assumptions
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema else { throw ContractError("schemaVersion", "must be \(Self.currentSchema)") }
        guard ContractText.isUUID(id), (1 ... 4_096).contains(revision) else { throw ContractError("id", "needs a UUID and a revision from 1 to 4096") }
        guard (revision == 1) == (supersedesID == nil), supersedesID.map(ContractText.isUUID) ?? true else { throw ContractError("supersedesID", "only later revisions supersede") }
        try assumptions.validate()
    }
}

public struct MoneyRange: Codable, Hashable, Sendable {
    public var currency: String
    public var low: ExactDecimal
    public var base: ExactDecimal
    public var high: ExactDecimal
    public init(currency: String, range: EstimateRange) {
        self.currency = currency; low = range.low; base = range.base; high = range.high
    }
    public var range: EstimateRange { EstimateRange(low: low, base: base, high: high) }
}

public struct LineCounts: Codable, Hashable, Sendable {
    public var additions: Int
    public var deletions: Int
    public init(additions: Int = 0, deletions: Int = 0) { self.additions = additions; self.deletions = deletions }
}

/// The economics of AI-assisted work for one period and scope: what was spent,
/// what landed and was accepted, and what comparable human effort it might
/// represent. Every number comes from the frozen accounting snapshot, the
/// outcome ledger or a stated assumption; nothing here is recomputed by a UI,
/// prompt or export. Optional fields that are absent mean unknown, never zero.
public struct EconomicReport: Codable, Equatable, Sendable {
    public static let currentSchema = "economic-report/1"
    /// Fields outside the report identity.
    public static let unidentifiedKeys: Set<String> = ["reportID", "generatedAt"]

    public enum ContentLevel: String, Codable, Sendable {
        /// Titles, commit subjects, repository names and paths, for this Mac.
        case local
        /// Labels, paths and identifiers replaced, for sharing.
        case sanitized
    }

    public struct Period: Codable, Equatable, Sendable {
        public enum Granularity: String, Codable, Sendable { case day, week, month, year, rolling, custom, all }
        /// Half-open [from, to). nil means all saved history.
        public var from: Date?
        public var to: Date
        public var timeZone: String
        public var granularity: Granularity
        public var label: String
        public init(from: Date?, to: Date, timeZone: String, granularity: Granularity, label: String) {
            self.from = from; self.to = to; self.timeZone = timeZone; self.granularity = granularity; self.label = label
        }
    }

    public struct ProjectRef: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var path: String?
        public init(id: String, name: String, path: String? = nil) { self.id = id; self.name = name; self.path = path }
    }

    public struct Scope: Codable, Equatable, Sendable {
        /// Repositories in scope (all scanned ones when no project is chosen).
        public var projects: [ProjectRef]
        public var projectFilter: String?
        public var provider: String?
        public var sessions: Int
        public init(projects: [ProjectRef], projectFilter: String?, provider: String?, sessions: Int) {
            self.projects = projects; self.projectFilter = projectFilter; self.provider = provider; self.sessions = sessions
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var asOf: Date
        public var accountingSchema: String
        public var metricDefinitions: String
        /// sha256 over the accounting/1 scope (window, as-of, session IDs) and
        /// its totals: equal fingerprints mean the same accounting result.
        /// Per-receipt evidence travels in a bundle's receipts.jsonl.
        public var accountingFingerprint: String
        public var repositoriesScannedAt: Date?
        public var sourceCoverageIsPartial: Bool
        public init(asOf: Date, accountingSchema: String, metricDefinitions: String, accountingFingerprint: String,
                    repositoriesScannedAt: Date?, sourceCoverageIsPartial: Bool) {
            self.asOf = asOf; self.accountingSchema = accountingSchema; self.metricDefinitions = metricDefinitions
            self.accountingFingerprint = accountingFingerprint; self.repositoriesScannedAt = repositoriesScannedAt
            self.sourceCoverageIsPartial = sourceCoverageIsPartial
        }
    }

    public struct Composition: Codable, Equatable, Sendable {
        public var freshInput: TokenQuantity
        public var rereadContext: TokenQuantity
        public var cacheWrites: TokenQuantity
        public var output: TokenQuantity
        public init(freshInput: TokenQuantity, rereadContext: TokenQuantity, cacheWrites: TokenQuantity, output: TokenQuantity) {
            self.freshInput = freshInput; self.rereadContext = rereadContext; self.cacheWrites = cacheWrites; self.output = output
        }
    }

    public struct ProviderUsage: Codable, Equatable, Sendable {
        public var provider: String
        public var tokens: TokenQuantity?
        public var outputTokens: TokenQuantity?
        public var modelSteps: Int
        public var sessions: Int
        public init(provider: String, tokens: TokenQuantity?, outputTokens: TokenQuantity?, modelSteps: Int, sessions: Int) {
            self.provider = provider; self.tokens = tokens; self.outputTokens = outputTokens; self.modelSteps = modelSteps; self.sessions = sessions
        }
    }

    public struct ModelUsage: Codable, Equatable, Sendable {
        public var provider: String
        public var model: String?
        public var tokens: TokenQuantity?
        public var outputTokens: TokenQuantity?
        public var modelSteps: Int
        public init(provider: String, model: String?, tokens: TokenQuantity?, outputTokens: TokenQuantity?, modelSteps: Int) {
            self.provider = provider; self.model = model; self.tokens = tokens; self.outputTokens = outputTokens; self.modelSteps = modelSteps
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        /// Always local_native_history: account and plan counters are other populations.
        public var scope: String
        public var tokens: TokenQuantity?
        public var outputTokens: TokenQuantity?
        public var tokensArePartial: Bool
        public var composition: Composition?
        /// Share of tokens that were context re-sent from cache, 0–1.
        public var rereadShare: ExactDecimal?
        public var modelSteps: Int
        public var sessions: Int
        public var byProvider: [ProviderUsage]
        public var byModel: [ModelUsage]
        public init(scope: String, tokens: TokenQuantity?, outputTokens: TokenQuantity?, tokensArePartial: Bool, composition: Composition?,
                    rereadShare: ExactDecimal?, modelSteps: Int, sessions: Int, byProvider: [ProviderUsage], byModel: [ModelUsage]) {
            self.scope = scope; self.tokens = tokens; self.outputTokens = outputTokens; self.tokensArePartial = tokensArePartial
            self.composition = composition; self.rereadShare = rereadShare; self.modelSteps = modelSteps; self.sessions = sessions
            self.byProvider = byProvider; self.byModel = byModel
        }
    }

    public struct OperatorSummary: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case known, partial, unknown }
        public var state: State
        /// Sum over accepted outcomes that have time; base is the midpoint.
        public var hours: EstimateRange?
        public var outcomesWithTime: Int
        public var outcomesWithoutTime: Int
        public init(state: State, hours: EstimateRange?, outcomesWithTime: Int, outcomesWithoutTime: Int) {
            self.state = state; self.hours = hours; self.outcomesWithTime = outcomesWithTime; self.outcomesWithoutTime = outcomesWithoutTime
        }
    }

    /// Recorded agent time is not human effort, and provider compute time is
    /// never reported, so those stay unknown.
    public struct TimeSummary: Codable, Equatable, Sendable {
        /// Union of recorded intervals: when any agent was working.
        public var activeSeconds: Int?
        /// Per-session unions summed: parallel agents add up.
        public var agentSeconds: Int?
        public var localCPUSeconds: Int?
        public var providerComputeSeconds: Int?
        public var operatorTime: OperatorSummary
        public init(activeSeconds: Int?, agentSeconds: Int?, operatorTime: OperatorSummary) {
            self.activeSeconds = activeSeconds; self.agentSeconds = agentSeconds; self.operatorTime = operatorTime
        }
    }

    public struct ToolingCost: Codable, Equatable, Sendable {
        public var subscriptionID: String
        public var provider: String
        public var label: String
        public var amount: MoneyAmount
        /// "200 USD a month × 7.0 of 30.44 days × 62.5% of tokens".
        public var calculation: String
        public init(subscriptionID: String, provider: String, label: String, amount: MoneyAmount, calculation: String) {
            self.subscriptionID = subscriptionID; self.provider = provider; self.label = label; self.amount = amount; self.calculation = calculation
        }
    }

    public struct Costs: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case known, unknown, mixedCurrencies = "mixed_currencies" }
        public enum Allocation: String, Codable, Sendable {
            /// Everything the subscriptions cost in the period.
            case wholePeriod = "whole_period"
            /// The scope's share of the period's known tokens.
            case tokenShare = "token_share"
        }
        public var state: State
        public var allocation: Allocation
        public var allocationShare: ExactDecimal?
        public var tooling: [ToolingCost]
        public var total: MoneyAmount?
        public init(state: State, allocation: Allocation, allocationShare: ExactDecimal?, tooling: [ToolingCost], total: MoneyAmount?) {
            self.state = state; self.allocation = allocation; self.allocationShare = allocationShare; self.tooling = tooling; self.total = total
        }
    }

    public struct OutcomeEffort: Codable, Equatable, Sendable {
        public var baseline: WorkingBaseline
        public var hours: EstimateRange
        public var assessor: EffortAssessmentRecord.Assessor
        public var assessmentID: String
        public var method: EffortAssessmentRecord.Method
        public var sizeClass: String?
        public var confidence: EffortAssessmentRecord.Confidence
        /// Assessments for this outcome and baseline, by anyone.
        public var assessments: Int
        /// Lowest low to highest high across them.
        public var spread: EstimateRange
        /// Base estimates differ by more than half.
        public var disagreement: Bool
        /// Assessed against an earlier revision of the outcome.
        public var stale: Bool
        public init(baseline: WorkingBaseline, hours: EstimateRange, assessor: EffortAssessmentRecord.Assessor, assessmentID: String,
                    method: EffortAssessmentRecord.Method, sizeClass: String?, confidence: EffortAssessmentRecord.Confidence,
                    assessments: Int, spread: EstimateRange, disagreement: Bool, stale: Bool) {
            self.baseline = baseline; self.hours = hours; self.assessor = assessor; self.assessmentID = assessmentID; self.method = method
            self.sizeClass = sizeClass; self.confidence = confidence; self.assessments = assessments; self.spread = spread
            self.disagreement = disagreement; self.stale = stale
        }
    }

    public struct OutcomeItem: Codable, Equatable, Sendable {
        public var outcomeID: String
        public var revisionID: String
        public var title: String
        public var summary: String?
        public var deliveryStandard: DeliveryStandard
        public var landedAt: Date
        public var repositories: [String]
        public var commits: Int
        /// Lines of the evidence commits found in the last scan.
        public var lines: LineCounts?
        public var sessions: Int
        /// Evidence commits that a later commit in the scan reverts.
        public var revertedCommits: Int
        public var evidence: [OutcomeEvidence]
        public var operatorTime: OperatorTime
        public var effort: OutcomeEffort?
        public init(outcomeID: String, revisionID: String, title: String, summary: String?, deliveryStandard: DeliveryStandard, landedAt: Date,
                    repositories: [String], commits: Int, lines: LineCounts?, sessions: Int, revertedCommits: Int = 0, evidence: [OutcomeEvidence],
                    operatorTime: OperatorTime, effort: OutcomeEffort?) {
            self.outcomeID = outcomeID; self.revisionID = revisionID; self.title = title; self.summary = summary
            self.deliveryStandard = deliveryStandard; self.landedAt = landedAt; self.repositories = repositories; self.commits = commits
            self.lines = lines; self.sessions = sessions; self.revertedCommits = revertedCommits; self.evidence = evidence
            self.operatorTime = operatorTime; self.effort = effort
        }
    }

    public struct CandidateItem: Codable, Equatable, Sendable {
        public var candidateID: String
        public var title: String
        public var repositories: [String]
        public var commits: Int
        public var lines: LineCounts
        public var sessions: Int
        public var firstCommitAt: Date
        public var lastCommitAt: Date
        public init(candidateID: String, title: String, repositories: [String], commits: Int, lines: LineCounts, sessions: Int,
                    firstCommitAt: Date, lastCommitAt: Date) {
            self.candidateID = candidateID; self.title = title; self.repositories = repositories; self.commits = commits
            self.lines = lines; self.sessions = sessions; self.firstCommitAt = firstCommitAt; self.lastCommitAt = lastCommitAt
        }
    }

    public struct CorrectionItem: Codable, Equatable, Sendable {
        public var outcomeID: String
        public var title: String
        public var reason: AcceptedOutcomeRecord.Correction.Reason
        public var landedAt: Date
        public var withdrawnAt: Date
        public init(outcomeID: String, title: String, reason: AcceptedOutcomeRecord.Correction.Reason, landedAt: Date, withdrawnAt: Date) {
            self.outcomeID = outcomeID; self.title = title; self.reason = reason; self.landedAt = landedAt; self.withdrawnAt = withdrawnAt
        }
    }

    public struct Outcomes: Codable, Equatable, Sendable {
        public var accepted: Int
        /// Rejected in this period (decision time).
        public var rejected: Int
        public var pendingCandidates: Int
        public var commitsInPeriod: Int
        public var commitsInAcceptedOutcomes: Int
        public var linesInPeriod: LineCounts
        public var items: [OutcomeItem]
        /// Up to 50 suggestions still waiting for a decision.
        public var pending: [CandidateItem]
        /// Accepted work withdrawn in this period, whenever it landed.
        public var corrections: [CorrectionItem]
        public init(accepted: Int, rejected: Int, pendingCandidates: Int, commitsInPeriod: Int, commitsInAcceptedOutcomes: Int,
                    linesInPeriod: LineCounts, items: [OutcomeItem], pending: [CandidateItem], corrections: [CorrectionItem]) {
            self.accepted = accepted; self.rejected = rejected; self.pendingCandidates = pendingCandidates; self.commitsInPeriod = commitsInPeriod
            self.commitsInAcceptedOutcomes = commitsInAcceptedOutcomes; self.linesInPeriod = linesInPeriod; self.items = items
            self.pending = pending; self.corrections = corrections
        }
    }

    public struct Effort: Codable, Equatable, Sendable {
        public var baseline: WorkingBaseline
        public var rubricVersion: String
        public var hoursPerDay: ExactDecimal
        public var estimatedOutcomes: Int
        public var unestimatedOutcomes: Int
        /// Sum over estimated outcomes only.
        public var hours: EstimateRange?
        public var personDays: EstimateRange?
        public init(baseline: WorkingBaseline, rubricVersion: String, hoursPerDay: ExactDecimal, estimatedOutcomes: Int, unestimatedOutcomes: Int,
                    hours: EstimateRange?, personDays: EstimateRange?) {
            self.baseline = baseline; self.rubricVersion = rubricVersion; self.hoursPerDay = hoursPerDay; self.estimatedOutcomes = estimatedOutcomes
            self.unestimatedOutcomes = unestimatedOutcomes; self.hours = hours; self.personDays = personDays
        }
    }

    public struct Economics: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            /// Every input is known.
            case available
            /// Wage-equivalent known, net benefit not.
            case partial
            case unavailable
        }
        public var state: State
        /// Codes of inputs that keep net benefit unknown.
        public var missing: [String]
        public var rate: LaborRate
        public var operatorRate: LaborRate
        /// Estimated hours × rate. A wage equivalent: not revenue, market value or cash saved.
        public var grossLaborEquivalent: MoneyRange?
        public var operatorCost: MoneyRange?
        public var toolingCost: MoneyAmount?
        /// Gross − operator cost − tooling, pessimistic low and optimistic high.
        public var netOpportunity: MoneyRange?
        /// Estimated human hours ÷ the person's hands-on hours.
        public var leverage: EstimateRange?
        public init(state: State, missing: [String], rate: LaborRate, operatorRate: LaborRate, grossLaborEquivalent: MoneyRange?,
                    operatorCost: MoneyRange?, toolingCost: MoneyAmount?, netOpportunity: MoneyRange?, leverage: EstimateRange?) {
            self.state = state; self.missing = missing; self.rate = rate; self.operatorRate = operatorRate
            self.grossLaborEquivalent = grossLaborEquivalent; self.operatorCost = operatorCost; self.toolingCost = toolingCost
            self.netOpportunity = netOpportunity; self.leverage = leverage
        }
    }

    public struct Friction: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case sessionsWithoutCommits = "sessions_without_commits"
            case contextReread = "context_reread"
            case revertedCommits = "reverted_commits"
            case rejectedOutcomes = "rejected_outcomes"
            case unlinkedCommits = "unlinked_commits"
        }
        public var kind: Kind
        public var count: Int
        public var tokens: TokenQuantity?
        public var share: ExactDecimal?
        public var detail: String
        /// Up to 20 session IDs or commit hashes behind it.
        public var evidence: [String]
        public init(kind: Kind, count: Int, tokens: TokenQuantity? = nil, share: ExactDecimal? = nil, detail: String, evidence: [String] = []) {
            self.kind = kind; self.count = count; self.tokens = tokens; self.share = share; self.detail = detail; self.evidence = evidence
        }
    }

    public struct Note: Codable, Equatable, Sendable {
        public var code: String
        public var message: String
        public init(code: String, message: String) { self.code = code; self.message = message }
    }

    public var schemaVersion: String
    public var reportID: String
    public var generatedAt: Date
    public var contentLevel: ContentLevel
    public var period: Period
    public var scope: Scope
    public var snapshot: Snapshot
    public var usage: Usage
    public var time: TimeSummary
    public var costs: Costs
    public var outcomes: Outcomes
    public var effort: Effort
    public var economics: Economics
    public var friction: [Friction]
    public var uncertainty: [Note]
    /// A concrete instruction for the next work cycle, built from the report.
    public var nextPrompt: String
    public var assumptions: EconomicAssumptions

    public init(generatedAt: Date, contentLevel: ContentLevel, period: Period, scope: Scope, snapshot: Snapshot, usage: Usage,
                time: TimeSummary, costs: Costs, outcomes: Outcomes, effort: Effort, economics: Economics, friction: [Friction],
                uncertainty: [Note], nextPrompt: String, assumptions: EconomicAssumptions) {
        schemaVersion = Self.currentSchema; reportID = ""
        self.generatedAt = generatedAt; self.contentLevel = contentLevel; self.period = period; self.scope = scope
        self.snapshot = snapshot; self.usage = usage; self.time = time; self.costs = costs; self.outcomes = outcomes
        self.effort = effort; self.economics = economics; self.friction = friction; self.uncertainty = uncertainty
        self.nextPrompt = nextPrompt; self.assumptions = assumptions
    }

    /// Identity of the content: the same facts and assumptions give the same
    /// ID whenever they're built; any change gives a new one.
    public func computedID() throws -> String { try ContractDigest.of(self, removing: Self.unidentifiedKeys) }

    public func identified() throws -> EconomicReport {
        var value = self
        value.reportID = try computedID()
        return value
    }
}
