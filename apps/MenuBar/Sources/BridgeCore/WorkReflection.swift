import Darwin
import Foundation

/// References to existing accounting/trace/native evidence, never a copy of
/// prompts, tool payloads, private reasoning or provider credentials.
public struct WorkReflectionEvidence: Codable, Equatable, Sendable {
    public var provider: AgentName
    public var sessionID: String
    public var goalID: String?
    public var nativeSessionID: String?
    public var nativeTurnID: String?
    public var modelStepID: String?
    public var toolCallID: String?
    public var stageID: String?
    public var traceReceiptID: String?
    public var payloadDigest: String?
    public var snapshotAsOf: Date?
    public init(provider: AgentName, sessionID: String, goalID: String? = nil, nativeSessionID: String? = nil,
                nativeTurnID: String? = nil, modelStepID: String? = nil, toolCallID: String? = nil,
                stageID: String? = nil, traceReceiptID: String? = nil, payloadDigest: String? = nil, snapshotAsOf: Date? = nil) {
        self.provider = provider; self.sessionID = sessionID; self.goalID = goalID; self.nativeSessionID = nativeSessionID
        self.nativeTurnID = nativeTurnID; self.modelStepID = modelStepID; self.toolCallID = toolCallID
        self.stageID = stageID; self.traceReceiptID = traceReceiptID
        self.payloadDigest = payloadDigest; self.snapshotAsOf = snapshotAsOf
    }
}

public enum WorkReflectionSource: String, Codable, CaseIterable, Sendable {
    case humanRating = "human_rating", deterministicCheck = "deterministic_check", modelAssessment = "model_assessment"
}
public enum WorkReflectionBasis: String, Codable, CaseIterable, Sendable { case observation, judgment, uncertain }
public enum WorkReflectionOutcome: String, Codable, CaseIterable, Sendable { case useful, partial, blocked, unknown }
public enum WorkReflectionProposalDecision: String, Codable, CaseIterable, Sendable { case pending, approved, rejected }
public enum WorkReflectionIssue: String, Codable, CaseIterable, Sendable {
    case failedTool = "failed_tool", failedTest = "failed_test", unclearRequest = "unclear_request"
    case unsupportedAssumption = "unsupported_assumption", repeatedStep = "repeated_step", reversedStep = "reversed_step"
    case malformedRequest = "malformed_request", other
    public var title: String {
        switch self {
        case .failedTool: return "Tool failed"
        case .failedTest: return "Check failed"
        case .unclearRequest: return "Request was unclear"
        case .unsupportedAssumption: return "Unsupported assumption"
        case .repeatedStep: return "Repeated work"
        case .reversedStep: return "Work had to be undone"
        case .malformedRequest: return "Request could not be read"
        case .other: return "Other observation"
        }
    }
}

/// A person's review, explicit check result, or optional model judgment. These
/// are different evidence classes, not interchangeable quality measurements.
public struct WorkReflectionDraft: Codable, Equatable, Sendable {
    public var evidence: [WorkReflectionEvidence]
    public var source: WorkReflectionSource
    public var outcome: WorkReflectionOutcome
    public var rating: Int?
    public var issue: WorkReflectionIssue?
    public var note: String?
    public var proposedSkillChange: String?
    public var basis: WorkReflectionBasis
    public var rubricVersion: String?
    public var comparisonKey: String?
    public var rubricHash: String?
    public var assessorModel: String?
    public var checkName: String?
    public var checkPassed: Bool?
    public init(evidence: [WorkReflectionEvidence], source: WorkReflectionSource = .humanRating,
                outcome: WorkReflectionOutcome = .unknown, rating: Int? = nil, issue: WorkReflectionIssue? = nil,
                note: String? = nil, proposedSkillChange: String? = nil, basis: WorkReflectionBasis = .judgment,
                rubricVersion: String? = nil, comparisonKey: String? = nil, rubricHash: String? = nil,
                assessorModel: String? = nil, checkName: String? = nil, checkPassed: Bool? = nil) {
        self.evidence = evidence; self.source = source; self.outcome = outcome; self.rating = rating
        self.issue = issue; self.note = note; self.proposedSkillChange = proposedSkillChange; self.basis = basis
        self.rubricVersion = rubricVersion; self.comparisonKey = comparisonKey; self.rubricHash = rubricHash
        self.assessorModel = assessorModel; self.checkName = checkName; self.checkPassed = checkPassed
    }
}

/// Revisions are new immutable records. An approved proposal is only a human
/// decision recorded here; this module has no skill editor or execution path.
public struct WorkReflectionRecord: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: String
    public let id: String
    public let reviewID: String
    public let revision: Int
    public let supersedesID: String?
    public let createdAt: Date
    public let draft: WorkReflectionDraft
    public let proposalDecision: WorkReflectionProposalDecision?
    /// Approval/rejection is always a separate explicit human action, even
    /// when the original proposal came from a model assessment.
    public let decisionByHuman: Bool
    public init(id: String, reviewID: String, revision: Int = 1, supersedesID: String? = nil, createdAt: Date,
                draft: WorkReflectionDraft, proposalDecision: WorkReflectionProposalDecision? = nil, decisionByHuman: Bool = false) {
        self.schemaVersion = "work-reflection/1"; self.id = id; self.reviewID = reviewID; self.revision = revision
        self.supersedesID = supersedesID; self.createdAt = createdAt; self.draft = draft
        self.proposalDecision = proposalDecision; self.decisionByHuman = decisionByHuman
    }
}

public struct WorkReflectionSourceSummary: Codable, Equatable, Sendable {
    public var source: WorkReflectionSource
    public var reviews: Int
    public var ratedReviews: Int
    public var knownOutcomes: Int
    public var recordedChecks: Int
}
public struct WorkReflectionComparisonSummary: Codable, Equatable, Sendable {
    public var source: WorkReflectionSource
    public var basis: WorkReflectionBasis
    public var comparisonKey: String?
    public var rubricVersion: String?
    public var rubricHash: String?
    public var assessorModel: String?
    public var checkName: String?
    public var reviews: Int
    public var ratedReviews: Int
    public var ratingCoverage: Double?
    public var averageRating: Double?
    public var knownOutcomes: Int
    public var passedChecks: Int
    public var failedChecks: Int
}
public struct WorkReflectionSuggestion: Codable, Equatable, Sendable {
    public var recordID: String
    public var reviewID: String
    public var evidence: [WorkReflectionEvidence]
    public var change: String
    public var decision: WorkReflectionProposalDecision
    public var requiresHumanApproval: Bool { decision == .pending }
}

/// Coverage and comparisons, not a synthetic overall quality or model ranking.
/// Missing comparison keys never cause unrelated reviews to be averaged.
public struct WorkReflectionSummary: Codable, Equatable, Sendable {
    public var schemaVersion = "work-reflection-summary/1"
    public var reviews: Int
    public var revisions: Int
    public var bySource: [WorkReflectionSourceSummary]
    public var comparisons: [WorkReflectionComparisonSummary]
    public var suggestions: [WorkReflectionSuggestion]

    public static func build(records: [WorkReflectionRecord]) -> Self {
        let latest = latestRecords(records)
        let sources = WorkReflectionSource.allCases.map { source -> WorkReflectionSourceSummary in
            let rows = latest.filter { $0.draft.source == source }
            return .init(source: source, reviews: rows.count, ratedReviews: rows.filter { $0.draft.rating != nil }.count,
                         knownOutcomes: rows.filter { $0.draft.outcome != .unknown }.count,
                         recordedChecks: rows.filter { $0.draft.checkPassed != nil }.count)
        }
        // Length-prefixed JSON keys avoid delimiter collisions in user labels.
        let groups = Dictionary(grouping: latest) { record -> String in
            let draft = record.draft
            let key = [draft.source.rawValue, draft.comparisonKey, draft.rubricVersion,
                       draft.rubricHash, draft.assessorModel, draft.basis.rawValue, draft.checkName,
                       draft.comparisonKey == nil ? record.reviewID : nil]
            return String(data: (try? BridgeJSON.compactEncoder.encode(key)) ?? Data(), encoding: .utf8) ?? record.id
        }
        var comparisons: [WorkReflectionComparisonSummary] = []
        for key in groups.keys.sorted() {
            guard let rows: [WorkReflectionRecord] = groups[key], let first = rows.first else { continue }
            let ratings: [Int] = rows.compactMap { $0.draft.rating }.filter { (1...5).contains($0) }
            let average: Double? = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
            let coverage: Double? = rows.isEmpty ? nil : Double(ratings.count) / Double(rows.count)
            let summary = WorkReflectionComparisonSummary(source: first.draft.source, basis: first.draft.basis, comparisonKey: first.draft.comparisonKey,
                rubricVersion: first.draft.rubricVersion, rubricHash: first.draft.rubricHash, assessorModel: first.draft.assessorModel,
                checkName: first.draft.checkName,
                reviews: rows.count, ratedReviews: ratings.count,
                ratingCoverage: coverage, averageRating: average,
                knownOutcomes: rows.filter { $0.draft.outcome != .unknown }.count,
                passedChecks: rows.filter { $0.draft.checkPassed == true }.count,
                failedChecks: rows.filter { $0.draft.checkPassed == false }.count)
            comparisons.append(summary)
        }
        let suggestions = latest.compactMap { record -> WorkReflectionSuggestion? in
            guard let change = record.draft.proposedSkillChange, !change.isEmpty else { return nil }
            return .init(recordID: record.id, reviewID: record.reviewID, evidence: record.draft.evidence,
                         change: change, decision: record.proposalDecision ?? .pending)
        }
        return .init(reviews: latest.count, revisions: records.count, bySource: sources, comparisons: comparisons, suggestions: suggestions)
    }

    fileprivate static func latestRecords(_ records: [WorkReflectionRecord]) -> [WorkReflectionRecord] {
        var latest: [String: WorkReflectionRecord] = [:]
        for record in records {
            if let old = latest[record.reviewID], old.revision > record.revision || (old.revision == record.revision && old.id >= record.id) { continue }
            latest[record.reviewID] = record
        }
        return latest.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }
}

public enum WorkReflectionError: LocalizedError, Equatable {
    case invalidInput, unavailable, invalidStore, staleRevision, limitReached
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "The review needs valid evidence references and a rating from 1 to 5, if rated."
        case .unavailable: return "Reviews could not be accessed. Please try again."
        case .invalidStore: return "The local review history could not be verified. Existing files were not changed."
        case .staleRevision: return "This review has a newer revision. Reload it before making a change."
        case .limitReached: return "The local review history is full. Existing reviews have been kept."
        }
    }
}

/// Bounded private store of immutable JSON records. Publishing a new revision
/// is an atomic rename, with process-safe nonblocking coordination. Incomplete
/// private staging files are ignored, never mistaken for completed reviews.
public actor WorkReflectionStore {
    public static let maximumRecords = 2_048
    public static let maximumRecordBytes = 16_384
    public static let maximumStoreBytes = 16 * 1_024 * 1_024
    public let directory: URL
    // Actor operations contain no suspension inside the lock; this is the
    // verified byte count of the immediately preceding readAll operation.
    private var verifiedStoreBytes = 0
    public init(directory: URL = BridgePaths.applicationSupport.appendingPathComponent("WorkReflections", isDirectory: true)) {
        self.directory = directory
    }

    public func load(limit: Int = 200, includingRevisions: Bool = false) throws -> [WorkReflectionRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try withDirectory(create: false) { fd in
            let records = try readAll(fd)
            let rows = includingRevisions ? records.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt } : WorkReflectionSummary.latestRecords(records)
            return Array(rows.prefix(max(0, min(limit, Self.maximumRecords))))
        }
    }

    public func summary(limit: Int = 200) throws -> WorkReflectionSummary {
        guard FileManager.default.fileExists(atPath: directory.path) else { return WorkReflectionSummary.build(records: []) }
        return try withDirectory(create: false) { fd in
            let records = try readAll(fd)
            let selected = Set(WorkReflectionSummary.latestRecords(records).prefix(max(0, min(limit, Self.maximumRecords))).map(\.reviewID))
            return WorkReflectionSummary.build(records: records.filter { selected.contains($0.reviewID) })
        }
    }

    @discardableResult public func append(_ draft: WorkReflectionDraft, revising recordID: String? = nil) throws -> WorkReflectionRecord {
        let safe = try sanitized(draft)
        return try withDirectory(create: true) { fd in
            let records = try readAll(fd)
            let previous = try predecessor(recordID, records: records)
            let id = UUID().uuidString.lowercased()
            guard let createdAt = ActivityAccountingPrecision.date(Date()) else { throw WorkReflectionError.unavailable }
            let record = WorkReflectionRecord(id: id, reviewID: previous?.reviewID ?? id, revision: (previous?.revision ?? 0) + 1,
                supersedesID: previous?.id, createdAt: createdAt, draft: safe,
                proposalDecision: safe.proposedSkillChange == nil ? nil : .pending)
            try publish(record, fd: fd, count: records.count)
            return record
        }
    }

    @discardableResult public func decideProposal(recordID: String, decision: WorkReflectionProposalDecision) throws -> WorkReflectionRecord {
        guard decision != .pending else { throw WorkReflectionError.invalidInput }
        return try withDirectory(create: false) { fd in
            let records = try readAll(fd)
            guard let previous = try predecessor(recordID, records: records), previous.draft.proposedSkillChange != nil else {
                throw WorkReflectionError.invalidInput
            }
            guard let createdAt = ActivityAccountingPrecision.date(Date()) else { throw WorkReflectionError.unavailable }
            let record = WorkReflectionRecord(id: UUID().uuidString.lowercased(), reviewID: previous.reviewID,
                revision: previous.revision + 1, supersedesID: previous.id, createdAt: createdAt, draft: previous.draft,
                proposalDecision: decision, decisionByHuman: true)
            try publish(record, fd: fd, count: records.count)
            return record
        }
    }

    private func predecessor(_ id: String?, records: [WorkReflectionRecord]) throws -> WorkReflectionRecord? {
        guard let id else { return nil }
        guard let record = records.first(where: { $0.id == id }) else { throw WorkReflectionError.staleRevision }
        guard WorkReflectionSummary.latestRecords(records).contains(where: { $0.id == id }) else { throw WorkReflectionError.staleRevision }
        return record
    }

    private func sanitized(_ draft: WorkReflectionDraft) throws -> WorkReflectionDraft {
        guard (1...16).contains(draft.evidence.count), draft.rating.map({ (1...5).contains($0) }) ?? true else { throw WorkReflectionError.invalidInput }
        func validID(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512 &&
                !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
        for evidence in draft.evidence {
            guard evidence.payloadDigest.map({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) ?? true,
                  evidence.snapshotAsOf.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { throw WorkReflectionError.invalidInput }
            guard evidence.provider != .none, [evidence.sessionID, evidence.goalID, evidence.nativeSessionID, evidence.nativeTurnID,
                evidence.modelStepID, evidence.toolCallID, evidence.stageID, evidence.traceReceiptID].allSatisfy(validID) else { throw WorkReflectionError.invalidInput }
        }
        guard [draft.rubricVersion, draft.comparisonKey, draft.rubricHash, draft.assessorModel, draft.checkName].allSatisfy(validID) else {
            throw WorkReflectionError.invalidInput
        }
        if draft.source == .deterministicCheck {
            guard draft.checkName != nil, draft.checkPassed != nil, draft.rating == nil, draft.outcome == .unknown,
                  draft.basis == .observation else { throw WorkReflectionError.invalidInput }
        } else if draft.checkPassed != nil { throw WorkReflectionError.invalidInput }
        if draft.source == .modelAssessment {
            guard draft.assessorModel != nil, draft.rubricVersion != nil, draft.basis != .observation else { throw WorkReflectionError.invalidInput }
        }
        var safe = draft
        func text(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : TraceRedactor.redact(trimmed, maximumCharacters: 1_200)
        }
        safe.note = text(draft.note); safe.proposedSkillChange = text(draft.proposedSkillChange)
        return safe
    }

    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkReflectionError.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              fchmod(fd, 0o700) == 0 else { throw WorkReflectionError.invalidStore }
        let lock = openat(fd, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard lock >= 0 else { throw WorkReflectionError.unavailable }
        defer { Darwin.close(lock) }
        guard fstat(lock, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw WorkReflectionError.unavailable }
        defer { flock(lock, LOCK_UN) }
        var namedLock = stat()
        guard fstatat(fd, ".lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == info.st_dev, namedLock.st_ino == info.st_ino else { throw WorkReflectionError.unavailable }
        return try body(fd)
    }

    private func readAll(_ fd: Int32) throws -> [WorkReflectionRecord] {
        guard let listing = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]) else { throw WorkReflectionError.unavailable }
        var records: [WorkReflectionRecord] = [], totalBytes = 0, entries = 0
        for case let url as URL in listing {
            entries += 1
            guard entries <= Self.maximumRecords * 2 + 32 else { throw WorkReflectionError.limitReached }
            guard url.pathExtension == "json" else { continue }
            let name = url.lastPathComponent
            guard let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  name == uuid.uuidString.lowercased() + ".json", records.count < Self.maximumRecords else { throw WorkReflectionError.invalidStore }
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw WorkReflectionError.invalidStore }
            let data: Data
            do {
                defer { Darwin.close(file) }
                var info = stat()
                guard fstat(file, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == geteuid(), info.st_nlink == 1,
                      (info.st_mode & 0o077) == 0, info.st_size > 0, info.st_size <= Self.maximumRecordBytes else { throw WorkReflectionError.invalidStore }
                totalBytes += Int(info.st_size)
                guard totalBytes <= Self.maximumStoreBytes else { throw WorkReflectionError.limitReached }
                data = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
                guard data.count == info.st_size else { throw WorkReflectionError.invalidStore }
            }
            let record: WorkReflectionRecord
            do { record = try BridgeJSON.decoder.decode(WorkReflectionRecord.self, from: data) }
            catch { throw WorkReflectionError.invalidStore }
            guard record.schemaVersion == "work-reflection/1", record.id == uuid.uuidString.lowercased(),
                  UUID(uuidString: record.reviewID) != nil, record.revision > 0, record.revision <= Self.maximumRecords,
                  record.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  (try? sanitized(record.draft)) == record.draft,
                  (record.draft.proposedSkillChange == nil) == (record.proposalDecision == nil),
                  record.decisionByHuman == (record.proposalDecision == .approved || record.proposalDecision == .rejected) else { throw WorkReflectionError.invalidStore }
            records.append(record)
        }
        var seen: Set<String> = []
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for record in records {
            guard seen.insert("\(record.reviewID):\(record.revision)").inserted else { throw WorkReflectionError.invalidStore }
            if record.revision == 1 {
                guard record.supersedesID == nil, record.reviewID == record.id else { throw WorkReflectionError.invalidStore }
            } else {
                guard let previousID = record.supersedesID, let previous = byID[previousID],
                      previous.reviewID == record.reviewID, previous.revision == record.revision - 1 else { throw WorkReflectionError.invalidStore }
            }
        }
        verifiedStoreBytes = totalBytes
        return records
    }

    private func publish(_ record: WorkReflectionRecord, fd: Int32, count: Int) throws {
        guard count < Self.maximumRecords else { throw WorkReflectionError.limitReached }
        let data = try BridgeJSON.compactEncoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw WorkReflectionError.invalidInput }
        guard verifiedStoreBytes + data.count <= Self.maximumStoreBytes else { throw WorkReflectionError.limitReached }
        let staging = ".pending-\(record.id)", destination = "\(record.id).json"
        let file = openat(fd, staging, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw WorkReflectionError.unavailable }
        defer { Darwin.close(file); unlinkat(fd, staging, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw WorkReflectionError.unavailable }
                offset += written
            }
        }
        var existing = stat()
        guard fsync(file) == 0, fstatat(fd, destination, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              renameat(fd, staging, fd, destination) == 0 else { throw WorkReflectionError.unavailable }
        _ = fsync(fd)
    }
}
