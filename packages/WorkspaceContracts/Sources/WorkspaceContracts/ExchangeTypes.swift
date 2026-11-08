import Foundation

/// The table of contents of an exported report folder. Checksums show the
/// files are the ones written; they don't make the contents true.
public struct ReportBundleManifest: Codable, Equatable, Sendable {
    public static let currentSchema = "report-bundle/1"
    public static let manifestName = "manifest.json"
    /// Every file a bundle may hold, and the contract each one follows.
    public static let knownFiles: [String: String] = [
        "report.json": EconomicReport.currentSchema,
        "outcomes.json": AcceptedOutcomeRecord.currentSchema,
        "assessments.json": EffortAssessmentRecord.currentSchema,
        "assumptions.json": EconomicAssumptions.bundleSchema,
        "evidence-index.json": EvidenceIndex.currentSchema,
        "receipts.jsonl": WorkspaceReceipt.currentSchema,
        "briefing.md": "text/markdown",
    ]
    public static let maximumFileBytes = 32 * 1_024 * 1_024

    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var bytes: Int
        public var sha256: String
        public var schemaVersion: String
        public init(path: String, bytes: Int, sha256: String, schemaVersion: String) {
            self.path = path; self.bytes = bytes; self.sha256 = sha256; self.schemaVersion = schemaVersion
        }
    }

    public struct Producer: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
        public init(name: String, version: String) { self.name = name; self.version = version }
    }

    public var schemaVersion: String
    public var reportID: String
    public var createdAt: Date
    public var contentLevel: EconomicReport.ContentLevel
    public var producer: Producer
    public var files: [File]

    public init(reportID: String, createdAt: Date, contentLevel: EconomicReport.ContentLevel, producer: Producer, files: [File]) {
        schemaVersion = Self.currentSchema
        self.reportID = reportID; self.createdAt = createdAt; self.contentLevel = contentLevel; self.producer = producer
        self.files = files.sorted { $0.path < $1.path }
    }

    /// Describes `data` for the manifest.
    public static func entry(path: String, data: Data) -> File {
        File(path: path, bytes: data.count, sha256: ContractDigest.sha256(data), schemaVersion: knownFiles[path] ?? "unknown")
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchema else { throw ContractError("schemaVersion", "must be \(Self.currentSchema)") }
        guard ContractText.isDigest(reportID) else { throw ContractError("reportID", "must be a sha256 digest") }
        guard files.contains(where: { $0.path == "report.json" }) else { throw ContractError("files", "a bundle holds report.json") }
        guard Set(files.map(\.path)).count == files.count else { throw ContractError("files", "paths must be unique") }
        for file in files {
            guard let expected = Self.knownFiles[file.path] else { throw ContractError("files", "\(file.path) isn't a bundle file") }
            guard file.schemaVersion == expected else { throw ContractError("files", "\(file.path) must follow \(expected)") }
            guard (0 ... Self.maximumFileBytes).contains(file.bytes), ContractText.isDigest(file.sha256) else {
                throw ContractError("files", "\(file.path) has an invalid size or checksum")
            }
        }
    }

    /// Checks a bundle folder: a known manifest, only listed plain files, and
    /// matching sizes and checksums. Reads bytes only; nothing is executed,
    /// followed or opened elsewhere.
    public static func verify(directory: URL) throws -> ReportBundleManifest {
        let manager = FileManager.default
        let manifestURL = directory.appendingPathComponent(manifestName)
        let manifestData = try boundedRead(manifestURL, limit: 256 * 1_024)
        let manifest = try ContractJSON.decoder.decode(ReportBundleManifest.self, from: manifestData)
        try manifest.validate()
        let listed = Set(manifest.files.map(\.path) + [manifestName])
        for name in try manager.contentsOfDirectory(atPath: directory.path) where !listed.contains(name) {
            throw ContractError("bundle", "\(name) isn't listed in the manifest")
        }
        for file in manifest.files {
            let data = try boundedRead(directory.appendingPathComponent(file.path), limit: maximumFileBytes)
            guard data.count == file.bytes, ContractDigest.sha256(data) == file.sha256 else { throw ContractError("bundle", "\(file.path) doesn't match its checksum") }
        }
        return manifest
    }

    private static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= limit else {
            throw ContractError("bundle", "\(url.lastPathComponent) must be a plain file under \(limit) bytes")
        }
        return try Data(contentsOf: url)
    }
}

extension EconomicAssumptions {
    public static let bundleSchema = "economic-assumptions-bundle/1"
}

/// What a bundle's assumptions file holds: the choices, every rate they can
/// name and the rubric, so a reader can redo the arithmetic.
public struct EconomicAssumptionsBundle: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var assumptions: EconomicAssumptions
    public var rates: [LaborRate]
    public var rubric: EffortRubric
    public var formulas: [String]
    public init(assumptions: EconomicAssumptions, rates: [LaborRate], rubric: EffortRubric, formulas: [String]) {
        schemaVersion = EconomicAssumptions.bundleSchema
        self.assumptions = assumptions; self.rates = rates; self.rubric = rubric; self.formulas = formulas
    }
}

/// Where each outcome's evidence points: commit hashes, sessions and goals,
/// with the repository each commit belongs to.
public struct EvidenceIndex: Codable, Equatable, Sendable {
    public static let currentSchema = "evidence-index/1"
    public struct Entry: Codable, Equatable, Sendable {
        public var outcomeID: String
        public var evidence: [OutcomeEvidence]
        public init(outcomeID: String, evidence: [OutcomeEvidence]) { self.outcomeID = outcomeID; self.evidence = evidence }
    }
    public var schemaVersion: String
    public var reportID: String
    public var entries: [Entry]
    public init(reportID: String, entries: [Entry]) {
        schemaVersion = Self.currentSchema; self.reportID = reportID; self.entries = entries
    }
}
