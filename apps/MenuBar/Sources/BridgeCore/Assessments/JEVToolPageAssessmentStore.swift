import Foundation
import Darwin

public enum JEVToolPageStoreError: Error { case unsafePath, tooLarge, invalidJSON, duplicateConflict, partialWrite(imported: Int) }

/// Historical receipts only. A failed publication can leave a complete prefix;
/// partialWrite reports its length and an exact replay safely skips that prefix.
public actor JEVToolPageAssessmentStore {
    public static let maximumImportBytes = 4 * 1024 * 1024
    public static let maximumReceipts = 10_000
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func readPrivate(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw JEVToolPageStoreError.unsafePath }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw JEVToolPageStoreError.unsafePath }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o777 == 0o600, st.st_nlink == 1 else { throw JEVToolPageStoreError.unsafePath }
        guard st.st_size >= 0 && st.st_size <= limit else { throw JEVToolPageStoreError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true { let n = read(fd, &buffer, buffer.count); guard n >= 0 else { throw JEVToolPageStoreError.unsafePath }; if n == 0 { break }; data.append(contentsOf: buffer.prefix(n)); guard data.count <= limit else { throw JEVToolPageStoreError.tooLarge } }
        return data
    }
    private func withLock<T>(_ exclusive: Bool, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard directory.isFileURL, directory.path.hasPrefix("/"), lstat(directory.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 else { throw JEVToolPageStoreError.unsafePath }
        let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JEVToolPageStoreError.unsafePath }; defer { close(fd) }
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o777 == 0o600, st.st_nlink == 1, flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw JEVToolPageStoreError.unsafePath }
        defer { flock(fd, LOCK_UN) }; return try body()
    }
    private func decode(_ data: Data) throws -> JEVToolPageAssessment {
        guard JSONUniqueKeys.valid(data) else { throw JEVToolPageStoreError.invalidJSON }
        let top: Set<String> = ["schemaVersion", "id", "sessionID", "turnID", "evidenceID", "captureID", "model", "rubricHash", "stateHash", "requestHash", "assessedAt", "capturedAt", "source", "pagePartial", "toolFactsTruncated", "artifactCountIsPartial", "factCount", "answers", "noul"]
        let fields: Set<String> = ["listedNonzeroExit", "listedCompletedTool", "artifactRecorded", "goalStatusRecordedCompleted", "listedMissingDuration", "recordedModelsPresent", "turnElapsedMissing"]
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(value.keys).isSubset(of: top), let answers = value["answers"] as? [String: Any], Set(answers.keys) == fields else { throw JEVToolPageStoreError.invalidJSON }
        guard let object = value["noul"] as? [String: Any], Set(object.keys) == fields else { throw JEVToolPageStoreError.invalidJSON }
        let item = try BridgeJSON.decoder.decode(JEVToolPageAssessment.self, from: data); try item.validate(); return item
    }
    private func listUnlocked() throws -> [JEVToolPageAssessment] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= Self.maximumReceipts else { throw JEVToolPageStoreError.tooLarge }
        return try files.map { file in
            try Task.checkCancellation()
            return try decode(readPrivate(file, limit: 65_536))
        }.sorted { ($0.assessedAt ?? .distantPast) == ($1.assessedAt ?? .distantPast) ? $0.id < $1.id : ($0.assessedAt ?? .distantPast) < ($1.assessedAt ?? .distantPast) }
    }
    public func list() throws -> [JEVToolPageAssessment] { try withLock(false) { try listUnlocked() } }
    @discardableResult public func importJSONL(at url: URL) throws -> Int {
        let data = try readPrivate(url, limit: Self.maximumImportBytes)
        return try withLock(true) {
            guard let text = String(data: data, encoding: .utf8) else { throw JEVToolPageStoreError.invalidJSON }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count <= Self.maximumReceipts else { throw JEVToolPageStoreError.tooLarge }
            var byID = Dictionary(try listUnlocked().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), pending: [JEVToolPageAssessment] = []
            for line in lines {
                guard line.utf8.count <= 65_536, let bytes = String(line).data(using: .utf8) else { throw JEVToolPageStoreError.tooLarge }
                let item: JEVToolPageAssessment
                do { item = try decode(bytes) } catch { throw JEVToolPageStoreError.invalidJSON }
                if let previous = byID[item.id] {
                    guard try BridgeJSON.compactEncoder.encode(previous) == BridgeJSON.compactEncoder.encode(item) else { throw JEVToolPageStoreError.duplicateConflict }
                } else { byID[item.id] = item; pending.append(item) }
            }
            guard byID.count <= Self.maximumReceipts else { throw JEVToolPageStoreError.tooLarge }
            var imported = 0
            for item in pending {
                let target = directory.appendingPathComponent(item.id + ".json"), temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
                let bytes: Data
                do { bytes = try BridgeJSON.compactEncoder.encode(item) } catch { throw JEVToolPageStoreError.partialWrite(imported: imported) }
                let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw JEVToolPageStoreError.partialWrite(imported: imported) }
                let success = bytes.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }; var offset = 0
                    while offset < raw.count { let n = write(fd, base.advanced(by: offset), raw.count - offset); if n <= 0 { return false }; offset += n }; return fsync(fd) == 0
                }
                close(fd)
                guard success else { unlink(temp.path); throw JEVToolPageStoreError.partialWrite(imported: imported) }
                guard link(temp.path, target.path) == 0 else { unlink(temp.path); throw JEVToolPageStoreError.partialWrite(imported: imported) }
                unlink(temp.path); imported += 1
            }
            return imported
        }
    }
}

/// JSONSerialization accepts duplicate keys. Scan every object key separately,
/// including escaped spellings, before decoding an external receipt.
private enum JSONUniqueKeys {
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
                    let literal = Data(bytes[start..<index]); return (try? JSONSerialization.jsonObject(with: literal, options: [.fragmentsAllowed])) as? String
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
