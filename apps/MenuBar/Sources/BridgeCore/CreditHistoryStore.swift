import Foundation
import Darwin

/// Private append-only provider observations. flock covers the read/validate/
/// deduplicate/append transaction across processes, not just this actor.
public actor CreditHistoryStore {
    public static let maximumFileBytes = 32 * 1024 * 1024
    public static let maximumLineBytes = 8192
    public static let maximumRecords = 100_000
    public let fileURL: URL

    public init(fileURL: URL = BridgePaths.applicationSupport.appendingPathComponent("CreditHistory", isDirectory: true)
        .appendingPathComponent("credits.jsonl")) {
        self.fileURL = fileURL
    }

    @discardableResult
    public func record(_ estimate: QuotaEstimate, anonymousEpochID: String, importScope: String? = nil) throws -> CreditHistoryRecordResult {
        func rejected(_ reason: String, scope: CreditHistoryScope? = nil) -> CreditHistoryRecordResult {
            .init(disposition: .rejected, reason: reason, scope: scope, warnings: [reason])
        }
        // Failed refreshes often carry a cached .live estimate. They are not a
        // new provider observation and must never add a synthetic history point.
        guard estimate.agent == .codex, estimate.source == .live, estimate.refreshFailedAt == nil,
              estimate.limitID == "codex", let credits = estimate.credits,
              let fetchedAt = estimate.fetchedAt, fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
            return rejected("not_a_successful_provider_credit_reading")
        }
        let scope: CreditHistoryScope
        if let importScope {
            guard validScopeInput(importScope) else { return rejected("invalid_import_scope") }
            scope = .imported(importScope)
        } else if let hash = estimate.accountIdentityHash, !hash.isEmpty {
            guard validScopeInput(hash) else { return rejected("invalid_account_scope") }
            scope = .account(hash)
        } else {
            guard validScopeInput(anonymousEpochID) else { return rejected("anonymous_epoch_required") }
            scope = .anonymous(anonymousEpochID)
        }
        // Use the same millisecond timestamp represented by the on-disk JSON,
        // so canonical hashes survive encoding/decoding and duplicate probes.
        guard let observedAt = ISO8601.withFractional.date(from: ISO8601.withFractional.string(from: fetchedAt)) else {
            return rejected("provider_timestamp_outside_supported_range", scope: scope)
        }
        var warnings: [String] = []
        let balance = QuotaCredits.validatedBalance(credits.balance)
        if credits.balance != nil && balance == nil { warnings.append("invalid_provider_balance_omitted") }
        if scope.kind == .anonymous { warnings.append("identity_unreported_anonymous_epoch_only") }
        var candidate = CreditHistoryRecord(sequence: 0, scope: scope, observedAt: observedAt,
            reportedBalance: balance, hasCredits: credits.hasCredits, unlimited: credits.unlimited,
            warnings: warnings, previousHash: nil, recordHash: "")
        if !CreditHistoryAnalytics.consistent(candidate) { candidate.warnings.append("inconsistent_provider_flags") }
        return try locked(create: true, exclusive: true) { descriptor in
            let existing = try read(descriptor)
            guard existing.integrityVerified else { throw CreditHistoryError.corruptHistory }
            let scoped = existing.records.filter { $0.scope == scope }
            if let sameTime = scoped.first(where: { $0.observedAt == observedAt }) {
                guard sameTime.reportedBalance == candidate.reportedBalance,
                      sameTime.hasCredits == candidate.hasCredits, sameTime.unlimited == candidate.unlimited,
                      sameTime.warnings == candidate.warnings else {
                    return rejected("same_timestamp_conflicting_payload", scope: scope)
                }
                return .init(disposition: .duplicate, reason: "same_provider_timestamp_and_payload", scope: scope, warnings: candidate.warnings)
            }
            if let last = scoped.last, observedAt < last.observedAt {
                return rejected("backwards_provider_clock_or_out_of_order_reading", scope: scope)
            }
            guard existing.records.count < Self.maximumRecords else { throw CreditHistoryError.limitExceeded }
            candidate.sequence = existing.records.count + 1
            candidate.previousHash = existing.records.last?.recordHash
            candidate.recordHash = try hash(candidate)
            var line = try BridgeJSON.compactEncoder.encode(candidate)
            guard line.count <= Self.maximumLineBytes else { throw CreditHistoryError.limitExceeded }
            line.append(0x0a)
            guard existing.byteCount + line.count <= Self.maximumFileBytes else { throw CreditHistoryError.limitExceeded }
            guard lseek(descriptor, 0, SEEK_END) >= 0 else { throw CreditHistoryError.io("seek before append") }
            try line.withUnsafeBytes { buffer in
                var written = 0
                while written < buffer.count {
                    let amount = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw CreditHistoryError.io("append a reading") }
                    written += amount
                }
            }
            guard fsync(descriptor) == 0 else { throw CreditHistoryError.io("flush the appended reading") }
            return .init(disposition: .appended, reason: nil, scope: scope, warnings: candidate.warnings)
        }
    }

    public func report(now: Date, from: Date, to: Date, scope: CreditHistoryScope? = nil) throws -> CreditHistoryReport {
        var metadata = stat()
        if lstat(fileURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw CreditHistoryError.io("inspect the history path") }
            return CreditHistoryAnalytics.report(records: [], now: now, from: from, to: to, scope: scope)
        }
        let snapshot = try locked(create: false, exclusive: false) { try read($0) }
        return CreditHistoryAnalytics.report(records: snapshot.records, now: now, from: from, to: to, scope: scope,
            integrityVerified: snapshot.integrityVerified, invalidLineCount: snapshot.invalidLineCount,
            tornFinalLine: snapshot.tornFinalLine)
    }

    /// Contains only scoped, provider-owned credit fields and local derivations;
    /// never credentials, email, process IDs, status prose or project/token data.
    public func sanitizedExport(now: Date, from: Date, to: Date, scope: CreditHistoryScope? = nil) throws -> Data {
        try BridgeJSON.encoder.encode(report(now: now, from: from, to: to, scope: scope))
    }

    private func validScopeInput(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
    }

    private struct Snapshot {
        var records: [CreditHistoryRecord] = []
        var invalidLineCount = 0
        var tornFinalLine = false
        var byteCount = 0
        var integrityVerified: Bool { invalidLineCount == 0 && !tornFinalLine }
    }

    private func read(_ descriptor: Int32) throws -> Snapshot {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw CreditHistoryError.io("inspect the history file") }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumFileBytes else { throw CreditHistoryError.limitExceeded }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw CreditHistoryError.io("read history") }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CreditHistoryError.io("read history") }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileBytes else { throw CreditHistoryError.limitExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        var snapshot = Snapshot(byteCount: data.count)
        guard !data.isEmpty else { return snapshot }
        snapshot.tornFinalLine = data.last != 0x0a
        var chainBroken = false
        var previousHash: String?
        var seenTimes: [CreditHistoryScope: Date] = [:]
        var lineStart = data.startIndex
        var lineNumber = 0
        // Do not materialize split()'s array: a hostile file of newline bytes
        // could otherwise allocate millions of slices before the record cap.
        for lineEnd in data.indices where data[lineEnd] == 0x0a {
            guard lineNumber < Self.maximumRecords else { throw CreditHistoryError.limitExceeded }
            lineNumber += 1
            let line = data[lineStart..<lineEnd]
            lineStart = data.index(after: lineEnd)
            guard !chainBroken, !line.isEmpty, line.count <= Self.maximumLineBytes,
                  let record = try? BridgeJSON.decoder.decode(CreditHistoryRecord.self, from: Data(line)),
                  record.schemaVersion == "credit-history/1", record.sequence == lineNumber,
                  record.scope.id.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
                  record.source == .live, record.limitID == "codex",
                  record.reportedBalance == nil || QuotaCredits.validatedBalance(record.reportedBalance) != nil,
                  record.observedAt.timeIntervalSinceReferenceDate.isFinite,
                  record.previousHash == previousHash,
                  record.recordHash == (try? hash(record)),
                  seenTimes[record.scope].map({ record.observedAt > $0 }) ?? true else {
                chainBroken = true; snapshot.invalidLineCount += 1; continue
            }
            snapshot.records.append(record)
            previousHash = record.recordHash
            seenTimes[record.scope] = record.observedAt
        }
        if snapshot.tornFinalLine { snapshot.invalidLineCount += 1 }
        return snapshot
    }

    private func hash(_ record: CreditHistoryRecord) throws -> String {
        var unsigned = record
        unsigned.recordHash = ""
        return TraceCrypto.digest(Data((record.previousHash ?? "").utf8) + (try BridgeJSON.compactEncoder.encode(unsigned)))
    }

    private func locked<T>(create: Bool, exclusive: Bool, operation: (Int32) throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw CreditHistoryError.unsafeFile }
            throw CreditHistoryError.io("open the history directory (system error \(errno))")
        }
        defer { Darwin.close(directoryFD) }
        var directoryMetadata = stat()
        guard fstat(directoryFD, &directoryMetadata) == 0 else { throw CreditHistoryError.io("inspect the history directory (system error \(errno))") }
        guard directoryMetadata.st_uid == getuid() else { throw CreditHistoryError.unsafeFile }
        if create {
            guard fchmod(directoryFD, 0o700) == 0 else { throw CreditHistoryError.io("protect the history directory") }
        } else {
            guard directoryMetadata.st_mode & 0o077 == 0 else { throw CreditHistoryError.unsafeFile }
        }
        let protectedFlags = O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let descriptor: Int32
        if create {
            // Separate atomic first creation from opening an existing inode.
            // On Darwin simultaneous non-exclusive O_CREAT lookups can report
            // ENOENT even while their parent directory remains linked/current.
            let created = Darwin.openat(directoryFD, fileURL.lastPathComponent,
                O_RDWR | O_CREAT | O_EXCL | protectedFlags, mode_t(0o600))
            if created >= 0 { descriptor = created }
            else if errno == EEXIST {
                descriptor = Darwin.openat(directoryFD, fileURL.lastPathComponent, O_RDWR | protectedFlags)
            } else { descriptor = created }
        } else {
            descriptor = Darwin.openat(directoryFD, fileURL.lastPathComponent, O_RDONLY | protectedFlags)
        }
        guard descriptor >= 0 else {
            let failure = errno
            if failure == ELOOP || failure == ENOTDIR { throw CreditHistoryError.unsafeFile }
            var openedDirectory = stat(), namedDirectory = stat()
            let openedValid = fstat(directoryFD, &openedDirectory) == 0
            let namedValid = lstat(directory.path, &namedDirectory) == 0
            let sameDirectory = openedValid && namedValid && openedDirectory.st_dev == namedDirectory.st_dev && openedDirectory.st_ino == namedDirectory.st_ino
            throw CreditHistoryError.io("open the history file (system error \(failure), directory linked: \(openedValid && openedDirectory.st_nlink > 0), current: \(sameDirectory))")
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw CreditHistoryError.io("lock history") }
        defer { flock(descriptor, LOCK_UN) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw CreditHistoryError.io("inspect the locked history file (system error \(errno))") }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1 else { throw CreditHistoryError.unsafeFile }
        var named = stat()
        guard fstatat(directoryFD, fileURL.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw CreditHistoryError.io("inspect the named history file (system error \(errno))")
        }
        guard named.st_dev == metadata.st_dev, named.st_ino == metadata.st_ino else { throw CreditHistoryError.unsafeFile }
        if create {
            guard fchmod(descriptor, 0o600) == 0 else { throw CreditHistoryError.io("protect the history file") }
        } else {
            guard metadata.st_mode & 0o077 == 0 else { throw CreditHistoryError.unsafeFile }
        }
        return try operation(descriptor)
    }
}
