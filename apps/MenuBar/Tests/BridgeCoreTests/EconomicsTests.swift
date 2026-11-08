import Foundation
import XCTest
@testable import BridgeCore
import WorkspaceContracts

/// Economic reporting over a synthetic workspace: one repository, a Claude
/// session that co-authors two commits, a Codex thread started in the
/// parent folder with a sub-agent, a revert, a cherry-picked copy, an
/// unlinked commit and a session that ships nothing. Every identifier, path
/// and figure is invented; no native file, account or repository is read.
final class EconomicsTests: XCTestCase {
    static let base = Date(timeIntervalSince1970: 1_767_603_600) // 2026-01-05T09:00:00Z
    static let root = (0 ..< 5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
    static let schemas = root.appendingPathComponent("schemas")
    static let golden = root.appendingPathComponent("tests/fixtures/workspace-economics/v1/golden-report-bundle")
    static let home = "/Users/example"
    static let week = EconomicReportQuery(from: base, to: base.addingTimeInterval(7 * 86_400))

    // MARK: Accounting parity and receipts

    func testUsageAndTimeComeFromTheSameAccountingAsMetrics() throws {
        let overview = Self.overview()
        let report = try Self.build(overview: overview).report
        let accounting = try ActivityAccountingQuery(from: Self.base, to: Self.base.addingTimeInterval(7 * 86_400)).report(overview: overview)
        XCTAssertEqual(report.usage.tokens?.intValue, accounting.totals.tokensKnown)
        XCTAssertEqual(report.usage.outputTokens?.intValue, accounting.totals.outputKnown)
        XCTAssertEqual(report.usage.modelSteps, accounting.totals.observedModelSteps)
        XCTAssertEqual(report.usage.sessions, accounting.totals.sessions)
        XCTAssertEqual(report.time.activeSeconds, accounting.totals.activeSeconds.map { Int($0) })
        XCTAssertEqual(report.time.agentSeconds, accounting.totals.agentSeconds.map { Int($0) })
        XCTAssertEqual(report.snapshot.accountingFingerprint, try EconomicReportBuilder.fingerprint(accounting), "The report names the accounting result it used")
        XCTAssertEqual(report.usage.byProvider.map(\.modelSteps).reduce(0, +), accounting.totals.observedModelSteps)
        XCTAssertEqual(report.usage.byProvider.map(\.sessions), [2, 3])
        XCTAssertEqual(report.usage.tokens?.intValue, 7_500)
        XCTAssertEqual(report.usage.byProvider.compactMap { $0.tokens?.intValue }.reduce(0, +), 7_500, "Provider rows add up to the total")
        XCTAssertNil(report.time.providerComputeSeconds, "Never reported, so never invented")
        XCTAssertNil(report.time.localCPUSeconds)
        XCTAssertEqual(report.usage.scope, "local_native_history")
    }

    func testReceiptProjectionFoldsBackToTheAccountingTotals() throws {
        let overview = Self.overview()
        let accounting = ActivityAccounting.build(overview: overview, from: nil, to: overview.generatedAt)
        let receipts = try WorkspaceReceiptProjection.receipts(from: accounting)
        XCTAssertEqual(receipts.count, accounting.receipts.count)
        var ledger = WorkspaceReceiptLedger()
        let first = ledger.ingest(receipts)
        XCTAssertEqual(first.rejected, [])
        XCTAssertEqual(first.conflicts, [])
        let totals = ledger.totals()
        XCTAssertEqual(totals.tokens?.intValue, accounting.totals.tokensKnown)
        XCTAssertEqual(totals.output?.intValue, accounting.totals.outputKnown)
        let replay = ledger.ingest(try WorkspaceReceiptProjection.receipts(from: accounting))
        XCTAssertEqual(replay.duplicates, receipts.count, "Re-exporting the same snapshot is a pure replay")
        XCTAssertEqual(ledger.totals().tokens, totals.tokens)
        var check = JSONSchemaCheck(directory: Self.schemas)
        for receipt in receipts { XCTAssertEqual(try check.validate(ContractJSON.encoder.encode(receipt), against: "workspace-receipt-v1.schema.json"), []) }
        XCTAssertTrue(receipts.filter { $0.unit == .modelStep }.allSatisfy { $0.aggregates == nil }, "Turn counters are never copied onto each step")
    }

    // MARK: Candidates

    func testCandidatesFollowAgentThreadsFoldCopiesAndFindReverts() throws {
        let output = try Self.build(overview: Self.overview())
        let candidates = output.candidates
        XCTAssertEqual(candidates.count, 4)
        let billing = try XCTUnwrap(candidates.first { $0.commits.map(\.id) == ["c1000001", "c2000002"] })
        XCTAssertEqual(billing.thread, "claude:s1")
        XCTAssertEqual(billing.title, "Add billing export (+1 more)")
        XCTAssertEqual(billing.lines, LineCounts(additions: 430, deletions: 25))
        XCTAssertEqual(billing.commits[0].generatedLines, 20, "Lock-file lines are counted and labelled")
        let audit = try XCTUnwrap(candidates.first { $0.commits.first?.id == "c4000004" })
        XCTAssertEqual(audit.commits.count, 1)
        XCTAssertEqual(audit.commits[0].duplicates, ["c5000005"], "A cherry-picked copy counts once")
        XCTAssertEqual(audit.thread, "codex:s2", "A parent-folder thread that edited the repository ties its commits")
        XCTAssertEqual(audit.commits[0].link, "same_files")
        let revert = try XCTUnwrap(candidates.first { $0.commits.first?.id == "c3000003" })
        XCTAssertEqual(revert.commits[0].reverts, "c2000002")
        XCTAssertNil(revert.thread)
        XCTAssertTrue(candidates.allSatisfy { !$0.isDecided })
        XCTAssertEqual(Set(candidates.map(\.id)).count, 4)
        XCTAssertEqual(try Self.build(overview: Self.overview()).candidates.map(\.id), candidates.map(\.id), "Suggestion IDs are stable")
    }

    // MARK: Ledger

    func testLedgerIsAppendOnlyAndRefusesConflictingDecisions() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = EconomicLedger(directory: folder)
        let first = try await ledger.decide(Self.decision(commits: ["c1000001", "c2000002"], candidate: "cand-a"), now: Self.base)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.outcomeID, first.id)

        await XCTAssertThrowsAsync(try await ledger.decide(Self.decision(commits: ["c2000002"]), now: Self.base), "A commit belongs to one accepted outcome")
        await XCTAssertThrowsAsync(try await ledger.decide(Self.decision(commits: ["c4000004"], candidate: "cand-a"), now: Self.base), "A suggestion is decided once")
        let rejected = try await ledger.decide(Self.decision(commits: ["c2000002"], decision: .rejected), now: Self.base)
        await XCTAssertThrowsAsync(try await ledger.decide(Self.decision(commits: ["c2000002"], decision: .withdrawn, correction: .init(reason: .regression)),
                                                           revising: rejected.id, now: Self.base), "Only accepted work can be withdrawn")

        var revised = Self.decision(commits: ["c1000001", "c2000002"], candidate: "cand-a")
        revised.operatorTime = .known(low: 2, high: 3)
        let second = try await ledger.decide(revised, revising: first.id, now: Self.base.addingTimeInterval(60))
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.supersedesID, first.id)
        XCTAssertEqual(second.outcomeID, first.outcomeID)
        await XCTAssertThrowsAsync(try await ledger.decide(revised, revising: first.id, now: Self.base), "Revising an old revision is stale")

        let state = try await ledger.state()
        XCTAssertEqual(state.outcomes.count, 3, "Earlier revisions stay")
        XCTAssertEqual(state.latestOutcomes.count, 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("outcomes").path)
        XCTAssertEqual(files.count, 3)
        for file in files {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("outcomes/\(file)").path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
        }

        // Interrupted writes are ignored; foreign files stop the read without changes.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("outcomes/.pending-x"))
        let afterStaging = try await ledger.state()
        XCTAssertEqual(afterStaging.outcomes.count, 3)
        let stray = folder.appendingPathComponent("outcomes/\(UUID().uuidString.lowercased()).json")
        try Data("not json".utf8).write(to: stray)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stray.path)
        await XCTAssertThrowsAsync(try await ledger.state(), "An unreadable record is reported, not skipped")
        try FileManager.default.removeItem(at: stray)

        // Assessments: importing the same record twice is a no-op.
        let assessment = Self.assessment(outcome: second, low: "16", base: "28", high: "48")
        let inserted = try await ledger.assess(assessment).inserted
        let replayed = try await ledger.assess(assessment).inserted
        XCTAssertTrue(inserted)
        XCTAssertFalse(replayed)
        var changed = assessment
        changed.hours = EstimateRange(low: 1, base: 2, high: 3)
        await XCTAssertThrowsAsync(try await ledger.assess(changed), "Another record can't reuse an ID")
        var orphan = Self.assessment(outcome: second, low: "1", base: "2", high: "3")
        orphan.outcomeID = UUID().uuidString.lowercased(); orphan.outcomeRevisionID = orphan.outcomeID
        await XCTAssertThrowsAsync(try await ledger.assess(orphan))

        let assumptions = EconomicCatalog.defaultAssumptions(timeZone: TimeZone(identifier: "UTC")!)
        let one = try await ledger.setAssumptions(assumptions, now: Self.base)
        let again = try await ledger.setAssumptions(assumptions, now: Self.base.addingTimeInterval(5))
        XCTAssertEqual(one, again, "Unchanged assumptions add no revision")
        var other = assumptions; other.hoursPerDay = 7
        let revisedAssumptions = try await ledger.setAssumptions(other, now: Self.base)
        XCTAssertEqual(revisedAssumptions.revision, 2)
    }

    // MARK: Economics

    func testEconomicsStayUnknownUntilEveryInputExists() throws {
        let report = try Self.build(overview: Self.overview()).report
        XCTAssertEqual(report.outcomes.accepted, 0)
        XCTAssertEqual(report.outcomes.pendingCandidates, 4)
        XCTAssertEqual(report.economics.state, .unavailable)
        XCTAssertEqual(report.economics.missing, ["accepted_outcomes", "effort_estimates", "operator_time", "tooling_cost"])
        XCTAssertNil(report.economics.grossLaborEquivalent)
        XCTAssertNil(report.economics.netOpportunity)
        XCTAssertNil(report.economics.leverage)
        XCTAssertEqual(report.costs.state, .unknown)
        XCTAssertEqual(report.time.operatorTime.state, .unknown)
        XCTAssertTrue(report.nextPrompt.contains("4 suggested outcomes"))
        XCTAssertTrue(report.uncertainty.contains { $0.code == "wage_equivalent" })

        // An accepted outcome with an estimate but no hands-on time: wage equivalent only.
        var state = Self.ledgerState(operatorTime: .unknown, subscriptions: [])
        state.assumptions = []
        let partial = try Self.build(overview: Self.overview(), ledger: state).report
        XCTAssertEqual(partial.economics.state, .partial)
        XCTAssertEqual(partial.economics.missing, ["operator_time", "tooling_cost"])
        XCTAssertNotNil(partial.economics.grossLaborEquivalent)
        XCTAssertNil(partial.economics.netOpportunity)
        XCTAssertNil(partial.economics.leverage, "Leverage needs hands-on time")
    }

    func testCompleteInputsGiveExactWageEquivalentNetBenefitAndLeverage() throws {
        let report = try Self.build(overview: Self.overview(), ledger: Self.ledgerState()).report
        XCTAssertEqual(report.outcomes.accepted, 1)
        XCTAssertEqual(report.outcomes.commitsInAcceptedOutcomes, 2)
        XCTAssertEqual(report.outcomes.pendingCandidates, 3, "The accepted suggestion is no longer pending")
        let item = try XCTUnwrap(report.outcomes.items.first)
        XCTAssertEqual(item.lines, LineCounts(additions: 430, deletions: 25))
        XCTAssertEqual(item.repositories, ["acme-billing"])
        XCTAssertEqual(item.revertedCommits, 1, "c2000002 was reverted later; the outcome says so")
        XCTAssertTrue(report.uncertainty.contains { $0.code == "reverted_evidence" })
        XCTAssertEqual(item.effort?.assessor.kind, .human)
        XCTAssertEqual(item.effort?.assessments, 2)
        XCTAssertEqual(item.effort?.spread, EstimateRange(low: 16, base: 28, high: 60), "The model's estimate stays visible in the spread")
        XCTAssertEqual(item.effort?.disagreement, false)
        XCTAssertEqual(report.effort.hours, EstimateRange(low: 16, base: 28, high: 48))
        XCTAssertEqual(report.effort.personDays, EstimateRange(low: 2, base: ExactDecimal("3.5")!, high: 6))
        XCTAssertEqual(report.costs.state, .known)
        XCTAssertEqual(report.costs.total, MoneyAmount(amount: 92, currency: "USD"), "200 USD a month, twice, over 7 of 30.44 days, rounded per plan")
        XCTAssertEqual(report.costs.tooling.first?.calculation, "200 USD a month × 7 of 30.44 days")
        let economics = report.economics
        XCTAssertEqual(economics.state, .available)
        XCTAssertEqual(economics.missing, [])
        XCTAssertEqual(economics.rate.id, EconomicCatalog.defaultRateID)
        XCTAssertEqual(economics.grossLaborEquivalent, MoneyRange(currency: "USD", range: Self.range("1046.08", "1830.64", "3138.24")))
        XCTAssertEqual(economics.operatorCost, MoneyRange(currency: "USD", range: Self.range("130.76", "163.45", "196.14")))
        XCTAssertEqual(economics.netOpportunity, MoneyRange(currency: "USD", range: Self.range("757.94", "1575.19", "2915.48")),
                       "Low pairs the least estimated effort with the most hands-on time")
        XCTAssertEqual(economics.leverage, Self.range("5.3", "11.2", "24"))
        let text = String(decoding: try ContractJSON.encoder.encode(report), as: UTF8.self)
        XCTAssertTrue(text.contains(#""low":"1046.08""#), "Money stays an exact decimal string")
        XCTAssertFalse(text.contains("Synthetic private title"), "Session titles never reach the report")
    }

    func testChangingAssumptionsMakesANewReportWithoutTouchingUsage() throws {
        let overview = Self.overview()
        let first = try Self.build(overview: overview, ledger: Self.ledgerState()).report
        var state = Self.ledgerState()
        var assumptions = state.assumptions[0].assumptions
        assumptions.rateID = "us-bls-15-1252-2021-05"
        state.assumptions.append(EconomicAssumptionsRecord(id: "7a0b0c0d-0e0f-4a1b-8c2d-3e4f5a6b7c8d", revision: 2, supersedesID: state.assumptions[0].id,
                                                           createdAt: Self.base, assumptions: assumptions))
        let second = try Self.build(overview: overview, ledger: state).report
        XCTAssertNotEqual(first.reportID, second.reportID)
        XCTAssertEqual(first.usage, second.usage)
        XCTAssertEqual(first.time, second.time)
        XCTAssertEqual(first.snapshot.accountingFingerprint, second.snapshot.accountingFingerprint)
        XCTAssertEqual(second.economics.grossLaborEquivalent?.low, ExactDecimal("928.8"), "16 h × 58.05")
        let again = try Self.build(overview: overview, ledger: Self.ledgerState(), generatedAt: Self.base.addingTimeInterval(99_999)).report
        XCTAssertEqual(again.reportID, first.reportID, "Identity depends on content, not build time")
    }

    func testWithdrawnWorkMovesToCorrectionsAndLeavesTheTotals() throws {
        var state = Self.ledgerState()
        let accepted = state.outcomes[0]
        var withdrawn = AcceptedOutcomeRecord(id: "9e8d7c6b-5a49-4382-a716-151413121110", outcomeID: accepted.outcomeID, revision: 2, supersedesID: accepted.id,
                                              createdAt: Self.base.addingTimeInterval(4 * 86_400), decision: .withdrawn, title: accepted.title,
                                              deliveryStandard: accepted.deliveryStandard, evidence: accepted.evidence, landedAt: accepted.landedAt,
                                              operatorTime: accepted.operatorTime, candidateID: accepted.candidateID, correction: .init(reason: .reverted))
        withdrawn.correction?.note = "Reverted after review"
        XCTAssertNoThrow(try withdrawn.validate())
        state.outcomes.append(withdrawn)
        let report = try Self.build(overview: Self.overview(), ledger: state).report
        XCTAssertEqual(report.outcomes.accepted, 0)
        XCTAssertEqual(report.outcomes.corrections.map(\.reason), [.reverted])
        XCTAssertEqual(report.outcomes.corrections.first?.landedAt, accepted.landedAt)
        XCTAssertEqual(report.outcomes.commitsInAcceptedOutcomes, 0)
        XCTAssertEqual(report.outcomes.pendingCandidates, 3, "Withdrawn work isn't suggested again")
        XCTAssertNil(report.economics.grossLaborEquivalent)
    }

    func testProjectScopeFollowsTheRepositoryAndSharesToolingByTokens() throws {
        var query = Self.week
        query.project = "/work/acme/billing"
        let report = try Self.build(overview: Self.overview(), ledger: Self.ledgerState(), query: query).report
        XCTAssertEqual(report.scope.projects.map(\.name), ["acme-billing"])
        XCTAssertEqual(report.usage.tokens?.intValue, 7_200, "The other project's 300 tokens stay out; the parent-folder thread that edited it is in")
        XCTAssertTrue(report.uncertainty.contains { $0.code == "parent_folder_sessions" })
        XCTAssertEqual(report.costs.allocation, .tokenShare)
        let claude = try XCTUnwrap(report.costs.tooling.first { $0.provider == "claude" })
        XCTAssertEqual(claude.calculation, "200 USD a month × 7 of 30.44 days × 76.9% of claude tokens")
        XCTAssertEqual(claude.amount.amount, ExactDecimal("35.38"))
        let codex = try XCTUnwrap(report.costs.tooling.first { $0.provider == "codex" })
        XCTAssertTrue(codex.calculation.hasSuffix("× 100% of codex tokens"))
        XCTAssertThrowsError(try Self.build(overview: Self.overview(), query: EconomicReportQuery(project: "/nowhere")))
    }

    // MARK: Briefing and exchange

    func testBriefingRendersTheReportsOwnFiguresAndAConcretePrompt() throws {
        let report = try Self.build(overview: Self.overview(), ledger: Self.ledgerState()).report
        let briefing = FeedbackBriefingBuilder.markdown(report)
        for fragment in [report.reportID, "**Billing export**", "1,046.08–3,138.24 USD (base 1,830.64)", "757.94–2,915.48 USD (base 1,575.19)",
                         "Evidence: c1000001, c2000002", "## Suggested next prompt", "> " + report.nextPrompt.split(separator: "\n")[0],
                         "16–48 h (base 28 h)", "Agent time isn't human effort", "Not revenue, market value or cash saved",
                         "1 of its commits later reverted", "across 1 accepted outcome."] {
            XCTAssertTrue(briefing.contains(fragment), fragment)
        }
        XCTAssertFalse(briefing.contains("Synthetic private title"))
        XCTAssertEqual(FeedbackBriefingBuilder.markdown(report), briefing, "Deterministic")
    }

    func testBundlesConformToTheirSchemasAndSanitizingRemovesNames() throws {
        let output = try Self.build(overview: Self.overview(), ledger: Self.ledgerState())
        var check = JSONSchemaCheck(directory: Self.schemas)
        for sanitized in [false, true] {
            let bundle = try EconomicReportExchange.bundle(output, sanitized: sanitized, includeReceipts: true, createdAt: Self.base, salt: "fixed-salt")
            func file(_ name: String) throws -> Data { try XCTUnwrap(bundle.files[name], name) }
            XCTAssertEqual(try check.validate(file("report.json"), against: "economic-report-v1.schema.json"), [])
            XCTAssertEqual(try check.validate(file("outcomes.json"), against: "report-bundle-v1.schema.json", definition: "outcomesFile"), [])
            XCTAssertEqual(try check.validate(file("assessments.json"), against: "report-bundle-v1.schema.json", definition: "assessmentsFile"), [])
            XCTAssertEqual(try check.validate(file("assumptions.json"), against: "economic-report-v1.schema.json", definition: "assumptionsBundle"), [])
            XCTAssertEqual(try check.validate(file("evidence-index.json"), against: "report-bundle-v1.schema.json", definition: "evidenceIndex"), [])
            XCTAssertEqual(try check.validate(ContractJSON.encoder.encode(bundle.manifest), against: "report-bundle-v1.schema.json"), [])
            for line in try file("receipts.jsonl").split(separator: UInt8(ascii: "\n")) {
                XCTAssertEqual(try check.validate(Data(line), against: "workspace-receipt-v1.schema.json"), [])
            }
            let decoded = try ContractJSON.decoder.decode(EconomicReport.self, from: file("report.json"))
            XCTAssertEqual(try decoded.computedID(), decoded.reportID, "The written report keeps its identity")
            let everything = bundle.files.values.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
            if sanitized {
                XCTAssertEqual(decoded.contentLevel, .sanitized)
                for secret in ["Billing export", "Add billing export", "/work/acme", "acme-billing", "c1000001", "claude:s1", "codex:s2", "Reviewed by the team"] {
                    XCTAssertFalse(everything.contains(secret), secret)
                }
                XCTAssertEqual(decoded.economics.netOpportunity, output.report.economics.netOpportunity, "Numbers survive sanitizing")
                XCTAssertNotEqual(decoded.reportID, output.report.reportID)
            } else {
                XCTAssertTrue(everything.contains("Billing export"))
            }
        }
        // Written folders are private and verify.
        let folder = try Self.temporaryFolder().appendingPathComponent("bundle")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let bundle = try EconomicReportExchange.bundle(output, sanitized: true, createdAt: Self.base, salt: "fixed-salt")
        try EconomicReportExchange.write(bundle, to: folder)
        XCTAssertEqual(try ReportBundleManifest.verify(directory: folder), bundle.manifest)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("report.json").path)[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try EconomicReportExchange.write(bundle, to: folder), "Never writes into an existing folder")
    }

    func testGoldenReportBundleIsByteStable() throws {
        let output = try Self.build(overview: Self.overview(), ledger: Self.ledgerState())
        let bundle = try EconomicReportExchange.bundle(output, sanitized: false, createdAt: Self.base)
        var files = bundle.files
        files["manifest.json"] = try ContractJSON.prettyEncoder.encode(bundle.manifest)
        if ProcessInfo.processInfo.environment["WORKSPACE_CONTRACTS_WRITE_FIXTURES"] == "1" {
            try? FileManager.default.removeItem(at: Self.golden)
            try FileManager.default.createDirectory(at: Self.golden, withIntermediateDirectories: true)
            for (name, data) in files { try data.write(to: Self.golden.appendingPathComponent(name)) }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.golden.path).sorted()
        XCTAssertEqual(names, files.keys.sorted())
        for name in names {
            XCTAssertEqual(try Data(contentsOf: Self.golden.appendingPathComponent(name)), files[name], "\(name) changed; regenerate with WORKSPACE_CONTRACTS_WRITE_FIXTURES=1 if intended")
        }
        XCTAssertEqual(try ReportBundleManifest.verify(directory: Self.golden), bundle.manifest)
    }

    // MARK: Skill

    func testSkillExamplesFollowTheContractAndTheRubricTableStaysInSync() async throws {
        let skill = Self.root.appendingPathComponent("skills/economic-work-review")
        let example = try Data(contentsOf: skill.appendingPathComponent("examples/model-assessment.json"))
        let records = try ContractJSON.decoder.decode([EffortAssessmentRecord].self, from: example)
        for record in records { XCTAssertNoThrow(try record.validate()) }
        var check = JSONSchemaCheck(directory: Self.schemas)
        XCTAssertEqual(try check.validate(example, against: "report-bundle-v1.schema.json", definition: "assessmentsFile"), [])
        XCTAssertNoThrow(try EconomicCatalog.rubric.validate())
        XCTAssertEqual(records.first?.hours, EconomicCatalog.rubric.hours(size: "m", standard: .internalTool, baseline: .historical),
                       "The example uses the rubric's own numbers")

        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = EconomicLedger(directory: folder)
        let golden = Self.ledgerState().outcomes[0]
        let decision = OutcomeDecision(decision: .accepted, title: golden.title, deliveryStandard: golden.deliveryStandard, evidence: golden.evidence, landedAt: golden.landedAt)
        let stored = try await ledger.decide(decision, now: Self.base)
        var imported = records[0]
        imported.outcomeID = stored.outcomeID; imported.outcomeRevisionID = stored.id
        let result = try await ledger.assess(imported)
        XCTAssertTrue(result.inserted)

        let document = skill.appendingPathComponent("references/effort-rubric-v1.md")
        var text = try String(contentsOf: document, encoding: .utf8)
        let start = "<!-- rubric-table:start -->", end = "<!-- rubric-table:end -->"
        let table = start + "\n" + Self.rubricTable() + "\n" + end
        if ProcessInfo.processInfo.environment["WORKSPACE_CONTRACTS_WRITE_FIXTURES"] == "1",
           let lower = text.range(of: start), let upper = text.range(of: end) {
            text.replaceSubrange(lower.lowerBound ..< upper.upperBound, with: table)
            try text.write(to: document, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(text.contains(table), "Regenerate the rubric table with WORKSPACE_CONTRACTS_WRITE_FIXTURES=1")
    }

    static func rubricTable() -> String {
        let rubric = EconomicCatalog.rubric
        var lines = ["| Size | Delivery standard | Developer with 2021–2022 tools | Developer with 2025–2026 assistants |", "|---|---|---|---|"]
        for size in rubric.sizes {
            for standard in DeliveryStandard.allCases {
                let historical = rubric.hours(size: size.id, standard: standard, baseline: .historical)!
                let contemporary = rubric.hours(size: size.id, standard: standard, baseline: .contemporary)!
                lines.append("| \(size.id) | \(standard.title) | \(historical.low) – \(historical.base) – \(historical.high) h | \(contemporary.low) – \(contemporary.base) – \(contemporary.high) h |")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Service and CLI

    func testServiceAcceptsEstimatesImportsAndExportsWithoutTouchingTheWorkspace() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let overview = Self.overview()
        let service = EconomicReportService(ledger: EconomicLedger(directory: folder.appendingPathComponent("ledger")), overview: { overview },
                                            now: { Self.base.addingTimeInterval(7 * 86_400) }, home: Self.home)
        let candidates = try await service.output(EconomicReportQuery(period: .all)).candidates
        let billing = try XCTUnwrap(candidates.first { $0.commits.first?.id == "c1000001" })
        let accepted = try ContractJSON.decoder.decode(AcceptedOutcomeRecord.self, from: Data(try await service.execute(
            EconomicsCLIRequest(arguments: ["accept", "--candidate", billing.id, "--hands-on", "2-3", "--period", "all"])).utf8))
        XCTAssertEqual(accepted.title, billing.title)
        XCTAssertEqual(accepted.operatorTime, .known(low: 2, high: 3))
        XCTAssertEqual(accepted.landedAt, billing.lastCommitAt)
        XCTAssertEqual(accepted.evidence.filter { $0.kind == .commit }.map(\.ref), ["c1000001", "c2000002"])
        await XCTAssertThrowsAsync(try await service.execute(EconomicsCLIRequest(arguments: ["accept", "--candidate", billing.id, "--period", "all"])))

        let human = try ContractJSON.decoder.decode(EffortAssessmentRecord.self, from: Data(try await service.execute(
            EconomicsCLIRequest(arguments: ["assess", "--outcome", accepted.outcomeID, "--size", "m"])).utf8))
        XCTAssertEqual(human.hours, EstimateRange(low: 16, base: 28, high: 48))
        XCTAssertEqual(human.assessor.rubricVersion, "hub-size-rubric/1")

        // A model's output from the skill, imported twice.
        let model = EffortAssessmentRecord(id: "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f", outcomeID: accepted.outcomeID, outcomeRevisionID: accepted.id,
                                           createdAt: Self.base, assessor: .init(kind: .model, identity: "example-model", rubricVersion: "hub-size-rubric/1"),
                                           baseline: .historical, deliveryStandard: .internalTool, method: .sizeClass, sizeClass: "l",
                                           hours: Self.range("48", "90", "160"), confidence: .low)
        let file = folder.appendingPathComponent("assessments.json")
        try ContractJSON.prettyEncoder.encode([model]).write(to: file)
        let first = try await service.importAssessments(file)
        XCTAssertEqual(first.inserted, [model.id])
        let second = try await service.importAssessments(file)
        XCTAssertEqual(second.unchanged, [model.id])
        XCTAssertEqual(second.inserted, [])

        _ = try await service.execute(EconomicsCLIRequest(arguments: ["assumptions", "--subscription", "claude-max|claude|Claude Max|200|USD"]))
        let report = try await service.output(Self.week).report
        XCTAssertEqual(report.outcomes.items.first?.effort?.assessor.kind, .human, "A person's estimate wins")
        XCTAssertEqual(report.outcomes.items.first?.effort?.disagreement, true, "28 h against 90 h is flagged")
        XCTAssertEqual(report.costs.tooling.map(\.label), ["Claude Max"])

        let exported = try await service.execute(EconomicsCLIRequest(arguments: ["export", "--output", folder.appendingPathComponent("out").path, "--sanitized"]))
        XCTAssertTrue(exported.contains("sanitized report"))
        XCTAssertNoThrow(try ReportBundleManifest.verify(directory: folder.appendingPathComponent("out")))
        let withdrawn = try await service.execute(EconomicsCLIRequest(arguments: ["withdraw", "--outcome", accepted.outcomeID, "--reason", "regression"]))
        XCTAssertTrue(withdrawn.contains("\"withdrawn\""))
    }

    func testCLIRequestsAreStrict() throws {
        XCTAssertEqual(try EconomicsCLIRequest(arguments: []).action, .view)
        XCTAssertEqual(try EconomicsCLIRequest(arguments: ["briefing", "--period", "week", "--previous"]).query, EconomicReportQuery(period: .week, previous: true))
        let export = try EconomicsCLIRequest(arguments: ["export", "--output", "/tmp/x", "--sanitized", "--provider", "codex"])
        XCTAssertEqual(export.query.provider, .codex)
        XCTAssertTrue(export.flags.contains("--sanitized"))
        for bad in [["nope"], ["view", "--period", "fortnight"], ["view", "--previous"], ["export"], ["view", "--output", "/tmp/x"],
                    ["accept"], ["accept", "--candidate", "a", "--commits", "b"], ["accept", "--commits", "abc1234", "--repository", "r"],
                    ["assess", "--outcome", "x"], ["assess", "--outcome", "x", "--size", "m", "--hours", "1"], ["assess", "--file", "f", "--size", "m"],
                    ["withdraw", "--outcome", "x"], ["view", "--period", "7d", "--period", "30d"], ["view", "--project", "relative/path"],
                    ["revise"], ["view", "--sanitized"]] {
            XCTAssertThrowsError(try EconomicsCLIRequest(arguments: bad), bad.joined(separator: " "))
        }
        XCTAssertEqual(try EconomicReportService.handsOn("1.5–3"), .known(low: ExactDecimal("1.5")!, high: 3))
        XCTAssertThrowsError(try EconomicReportService.handsOn("3-1"))
        XCTAssertEqual(try EconomicReportQuery.parse(target: "/economics/report?period=30d&provider=claude").provider, .claude)
        XCTAssertThrowsError(try EconomicReportQuery.parse(target: "/economics/report?window=24h"))
    }

    func testPeriodsUseGregorianCalendarBoundariesInTheChosenZone() throws {
        let bangkok = TimeZone(identifier: "Asia/Bangkok")!
        let asOf = Date(timeIntervalSince1970: 1_767_954_600) // Fri 2026-01-09 10:30 UTC = 17:30 Bangkok
        let week = try EconomicReportQuery(period: .week).resolvePeriod(asOf: asOf, timeZone: bangkok)
        XCTAssertEqual(week.from, Date(timeIntervalSince1970: 1_767_546_000), "Monday 00:00 in Bangkok")
        XCTAssertEqual(week.to, asOf)
        XCTAssertEqual(week.label, "This week")
        let last = try EconomicReportQuery(period: .week, previous: true).resolvePeriod(asOf: asOf, timeZone: bangkok)
        XCTAssertEqual(last.to, week.from)
        XCTAssertEqual(last.from, week.from.map { $0.addingTimeInterval(-7 * 86_400) })
        let month = try EconomicReportQuery(period: .month).resolvePeriod(asOf: asOf, timeZone: bangkok)
        XCTAssertEqual(month.from, Date(timeIntervalSince1970: 1_767_200_400), "1 January 00:00 in Bangkok")
        let rolling = try EconomicReportQuery(period: .last24Hours).resolvePeriod(asOf: asOf, timeZone: bangkok)
        XCTAssertEqual(rolling.from, asOf.addingTimeInterval(-86_400))
        let all = try EconomicReportQuery(period: .all).resolvePeriod(asOf: asOf, timeZone: bangkok)
        XCTAssertNil(all.from)
        XCTAssertThrowsError(try EconomicReportQuery(period: .last7Days, previous: true).resolvePeriod(asOf: asOf, timeZone: bangkok))
        XCTAssertThrowsError(try EconomicReportQuery(to: asOf.addingTimeInterval(1)).resolvePeriod(asOf: asOf, timeZone: bangkok), "Can't end after the snapshot")
    }

    // MARK: Fixture

    static func build(overview: ActivityOverview, ledger: EconomicLedgerState = .empty, query: EconomicReportQuery = week,
                      generatedAt: Date = base.addingTimeInterval(7 * 86_400)) throws -> EconomicReportBuilder.Output {
        var state = ledger
        if state.assumptions.isEmpty {
            state.assumptions = [EconomicAssumptionsRecord(id: "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", revision: 1, supersedesID: nil, createdAt: base,
                                                           assumptions: EconomicCatalog.defaultAssumptions(timeZone: TimeZone(identifier: "UTC")!))]
        }
        return try EconomicReportBuilder.build(.init(overview: overview, query: query, ledger: state, generatedAt: generatedAt, home: home))
    }

    static func overview() -> ActivityOverview {
        func at(_ days: Double, _ hours: Double) -> Date { base.addingTimeInterval(days * 86_400 + hours * 3_600) }
        func turn(_ id: String, _ start: Date, _ end: Date, total: Int, output: Int, cached: Int, codex: Bool, artifacts: [String] = []) -> ActivityTurn {
            let usage = TokenUsage(input: codex ? total - output : total - output - cached, output: output, cachedInput: cached, cacheWriteInput: 0,
                                   reasoning: 0, total: total, provenance: .providerReported)
            return ActivityTurn(id: id, startedAt: start, completedAt: end, durationSeconds: end.timeIntervalSince(start), status: "completed",
                                promptCount: 1, humanPromptCount: 1, toolCount: artifacts.count, model: codex ? "example-codex" : "example-claude",
                                usage: usage, categories: [:], artifacts: artifacts.enumerated().map { ActivityArtifact(id: "\(id)-a\($0.offset)", path: $0.element, kind: "edit") },
                                usageIsPartial: false,
                                modelSteps: [ActivityModelStep(id: id + "-step", timestamp: end, model: codex ? "example-codex" : "example-claude", usage: usage,
                                                               evidence: "synthetic-economics/1", usageIsPartial: false)],
                                modelStepsComplete: true)
        }
        func session(_ id: String, _ provider: AgentName, _ path: String, parent: String? = nil, _ turns: [ActivityTurn]) -> ActivitySession {
            ActivitySession(id: id, provider: provider, nativeID: String(id.split(separator: ":")[1]), title: "Synthetic private title", projectPath: path,
                            createdAt: turns[0].startedAt!, updatedAt: turns.last!.completedAt!, observedAt: at(7, 0), runtimeState: "idle",
                            parentSessionID: parent, turns: turns, historyComplete: true, source: "synthetic-economics-fixture")
        }
        let sessions = [
            session("claude:s1", .claude, "/work/acme/billing", [turn("s1-t1", at(1, 0.5), at(1, 1.9), total: 1_000, output: 100, cached: 600, codex: false,
                                                                       artifacts: ["/work/acme/billing/src/billing.swift"])]),
            session("codex:s2", .codex, "/work/acme", [turn("s2-t1", at(3, 0), at(3, 1.3), total: 5_000, output: 200, cached: 4_000, codex: true,
                                                            artifacts: ["/work/acme/billing/src/audit.swift"])]),
            session("codex:s3", .codex, "/work/acme/billing", parent: "codex:s2", [turn("s3-t1", at(3, 0.5), at(3, 0.8), total: 800, output: 50, cached: 600, codex: true)]),
            session("claude:s4", .claude, "/work/other", [turn("s4-t1", at(4, 1), at(4, 1.5), total: 300, output: 30, cached: 100, codex: false)]),
            session("codex:s5", .codex, "/work/acme/billing", [turn("s5-t1", at(6, -1), at(6, -0.5), total: 400, output: 40, cached: 300, codex: true)]),
        ]
        func commit(_ id: String, _ subject: String, _ time: Date, _ files: [(String, Int, Int)], coAuthors: [AgentName]? = nil) -> ActivityCommit {
            ActivityCommit(id: id, subject: subject, timestamp: time, paths: files.map(\.0), additions: files.reduce(0) { $0 + $1.1 },
                           deletions: files.reduce(0) { $0 + $1.2 }, filesChanged: files.count,
                           files: files.map { ActivityCommitFile(path: $0.0, additions: $0.1, deletions: $0.2) }, coAuthors: coAuthors)
        }
        let repository = ActivityRepository(id: "repo-billing", name: "acme-billing", root: "/work/acme/billing", commits: [
            commit("c1000001", "Add billing export", at(1, 1), [("src/billing.swift", 380, 20), ("package-lock.json", 20, 0)], coAuthors: [.claude]),
            commit("c2000002", "Fix export rounding", at(1, 2), [("src/billing.swift", 30, 5)], coAuthors: [.claude]),
            commit("c3000003", "Revert \"Fix export rounding\"", at(2, 6), [("src/billing.swift", 5, 30)]),
            commit("c4000004", "Add audit log", at(3, 1), [("src/audit.swift", 900, 100)]),
            commit("c5000005", "Add audit log", at(3, 1.5), [("src/audit.swift", 900, 100)]),
            commit("c6000006", "Update README", at(5, 0), [("README.md", 12, 2)]),
        ], observedAt: at(7, 0), commitHistoryAvailable: true)
        return ActivityOverview(generatedAt: at(7, 0), sessions: sessions,
                                sources: [ActivitySourceHealth(id: "claude", status: "ready", checkedAt: at(7, 0), message: "Synthetic"),
                                          ActivitySourceHealth(id: "codex", status: "ready", checkedAt: at(7, 0), message: "Synthetic")],
                                repositories: [repository])
    }

    /// One accepted outcome for the billing commits, a person's estimate, a
    /// model's estimate, and assumptions with two subscriptions.
    static func ledgerState(operatorTime: OperatorTime = .known(low: 2, high: 3),
                            subscriptions: [ToolSubscription] = [
                                ToolSubscription(id: "claude-max", provider: "claude", label: "Claude Max", monthly: MoneyAmount(amount: 200, currency: "USD")),
                                ToolSubscription(id: "chatgpt-pro", provider: "codex", label: "ChatGPT Pro", monthly: MoneyAmount(amount: 200, currency: "USD")),
                            ]) -> EconomicLedgerState {
        let outcomeID = "5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e"
        let outcome = AcceptedOutcomeRecord(id: outcomeID, outcomeID: outcomeID, createdAt: base.addingTimeInterval(2 * 86_400), decision: .accepted,
                                            title: "Billing export", summary: "Reviewed by the team", deliveryStandard: .internalTool,
                                            evidence: [OutcomeEvidence(kind: .commit, repositoryID: "repo-billing", ref: "c1000001"),
                                                       OutcomeEvidence(kind: .commit, repositoryID: "repo-billing", ref: "c2000002"),
                                                       OutcomeEvidence(kind: .session, ref: "claude:s1")],
                                            landedAt: base.addingTimeInterval(86_400 + 2 * 3_600), operatorTime: operatorTime)
        var human = assessment(outcome: outcome, low: "16", base: "28", high: "48")
        human.id = "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"
        var model = assessment(outcome: outcome, low: "20", base: "32", high: "60")
        model.id = "8f9e0d1c-2b3a-4c5d-8e7f-6a5b4c3d2e1f"
        model.assessor = .init(kind: .model, identity: "example-model", rubricVersion: "hub-size-rubric/1")
        model.method = .expertJudgment; model.sizeClass = nil
        model.createdAt = base.addingTimeInterval(3 * 86_400)
        var assumptions = EconomicCatalog.defaultAssumptions(timeZone: TimeZone(identifier: "UTC")!)
        assumptions.subscriptions = subscriptions
        return EconomicLedgerState(outcomes: [outcome], assessments: [human, model],
                                   assumptions: [EconomicAssumptionsRecord(id: "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f7a", revision: 1, supersedesID: nil,
                                                                           createdAt: base, assumptions: assumptions)])
    }

    static func decision(commits: [String], decision: AcceptedOutcomeRecord.Decision = .accepted, candidate: String? = nil,
                         correction: AcceptedOutcomeRecord.Correction? = nil) -> OutcomeDecision {
        OutcomeDecision(decision: decision, title: "Billing export", deliveryStandard: .internalTool,
                        evidence: commits.map { OutcomeEvidence(kind: .commit, repositoryID: "repo-billing", ref: $0) },
                        landedAt: base.addingTimeInterval(86_400), candidateID: candidate, correction: correction)
    }

    static func assessment(outcome: AcceptedOutcomeRecord, low: String, base hours: String, high: String) -> EffortAssessmentRecord {
        EffortAssessmentRecord(id: UUID().uuidString.lowercased(), outcomeID: outcome.outcomeID, outcomeRevisionID: outcome.id,
                               createdAt: base.addingTimeInterval(2 * 86_400), assessor: .init(kind: .human, identity: "user", rubricVersion: "hub-size-rubric/1"),
                               baseline: .historical, deliveryStandard: .internalTool, method: .sizeClass, sizeClass: "m",
                               hours: range(low, hours, high), rationale: "Three components and a schema.", confidence: .medium)
    }

    static func range(_ low: String, _ base: String, _ high: String) -> EstimateRange {
        EstimateRange(low: ExactDecimal(low)!, base: ExactDecimal(base)!, high: ExactDecimal(high)!)
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("economics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error. " + message, file: file, line: line)
    } catch {}
}
