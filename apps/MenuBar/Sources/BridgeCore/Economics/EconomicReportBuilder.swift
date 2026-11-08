import Foundation

/// Builds the economic report from one frozen snapshot. Usage and time come
/// from `ActivityAccounting` (the same engine as every other page and
/// `bridge metrics`), commits from the last Scan projects, outcomes and
/// estimates from the ledger, money from the person's assumptions. Missing
/// inputs stay missing: nothing is guessed to complete a number.
public enum EconomicReportBuilder {
    public struct Input: Sendable {
        public var overview: ActivityOverview
        public var query: EconomicReportQuery
        public var ledger: EconomicLedgerState
        public var generatedAt: Date
        public var home: String

        public init(overview: ActivityOverview, query: EconomicReportQuery, ledger: EconomicLedgerState, generatedAt: Date = Date(),
                    home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
            self.overview = overview; self.query = query; self.ledger = ledger; self.generatedAt = generatedAt; self.home = home
        }
    }

    public struct Output: Sendable {
        public var report: EconomicReport
        /// Every suggestion for the period, decided or not.
        public var candidates: [OutcomeCandidate]
        public var accounting: ActivityAccounting.Report
        /// All revisions of the outcomes the report shows, oldest first.
        public var outcomeRecords: [AcceptedOutcomeRecord]
        public var assessments: [EffortAssessmentRecord]
    }

    /// Average Gregorian month: 365.2425 ÷ 12 days.
    static let secondsPerMonth = 2_629_746

    public static func build(_ input: Input) throws -> Output {
        let overview = input.overview
        guard ActivityAccountingQuery.hasSnapshot(overview), let asOf = ContractTime.normalized(overview.generatedAt) else {
            throw BridgeError.invalidRequest("No local history has been collected; refresh activity first.")
        }
        let assumptions = input.ledger.assumptions(default: EconomicCatalog.defaultAssumptions())
        let timeZone = TimeZone(identifier: assumptions.timeZone) ?? ActivityAnalytics.reportingTimeZone
        let period = try input.query.resolvePeriod(asOf: asOf, timeZone: timeZone)
        func inPeriod(_ date: Date) -> Bool { date < period.to && (period.from.map { date >= $0 } ?? true) }

        // Scope: sessions (by provider and project folder) and repositories.
        let scope = try Self.scope(overview: overview, query: input.query, home: input.home)
        let accounting = ActivityAccounting.build(overview: overview, sessionIDs: scope.filtered ? scope.sessionIDs : nil, from: period.from, to: period.to)
        let bySession = accounting.bySession()
        let shipped = ShippedCodeReport.build(.init(sessions: overview.sessions.filter { scope.sessionIDs.contains($0.id) },
                                                    repositories: scope.repositories, from: period.from, to: period.to,
                                                    tokensBySession: bySession.compactMapValues { $0.totals.usage.tokensKnown },
                                                    outputTokensBySession: bySession.compactMapValues { $0.totals.usage.outputKnown }, home: input.home))
        let candidates = OutcomeCandidates.build(shipped: shipped, sessions: overview.sessions, outcomes: input.ledger.outcomes)

        // Outcomes the person decided, limited to the scope.
        let linkedSessions = Dictionary(shipped.commits.map { ($0.repositoryID + ":" + $0.commit.id, Set($0.sessionIDs)) }, uniquingKeysWith: { $0.union($1) })
        func relevant(_ record: AcceptedOutcomeRecord) -> Bool {
            guard scope.filtered else { return true }
            for item in record.evidence {
                switch item.kind {
                case .session: if scope.sessionIDs.contains(item.ref) { return true }
                case .commit:
                    let repository = item.repositoryID ?? ""
                    if input.query.provider == nil, scope.repositories.contains(where: { $0.id == repository }) { return true }
                    if let match = linkedSessions.first(where: { $0.key.hasPrefix(repository + ":" + item.ref) }), !match.value.isDisjoint(with: scope.sessionIDs) { return true }
                default: continue
                }
            }
            return false
        }
        let latest = input.ledger.latestOutcomes.filter(relevant)
        let accepted = latest.filter { $0.decision == .accepted && inPeriod($0.landedAt) }.sorted { ($0.landedAt, $0.id) > ($1.landedAt, $1.id) }
        let rejected = latest.filter { $0.decision == .rejected && inPeriod($0.createdAt) }
        let withdrawn = latest.filter { $0.decision == .withdrawn && inPeriod($0.createdAt) }
        let shownIDs = Set((accepted + withdrawn).map(\.outcomeID))
        let assessments = input.ledger.assessments.filter { shownIDs.contains($0.outcomeID) }

        let repositoryNames = Dictionary(overview.repositories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let allCommits = overview.repositories.flatMap { repository in repository.commits.map { (repository.id, $0) } }
        let reverted = Self.revertedCommits(overview.repositories)
        var items: [EconomicReport.OutcomeItem] = []
        for record in accepted {
            let commitRefs = record.commitRefs
            var lines = LineCounts(), counted = 0
            for ref in commitRefs {
                guard let commit = allCommits.first(where: { $0.0 == ref.repositoryID && $0.1.id.hasPrefix(ref.ref) })?.1, let additions = commit.additions else { continue }
                lines.additions += additions; lines.deletions += commit.deletions ?? 0; counted += 1
            }
            let repositories = Array(Set(commitRefs.compactMap(\.repositoryID).map { repositoryNames[$0] ?? $0 })).sorted()
            items.append(.init(outcomeID: record.outcomeID, revisionID: record.id, title: record.title, summary: record.summary,
                               deliveryStandard: record.deliveryStandard, landedAt: record.landedAt, repositories: repositories,
                               commits: commitRefs.count, lines: counted == commitRefs.count && counted > 0 ? lines : nil,
                               sessions: record.evidence.filter { $0.kind == .session }.count,
                               revertedCommits: commitRefs.filter { ref in reverted.contains { $0.hasPrefix((ref.repositoryID ?? "") + ":" + ref.ref) } }.count,
                               evidence: record.evidence,
                               operatorTime: record.operatorTime,
                               effort: effort(for: record, assessments: assessments, baseline: assumptions.baseline)))
        }
        let corrections = withdrawn.map { record in
            EconomicReport.CorrectionItem(outcomeID: record.outcomeID, title: record.title, reason: record.correction?.reason ?? .other,
                                          landedAt: record.landedAt, withdrawnAt: record.createdAt)
        }
        let pending = candidates.filter { !$0.isDecided }
        let acceptedCommits = OutcomeCandidates.latestDecisions(input.ledger.outcomes).filter { $0.record.decision == .accepted }.map(\.commits)
        let commitsInAccepted = shipped.commits.filter { commit in acceptedCommits.contains { OutcomeCandidates.holds($0, repositoryID: commit.repositoryID, commitID: commit.commit.id) } }.count
        let outcomes = EconomicReport.Outcomes(
            accepted: accepted.count, rejected: rejected.count, pendingCandidates: pending.count, commitsInPeriod: shipped.totals.commits,
            commitsInAcceptedOutcomes: commitsInAccepted,
            linesInPeriod: LineCounts(additions: shipped.totals.lines.additions, deletions: shipped.totals.lines.deletions), items: items,
            pending: pending.prefix(50).map { candidate in
                EconomicReport.CandidateItem(candidateID: candidate.id, title: candidate.title, repositories: candidate.repositoryNames,
                                             commits: candidate.commits.count, lines: candidate.lines, sessions: candidate.sessionIDs.count,
                                             firstCommitAt: candidate.firstCommitAt, lastCommitAt: candidate.lastCommitAt)
            },
            corrections: corrections)

        let usage = Self.usage(accounting, bySession: bySession)
        let operatorSummary = Self.operatorTime(items)
        let time = EconomicReport.TimeSummary(activeSeconds: accounting.totals.activeSeconds.map { Int($0) },
                                              agentSeconds: accounting.totals.agentSeconds.map { Int($0) }, operatorTime: operatorSummary)
        let costs = Self.costs(assumptions: assumptions, period: period, overview: overview, accounting: accounting, query: input.query)
        let effort = Self.effortTotals(items, assumptions: assumptions)
        let economics = Self.economics(items: items, effort: effort, operatorTime: operatorSummary, costs: costs, assumptions: assumptions)
        let friction = Self.friction(shipped: shipped, usage: usage, rejected: rejected.count)
        let uncertainty = Self.uncertainty(accounting: accounting, shipped: shipped, outcomes: outcomes, effort: effort, economics: economics,
                                           costs: costs, period: period, assumptions: assumptions, scope: scope, query: input.query)
        let projects = scope.repositories.map { EconomicReport.ProjectRef(id: $0.id, name: $0.name, path: $0.root) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        var report = EconomicReport(
            generatedAt: ContractTime.normalized(input.generatedAt) ?? asOf, contentLevel: .local, period: period,
            scope: .init(projects: projects, projectFilter: input.query.project, provider: input.query.provider?.rawValue, sessions: accounting.totals.sessions),
            snapshot: .init(asOf: asOf, accountingSchema: accounting.schemaVersion, metricDefinitions: accounting.metricDefinitionsVersion,
                            accountingFingerprint: try Self.fingerprint(accounting), repositoriesScannedAt: shipped.totals.newestScan.flatMap(ContractTime.normalized),
                            sourceCoverageIsPartial: accounting.sourceCoverageIsPartial),
            usage: usage, time: time, costs: costs, outcomes: outcomes, effort: effort, economics: economics, friction: friction,
            uncertainty: uncertainty, nextPrompt: "", assumptions: assumptions)
        report.nextPrompt = FeedbackBriefingBuilder.nextPrompt(report)
        report = try report.identified()
        let records = input.ledger.outcomes.filter { shownIDs.contains($0.outcomeID) }
        return Output(report: report, candidates: candidates, accounting: accounting, outcomeRecords: records, assessments: assessments)
    }

    /// "repository:commit" of commits that a later commit in the same scan reverts
    /// (Git's own `Revert "subject"` message).
    static func revertedCommits(_ repositories: [ActivityRepository]) -> Set<String> {
        var result = Set<String>()
        for repository in repositories {
            let ordered = repository.commits.sorted { $0.timestamp < $1.timestamp }
            var bySubject: [String: String] = [:]
            for commit in ordered {
                if commit.subject.hasPrefix("Revert \""), commit.subject.hasSuffix("\""), let original = bySubject[String(commit.subject.dropFirst(8).dropLast())] {
                    result.insert(repository.id + ":" + original)
                }
                bySubject[commit.subject] = commit.id
            }
        }
        return result
    }

    // MARK: Scope

    struct Scope {
        var sessionIDs: Set<String>
        var repositories: [ActivityRepository]
        var filtered: Bool
        /// Sessions started in a folder above the project that edited it.
        var parentFolderSessions: Int
    }

    static func scope(overview: ActivityOverview, query: EconomicReportQuery, home: String) throws -> Scope {
        let byProvider = overview.sessions.filter { query.provider == nil || $0.provider == query.provider }
        guard let project = query.project else {
            return Scope(sessionIDs: Set(byProvider.map(\.id)), repositories: overview.repositories, filtered: query.provider != nil, parentFolderSessions: 0)
        }
        let target = ShippedCodeReport.resolved(project)
        func roots(_ repository: ActivityRepository) -> [String] { ([repository.root] + repository.worktrees.map(\.path)).map(ShippedCodeReport.resolved) }
        let repositories = overview.repositories.filter { repository in
            roots(repository).contains { $0 == target || target.hasPrefix($0 + "/") || $0.hasPrefix(target + "/") }
        }
        let scopeRoots = repositories.isEmpty ? [target] : repositories.flatMap(roots)
        let allRoots = Array(Set(overview.repositories.flatMap(roots))).sorted { $0.count > $1.count }
        var ids = Set<String>(), parents = 0
        for session in byProvider {
            guard let path = session.projectPath.map(ShippedCodeReport.resolved) else { continue }
            if scopeRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) || path == target || path.hasPrefix(target + "/") {
                ids.insert(session.id)
            } else if let root = ShippedCodeReport.editedRoot(session, project: path, roots: allRoots, home: home), scopeRoots.contains(root) {
                ids.insert(session.id); parents += 1
            }
        }
        guard !ids.isEmpty || !repositories.isEmpty else {
            throw BridgeError.invalidRequest("Choose a project folder with saved activity or a scanned repository.")
        }
        return Scope(sessionIDs: ids, repositories: repositories, filtered: true, parentFolderSessions: parents)
    }

    // MARK: Usage and time

    /// Cheap identity of an accounting result. The full evidence digest
    /// encodes every receipt (seconds for a busy week); this hashes the scope
    /// and the totals the report shows.
    static func fingerprint(_ accounting: ActivityAccounting.Report) throws -> String {
        struct Fingerprint: Encodable {
            var schema: String, metrics: String, from: Date?, to: Date, asOf: Date, sessionIDs: [String]
            var tokens: Int?, output: Int?, modelSteps: Int, usageRecords: Int, nativeRecords: Int
            var activeSeconds: Int?, agentSeconds: Int?, tokensArePartial: Bool, sourceCoverageIsPartial: Bool, valid: Bool
        }
        let totals = accounting.totals
        return try ContractDigest.of(Fingerprint(
            schema: accounting.schemaVersion, metrics: accounting.metricDefinitionsVersion, from: accounting.scope.from, to: accounting.scope.to,
            asOf: accounting.scope.asOf, sessionIDs: accounting.scope.sessionIDs.sorted(), tokens: totals.tokensKnown, output: totals.outputKnown,
            modelSteps: totals.observedModelSteps, usageRecords: totals.usageRecords, nativeRecords: totals.nativeRecords,
            activeSeconds: totals.activeSeconds.map { Int($0) }, agentSeconds: totals.agentSeconds.map { Int($0) },
            tokensArePartial: totals.tokensArePartial, sourceCoverageIsPartial: accounting.sourceCoverageIsPartial, valid: accounting.isValid))
    }

    static func usage(_ accounting: ActivityAccounting.Report, bySession: [String: ActivityAccounting.Report]) -> EconomicReport.Usage {
        let totals = accounting.totals
        let composition = totals.usage.composition.flatMap { value -> EconomicReport.Composition? in
            guard let fresh = TokenQuantity(value.freshInput), let reread = TokenQuantity(value.rereadContext),
                  let writes = TokenQuantity(value.cacheWrites), let output = TokenQuantity(value.output) else { return nil }
            return .init(freshInput: fresh, rereadContext: reread, cacheWrites: writes, output: output)
        }
        let share = totals.usage.composition.flatMap { value -> ExactDecimal? in
            guard let total = value.total, total > 0 else { return nil }
            return ExactDecimal(Decimal(value.rereadContext) / Decimal(total))?.rounded(scale: 4)
        }
        // Known totals are sums of per-receipt values, so per-session
        // reports add up exactly to per-provider ones.
        let providerOf = Dictionary(accounting.receipts.map { ($0.sessionID, $0.provider) }, uniquingKeysWith: { first, _ in first })
        let participating = Set(accounting.participatingSessionIDs)
        var rows: [AgentName: (tokens: Int?, output: Int?, steps: Int, sessions: Int)] = [:]
        for (id, report) in bySession {
            guard let provider = providerOf[id] else { continue }
            var row = rows[provider] ?? (nil, nil, 0, 0)
            if let tokens = report.totals.tokensKnown { row.tokens = (row.tokens ?? 0) + tokens }
            if let output = report.totals.outputKnown { row.output = (row.output ?? 0) + output }
            row.steps += report.totals.observedModelSteps
            if participating.contains(id) { row.sessions += 1 }
            rows[provider] = row
        }
        let byProvider = rows.keys.sorted { $0.rawValue < $1.rawValue }.map { provider -> EconomicReport.ProviderUsage in
            let row = rows[provider]!
            return .init(provider: provider.rawValue, tokens: row.tokens.flatMap(TokenQuantity.init), outputTokens: row.output.flatMap(TokenQuantity.init),
                         modelSteps: row.steps, sessions: row.sessions)
        }
        let byModel = accounting.modelRows.filter { $0.requests > 0 || ($0.tokens ?? 0) > 0 }
            .sorted { lhs, rhs in
                let a = lhs.tokens ?? -1, b = rhs.tokens ?? -1
                return a != b ? a > b : (lhs.provider.rawValue, lhs.key.model ?? "") < (rhs.provider.rawValue, rhs.key.model ?? "")
            }
            .map { row in
                EconomicReport.ModelUsage(provider: row.provider.rawValue, model: row.key.model, tokens: row.tokens.flatMap(TokenQuantity.init),
                                          outputTokens: row.output.flatMap(TokenQuantity.init), modelSteps: row.requests)
            }
        return .init(scope: ActivityMetricScope.localNativeHistory.rawValue, tokens: totals.tokensKnown.flatMap(TokenQuantity.init),
                     outputTokens: totals.outputKnown.flatMap(TokenQuantity.init), tokensArePartial: totals.tokensArePartial,
                     composition: composition, rereadShare: share, modelSteps: totals.observedModelSteps, sessions: totals.sessions,
                     byProvider: byProvider, byModel: byModel)
    }

    static func operatorTime(_ items: [EconomicReport.OutcomeItem]) -> EconomicReport.OperatorSummary {
        let known = items.filter { $0.operatorTime.state == .known }
        var low = ExactDecimal.zero, high = ExactDecimal.zero
        for item in known {
            low = low.adding(item.operatorTime.lowHours ?? 0) ?? low
            high = high.adding(item.operatorTime.highHours ?? 0) ?? high
        }
        let state: EconomicReport.OperatorSummary.State = items.isEmpty || known.isEmpty ? .unknown : (known.count == items.count ? .known : .partial)
        let base = low.adding(high).flatMap { $0.divided(by: 2) } ?? low
        return .init(state: state, hours: known.isEmpty ? nil : EstimateRange(low: low, base: base, high: high),
                     outcomesWithTime: known.count, outcomesWithoutTime: items.count - known.count)
    }

    // MARK: Effort

    /// The chosen estimate is the latest by a person, else the latest by a
    /// model, for the report's baseline and the outcome's delivery standard.
    static func effort(for record: AcceptedOutcomeRecord, assessments: [EffortAssessmentRecord], baseline: WorkingBaseline) -> EconomicReport.OutcomeEffort? {
        let matching = assessments.filter { $0.outcomeID == record.outcomeID && $0.baseline == baseline && $0.deliveryStandard == record.deliveryStandard }
        func latest(_ kind: EffortAssessmentRecord.Assessor.Kind) -> EffortAssessmentRecord? {
            matching.filter { $0.assessor.kind == kind }.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        }
        guard let chosen = latest(.human) ?? latest(.model) else { return nil }
        let lows = matching.map(\.hours.low), bases = matching.map(\.hours.base), highs = matching.map(\.hours.high)
        let spread = EstimateRange(low: lows.min()!, base: chosen.hours.base, high: highs.max()!)
        let disagreement = (bases.min().flatMap { minimum in bases.max().flatMap { maximum in minimum.multiplied(by: ExactDecimal("1.5")!).map { maximum > $0 } } }) ?? false
        return .init(baseline: baseline, hours: chosen.hours, assessor: chosen.assessor, assessmentID: chosen.id, method: chosen.method,
                     sizeClass: chosen.sizeClass, confidence: chosen.confidence, assessments: matching.count, spread: spread,
                     disagreement: disagreement, stale: chosen.outcomeRevisionID != record.id)
    }

    static func effortTotals(_ items: [EconomicReport.OutcomeItem], assumptions: EconomicAssumptions) -> EconomicReport.Effort {
        let estimated = items.compactMap(\.effort)
        var hours: EstimateRange?
        for effort in estimated { hours = hours.map { $0.adding(effort.hours) ?? $0 } ?? effort.hours }
        let days = hours.flatMap { $0.divided(by: assumptions.hoursPerDay) }?.rounded(scale: 2)
        return .init(baseline: assumptions.baseline, rubricVersion: EconomicCatalog.rubric.version, hoursPerDay: assumptions.hoursPerDay,
                     estimatedOutcomes: estimated.count, unestimatedOutcomes: items.count - estimated.count, hours: hours, personDays: days)
    }

    // MARK: Costs and economics

    static func costs(assumptions: EconomicAssumptions, period: EconomicReport.Period, overview: ActivityOverview,
                      accounting: ActivityAccounting.Report, query: EconomicReportQuery) -> EconomicReport.Costs {
        let projectScoped = query.project != nil
        let allocation: EconomicReport.Costs.Allocation = projectScoped ? .tokenShare : .wholePeriod
        let subscriptions = assumptions.subscriptions.filter { query.provider == nil || $0.provider == query.provider?.rawValue }
        guard !subscriptions.isEmpty else { return .init(state: .unknown, allocation: allocation, allocationShare: nil, tooling: [], total: nil) }
        let start = period.from ?? overview.sessions.map(\.createdAt).min() ?? period.to
        // Token shares per provider, from the same engine over every session in the period.
        var shares: [String: ExactDecimal] = [:]
        var overallShare: ExactDecimal?
        if projectScoped {
            let everything = ActivityAccounting.build(overview: overview, from: period.from, to: period.to)
            var scopeTotal = 0, allTotal = 0
            for provider in Set(subscriptions.map(\.provider)) {
                let all = everything.projected(sessionIDs: Set(everything.receipts.filter { $0.provider.rawValue == provider }.map(\.sessionID))).totals.tokensKnown ?? 0
                let mine = accounting.projected(sessionIDs: Set(accounting.receipts.filter { $0.provider.rawValue == provider }.map(\.sessionID))).totals.tokensKnown ?? 0
                scopeTotal += mine; allTotal += all
                if all > 0 { shares[provider] = ExactDecimal(Decimal(mine) / Decimal(all))?.rounded(scale: 4) }
            }
            overallShare = allTotal > 0 ? ExactDecimal(Decimal(scopeTotal) / Decimal(allTotal))?.rounded(scale: 4) : nil
        }
        var tooling: [EconomicReport.ToolingCost] = []
        for subscription in subscriptions.sorted(by: { $0.id < $1.id }) {
            let from = max(start, subscription.from ?? start), to = min(period.to, subscription.to ?? period.to)
            let seconds = max(0, Int(to.timeIntervalSince(from)))
            var amount = Decimal(seconds) / Decimal(secondsPerMonth) * subscription.monthly.amount.decimal
            let days = ExactDecimal(Decimal(seconds) / 86_400)?.rounded(scale: 1).description ?? "0"
            var calculation = "\(subscription.monthly.amount) \(subscription.monthly.currency) a month × \(days) of 30.44 days"
            if projectScoped {
                guard let share = shares[subscription.provider] else { continue }
                amount *= share.decimal
                calculation += " × \(percent(share)) of \(subscription.provider) tokens"
            }
            guard let value = ExactDecimal(amount)?.rounded(scale: 2) else { continue }
            tooling.append(.init(subscriptionID: subscription.id, provider: subscription.provider, label: subscription.label,
                                 amount: MoneyAmount(amount: value, currency: subscription.monthly.currency), calculation: calculation))
        }
        let currencies = Set(tooling.map(\.amount.currency))
        guard currencies.count <= 1 else {
            return .init(state: .mixedCurrencies, allocation: allocation, allocationShare: overallShare, tooling: tooling, total: nil)
        }
        let currency = currencies.first ?? subscriptions[0].monthly.currency
        let total = tooling.reduce(ExactDecimal.zero) { $0.adding($1.amount.amount) ?? $0 }.rounded(scale: 2)
        return .init(state: .known, allocation: allocation, allocationShare: overallShare, tooling: tooling, total: MoneyAmount(amount: total, currency: currency))
    }

    static func economics(items: [EconomicReport.OutcomeItem], effort: EconomicReport.Effort, operatorTime: EconomicReport.OperatorSummary,
                          costs: EconomicReport.Costs, assumptions: EconomicAssumptions) -> EconomicReport.Economics {
        let rate = EconomicCatalog.rate(assumptions.rateID, in: assumptions) ?? EconomicCatalog.rate(EconomicCatalog.defaultRateID, in: assumptions)!
        let operatorRate = assumptions.operatorRateID.flatMap { EconomicCatalog.rate($0, in: assumptions) } ?? rate
        var missing: [String] = []
        if items.isEmpty { missing.append("accepted_outcomes") }
        if effort.estimatedOutcomes == 0 || effort.unestimatedOutcomes > 0 { missing.append("effort_estimates") }
        if operatorTime.state != .known { missing.append("operator_time") }
        if costs.state != .known { missing.append(costs.state == .mixedCurrencies ? "single_currency" : "tooling_cost") }
        let currency = rate.hourly.currency
        if operatorRate.hourly.currency != currency || (costs.total.map { $0.currency != currency } ?? false), !missing.contains("single_currency") {
            missing.append("single_currency")
        }
        let gross = effort.hours.flatMap { $0.multiplied(by: rate.hourly.amount) }.map { MoneyRange(currency: currency, range: $0.rounded(scale: 2)) }
        let operatorCost = operatorTime.hours.flatMap { $0.multiplied(by: operatorRate.hourly.amount) }
            .map { MoneyRange(currency: operatorRate.hourly.currency, range: $0.rounded(scale: 2)) }
        var net: MoneyRange?, leverage: EstimateRange?
        if missing.isEmpty, let gross, let operatorCost, let tooling = costs.total?.amount {
            if let low = gross.low.subtracting(operatorCost.high).flatMap({ $0.subtracting(tooling) }),
               let base = gross.base.subtracting(operatorCost.base).flatMap({ $0.subtracting(tooling) }),
               let high = gross.high.subtracting(operatorCost.low).flatMap({ $0.subtracting(tooling) }) {
                net = MoneyRange(currency: currency, range: EstimateRange(low: low, base: base, high: high).rounded(scale: 2))
            }
        }
        if operatorTime.state == .known, let hours = effort.hours, let spent = operatorTime.hours, spent.low > 0, effort.unestimatedOutcomes == 0,
           let low = hours.low.divided(by: spent.high), let base = hours.base.divided(by: spent.base), let high = hours.high.divided(by: spent.low) {
            leverage = EstimateRange(low: low, base: base, high: high).rounded(scale: 1)
        }
        let state: EconomicReport.Economics.State = missing.isEmpty && net != nil ? .available : (gross != nil ? .partial : .unavailable)
        return .init(state: state, missing: missing, rate: rate, operatorRate: operatorRate, grossLaborEquivalent: gross, operatorCost: operatorCost,
                     toolingCost: costs.total, netOpportunity: net, leverage: leverage)
    }

    // MARK: Friction and uncertainty

    static func friction(shipped: ShippedCodeReport.Result, usage: EconomicReport.Usage, rejected: Int) -> [EconomicReport.Friction] {
        var values: [EconomicReport.Friction] = []
        let totals = shipped.totals
        if shipped.hasScan, totals.sessionsWithoutCommits > 0 {
            values.append(.init(kind: .sessionsWithoutCommits, count: totals.sessionsWithoutCommits, tokens: TokenQuantity(totals.tokensWithoutCommits),
                                detail: "\(totals.sessionsWithoutCommits) of \(totals.sessions) agent sessions in scanned repositories have no linked commit. Research, reviews, planning and uncommitted work land here too."))
        }
        if let composition = usage.composition, let share = usage.rereadShare, share > 0 {
            values.append(.init(kind: .contextReread, count: usage.modelSteps, tokens: composition.rereadContext, share: share,
                                detail: "\(percent(share)) of known tokens were context re-sent from cache on each step."))
        }
        let reverts = shipped.commits.filter { $0.commit.subject.hasPrefix("Revert \"") }
        if !reverts.isEmpty {
            values.append(.init(kind: .revertedCommits, count: reverts.count, detail: "\(reverts.count) \(reverts.count == 1 ? "commit reverts" : "commits revert") earlier work.",
                                evidence: reverts.prefix(20).map { String($0.commit.id.prefix(12)) }))
        }
        if rejected > 0 {
            values.append(.init(kind: .rejectedOutcomes, count: rejected, detail: "\(rejected) suggested \(rejected == 1 ? "outcome was" : "outcomes were") rejected as not useful."))
        }
        let unlinked = shipped.commits.filter { !$0.isLinked }
        if shipped.hasScan, !unlinked.isEmpty {
            values.append(.init(kind: .unlinkedCommits, count: unlinked.count,
                                detail: "\(unlinked.count) \(unlinked.count == 1 ? "commit isn't" : "commits aren't") linked to any agent session in view.",
                                evidence: unlinked.prefix(20).map { String($0.commit.id.prefix(12)) }))
        }
        return values
    }

    static func uncertainty(accounting: ActivityAccounting.Report, shipped: ShippedCodeReport.Result, outcomes: EconomicReport.Outcomes,
                            effort: EconomicReport.Effort, economics: EconomicReport.Economics, costs: EconomicReport.Costs,
                            period: EconomicReport.Period, assumptions: EconomicAssumptions, scope: Scope, query: EconomicReportQuery) -> [EconomicReport.Note] {
        var notes: [EconomicReport.Note] = []
        func add(_ code: String, _ message: String) { notes.append(.init(code: code, message: message)) }
        if accounting.sourceCoverageIsPartial { add("source_coverage_partial", "Saved history covers what this Mac's agents recorded; it isn't an account-wide total.") }
        if accounting.totals.tokensArePartial { add("tokens_partial", "Some usage records have no token counts, so token totals are lower bounds.") }
        if !shipped.hasScan {
            add("no_repository_scan", "No scanned repository is in scope. Run Scan projects to link commits and suggest outcomes.")
        } else {
            if let scanned = shipped.totals.newestScan, scanned < period.to.addingTimeInterval(-3_600) {
                add("scan_before_period_end", "The last scan ran before the period ended; later commits aren't included.")
            }
            if let oldest = shipped.totals.oldestScan, let from = period.from, from < oldest.addingTimeInterval(-30 * 86_400) {
                add("git_window", "Scans read the last 30 days of Git history; earlier commits in this period aren't included.")
            } else if period.from == nil { add("git_window", "Scans read the last 30 days of Git history; older commits aren't included.") }
        }
        if shipped.totals.unavailableRepositories > 0 { add("repositories_unavailable", "\(shipped.totals.unavailableRepositories) repositories with agent work couldn't be read.") }
        if outcomes.pendingCandidates > 0 { add("pending_candidates", "\(outcomes.pendingCandidates) suggested outcomes are waiting for a decision; only accepted work counts.") }
        if effort.unestimatedOutcomes > 0 { add("unestimated_outcomes", "\(effort.unestimatedOutcomes) of \(outcomes.accepted) accepted outcomes have no effort estimate for this baseline.") }
        let disagreements = outcomes.items.filter { $0.effort?.disagreement == true }.count
        if disagreements > 0 { add("assessment_disagreement", "Estimates disagree by more than half for \(disagreements) outcomes; the person's estimate is used when there is one.") }
        let reverted = outcomes.items.filter { $0.revertedCommits > 0 }.count
        if reverted > 0 { add("reverted_evidence", "\(reverted) accepted \(reverted == 1 ? "outcome includes" : "outcomes include") commits that were later reverted; revise or withdraw \(reverted == 1 ? "it" : "them") if the work didn't stick.") }
        let stale = outcomes.items.filter { $0.effort?.stale == true }.count
        if stale > 0 { add("stale_assessments", "\(stale) estimates were made before their outcome was last revised.") }
        if outcomes.accepted > 0, economics.missing.contains("operator_time") { add("operator_time_unknown", "Hands-on time isn't recorded for every accepted outcome, so net benefit and leverage stay unknown.") }
        if costs.state == .unknown { add("tooling_cost_unknown", "No subscriptions are set, so tooling cost is unknown. Add them with bridge economics assumptions --subscription.") }
        if costs.state == .mixedCurrencies { add("mixed_currencies", "Subscriptions use different currencies; costs aren't added together.") }
        if scope.parentFolderSessions > 0 { add("parent_folder_sessions", "\(scope.parentFolderSessions) sessions started in a parent folder are counted whole, though they may also have worked elsewhere.") }
        if assumptions.baseline == .contemporary { add("contemporary_baseline", "Uplift from 2025–2026 assistants is uncertain and can be negative, so these estimates use a wide range.") }
        if query.provider != nil { add("provider_filter", "Only \(query.provider!.rawValue) usage and subscriptions are counted; outcomes are those its sessions worked on.") }
        add("wage_equivalent", "Wage equivalents are what comparable hours would cost at the chosen rate: not revenue, market value or cash saved.")
        return notes
    }

    static func percent(_ share: ExactDecimal) -> String {
        let value = (share.multiplied(by: 100) ?? .zero).rounded(scale: 1)
        return "\(value)%"
    }
}
