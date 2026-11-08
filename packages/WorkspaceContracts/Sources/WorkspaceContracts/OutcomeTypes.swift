import Foundation

/// The standard a delivered outcome is judged against. Estimates compare like
/// with like: a prototype is never priced as a production system.
public enum DeliveryStandard: String, Codable, CaseIterable, Sendable {
    case prototype
    case internalTool = "internal_tool"
    case production

    public var title: String {
        switch self {
        case .prototype: return "Prototype"
        case .internalTool: return "Useful internal tool"
        case .production: return "Production-oriented"
        }
    }
}

/// Who the comparable human is. Rate vintage is a separate setting: a 2021
/// wage doesn't make a 2021 working baseline.
public enum WorkingBaseline: String, Codable, CaseIterable, Sendable {
    /// A competent developer with 2021–2022 tools, before generative assistants.
    case historical = "historical_2021_2022"
    /// A developer using 2025–2026 coding assistants.
    case contemporary = "contemporary_2025_2026"
    /// Measured time on comparable work the user did or observed.
    case measuredComparable = "measured_comparable"

    public var title: String {
        switch self {
        case .historical: return "Developer with 2021–2022 tools"
        case .contemporary: return "Developer with 2025–2026 assistants"
        case .measuredComparable: return "Measured comparable work"
        }
    }
}

/// A pointer to existing evidence, never a copy of it.
public struct OutcomeEvidence: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case commit, session, goal, artifact }
    public var kind: Kind
    /// Repository identity for commits; nil otherwise.
    public var repositoryID: String?
    /// Commit hash, session ID, goal ID or artifact path.
    public var ref: String

    public init(kind: Kind, repositoryID: String? = nil, ref: String) {
        self.kind = kind; self.repositoryID = repositoryID; self.ref = ref
    }

    enum CodingKeys: String, CodingKey { case kind, repositoryID, ref }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind); try container.encode(repositoryID, forKey: .repositoryID); try container.encode(ref, forKey: .ref)
    }
}

/// Hands-on time the person spent. Unknown is a state, never zero, and is
/// never inferred from agent runtime.
public struct OperatorTime: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case known, unknown }
    public enum Basis: String, Codable, Sendable { case userEstimate = "user_estimate", timesheet }
    public var state: State
    public var lowHours: ExactDecimal?
    public var highHours: ExactDecimal?
    public var basis: Basis?

    public init(state: State, lowHours: ExactDecimal? = nil, highHours: ExactDecimal? = nil, basis: Basis? = nil) {
        self.state = state; self.lowHours = lowHours; self.highHours = highHours; self.basis = basis
    }

    public static let unknown = OperatorTime(state: .unknown)
    public static func known(low: ExactDecimal, high: ExactDecimal, basis: Basis = .userEstimate) -> OperatorTime {
        OperatorTime(state: .known, lowHours: low, highHours: high, basis: basis)
    }

    enum CodingKeys: String, CodingKey { case state, lowHours, highHours, basis }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state); try container.encode(lowHours, forKey: .lowHours)
        try container.encode(highHours, forKey: .highHours); try container.encode(basis, forKey: .basis)
    }

    public func validate(_ field: String) throws {
        switch state {
        case .unknown:
            guard lowHours == nil, highHours == nil, basis == nil else { throw ContractError(field, "unknown time carries no hours") }
        case .known:
            guard let low = lowHours, let high = highHours, basis != nil else { throw ContractError(field, "known time needs low and high hours and a basis") }
            guard !low.isNegative, low <= high, high <= 10_000 else { throw ContractError(field, "needs 0 ≤ low ≤ high ≤ 10000 hours") }
        }
    }
}

/// One revision of a delivered outcome. Revisions are new immutable records:
/// acceptance, rejection and later withdrawal (a regression or revert) all
/// leave the earlier records in place. Only a person's decision accepts work.
public struct AcceptedOutcomeRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchema = "accepted-outcome/1"

    public enum Decision: String, Codable, Sendable {
        case accepted, rejected
        /// Previously accepted, now reversed.
        case withdrawn
    }

    public struct Correction: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Sendable { case regression, reverted, duplicate, scopeChange = "scope_change", other }
        public var reason: Reason
        public var note: String?
        public init(reason: Reason, note: String? = nil) { self.reason = reason; self.note = note }
        enum CodingKeys: String, CodingKey { case reason, note }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(reason, forKey: .reason); try container.encode(note, forKey: .note)
        }
    }

    public var schemaVersion: String
    public var id: String
    public var outcomeID: String
    public var revision: Int
    public var supersedesID: String?
    public var createdAt: Date
    public var decision: Decision
    /// v1 accepts only a person's decision.
    public var decidedBy: String
    public var title: String
    public var summary: String?
    public var deliveryStandard: DeliveryStandard
    public var evidence: [OutcomeEvidence]
    /// When the work landed: the latest commit in the evidence, else the
    /// decision time. Reports count the outcome in the period holding it.
    public var landedAt: Date
    public var operatorTime: OperatorTime
    /// The Hub suggestion this came from, if any.
    public var candidateID: String?
    public var correction: Correction?

    public init(id: String, outcomeID: String, revision: Int = 1, supersedesID: String? = nil, createdAt: Date, decision: Decision,
                title: String, summary: String? = nil, deliveryStandard: DeliveryStandard, evidence: [OutcomeEvidence], landedAt: Date,
                operatorTime: OperatorTime = .unknown, candidateID: String? = nil, correction: Correction? = nil) {
        schemaVersion = Self.currentSchema
        self.id = id; self.outcomeID = outcomeID; self.revision = revision; self.supersedesID = supersedesID
        self.createdAt = createdAt; self.decision = decision; decidedBy = "user"; self.title = title; self.summary = summary
        self.deliveryStandard = deliveryStandard; self.evidence = evidence; self.landedAt = landedAt
        self.operatorTime = operatorTime; self.candidateID = candidateID; self.correction = correction
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, outcomeID, revision, supersedesID, createdAt, decision, decidedBy, title, summary
        case deliveryStandard, evidence, landedAt, operatorTime, candidateID, correction
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion); try container.encode(id, forKey: .id)
        try container.encode(outcomeID, forKey: .outcomeID); try container.encode(revision, forKey: .revision)
        try container.encode(supersedesID, forKey: .supersedesID); try container.encode(createdAt, forKey: .createdAt)
        try container.encode(decision, forKey: .decision); try container.encode(decidedBy, forKey: .decidedBy)
        try container.encode(title, forKey: .title); try container.encode(summary, forKey: .summary)
        try container.encode(deliveryStandard, forKey: .deliveryStandard); try container.encode(evidence, forKey: .evidence)
        try container.encode(landedAt, forKey: .landedAt); try container.encode(operatorTime, forKey: .operatorTime)
        try container.encode(candidateID, forKey: .candidateID); try container.encode(correction, forKey: .correction)
    }

    public var commitRefs: [OutcomeEvidence] { evidence.filter { $0.kind == .commit } }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema else { throw ContractError("schemaVersion", "must be \(Self.currentSchema)") }
        guard ContractText.isUUID(id), ContractText.isUUID(outcomeID) else { throw ContractError("id", "id and outcomeID are lowercase UUIDs") }
        guard (1 ... 2_048).contains(revision) else { throw ContractError("revision", "must be from 1 to 2048") }
        if revision == 1 {
            guard supersedesID == nil, outcomeID == id else { throw ContractError("supersedesID", "a first revision supersedes nothing and names its own outcome") }
        } else {
            guard let supersedesID, ContractText.isUUID(supersedesID) else { throw ContractError("supersedesID", "later revisions name the record they replace") }
        }
        guard decidedBy == "user" else { throw ContractError("decidedBy", "only a person's decision is recorded in v1") }
        guard ContractText.isLabel(title, maximum: 200) else { throw ContractError("title", "needs 1 to 200 characters") }
        if let summary { guard ContractText.isLabel(summary, maximum: 1_200) else { throw ContractError("summary", "up to 1200 characters") } }
        guard (1 ... 256).contains(evidence.count) else { throw ContractError("evidence", "needs 1 to 256 references") }
        guard Set(evidence).count == evidence.count else { throw ContractError("evidence", "references must be unique") }
        for item in evidence {
            guard ContractText.isIdentifier(item.ref) else { throw ContractError("evidence.ref", "must be a nonempty identifier") }
            if item.kind == .commit {
                guard let repository = item.repositoryID, ContractText.isIdentifier(repository) else { throw ContractError("evidence.repositoryID", "commits name their repository") }
                guard item.ref.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil else { throw ContractError("evidence.ref", "commit refs are hex hashes") }
            }
        }
        try operatorTime.validate("operatorTime")
        switch decision {
        case .withdrawn: guard correction != nil, revision > 1 else { throw ContractError("correction", "a withdrawal revises an earlier record and gives a reason") }
        case .accepted, .rejected: break
        }
        if let note = correction?.note { guard ContractText.isLabel(note, maximum: 1_200) else { throw ContractError("correction.note", "up to 1200 characters") } }
        if let candidateID { guard ContractText.isIdentifier(candidateID, maximum: 128) else { throw ContractError("candidateID", "must be a short identifier") } }
    }
}

/// An estimate of the human effort an accepted outcome represents, from one
/// assessor under one working baseline and delivery standard. Changing an
/// estimate adds a record; it never changes observed usage.
public struct EffortAssessmentRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchema = "effort-assessment/1"

    public struct Assessor: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// The person who accepted the work, or another person.
            case human
            /// A model following the economic-work-review skill.
            case model
        }
        public var kind: Kind
        /// "user", or the model's exact identity (claude-opus-5-5, gpt-6.1-terra).
        public var identity: String
        public var rubricVersion: String?
        public init(kind: Kind, identity: String, rubricVersion: String? = nil) {
            self.kind = kind; self.identity = identity; self.rubricVersion = rubricVersion
        }
        enum CodingKeys: String, CodingKey { case kind, identity, rubricVersion }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind); try container.encode(identity, forKey: .identity)
            try container.encode(rubricVersion, forKey: .rubricVersion)
        }
    }

    public enum Method: String, Codable, Sendable {
        /// A size class from the rubric, priced by the rubric's hour table.
        case sizeClass = "size_class"
        case taskBreakdown = "task_breakdown"
        case comparableWork = "comparable_work"
        case expertJudgment = "expert_judgment"
    }

    public enum Confidence: String, Codable, Sendable { case low, medium, high }

    public enum Activity: String, Codable, CaseIterable, Sendable { case discovery, implementation, testing, review, integration }

    public struct Component: Codable, Equatable, Sendable {
        public var activity: Activity
        public var hours: ExactDecimal
        public init(activity: Activity, hours: ExactDecimal) { self.activity = activity; self.hours = hours }
    }

    public var schemaVersion: String
    public var id: String
    public var outcomeID: String
    /// The outcome revision assessed; a later revision makes this stale.
    public var outcomeRevisionID: String
    public var createdAt: Date
    public var assessor: Assessor
    public var baseline: WorkingBaseline
    public var deliveryStandard: DeliveryStandard
    public var method: Method
    public var sizeClass: String?
    public var hours: EstimateRange
    public var components: [Component]?
    public var assumptions: [String]
    public var rationale: String?
    /// The assessor's own confidence; evidence coverage is reported separately.
    public var confidence: Confidence

    public init(id: String, outcomeID: String, outcomeRevisionID: String, createdAt: Date, assessor: Assessor, baseline: WorkingBaseline,
                deliveryStandard: DeliveryStandard, method: Method, sizeClass: String? = nil, hours: EstimateRange,
                components: [Component]? = nil, assumptions: [String] = [], rationale: String? = nil, confidence: Confidence) {
        schemaVersion = Self.currentSchema
        self.id = id; self.outcomeID = outcomeID; self.outcomeRevisionID = outcomeRevisionID; self.createdAt = createdAt
        self.assessor = assessor; self.baseline = baseline; self.deliveryStandard = deliveryStandard; self.method = method
        self.sizeClass = sizeClass; self.hours = hours; self.components = components; self.assumptions = assumptions
        self.rationale = rationale; self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, outcomeID, outcomeRevisionID, createdAt, assessor, baseline, deliveryStandard, method
        case sizeClass, hours, components, assumptions, rationale, confidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion); try container.encode(id, forKey: .id)
        try container.encode(outcomeID, forKey: .outcomeID); try container.encode(outcomeRevisionID, forKey: .outcomeRevisionID)
        try container.encode(createdAt, forKey: .createdAt); try container.encode(assessor, forKey: .assessor)
        try container.encode(baseline, forKey: .baseline); try container.encode(deliveryStandard, forKey: .deliveryStandard)
        try container.encode(method, forKey: .method); try container.encode(sizeClass, forKey: .sizeClass)
        try container.encode(hours, forKey: .hours); try container.encode(components, forKey: .components)
        try container.encode(assumptions, forKey: .assumptions); try container.encode(rationale, forKey: .rationale)
        try container.encode(confidence, forKey: .confidence)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema else { throw ContractError("schemaVersion", "must be \(Self.currentSchema)") }
        guard ContractText.isUUID(id), ContractText.isUUID(outcomeID), ContractText.isUUID(outcomeRevisionID) else {
            throw ContractError("id", "id, outcomeID and outcomeRevisionID are lowercase UUIDs")
        }
        guard ContractText.isIdentifier(assessor.identity, maximum: 128) else { throw ContractError("assessor.identity", "must be a short identifier") }
        if let version = assessor.rubricVersion { guard ContractText.isIdentifier(version, maximum: 64) else { throw ContractError("assessor.rubricVersion", "must be a short identifier") } }
        if assessor.kind == .model { guard assessor.rubricVersion != nil else { throw ContractError("assessor.rubricVersion", "model assessments name the rubric they followed") } }
        try hours.validate("hours")
        guard hours.high > 0, hours.high <= 100_000 else { throw ContractError("hours.high", "must be above 0 and at most 100000") }
        if method == .sizeClass {
            guard let size = sizeClass, EffortRubric.sizeIDs.contains(size), assessor.rubricVersion != nil else {
                throw ContractError("sizeClass", "size-class estimates name a rubric size (xs, s, m, l, xl) and rubric version")
            }
        } else if sizeClass != nil { throw ContractError("sizeClass", "only size-class estimates carry a size") }
        if let components {
            guard (1 ... 5).contains(components.count), Set(components.map(\.activity)).count == components.count,
                  components.allSatisfy({ !$0.hours.isNegative }) else { throw ContractError("components", "one entry per activity, nonnegative hours") }
        }
        guard assumptions.count <= 16, assumptions.allSatisfy({ ContractText.isLabel($0, maximum: 300) }) else {
            throw ContractError("assumptions", "up to 16 assumptions of up to 300 characters")
        }
        if let rationale { guard ContractText.isLabel(rationale, maximum: 1_200) else { throw ContractError("rationale", "up to 1200 characters") } }
    }
}

/// Size classes describe capability and integration complexity, not lines of
/// code. A person or model picks the class; the table turns it into hours,
/// and the assessment stores those hours, so editing the rubric later never
/// rewrites an old estimate.
public struct EffortRubric: Codable, Equatable, Sendable {
    public static let sizeIDs: Set<String> = ["xs", "s", "m", "l", "xl"]

    public struct SizeClass: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var description: String
        /// Hours for the historical baseline at the internal-tool standard.
        public var hours: EstimateRange
        public init(id: String, title: String, description: String, hours: EstimateRange) {
            self.id = id; self.title = title; self.description = description; self.hours = hours
        }
    }

    public var version: String
    public var sizes: [SizeClass]
    /// Applied to the historical hours, keyed by delivery standard.
    public var standardFactors: [String: ExactDecimal]
    /// Applied to low, base and high for a developer with 2025–2026 assistants.
    public var contemporaryFactors: EstimateRange
    public var notes: [String]

    public init(version: String, sizes: [SizeClass], standardFactors: [String: ExactDecimal], contemporaryFactors: EstimateRange, notes: [String]) {
        self.version = version; self.sizes = sizes; self.standardFactors = standardFactors
        self.contemporaryFactors = contemporaryFactors; self.notes = notes
    }

    /// Hours for a size class; nil for measured comparable work, which needs
    /// real measurements rather than a table.
    public func hours(size: String, standard: DeliveryStandard, baseline: WorkingBaseline) -> EstimateRange? {
        guard let entry = sizes.first(where: { $0.id == size }), let factor = standardFactors[standard.rawValue],
              let scaled = entry.hours.multiplied(by: factor) else { return nil }
        switch baseline {
        case .historical: return scaled.rounded(scale: 1)
        case .contemporary:
            guard let low = scaled.low.multiplied(by: contemporaryFactors.low), let base = scaled.base.multiplied(by: contemporaryFactors.base),
                  let high = scaled.high.multiplied(by: contemporaryFactors.high) else { return nil }
            return EstimateRange(low: low, base: base, high: high).rounded(scale: 1)
        case .measuredComparable: return nil
        }
    }

    public func validate() throws {
        guard ContractText.isIdentifier(version, maximum: 64) else { throw ContractError("version", "must be a short identifier") }
        guard Set(sizes.map(\.id)) == Self.sizeIDs, sizes.count == Self.sizeIDs.count else { throw ContractError("sizes", "needs exactly xs, s, m, l and xl") }
        for size in sizes { try size.hours.validate("sizes.\(size.id).hours") }
        guard Set(standardFactors.keys) == Set(DeliveryStandard.allCases.map(\.rawValue)), standardFactors.values.allSatisfy({ $0 > 0 }) else {
            throw ContractError("standardFactors", "needs a positive factor for each delivery standard")
        }
        try contemporaryFactors.validate("contemporaryFactors")
        guard contemporaryFactors.low > 0 else { throw ContractError("contemporaryFactors.low", "must be positive") }
    }
}
