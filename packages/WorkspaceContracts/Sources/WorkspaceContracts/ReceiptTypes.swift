import Foundation

/// One observation of agent work: a model step, a conversation turn, a request
/// attempt or a session total, as a source saw it. The same logical event can
/// be observed again (`revision`), and `contentDigest` makes a replay of the
/// same observation recognisable. Receipts never carry prompts, tool payloads,
/// reasoning text or credentials.
public struct WorkspaceReceipt: Codable, Equatable, Sendable {
    public static let currentSchema = "workspace-receipt/1"
    /// Fields outside the digested content.
    public static let undigestedKeys: Set<String> = ["revision", "observedAt", "contentDigest"]

    public enum Unit: String, Codable, CaseIterable, Sendable {
        /// One model response (a usage checkpoint with its own identity).
        case modelStep = "model_step"
        /// One conversation turn, which can contain many model steps.
        case conversationTurn = "conversation_turn"
        /// One API request attempt, including retries that produced no turn.
        case requestAttempt = "request_attempt"
        /// A whole-session total.
        case session
    }

    public enum Accumulation: String, Codable, Sendable {
        /// Usage of this unit alone.
        case incremental
        /// A running total since the start of the session's series.
        case cumulative
    }

    /// The population a measurement describes. Different scopes are never added.
    public enum Scope: String, Codable, CaseIterable, Sendable {
        case localNativeHistory = "local_native_history"
        case providerAccount = "provider_account"
        case providerPlanWindow = "provider_plan_window"
        case nativeGoal = "native_goal"
        case bridgeSession = "bridge_session"
        case directProviderResponse = "direct_provider_response"
        case repositoryHistory = "repository_history"
    }

    public enum Provenance: String, Codable, Sendable {
        case providerReported = "provider_reported"
        case derived, estimated, unavailable
        /// Only reported or derived values enter known totals.
        public var isAuthoritative: Bool { self == .providerReported || self == .derived }
    }

    public enum Completeness: String, Codable, Sendable { case complete, partial, unknown }

    public struct Producer: Codable, Equatable, Sendable {
        public var adapter: String
        public var adapterVersion: String
        public init(adapter: String, adapterVersion: String) { self.adapter = adapter; self.adapterVersion = adapterVersion }
    }

    public struct Time: Codable, Equatable, Sendable {
        public enum Basis: String, Codable, Sendable {
            /// `at` is when the provider recorded the event.
            case providerEvent = "provider_event"
            /// Only the containing native interval (`start`…`end`) is known.
            case nativeInterval = "native_interval"
            /// Known usage that can't be placed in time.
            case unplaced
        }
        public var basis: Basis
        public var at: Date?
        public var start: Date?
        public var end: Date?
        public init(basis: Basis, at: Date? = nil, start: Date? = nil, end: Date? = nil) {
            self.basis = basis; self.at = at; self.start = start; self.end = end
        }
        enum CodingKeys: String, CodingKey { case basis, at, start, end }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(basis, forKey: .basis); try container.encode(at, forKey: .at)
            try container.encode(start, forKey: .start); try container.encode(end, forKey: .end)
        }
    }

    /// Provider fields as reported. `total` and `output` are the canonical
    /// sums; `input` follows the provider's convention, which
    /// `inputIncludesCachedInput` states (Codex includes cache reads in input,
    /// Claude doesn't). `cachedInput` and `reasoning` are subsets, never added.
    public struct Usage: Codable, Equatable, Sendable {
        public var input: TokenQuantity?
        public var cachedInput: TokenQuantity?
        public var cacheWriteInput: TokenQuantity?
        public var output: TokenQuantity?
        public var reasoning: TokenQuantity?
        public var total: TokenQuantity?
        public var inputIncludesCachedInput: Bool?
        public var provenance: Provenance
        public var completeness: Completeness
        public init(input: TokenQuantity? = nil, cachedInput: TokenQuantity? = nil, cacheWriteInput: TokenQuantity? = nil,
                    output: TokenQuantity? = nil, reasoning: TokenQuantity? = nil, total: TokenQuantity? = nil,
                    inputIncludesCachedInput: Bool? = nil, provenance: Provenance, completeness: Completeness) {
            self.input = input; self.cachedInput = cachedInput; self.cacheWriteInput = cacheWriteInput; self.output = output
            self.reasoning = reasoning; self.total = total; self.inputIncludesCachedInput = inputIncludesCachedInput
            self.provenance = provenance; self.completeness = completeness
        }
        enum CodingKeys: String, CodingKey {
            case input, cachedInput, cacheWriteInput, output, reasoning, total, inputIncludesCachedInput, provenance, completeness
        }
        /// Unknown stays an explicit null on the wire.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(input, forKey: .input); try container.encode(cachedInput, forKey: .cachedInput)
            try container.encode(cacheWriteInput, forKey: .cacheWriteInput); try container.encode(output, forKey: .output)
            try container.encode(reasoning, forKey: .reasoning); try container.encode(total, forKey: .total)
            try container.encode(inputIncludesCachedInput, forKey: .inputIncludesCachedInput)
            try container.encode(provenance, forKey: .provenance); try container.encode(completeness, forKey: .completeness)
        }
    }

    /// Counts recorded for the whole unit. They are aggregates: a reader must
    /// not turn them into individual tool executions or prompts.
    public struct Aggregates: Codable, Equatable, Sendable {
        public var toolCalls: Int?
        public var submittedPrompts: Int?
        public var confirmedHumanPrompts: Int?
        public init(toolCalls: Int? = nil, submittedPrompts: Int? = nil, confirmedHumanPrompts: Int? = nil) {
            self.toolCalls = toolCalls; self.submittedPrompts = submittedPrompts; self.confirmedHumanPrompts = confirmedHumanPrompts
        }
        enum CodingKeys: String, CodingKey { case toolCalls, submittedPrompts, confirmedHumanPrompts }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(toolCalls, forKey: .toolCalls); try container.encode(submittedPrompts, forKey: .submittedPrompts)
            try container.encode(confirmedHumanPrompts, forKey: .confirmedHumanPrompts)
        }
    }

    public var schemaVersion: String
    /// Stable logical identity, namespaced by the producer.
    public var eventID: String
    /// Observation revision: a later observation with different content is
    /// a higher revision and supersedes the lower one.
    public var revision: Int
    public var contentDigest: String
    public var observedAt: Date
    public var producer: Producer
    /// Lowercase provider slug: claude, codex, grok, gemini or another name.
    public var provider: String
    /// Provider-prefixed session identity.
    public var sessionID: String
    public var nativeTurnID: String?
    public var unit: Unit
    public var accumulation: Accumulation
    public var scope: Scope
    public var time: Time
    public var model: String?
    public var effort: String?
    public var usage: Usage
    public var aggregates: Aggregates?
    public var projectPath: String?
    /// False keeps a receipt in the ledger without entering totals (for
    /// example usage that can't be placed in the reporting window).
    public var includedInTotals: Bool
    /// Short label of the evidence class, such as `native_model_step/1`.
    public var evidence: String

    public init(eventID: String, revision: Int = 1, observedAt: Date, producer: Producer, provider: String, sessionID: String,
                nativeTurnID: String? = nil, unit: Unit, accumulation: Accumulation = .incremental, scope: Scope = .localNativeHistory,
                time: Time, model: String? = nil, effort: String? = nil, usage: Usage, aggregates: Aggregates? = nil,
                projectPath: String? = nil, includedInTotals: Bool = true, evidence: String) {
        schemaVersion = Self.currentSchema
        self.eventID = eventID; self.revision = revision; contentDigest = ""; self.observedAt = observedAt
        self.producer = producer; self.provider = provider; self.sessionID = sessionID; self.nativeTurnID = nativeTurnID
        self.unit = unit; self.accumulation = accumulation; self.scope = scope; self.time = time; self.model = model
        self.effort = effort; self.usage = usage; self.aggregates = aggregates; self.projectPath = projectPath
        self.includedInTotals = includedInTotals; self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, eventID, revision, contentDigest, observedAt, producer, provider, sessionID, nativeTurnID
        case unit, accumulation, scope, time, model, effort, usage, aggregates, projectPath, includedInTotals, evidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion); try container.encode(eventID, forKey: .eventID)
        try container.encode(revision, forKey: .revision); try container.encode(contentDigest, forKey: .contentDigest)
        try container.encode(observedAt, forKey: .observedAt); try container.encode(producer, forKey: .producer)
        try container.encode(provider, forKey: .provider); try container.encode(sessionID, forKey: .sessionID)
        try container.encode(nativeTurnID, forKey: .nativeTurnID); try container.encode(unit, forKey: .unit)
        try container.encode(accumulation, forKey: .accumulation); try container.encode(scope, forKey: .scope)
        try container.encode(time, forKey: .time); try container.encode(model, forKey: .model)
        try container.encode(effort, forKey: .effort); try container.encode(usage, forKey: .usage)
        try container.encode(aggregates, forKey: .aggregates); try container.encode(projectPath, forKey: .projectPath)
        try container.encode(includedInTotals, forKey: .includedInTotals); try container.encode(evidence, forKey: .evidence)
    }

    /// The digest of everything except revision, observation time, the digest
    /// itself and `x-` extensions.
    public func computedDigest() throws -> String { try ContractDigest.of(self, removing: Self.undigestedKeys) }

    /// A copy with `contentDigest` filled in.
    public func sealed() throws -> WorkspaceReceipt {
        var value = self
        value.contentDigest = try computedDigest()
        return value
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema else { throw ContractError("schemaVersion", "must be \(Self.currentSchema)") }
        guard ContractText.isIdentifier(eventID) else { throw ContractError("eventID", "must be a nonempty identifier up to 512 bytes") }
        guard (1 ... 1_000_000).contains(revision) else { throw ContractError("revision", "must be from 1 to 1000000") }
        guard ContractText.isDigest(contentDigest), contentDigest == (try? computedDigest()) else { throw ContractError("contentDigest", "doesn't match the receipt content") }
        guard ContractText.isIdentifier(producer.adapter, maximum: 128), ContractText.isIdentifier(producer.adapterVersion, maximum: 64) else {
            throw ContractError("producer", "needs an adapter name and version")
        }
        guard provider.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else { throw ContractError("provider", "must be a lowercase slug") }
        guard ContractText.isIdentifier(sessionID) else { throw ContractError("sessionID", "must be a nonempty identifier") }
        if let nativeTurnID { guard ContractText.isIdentifier(nativeTurnID) else { throw ContractError("nativeTurnID", "must be a nonempty identifier") } }
        guard ContractText.isIdentifier(evidence, maximum: 128) else { throw ContractError("evidence", "must be a short label") }
        switch time.basis {
        case .providerEvent: guard time.at != nil else { throw ContractError("time.at", "is required for provider events") }
        case .nativeInterval: guard time.start != nil || time.end != nil else { throw ContractError("time", "a native interval needs a start or an end") }
        case .unplaced: guard time.at == nil else { throw ContractError("time.at", "must be null for unplaced usage") }
        }
        if let start = time.start, let end = time.end { guard start <= end else { throw ContractError("time", "start must not follow end") } }
        if time.basis == .unplaced { guard !includedInTotals else { throw ContractError("includedInTotals", "unplaced usage can't enter windowed totals") } }
        if accumulation == .cumulative { guard time.at != nil else { throw ContractError("time.at", "cumulative checkpoints need a time to order them") } }
        for count in [aggregates?.toolCalls, aggregates?.submittedPrompts, aggregates?.confirmedHumanPrompts] {
            if let count { guard (0 ... 9_007_199_254_740_991).contains(count) else { throw ContractError("aggregates", "counts must be from 0 to 2^53−1") } }
        }
        if let total = usage.total, let output = usage.output { guard output <= total else { throw ContractError("usage.output", "can't exceed total") } }
        if let output = usage.output, let reasoning = usage.reasoning { guard reasoning <= output else { throw ContractError("usage.reasoning", "is a subset of output") } }
        if let path = projectPath { guard path.hasPrefix("/"), ContractText.isIdentifier(path, maximum: 4_096) else { throw ContractError("projectPath", "must be absolute") } }
    }

    /// The instant used for windowing: provider time, else the interval's end
    /// (or start). nil for unplaced usage.
    public var placement: Date? { time.at ?? time.end ?? time.start }
}

/// Folds receipts idempotently: a replayed observation changes nothing, a
/// higher revision replaces a lower one, and cumulative checkpoints are
/// differenced, so the same evidence imported twice can't double a total.
public struct WorkspaceReceiptLedger: Sendable {
    public struct Conflict: Equatable, Sendable {
        public var eventID: String
        public var revision: Int
        public var keptDigest: String
        public var rejectedDigest: String
    }

    public struct IngestResult: Equatable, Sendable {
        public var accepted = 0
        public var duplicates = 0
        public var superseded = 0
        /// Lower revisions than the one already held.
        public var stale = 0
        public var conflicts: [Conflict] = []
        public var rejected: [String] = []
    }

    public struct Totals: Equatable, Sendable {
        public var receipts = 0
        public var tokens: TokenQuantity?
        public var output: TokenQuantity?
        /// Receipts with partial, unknown or unauthoritative usage, or a missing total.
        public var partialReceipts = 0
        public var tokensArePartial = false
        /// Cumulative series that went down: counted from the lower value as a new series.
        public var seriesResets = 0
        /// First instant to last instant of placed intervals.
        public var wallClockSpanSeconds: Int64?
        /// Union of intervals: overlapping agents count once.
        public var activeSeconds: Int64?
        /// Intervals unioned per session, then summed: parallel agents add up.
        public var agentSeconds: Int64?
        public var toolCalls: Int?
        public var sessions = 0
    }

    public private(set) var receipts: [String: WorkspaceReceipt] = [:]

    public init() {}

    @discardableResult
    public mutating func ingest<S: Sequence>(_ incoming: S) -> IngestResult where S.Element == WorkspaceReceipt {
        var result = IngestResult()
        for receipt in incoming {
            do { try receipt.validate() } catch {
                result.rejected.append("\(receipt.eventID): \(error)")
                continue
            }
            guard let held = receipts[receipt.eventID] else {
                receipts[receipt.eventID] = receipt; result.accepted += 1; continue
            }
            if receipt.revision < held.revision { result.stale += 1; continue }
            if receipt.revision == held.revision {
                if receipt.contentDigest == held.contentDigest { result.duplicates += 1 }
                else { result.conflicts.append(Conflict(eventID: receipt.eventID, revision: receipt.revision, keptDigest: held.contentDigest, rejectedDigest: receipt.contentDigest)) }
                continue
            }
            if receipt.contentDigest == held.contentDigest { result.duplicates += 1; continue }
            receipts[receipt.eventID] = receipt
            result.superseded += 1
        }
        return result
    }

    /// Totals for one scope in the half-open window [from, to). Receipts of
    /// other scopes are never mixed in.
    public func totals(scope: WorkspaceReceipt.Scope = .localNativeHistory, from: Date? = nil, to: Date? = nil) -> Totals {
        func inWindow(_ date: Date) -> Bool { (from.map { date >= $0 } ?? true) && (to.map { date < $0 } ?? true) }
        var totals = Totals()
        var tokenSum: Int64 = 0, outputSum: Int64 = 0, overflow = false, sawTokens = false, sawOutput = false
        var sessions = Set<String>()
        var intervals: [(session: String, start: Date, end: Date)] = []
        var toolCalls: Int?
        let candidates = receipts.values.filter { $0.scope == scope && $0.includedInTotals }

        func add(total: TokenQuantity?, output: TokenQuantity?, usage: WorkspaceReceipt.Usage) {
            if !usage.provenance.isAuthoritative || usage.completeness != .complete || total == nil { totals.partialReceipts += 1 }
            guard usage.provenance.isAuthoritative else { return }
            if let total {
                let sum = tokenSum.addingReportingOverflow(total.value); overflow = overflow || sum.overflow; tokenSum = sum.partialValue; sawTokens = true
            }
            if let output {
                let sum = outputSum.addingReportingOverflow(output.value); overflow = overflow || sum.overflow; outputSum = sum.partialValue; sawOutput = true
            }
        }

        // Incremental receipts count as they are.
        for receipt in candidates where receipt.accumulation == .incremental {
            guard let placed = receipt.placement, inWindow(placed) else { continue }
            totals.receipts += 1
            sessions.insert(receipt.sessionID)
            add(total: receipt.usage.total, output: receipt.usage.output, usage: receipt.usage)
            if let start = receipt.time.start, let end = receipt.time.end { intervals.append((receipt.sessionID, start, end)) }
            if let count = receipt.aggregates?.toolCalls { toolCalls = (toolCalls ?? 0) + count }
        }
        // Cumulative checkpoints: each one contributes its advance over the
        // previous checkpoint of the same session series, at its own time.
        let series = Dictionary(grouping: candidates.filter { $0.accumulation == .cumulative }) { $0.sessionID + "\u{1f}" + $0.unit.rawValue }
        for key in series.keys.sorted() {
            let points = series[key]!.sorted { ($0.time.at!, $0.eventID) < ($1.time.at!, $1.eventID) }
            var previousTotal: TokenQuantity? = .zero, previousOutput: TokenQuantity? = .zero
            for point in points {
                var total: TokenQuantity?, output: TokenQuantity?, reset = false
                if let current = point.usage.total, let prior = previousTotal {
                    if let delta = current.subtracting(prior) { total = delta } else { total = current; reset = true }
                }
                if let current = point.usage.output, let prior = previousOutput { output = current.subtracting(prior) ?? current }
                previousTotal = point.usage.total ?? previousTotal
                previousOutput = point.usage.output ?? previousOutput
                guard inWindow(point.time.at!) else { continue }
                if reset { totals.seriesResets += 1 }
                totals.receipts += 1
                sessions.insert(point.sessionID)
                add(total: total, output: output, usage: point.usage)
            }
        }
        totals.sessions = sessions.count
        totals.tokens = sawTokens && !overflow ? TokenQuantity(Int(tokenSum)) : nil
        totals.output = sawOutput && !overflow ? TokenQuantity(Int(outputSum)) : nil
        totals.tokensArePartial = totals.partialReceipts > 0 || overflow
        totals.toolCalls = toolCalls

        let clipped = intervals.compactMap { item -> (session: String, start: Date, end: Date)? in
            let start = max(item.start, from ?? item.start), end = min(item.end, to ?? item.end)
            return end > start ? (item.session, start, end) : nil
        }
        if let first = clipped.map(\.start).min(), let last = clipped.map(\.end).max() {
            totals.wallClockSpanSeconds = Int64(last.timeIntervalSince(first))
            totals.activeSeconds = Int64(Self.union(clipped.map { ($0.start, $0.end) }))
            let bySession = Dictionary(grouping: clipped, by: \.session)
            totals.agentSeconds = Int64(bySession.values.reduce(0) { $0 + Self.union($1.map { ($0.start, $0.end) }) })
        }
        return totals
    }

    static func union(_ spans: [(Date, Date)]) -> Double {
        let sorted = spans.sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return 0 }
        var total = 0.0
        for span in sorted.dropFirst() {
            if span.0 <= current.1 { current.1 = max(current.1, span.1) } else { total += current.1.timeIntervalSince(current.0); current = span }
        }
        return total + current.1.timeIntervalSince(current.0)
    }
}

/// Reads and writes receipts as JSON Lines, one receipt per line.
public enum WorkspaceReceiptLines {
    public static let maximumLineBytes = 64 * 1_024

    public static func decode(_ data: Data) -> (receipts: [WorkspaceReceipt], errors: [String]) {
        var receipts: [WorkspaceReceipt] = [], errors: [String] = []
        let decoder = ContractJSON.decoder
        for (number, line) in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= maximumLineBytes else { errors.append("line \(number + 1): longer than \(maximumLineBytes) bytes"); continue }
            do { receipts.append(try decoder.decode(WorkspaceReceipt.self, from: Data(trimmed))) }
            catch { errors.append("line \(number + 1): not a workspace receipt") }
        }
        return (receipts, errors)
    }

    public static func encode(_ receipts: [WorkspaceReceipt]) throws -> Data {
        let encoder = ContractJSON.encoder
        var data = Data()
        for receipt in receipts {
            data.append(try encoder.encode(receipt))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}
