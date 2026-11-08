import Foundation

/// Strict parsing for `bridge economics`, testable without the CLI. Reading
/// a report, exporting or importing never refreshes activity, launches a
/// provider, spends credits or touches a repository.
public struct EconomicsCLIRequest: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case view, briefing, export, candidates, outcomes, accept, reject, revise, withdraw, assess, assumptions
    }

    public var action: Action
    public var query: EconomicReportQuery
    public var values: [String: String]
    public var flags: Set<String>

    static let selectors: Set<String> = ["--period", "--from", "--to", "--provider", "--project"]
    static let flagNames: Set<String> = ["--previous", "--sanitized", "--receipts"]
    static let allowed: [Action: Set<String>] = [
        .view: selectors, .briefing: selectors, .candidates: selectors,
        .export: selectors.union(["--output"]),
        .outcomes: [],
        .accept: selectors.union(["--candidate", "--commits", "--repository", "--title", "--summary", "--standard", "--hands-on"]),
        .reject: selectors.union(["--candidate", "--commits", "--repository", "--title"]),
        .revise: ["--outcome", "--title", "--summary", "--standard", "--hands-on"],
        .withdraw: ["--outcome", "--reason", "--note"],
        .assess: ["--outcome", "--size", "--hours", "--baseline", "--method", "--confidence", "--rationale", "--file"],
        .assumptions: ["--baseline", "--rate", "--operator-rate", "--hours-per-day", "--time-zone", "--add-rate", "--remove-rate", "--subscription", "--remove-subscription"],
    ]
    static let allowedFlags: [Action: Set<String>] = [
        .view: ["--previous"], .briefing: ["--previous"], .candidates: ["--previous"], .accept: ["--previous"], .reject: ["--previous"],
        .export: ["--previous", "--sanitized", "--receipts"],
    ]

    public init(arguments: [String]) throws {
        var index = 0
        var action = Action.view
        if let first = arguments.first, !first.hasPrefix("--") {
            guard let value = Action(rawValue: first) else {
                throw BridgeError.invalidRequest("Use economics " + Action.allCases.map(\.rawValue).joined(separator: "|") + ".")
            }
            action = value; index = 1
        }
        var values: [String: String] = [:], flags: Set<String> = []
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), values[name] == nil, !flags.contains(name) else { throw BridgeError.invalidRequest("Use each economics option once: \(name).") }
            if Self.flagNames.contains(name) {
                guard Self.allowedFlags[action]?.contains(name) == true else { throw BridgeError.invalidRequest("\(name) doesn't apply to economics \(action.rawValue).") }
                flags.insert(name); index += 1; continue
            }
            guard Self.allowed[action]?.contains(name) == true else { throw BridgeError.invalidRequest("\(name) doesn't apply to economics \(action.rawValue).") }
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--"), arguments[index + 1].utf8.count <= 4_096 else {
                throw BridgeError.invalidRequest("\(name) needs a value.")
            }
            values[name] = arguments[index + 1]
            index += 2
        }
        var items: [URLQueryItem] = Self.selectors.sorted().compactMap { name in values[name].map { URLQueryItem(name: String(name.dropFirst(2)), value: $0) } }
        if flags.contains("--previous") { items.append(.init(name: "previous", value: "true")) }
        let query = try EconomicReportQuery(queryItems: items)
        switch action {
        case .export: guard values["--output"] != nil else { throw BridgeError.invalidRequest("economics export needs --output FOLDER.") }
        case .accept, .reject:
            guard (values["--candidate"] != nil) != (values["--commits"] != nil) else { throw BridgeError.invalidRequest("Name a --candidate, or --commits with --repository.") }
            if values["--commits"] != nil, values["--repository"] == nil { throw BridgeError.invalidRequest("--commits needs --repository.") }
            if action == .accept, values["--commits"] != nil, values["--title"] == nil { throw BridgeError.invalidRequest("Accepting commits directly needs a --title.") }
        case .revise, .withdraw: guard values["--outcome"] != nil else { throw BridgeError.invalidRequest("economics \(action.rawValue) needs --outcome ID.") }
        case .assess:
            if values["--file"] != nil {
                guard values.count == 1 else { throw BridgeError.invalidRequest("--file imports assessments as written; use it alone.") }
            } else {
                guard values["--outcome"] != nil, (values["--size"] != nil) != (values["--hours"] != nil) else {
                    throw BridgeError.invalidRequest("economics assess needs --outcome with --size or --hours, or --file.")
                }
            }
        default: break
        }
        if action == .withdraw, values["--reason"] == nil { throw BridgeError.invalidRequest("economics withdraw needs --reason regression|reverted|duplicate|scope_change|other.") }
        self.action = action; self.query = query; self.values = values; self.flags = flags
    }
}

/// Runs economics requests against the saved activity snapshot and the
/// ledger. Shared by the CLI and the local API.
public struct EconomicReportService: Sendable {
    public var ledger: EconomicLedger
    public var overview: @Sendable () async throws -> ActivityOverview
    public var now: @Sendable () -> Date
    public var home: String

    public init(ledger: EconomicLedger = .shared, overview: @escaping @Sendable () async throws -> ActivityOverview = { try await ActivityReportingService.shared.overview() },
                now: @escaping @Sendable () -> Date = { Date() }, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.ledger = ledger; self.overview = overview; self.now = now; self.home = home
    }

    public func output(_ query: EconomicReportQuery) async throws -> EconomicReportBuilder.Output {
        let snapshot = try await overview()
        let state = try await ledger.state()
        return try EconomicReportBuilder.build(.init(overview: snapshot, query: query, ledger: state, generatedAt: now(), home: home))
    }

    /// Output to print: pretty JSON, or Markdown for the briefing.
    public func execute(_ request: EconomicsCLIRequest) async throws -> String {
        let encoder = ContractJSON.prettyEncoder
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        switch request.action {
        case .view: return try json(try await output(request.query).report)
        case .briefing: return FeedbackBriefingBuilder.markdown(try await output(request.query).report)
        case .candidates: return try json(try await output(request.query).candidates)
        case .export:
            let built = try await output(request.query)
            let bundle = try EconomicReportExchange.bundle(built, sanitized: request.flags.contains("--sanitized"),
                                                           includeReceipts: request.flags.contains("--receipts"), createdAt: now())
            let folder = URL(fileURLWithPath: request.values["--output"]!).standardizedFileURL
            try EconomicReportExchange.write(bundle, to: folder)
            return "Exported \(bundle.report.contentLevel.rawValue) report \(bundle.report.reportID) to \(folder.path) (\(bundle.manifest.files.count) files)."
        case .outcomes:
            let state = try await ledger.state()
            return try json(OutcomeListing(outcomes: state.latestOutcomes, assessments: state.assessments))
        case .accept, .reject: return try json(try await decideCandidate(request))
        case .revise: return try json(try await revise(request))
        case .withdraw:
            let previous = try await latest(request.values["--outcome"]!)
            guard let reason = AcceptedOutcomeRecord.Correction.Reason(rawValue: request.values["--reason"]!) else {
                throw BridgeError.invalidRequest("--reason must be regression, reverted, duplicate, scope_change or other.")
            }
            let draft = OutcomeDecision(decision: .withdrawn, title: previous.title, summary: previous.summary, deliveryStandard: previous.deliveryStandard,
                                        evidence: previous.evidence, landedAt: previous.landedAt, operatorTime: previous.operatorTime,
                                        candidateID: previous.candidateID, correction: .init(reason: reason, note: request.values["--note"]))
            return try json(try await ledger.decide(draft, revising: previous.id, now: now()))
        case .assess:
            if let path = request.values["--file"] { return try json(try await importAssessments(URL(fileURLWithPath: path))) }
            return try json(try await assess(request))
        case .assumptions: return try json(try await assumptions(request))
        }
    }

    public struct OutcomeListing: Codable, Sendable {
        public var outcomes: [AcceptedOutcomeRecord]
        public var assessments: [EffortAssessmentRecord]
    }

    public struct ImportSummary: Codable, Sendable {
        public var inserted: [String]
        public var unchanged: [String]
        public var refused: [String]
    }

    // MARK: Decisions

    private func latest(_ outcomeID: String) async throws -> AcceptedOutcomeRecord {
        guard let record = try await ledger.state().latestOutcomes.first(where: { $0.outcomeID == outcomeID.lowercased() }) else {
            throw EconomicLedgerError.unknownOutcome
        }
        return record
    }

    private func decideCandidate(_ request: EconomicsCLIRequest) async throws -> AcceptedOutcomeRecord {
        let decision: AcceptedOutcomeRecord.Decision = request.action == .accept ? .accepted : .rejected
        let standard = try request.values["--standard"].map(Self.standard) ?? .internalTool
        let operatorTime = try request.values["--hands-on"].map(Self.handsOn) ?? .unknown
        if let candidateID = request.values["--candidate"] {
            var built = try await output(request.query)
            var candidate = built.candidates.first { $0.id == candidateID }
            if candidate == nil {
                var wider = request.query
                wider.period = .all; wider.previous = false; wider.from = nil; wider.to = nil
                built = try await output(wider)
                candidate = built.candidates.first { $0.id == candidateID }
            }
            guard let candidate else { throw BridgeError.invalidRequest("No suggestion \(candidateID); list them with bridge economics candidates.") }
            let commits = candidate.evidence.filter { $0.kind == .commit }
            let sessions = candidate.evidence.filter { $0.kind == .session }
            guard commits.count <= 256 else { throw BridgeError.invalidRequest("That suggestion has more than 256 commits; accept it in parts with --commits.") }
            let draft = OutcomeDecision(decision: decision, title: request.values["--title"] ?? candidate.title, summary: request.values["--summary"],
                                        deliveryStandard: standard, evidence: commits + sessions.prefix(256 - commits.count),
                                        landedAt: candidate.lastCommitAt, operatorTime: operatorTime, candidateID: candidate.id)
            return try await ledger.decide(draft, now: now())
        }
        let snapshot = try await overview()
        let key = request.values["--repository"]!
        let resolved = ShippedCodeReport.resolved(key)
        guard let repository = snapshot.repositories.first(where: { $0.id == key || $0.name == key || ShippedCodeReport.resolved($0.root) == resolved
            || $0.worktrees.contains { ShippedCodeReport.resolved($0.path) == resolved } }) else {
            throw BridgeError.invalidRequest("No scanned repository matches \(key); run Scan projects first.")
        }
        var evidence: [OutcomeEvidence] = [], landed: Date?
        for ref in request.values["--commits"]!.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !ref.isEmpty {
            let matches = repository.commits.filter { $0.id.hasPrefix(ref) }
            guard ref.count >= 7, matches.count == 1, let commit = matches.first else {
                throw BridgeError.invalidRequest("Commit \(ref) isn't one commit in the last scan of \(repository.name).")
            }
            evidence.append(OutcomeEvidence(kind: .commit, repositoryID: repository.id, ref: commit.id))
            landed = max(landed ?? commit.timestamp, commit.timestamp)
        }
        guard let landedAt = landed else { throw BridgeError.invalidRequest("List at least one commit.") }
        let title = request.values["--title"] ?? evidence.first.flatMap { ref in repository.commits.first { $0.id == ref.ref }?.subject } ?? "Rejected work"
        let draft = OutcomeDecision(decision: decision, title: String(title.prefix(200)), summary: request.values["--summary"], deliveryStandard: standard,
                                    evidence: evidence, landedAt: landedAt, operatorTime: operatorTime)
        return try await ledger.decide(draft, now: now())
    }

    private func revise(_ request: EconomicsCLIRequest) async throws -> AcceptedOutcomeRecord {
        let previous = try await latest(request.values["--outcome"]!)
        guard previous.decision != .withdrawn else { throw BridgeError.invalidRequest("A withdrawn outcome can't be revised.") }
        let draft = OutcomeDecision(decision: previous.decision, title: request.values["--title"] ?? previous.title,
                                    summary: request.values["--summary"] ?? previous.summary,
                                    deliveryStandard: try request.values["--standard"].map(Self.standard) ?? previous.deliveryStandard,
                                    evidence: previous.evidence, landedAt: previous.landedAt,
                                    operatorTime: try request.values["--hands-on"].map(Self.handsOn) ?? previous.operatorTime,
                                    candidateID: previous.candidateID)
        return try await ledger.decide(draft, revising: previous.id, now: now())
    }

    // MARK: Assessments

    private func assess(_ request: EconomicsCLIRequest) async throws -> EffortAssessmentRecord {
        let outcome = try await latest(request.values["--outcome"]!)
        guard outcome.decision == .accepted else { throw BridgeError.invalidRequest("Only accepted outcomes are estimated.") }
        let state = try await ledger.state()
        let assumptions = state.assumptions(default: EconomicCatalog.defaultAssumptions())
        let baseline = try request.values["--baseline"].map(Self.baseline) ?? assumptions.baseline
        let confidence = try request.values["--confidence"].map { raw -> EffortAssessmentRecord.Confidence in
            guard let value = EffortAssessmentRecord.Confidence(rawValue: raw) else { throw BridgeError.invalidRequest("--confidence must be low, medium or high.") }
            return value
        } ?? .medium
        var method: EffortAssessmentRecord.Method, hours: EstimateRange, size: String?
        if let raw = request.values["--size"] {
            guard let range = EconomicCatalog.rubric.hours(size: raw, standard: outcome.deliveryStandard, baseline: baseline) else {
                throw BridgeError.invalidRequest("--size must be xs, s, m, l or xl, and measured comparable work needs --hours.")
            }
            method = .sizeClass; hours = range; size = raw
        } else {
            let parts = request.values["--hours"]!.split(separator: ",").compactMap { ExactDecimal(String($0).trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 || parts.count == 1 else { throw BridgeError.invalidRequest("--hours takes LOW,BASE,HIGH (or one number).") }
            hours = parts.count == 3 ? EstimateRange(low: parts[0], base: parts[1], high: parts[2]) : EstimateRange(low: parts[0], base: parts[0], high: parts[0])
            method = try request.values["--method"].map { raw -> EffortAssessmentRecord.Method in
                guard let value = EffortAssessmentRecord.Method(rawValue: raw), value != .sizeClass else {
                    throw BridgeError.invalidRequest("--method must be task_breakdown, comparable_work or expert_judgment.")
                }
                return value
            } ?? (baseline == .measuredComparable ? .comparableWork : .expertJudgment)
        }
        let record = EffortAssessmentRecord(id: UUID().uuidString.lowercased(), outcomeID: outcome.outcomeID, outcomeRevisionID: outcome.id,
                                            createdAt: ContractTime.normalized(now()) ?? now(),
                                            assessor: .init(kind: .human, identity: "user", rubricVersion: method == .sizeClass ? EconomicCatalog.rubric.version : nil),
                                            baseline: baseline, deliveryStandard: outcome.deliveryStandard, method: method, sizeClass: size, hours: hours,
                                            rationale: request.values["--rationale"], confidence: confidence)
        return try await ledger.assess(record).record
    }

    /// Imports effort-assessment/1 records (one object or an array), such as
    /// a model's output from the economic-work-review skill.
    public func importAssessments(_ url: URL) async throws -> ImportSummary {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? .max) <= 1_048_576 else { throw BridgeError.invalidRequest("Assessments must be a file under 1 MB.") }
        let data = try Data(contentsOf: url)
        let decoder = ContractJSON.decoder
        let records: [EffortAssessmentRecord]
        if let many = try? decoder.decode([EffortAssessmentRecord].self, from: data) { records = many }
        else if let one = try? decoder.decode(EffortAssessmentRecord.self, from: data) { records = [one] }
        else { throw BridgeError.invalidRequest("The file isn't effort-assessment/1 JSON.") }
        guard records.count <= 256 else { throw BridgeError.invalidRequest("Import at most 256 assessments at a time.") }
        var summary = ImportSummary(inserted: [], unchanged: [], refused: [])
        for record in records {
            do {
                let result = try await ledger.assess(record)
                if result.inserted { summary.inserted.append(record.id) } else { summary.unchanged.append(record.id) }
            } catch { summary.refused.append("\(record.id): \(error.localizedDescription)") }
        }
        return summary
    }

    // MARK: Assumptions

    private func assumptions(_ request: EconomicsCLIRequest) async throws -> EconomicAssumptions {
        let state = try await ledger.state()
        var value = state.assumptions(default: EconomicCatalog.defaultAssumptions())
        guard !request.values.isEmpty else { return value }
        if let raw = request.values["--baseline"] { value.baseline = try Self.baseline(raw) }
        if let raw = request.values["--hours-per-day"] {
            guard let hours = ExactDecimal(raw) else { throw BridgeError.invalidRequest("--hours-per-day must be a number.") }
            value.hoursPerDay = hours
        }
        if let raw = request.values["--time-zone"] { value.timeZone = raw }
        if let raw = request.values["--remove-rate"] { value.customRates.removeAll { $0.id == raw } }
        if let raw = request.values["--add-rate"] {
            // id|label|amount|currency|basis
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 5, let amount = ExactDecimal(parts[2]), let basis = LaborRate.Basis(rawValue: parts[4]) else {
                throw BridgeError.invalidRequest("--add-rate takes \"id|label|hourly amount|currency|user_rate, contractor_rate, loaded_cost or median_wage\".")
            }
            guard !EconomicCatalog.rates.contains(where: { $0.id == parts[0] }) else { throw BridgeError.invalidRequest("\(parts[0]) is a built-in rate.") }
            value.customRates.removeAll { $0.id == parts[0] }
            value.customRates.append(LaborRate(id: parts[0], label: parts[1], hourly: MoneyAmount(amount: amount, currency: parts[3].uppercased()),
                                               vintage: "Set \(FeedbackBriefingBuilder.date(now(), value.timeZone).prefix(10))", basis: basis))
        }
        if let raw = request.values["--rate"] {
            guard EconomicCatalog.rate(raw, in: value) != nil else { throw BridgeError.invalidRequest("No rate \(raw). Built-in: " + EconomicCatalog.rates.map(\.id).joined(separator: ", ") + ".") }
            value.rateID = raw
        }
        if let raw = request.values["--operator-rate"] {
            guard raw == "same" || EconomicCatalog.rate(raw, in: value) != nil else { throw BridgeError.invalidRequest("No rate \(raw).") }
            value.operatorRateID = raw == "same" ? nil : raw
        }
        if let raw = request.values["--remove-subscription"] { value.subscriptions.removeAll { $0.id == raw } }
        if let raw = request.values["--subscription"] {
            // id|provider|label|monthly amount|currency
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 5, let amount = ExactDecimal(parts[3]) else {
                throw BridgeError.invalidRequest("--subscription takes \"id|provider|label|monthly amount|currency\", such as \"claude-max|claude|Claude Max|200|USD\".")
            }
            value.subscriptions.removeAll { $0.id == parts[0] }
            value.subscriptions.append(ToolSubscription(id: parts[0], provider: parts[1], label: parts[2], monthly: MoneyAmount(amount: amount, currency: parts[4].uppercased())))
        }
        guard EconomicCatalog.rate(value.rateID, in: value) != nil, value.operatorRateID.map({ EconomicCatalog.rate($0, in: value) != nil }) ?? true else {
            throw BridgeError.invalidRequest("A chosen rate was removed; choose another with --rate or --operator-rate.")
        }
        return try await ledger.setAssumptions(value, now: now()).assumptions
    }

    static func standard(_ raw: String) throws -> DeliveryStandard {
        guard let value = DeliveryStandard(rawValue: raw) else { throw BridgeError.invalidRequest("--standard must be prototype, internal_tool or production.") }
        return value
    }

    static func baseline(_ raw: String) throws -> WorkingBaseline {
        let aliases = ["historical": WorkingBaseline.historical, "contemporary": .contemporary, "measured": .measuredComparable]
        guard let value = WorkingBaseline(rawValue: raw) ?? aliases[raw] else { throw BridgeError.invalidRequest("--baseline must be historical, contemporary or measured.") }
        return value
    }

    /// "2", "1.5-3" or "1.5–3" hours.
    static func handsOn(_ raw: String) throws -> OperatorTime {
        let parts = raw.replacingOccurrences(of: "–", with: "-").split(separator: "-", omittingEmptySubsequences: false).map { ExactDecimal(String($0).trimmingCharacters(in: .whitespaces)) }
        guard (1 ... 2).contains(parts.count), let low = parts.first ?? nil, let high = parts.last ?? nil, !low.isNegative, low <= high else {
            throw BridgeError.invalidRequest("--hands-on takes hours, such as 2 or 1.5-3.")
        }
        return .known(low: low, high: high)
    }
}
