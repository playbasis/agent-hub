import Darwin
import Foundation

/// Writes a report folder another person or tool can read: the report, the
/// outcome and assessment records behind it, the assumptions, an evidence
/// index, the briefing and a checksummed manifest. Owner-only files; no raw
/// transcripts, prompts, credentials or hidden reasoning.
public enum EconomicReportExchange {
    public struct Bundle: Sendable {
        public var report: EconomicReport
        public var files: [String: Data]
        public var manifest: ReportBundleManifest
    }

    public static let producer = ReportBundleManifest.Producer(name: BridgeBrand.productName, version: "economic-reporting/1")

    /// The bundle's files in memory. `sanitized` replaces labels, paths and
    /// identifiers first, with a salt that stays out of the bundle.
    public static func bundle(_ output: EconomicReportBuilder.Output, sanitized: Bool, includeReceipts: Bool = false,
                              createdAt: Date = Date(), salt: String = UUID().uuidString) throws -> Bundle {
        var report = output.report
        var records = output.outcomeRecords
        var assessments = output.assessments
        var receipts: [WorkspaceReceipt] = includeReceipts ? try WorkspaceReceiptProjection.receipts(from: output.accounting) : []
        if sanitized {
            let redactor = Sanitizer(salt: salt, report: report)
            report = try redactor.report(report)
            records = records.map(redactor.outcome)
            assessments = assessments.map(redactor.assessment)
            receipts = try receipts.map(redactor.receipt)
        }
        let pretty = ContractJSON.prettyEncoder
        let assumptions = EconomicAssumptionsBundle(assumptions: report.assumptions, rates: EconomicCatalog.allRates(report.assumptions),
                                                    rubric: EconomicCatalog.rubric, formulas: EconomicCatalog.formulas)
        let index = EvidenceIndex(reportID: report.reportID, entries: report.outcomes.items.map { .init(outcomeID: $0.outcomeID, evidence: $0.evidence) })
        var files: [String: Data] = [
            "report.json": try pretty.encode(report),
            "outcomes.json": try pretty.encode(records),
            "assessments.json": try pretty.encode(assessments),
            "assumptions.json": try pretty.encode(assumptions),
            "evidence-index.json": try pretty.encode(index),
            "briefing.md": Data(FeedbackBriefingBuilder.markdown(report).utf8),
        ]
        if includeReceipts { files["receipts.jsonl"] = try WorkspaceReceiptLines.encode(receipts) }
        let manifest = ReportBundleManifest(reportID: report.reportID, createdAt: ContractTime.normalized(createdAt) ?? report.generatedAt,
                                            contentLevel: report.contentLevel, producer: producer,
                                            files: files.keys.sorted().map { ReportBundleManifest.entry(path: $0, data: files[$0]!) })
        try manifest.validate()
        return Bundle(report: report, files: files, manifest: manifest)
    }

    /// Creates `directory` (which must not exist) owner-only and writes the
    /// bundle into it; the manifest is written last.
    public static func write(_ bundle: Bundle, to directory: URL) throws {
        let destination = directory.standardizedFileURL
        guard destination.isFileURL, !destination.path.contains("\0"), destination.path.utf8.count <= 4_000 else {
            throw BridgeError.invalidRequest("Choose a valid export folder.")
        }
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else {
            throw BridgeError.invalidRequest("\(destination.path) already exists; choose a new folder for the export.")
        }
        guard mkdir(destination.path, 0o700) == 0 else { throw BridgeError.configuration("The export folder couldn't be created.") }
        for name in bundle.files.keys.sorted() {
            try ActivityAccountingExport.write(bundle.files[name]!, to: destination.appendingPathComponent(name))
        }
        try ActivityAccountingExport.write(ContractJSON.prettyEncoder.encode(bundle.manifest), to: destination.appendingPathComponent(ReportBundleManifest.manifestName))
    }

    /// Replaces everything that names a person's work: titles, summaries,
    /// commit subjects, repository names, paths, session and commit
    /// identifiers. Numbers, models and assumptions stay.
    struct Sanitizer {
        let salt: String
        let titles: [String: String]

        init(salt: String, report: EconomicReport) {
            self.salt = salt
            var titles: [String: String] = [:]
            for (index, item) in report.outcomes.items.enumerated() { titles[item.outcomeID] = "Outcome \(index + 1)" }
            for (index, item) in report.outcomes.corrections.enumerated() where titles[item.outcomeID] == nil { titles[item.outcomeID] = "Withdrawn outcome \(index + 1)" }
            self.titles = titles
        }

        /// A salted, stable stand-in: hex, so commit references keep their shape.
        func token(_ value: String) -> String { String(ContractDigest.hex(Data((salt + "\u{1f}" + value).utf8)).prefix(12)) }

        func evidence(_ item: OutcomeEvidence) -> OutcomeEvidence {
            OutcomeEvidence(kind: item.kind, repositoryID: item.repositoryID.map { "repo-" + token($0) }, ref: token(item.ref))
        }

        func repositoryName(_ name: String) -> String { "repository-" + token("name:" + name).prefix(6) }

        func report(_ value: EconomicReport) throws -> EconomicReport {
            var report = value
            report.contentLevel = .sanitized
            report.scope.projects = value.scope.projects.map { .init(id: "repo-" + token($0.id), name: repositoryName($0.name)) }
            report.scope.projectFilter = nil
            report.outcomes.items = value.outcomes.items.map { item in
                var item = item
                item.title = titles[item.outcomeID] ?? "Outcome"
                item.summary = nil
                item.repositories = item.repositories.map(repositoryName)
                item.evidence = item.evidence.map(evidence)
                return item
            }
            report.outcomes.pending = value.outcomes.pending.enumerated().map { index, item in
                var item = item
                item.candidateID = "cand-" + token(item.candidateID)
                item.title = "Suggestion \(index + 1)"
                item.repositories = item.repositories.map(repositoryName)
                return item
            }
            report.outcomes.corrections = value.outcomes.corrections.map { item in
                var item = item
                item.title = titles[item.outcomeID] ?? "Outcome"
                return item
            }
            report.friction = value.friction.map { item in
                var item = item
                item.evidence = item.evidence.map(token)
                return item
            }
            report.assumptions.customRates = value.assumptions.customRates.map { rate in
                var rate = rate
                rate.source = nil
                return rate
            }
            report.economics.rate.source = value.economics.rate.basis == .medianWage ? value.economics.rate.source : nil
            report.economics.operatorRate.source = value.economics.operatorRate.basis == .medianWage ? value.economics.operatorRate.source : nil
            report.nextPrompt = FeedbackBriefingBuilder.nextPrompt(report)
            return try report.identified()
        }

        func outcome(_ value: AcceptedOutcomeRecord) -> AcceptedOutcomeRecord {
            var record = value
            record.title = titles[value.outcomeID] ?? "Outcome"
            record.summary = nil
            record.evidence = value.evidence.map(evidence)
            record.candidateID = value.candidateID.map { "cand-" + token($0) }
            record.correction = value.correction.map { .init(reason: $0.reason, note: nil) }
            return record
        }

        func assessment(_ value: EffortAssessmentRecord) -> EffortAssessmentRecord {
            var record = value
            record.assumptions = []
            record.rationale = nil
            return record
        }

        func receipt(_ value: WorkspaceReceipt) throws -> WorkspaceReceipt {
            var receipt = value
            receipt.eventID = "agent-hub:" + token(value.eventID)
            receipt.sessionID = value.provider + ":" + token(value.sessionID)
            receipt.nativeTurnID = value.nativeTurnID.map(token)
            receipt.projectPath = nil
            return try receipt.sealed()
        }
    }
}
