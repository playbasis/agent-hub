import Darwin
import Foundation

/// Everything a person has decided: outcome revisions, effort assessments and
/// assumption revisions, oldest first.
public struct EconomicLedgerState: Equatable, Sendable {
    public var outcomes: [AcceptedOutcomeRecord]
    public var assessments: [EffortAssessmentRecord]
    public var assumptions: [EconomicAssumptionsRecord]

    public init(outcomes: [AcceptedOutcomeRecord] = [], assessments: [EffortAssessmentRecord] = [], assumptions: [EconomicAssumptionsRecord] = []) {
        self.outcomes = outcomes; self.assessments = assessments; self.assumptions = assumptions
    }

    public static let empty = EconomicLedgerState()

    /// Latest revision of each outcome.
    public var latestOutcomes: [AcceptedOutcomeRecord] { Self.latest(outcomes) }

    public var currentAssumptionsRecord: EconomicAssumptionsRecord? {
        assumptions.max { ($0.revision, $0.id) < ($1.revision, $1.id) }
    }

    public func assumptions(default fallback: EconomicAssumptions) -> EconomicAssumptions {
        currentAssumptionsRecord?.assumptions ?? fallback
    }

    public static func latest(_ records: [AcceptedOutcomeRecord]) -> [AcceptedOutcomeRecord] {
        var latest: [String: AcceptedOutcomeRecord] = [:]
        for record in records {
            if let held = latest[record.outcomeID], (held.revision, held.id) >= (record.revision, record.id) { continue }
            latest[record.outcomeID] = record
        }
        return latest.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}

/// What a person decides about an outcome; the ledger adds identity,
/// revision and time.
public struct OutcomeDecision: Equatable, Sendable {
    public var decision: AcceptedOutcomeRecord.Decision
    public var title: String
    public var summary: String?
    public var deliveryStandard: DeliveryStandard
    public var evidence: [OutcomeEvidence]
    public var landedAt: Date
    public var operatorTime: OperatorTime
    public var candidateID: String?
    public var correction: AcceptedOutcomeRecord.Correction?

    public init(decision: AcceptedOutcomeRecord.Decision, title: String, summary: String? = nil, deliveryStandard: DeliveryStandard,
                evidence: [OutcomeEvidence], landedAt: Date, operatorTime: OperatorTime = .unknown, candidateID: String? = nil,
                correction: AcceptedOutcomeRecord.Correction? = nil) {
        self.decision = decision; self.title = title; self.summary = summary; self.deliveryStandard = deliveryStandard
        self.evidence = evidence; self.landedAt = landedAt; self.operatorTime = operatorTime; self.candidateID = candidateID
        self.correction = correction
    }
}

public enum EconomicLedgerError: LocalizedError, Equatable {
    case invalidInput(String)
    case unavailable
    case invalidStore(String)
    case staleRevision
    case conflict(String)
    case unknownOutcome
    case limitReached

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let reason): return "The record isn't valid: \(reason)."
        case .unavailable: return "The economics ledger is busy or can't be opened. Try again."
        case .invalidStore(let reason): return "The economics ledger couldn't be verified (\(reason)). Existing files were not changed."
        case .staleRevision: return "This outcome has a newer revision. Reload it before changing it."
        case .conflict(let reason): return reason
        case .unknownOutcome: return "No outcome has that ID."
        case .limitReached: return "The economics ledger is full. Existing records were kept."
        }
    }
}

/// Append-only private store: each record is its own owner-only JSON file,
/// published by atomic rename under a process-wide lock. Nothing is edited
/// or deleted; a change is a new revision that names the one it replaces.
public actor EconomicLedger {
    public static let shared = EconomicLedger()
    public static let maximumRecordsPerKind = 4_096
    public static let maximumRecordBytes = 64 * 1_024
    public static let maximumStoreBytes = 64 * 1_024 * 1_024

    public let directory: URL

    public init(directory: URL = BridgePaths.applicationSupport.appendingPathComponent("Economics", isDirectory: true)) {
        self.directory = directory
    }

    public func state() throws -> EconomicLedgerState {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .empty }
        return try withLock(create: false) { try read() }
    }

    /// Records a decision. A new outcome needs no `revising`; changing one
    /// names its latest record. Accepted commits can belong to one outcome.
    @discardableResult
    public func decide(_ draft: OutcomeDecision, revising recordID: String? = nil, now: Date = Date()) throws -> AcceptedOutcomeRecord {
        try withLock(create: true) {
            let state = try read()
            let latest = state.latestOutcomes
            var previous: AcceptedOutcomeRecord?
            if let recordID {
                guard let record = state.outcomes.first(where: { $0.id == recordID }) else { throw EconomicLedgerError.unknownOutcome }
                guard latest.contains(where: { $0.id == recordID }) else { throw EconomicLedgerError.staleRevision }
                previous = record
            }
            if draft.decision == .withdrawn, previous?.decision != .accepted {
                throw EconomicLedgerError.invalidInput("only an accepted outcome can be withdrawn")
            }
            if previous == nil, let candidate = draft.candidateID, let held = latest.first(where: { $0.candidateID == candidate }) {
                throw EconomicLedgerError.conflict("That suggestion was already recorded as outcome \(held.outcomeID) (\(held.decision.rawValue)).")
            }
            if draft.decision == .accepted {
                for other in latest where other.decision == .accepted && other.outcomeID != previous?.outcomeID {
                    let held = Set(other.commitRefs.map { ($0.repositoryID ?? "") + ":" + $0.ref })
                    if let shared = draft.evidence.first(where: { $0.kind == .commit && OutcomeCandidates.holds(held, repositoryID: $0.repositoryID ?? "", commitID: $0.ref) }) {
                        throw EconomicLedgerError.conflict("Commit \(shared.ref.prefix(7)) already belongs to accepted outcome \"\(other.title)\" (\(other.outcomeID)). Revise or withdraw that outcome first.")
                    }
                }
            }
            guard let createdAt = ContractTime.normalized(now), let landedAt = ContractTime.normalized(draft.landedAt) else {
                throw EconomicLedgerError.invalidInput("dates must be valid")
            }
            let id = UUID().uuidString.lowercased()
            let record = AcceptedOutcomeRecord(id: id, outcomeID: previous?.outcomeID ?? id, revision: (previous?.revision ?? 0) + 1,
                supersedesID: previous?.id, createdAt: createdAt, decision: draft.decision,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: draft.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, deliveryStandard: draft.deliveryStandard,
                evidence: draft.evidence, landedAt: landedAt, operatorTime: draft.operatorTime,
                candidateID: draft.candidateID ?? previous?.candidateID, correction: draft.correction)
            do { try record.validate() } catch { throw EconomicLedgerError.invalidInput(String(describing: error)) }
            try publish(record, id: record.id, kind: .outcomes, count: state.outcomes.count)
            return record
        }
    }

    /// Adds an assessment. Importing the same record again changes nothing;
    /// a different record under an existing ID is refused.
    @discardableResult
    public func assess(_ record: EffortAssessmentRecord) throws -> (record: EffortAssessmentRecord, inserted: Bool) {
        do { try record.validate() } catch { throw EconomicLedgerError.invalidInput(String(describing: error)) }
        return try withLock(create: true) {
            let state = try read()
            if let held = state.assessments.first(where: { $0.id == record.id }) {
                guard held == record else { throw EconomicLedgerError.conflict("Another assessment already uses ID \(record.id).") }
                return (held, false)
            }
            let revisions = state.outcomes.filter { $0.outcomeID == record.outcomeID }
            guard !revisions.isEmpty else { throw EconomicLedgerError.unknownOutcome }
            guard revisions.contains(where: { $0.id == record.outcomeRevisionID }) else {
                throw EconomicLedgerError.invalidInput("outcomeRevisionID isn't a revision of that outcome")
            }
            var normalized = record
            guard let createdAt = ContractTime.normalized(record.createdAt) else { throw EconomicLedgerError.invalidInput("createdAt must be valid") }
            normalized.createdAt = createdAt
            try publish(normalized, id: normalized.id, kind: .assessments, count: state.assessments.count)
            return (normalized, true)
        }
    }

    @discardableResult
    public func setAssumptions(_ assumptions: EconomicAssumptions, now: Date = Date()) throws -> EconomicAssumptionsRecord {
        do { try assumptions.validate() } catch { throw EconomicLedgerError.invalidInput(String(describing: error)) }
        return try withLock(create: true) {
            let state = try read()
            let previous = state.currentAssumptionsRecord
            if previous?.assumptions == assumptions, let previous { return previous }
            guard let createdAt = ContractTime.normalized(now) else { throw EconomicLedgerError.invalidInput("date must be valid") }
            let record = EconomicAssumptionsRecord(id: UUID().uuidString.lowercased(), revision: (previous?.revision ?? 0) + 1,
                                                   supersedesID: previous?.id, createdAt: createdAt, assumptions: assumptions)
            try publish(record, id: record.id, kind: .assumptions, count: state.assumptions.count)
            return record
        }
    }

    // MARK: Files

    enum Kind: String, CaseIterable { case outcomes, assessments, assumptions }

    private var verifiedBytes = 0

    private func withLock<T>(create: Bool, _ body: () throws -> T) throws -> T {
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for kind in Kind.allCases {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(kind.rawValue), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw EconomicLedgerError.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw EconomicLedgerError.invalidStore("the folder isn't owned by you")
        }
        let lock = openat(fd, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard lock >= 0 else { throw EconomicLedgerError.unavailable }
        defer { Darwin.close(lock) }
        // Waits briefly for another process instead of failing at once.
        var locked = false
        for _ in 0 ..< 50 {
            if flock(lock, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            usleep(20_000)
        }
        guard locked else { throw EconomicLedgerError.unavailable }
        defer { flock(lock, LOCK_UN) }
        return try body()
    }

    private func read() throws -> EconomicLedgerState {
        verifiedBytes = 0
        let outcomes: [AcceptedOutcomeRecord] = try records(.outcomes) { try $0.validate(); return $0.id }
        let assessments: [EffortAssessmentRecord] = try records(.assessments) { try $0.validate(); return $0.id }
        let assumptions: [EconomicAssumptionsRecord] = try records(.assumptions) { try $0.validate(); return $0.id }
        let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.id, $0) })
        var seen = Set<String>()
        for record in outcomes {
            guard seen.insert("\(record.outcomeID):\(record.revision)").inserted else { throw EconomicLedgerError.invalidStore("two records claim one revision") }
            if record.revision > 1 {
                guard let previous = record.supersedesID.flatMap({ byID[$0] }), previous.outcomeID == record.outcomeID,
                      previous.revision == record.revision - 1 else { throw EconomicLedgerError.invalidStore("an outcome revision has no predecessor") }
            }
        }
        let assumptionIDs = Set(assumptions.map(\.id))
        guard Set(assumptions.map(\.revision)).count == assumptions.count,
              assumptions.allSatisfy({ $0.supersedesID.map(assumptionIDs.contains) ?? true }) else {
            throw EconomicLedgerError.invalidStore("assumption revisions don't form a chain")
        }
        return EconomicLedgerState(outcomes: outcomes.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) },
                                   assessments: assessments.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) },
                                   assumptions: assumptions.sorted { ($0.revision, $0.id) < ($1.revision, $1.id) })
    }

    private func records<T: Decodable>(_ kind: Kind, identify: (T) throws -> String) throws -> [T] {
        let folder = directory.appendingPathComponent(kind.rawValue)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let fd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw EconomicLedgerError.invalidStore("\(kind.rawValue) can't be opened") }
        defer { Darwin.close(fd) }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard names.count <= Self.maximumRecordsPerKind * 2 + 32 else { throw EconomicLedgerError.limitReached }
        var values: [T] = []
        let decoder = ContractJSON.decoder
        for name in names.sorted() {
            // Staging files from an interrupted write are never records.
            if name.hasPrefix(".pending-") { continue }
            guard name.hasSuffix(".json"), ContractText.isUUID(String(name.dropLast(5))) else {
                throw EconomicLedgerError.invalidStore("unexpected file \(kind.rawValue)/\(name)")
            }
            guard values.count < Self.maximumRecordsPerKind else { throw EconomicLedgerError.limitReached }
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw EconomicLedgerError.invalidStore("\(name) can't be read") }
            let data: Data
            do {
                defer { Darwin.close(file) }
                var info = stat()
                guard fstat(file, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == geteuid(), info.st_nlink == 1,
                      (info.st_mode & 0o077) == 0, info.st_size > 0, info.st_size <= Self.maximumRecordBytes else {
                    throw EconomicLedgerError.invalidStore("\(name) isn't a private record file")
                }
                verifiedBytes += Int(info.st_size)
                guard verifiedBytes <= Self.maximumStoreBytes else { throw EconomicLedgerError.limitReached }
                data = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
                guard data.count == info.st_size else { throw EconomicLedgerError.invalidStore("\(name) changed while being read") }
            }
            let value: T
            do { value = try decoder.decode(T.self, from: data) } catch { throw EconomicLedgerError.invalidStore("\(name) isn't a valid record") }
            do { guard try identify(value) + ".json" == name else { throw EconomicLedgerError.invalidStore("\(name) holds another record") } }
            catch let error as EconomicLedgerError { throw error }
            catch { throw EconomicLedgerError.invalidStore("\(name): \(error)") }
            values.append(value)
        }
        return values
    }

    private func publish<T: Encodable>(_ record: T, id: String, kind: Kind, count: Int) throws {
        guard count < Self.maximumRecordsPerKind else { throw EconomicLedgerError.limitReached }
        let data = try ContractJSON.encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw EconomicLedgerError.invalidInput("the record is larger than 64 KB") }
        guard verifiedBytes + data.count <= Self.maximumStoreBytes else { throw EconomicLedgerError.limitReached }
        let folder = directory.appendingPathComponent(kind.rawValue)
        let fd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw EconomicLedgerError.unavailable }
        defer { Darwin.close(fd) }
        let staging = ".pending-\(id)", destination = "\(id).json"
        let file = openat(fd, staging, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw EconomicLedgerError.unavailable }
        defer { Darwin.close(file); unlinkat(fd, staging, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw EconomicLedgerError.unavailable }
                offset += written
            }
        }
        var existing = stat()
        guard fsync(file) == 0, fstatat(fd, destination, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              renameat(fd, staging, fd, destination) == 0 else { throw EconomicLedgerError.unavailable }
        _ = fsync(fd)
        verifiedBytes += data.count
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
