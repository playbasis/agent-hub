import Foundation
import Darwin

/// Explicit local import only. Every receipt is a separate, immutable 0600 file.
public actor JEVAssessmentStore {
    public static let maximumImportBytes = 4 * 1024 * 1024
    public static let maximumReceipts = 10_000
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(directory.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else { throw JEVAssessmentError.unsafePath }
    }
    private func readPrivate(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw JEVAssessmentError.unsafePath }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw JEVAssessmentError.unsafePath }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o077) == 0, st.st_nlink == 1 else { throw JEVAssessmentError.unsafePath }
        guard st.st_size >= 0, st.st_size <= limit else { throw JEVAssessmentError.tooLarge }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw JEVAssessmentError.unsafePath }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw JEVAssessmentError.tooLarge }
        }
        return data
    }
    private func decoder() -> JSONDecoder { BridgeJSON.decoder }
    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    private func checkFields(_ data: Data) throws {
        guard AssessmentJSONUniqueKeys.valid(data), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "id", "evidenceID", "snapshotDigest", "sessionID", "turnID", "provider", "inputDigest", "model", "rubricVersion", "rubricHash", "assessedAt", "status", "result", "usage"]) else { throw JEVAssessmentError.invalidJSON }
        if let result = object["result"] as? [String: Any], !Set(result.keys).isSubset(of: ["workKind", "evidenceLevel", "outcomeSupport", "tags", "retry", "correction", "clarification", "claimNeedsReview", "modelReportedConfidence"]) { throw JEVAssessmentError.invalidJSON }
        if let usage = object["usage"] as? [String: Any], !Set(usage.keys).isSubset(of: ["inputTokens", "outputTokens"]) { throw JEVAssessmentError.invalidJSON }
    }

    private func withLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        try ensureDirectory()
        let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JEVAssessmentError.unsafePath }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              (st.st_mode & 0o077) == 0, st.st_nlink == 1 else { throw JEVAssessmentError.unsafePath }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw JEVAssessmentError.unsafePath }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func listUnlocked() throws -> [JEVAssessmentReceipt] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= Self.maximumReceipts else { throw JEVAssessmentError.tooLarge }
        return try files.map { file in
            try Task.checkCancellation()
            let data = try readPrivate(file, limit: 65_536)
            try checkFields(data)
            let receipt = try decoder().decode(JEVAssessmentReceipt.self, from: data)
            try receipt.validate(); return receipt
        }.sorted { $0.assessedAt == $1.assessedAt ? $0.id < $1.id : $0.assessedAt < $1.assessedAt }
    }
    public func list() throws -> [JEVAssessmentReceipt] { try withLock(exclusive: false) { try listUnlocked() } }

    /// Imports a private bounded JSONL file. Receipt IDs are attempt identities:
    /// a repeated evaluation with a new ID remains evidence, while replay of
    /// the same ID is idempotent and conflicting content is rejected.
    @discardableResult public func importJSONL(at url: URL) throws -> Int {
        let data = try readPrivate(url, limit: Self.maximumImportBytes)
        return try withLock(exclusive: true) { try importLocked(data) }
    }
    private func importLocked(_ data: Data) throws -> Int {
        guard let text = String(data: data, encoding: .utf8) else { throw JEVAssessmentError.invalidJSON }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count <= Self.maximumReceipts else { throw JEVAssessmentError.tooLarge }
        var existing = try listUnlocked(); var new: [JEVAssessmentReceipt] = []
        for line in lines {
            guard line.utf8.count <= 65_536, let raw = String(line).data(using: .utf8) else { throw JEVAssessmentError.tooLarge }
            let receipt: JEVAssessmentReceipt
            do { try checkFields(raw); receipt = try decoder().decode(JEVAssessmentReceipt.self, from: raw); try receipt.validate() } catch { throw JEVAssessmentError.invalidJSON }
            if let previous = existing.first(where: { $0.id == receipt.id }) {
                // The store's wire format has second precision. Compare the
                // serialized form so re-importing a fractional timestamp is
                // idempotent, rather than conflicting with its own first save.
                guard try encoder().encode(previous) == encoder().encode(receipt) else { throw JEVAssessmentError.duplicateConflict }; continue
            }
            existing.append(receipt); new.append(receipt)
        }
        guard existing.count <= Self.maximumReceipts else { throw JEVAssessmentError.tooLarge }
        for receipt in new {
            let target = directory.appendingPathComponent(receipt.id + ".json")
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            let encoded = try encoder().encode(receipt)
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw JEVAssessmentError.duplicateConflict }
            let written = encoded.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }; var offset = 0
                while offset < bytes.count { let n = write(fd, base.advanced(by: offset), bytes.count - offset); if n <= 0 { return false }; offset += n }; return fsync(fd) == 0
            }
            close(fd)
            guard written else { unlink(temporary.path); throw JEVAssessmentError.unsafePath }
            // Hard-link publication is atomic and refuses to replace an existing receipt.
            guard link(temporary.path, target.path) == 0 else { unlink(temporary.path); throw JEVAssessmentError.duplicateConflict }
            unlink(temporary.path)
        }
        return new.count
    }
    public func summaries(currentSnapshotDigests: [String: String] = [:]) throws -> [JEVAssessmentSummary] {
        try list().map { receipt in JEVAssessmentSummary(receipt: receipt, isStale: currentSnapshotDigests[receipt.evidenceID].map { $0 != receipt.snapshotDigest }) }
    }
    public func rollup(currentSnapshotDigests: [String: String] = [:]) throws -> JEVAssessmentRollup {
        let summaries = try summaries(currentSnapshotDigests: currentSnapshotDigests)
        var providers: [String: Int] = [:], sessions: [String: Int] = [:], kinds: [String: Int] = [:]
        for item in summaries { providers[item.receipt.provider, default: 0] += 1; sessions[item.receipt.sessionID, default: 0] += 1; if item.isStale == false, let kind = item.receipt.result?.workKind { kinds[kind, default: 0] += 1 } }
        return JEVAssessmentRollup(total: summaries.count, assessed: summaries.filter { $0.receipt.status == .assessed }.count, failed: summaries.filter { $0.receipt.status == .failed }.count, unavailable: summaries.filter { $0.receipt.status == .unavailable }.count, stale: summaries.filter { $0.isStale == true }.count, byProvider: providers, bySession: sessions, byWorkKind: kinds)
    }
}

/// Reject duplicate object keys, including escaped spellings, before decoding.
private enum AssessmentJSONUniqueKeys {
    static func valid(_ data: Data) -> Bool {
        let bytes = Array(data); var index = 0
        func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func string() -> String? {
            guard index < bytes.count, bytes[index] == 34 else { return nil }
            let start = index; index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    index += 1
                    return (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) as? String
                }
                index += 1
            }
            return nil
        }
        func value(_ depth: Int) -> Bool {
            guard depth < 32 else { return false }; whitespace(); guard index < bytes.count else { return false }
            if bytes[index] == 34 { return string() != nil }
            if bytes[index] == 123 {
                index += 1; whitespace(); var keys = Set<String>()
                if index < bytes.count && bytes[index] == 125 { index += 1; return true }
                while true {
                    whitespace(); guard let key = string(), keys.insert(key).inserted else { return false }
                    whitespace(); guard index < bytes.count && bytes[index] == 58 else { return false }; index += 1
                    guard value(depth + 1) else { return false }; whitespace(); guard index < bytes.count else { return false }
                    if bytes[index] == 125 { index += 1; return true }; guard bytes[index] == 44 else { return false }; index += 1
                }
            }
            if bytes[index] == 91 {
                index += 1; whitespace(); if index < bytes.count && bytes[index] == 93 { index += 1; return true }
                while true { guard value(depth + 1) else { return false }; whitespace(); guard index < bytes.count else { return false }; if bytes[index] == 93 { index += 1; return true }; guard bytes[index] == 44 else { return false }; index += 1 }
            }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            return index > start
        }
        guard value(0) else { return false }; whitespace(); return index == bytes.count
    }
}
