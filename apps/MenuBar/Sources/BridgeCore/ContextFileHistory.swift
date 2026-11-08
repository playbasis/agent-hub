import Foundation

/// One version of an instruction or skill file, as observed on this Mac.
public struct ContextFileVersion: Codable, Equatable, Identifiable, Sendable {
    public var fingerprint: String
    /// The file's modification date when this version was first read.
    public var changedAt: Date
    public var firstSeen: Date
    public var bytes: Int
    public var lines: Int
    /// Lines added and removed since the previous version; nil for the
    /// first version seen, whose earlier history isn't known.
    public var added: Int?
    public var removed: Int?

    public var id: String { fingerprint + "@\(changedAt.timeIntervalSince1970)" }
}

public struct ContextFileRecord: Codable, Equatable, Sendable {
    public var path: String
    /// Oldest first.
    public var versions: [ContextFileVersion]
    /// Salted hashes of the latest version's lines, for counting the lines
    /// the next version changes. Never the text.
    var lineHashes: [UInt32]

    public var current: ContextFileVersion? { versions.last }
    /// 1 for the first version seen, counting up.
    public func number(of version: ContextFileVersion) -> Int? { versions.firstIndex(of: version).map { $0 + 1 } }
}

/// Versions of the files agents read (SKILL.md, AGENTS.md, CLAUDE.md, rules):
/// when each changed and how many lines changed. Fed by the skill and
/// instruction catalogs as they read files; stored only on this Mac. Keeps
/// fingerprints, sizes, line counts and salted per-line hashes, not contents.
public final class ContextFileHistory: @unchecked Sendable {
    /// Previews keep history in memory unless BRIDGE_CONTEXT_HISTORY names a scratch file.
    public static let shared: ContextFileHistory = {
        let environment = ProcessInfo.processInfo.environment
        if environment["BRIDGE_UI_PREVIEW"] == "1" {
            return ContextFileHistory(url: environment["BRIDGE_CONTEXT_HISTORY"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil })
        }
        return ContextFileHistory(url: BridgePaths.applicationSupport.appendingPathComponent("context-history.json"))
    }()

    private struct Stored: Codable {
        var version = 1
        var salt: UInt32
        var records: [String: ContextFileRecord]
    }

    private let url: URL?
    private let lock = NSLock()
    private var stored: Stored
    private var loaded = false
    private var writeScheduled = false
    private let queue = DispatchQueue(label: "agent-hub.context-history", qos: .utility)
    static let versionLimit = 40
    static let recordLimit = 2_000

    /// `url` nil keeps the history in memory (tests).
    public init(url: URL?) {
        self.url = url
        stored = Stored(salt: UInt32.random(in: .min ... .max), records: [:])
    }

    /// Records a new version when the file's contents differ from the last
    /// version seen. Returns the file's record.
    @discardableResult
    public func observe(path: String, data: Data, modifiedAt: Date?, now: Date = Date()) -> ContextFileRecord {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let fingerprint = TraceCrypto.digest(data)
        if let record = stored.records[path], record.current?.fingerprint == fingerprint { return record }
        let hashes = Self.lineHashes(data, salt: stored.salt)
        var record = stored.records[path] ?? ContextFileRecord(path: path, versions: [], lineHashes: [])
        let changes = record.versions.isEmpty ? nil : Self.difference(old: record.lineHashes, new: hashes)
        record.versions.append(ContextFileVersion(fingerprint: fingerprint, changedAt: modifiedAt ?? now, firstSeen: now, bytes: data.count,
                                                  lines: hashes.count, added: changes?.added, removed: changes?.removed))
        if record.versions.count > Self.versionLimit { record.versions.removeFirst(record.versions.count - Self.versionLimit) }
        record.lineHashes = hashes
        stored.records[path] = record
        if stored.records.count > Self.recordLimit {
            // Drop the files changed least recently.
            let victims = stored.records.values.sorted { ($0.current?.changedAt ?? .distantPast) < ($1.current?.changedAt ?? .distantPast) }
                .prefix(stored.records.count - Self.recordLimit).map(\.path)
            for victim in victims { stored.records.removeValue(forKey: victim) }
        }
        scheduleWrite()
        return record
    }

    public func records(for paths: [String]) -> [String: ContextFileRecord] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var result: [String: ContextFileRecord] = [:]
        for path in paths { if let record = stored.records[path] { result[path] = record } }
        return result
    }

    /// Lines added and removed between two versions, as multisets of lines:
    /// a moved line counts as unchanged.
    static func difference(old: [UInt32], new: [UInt32]) -> (added: Int, removed: Int) {
        var counts: [UInt32: Int] = [:]
        for hash in old { counts[hash, default: 0] += 1 }
        var added = 0
        for hash in new {
            if let count = counts[hash], count > 0 { counts[hash] = count - 1 } else { added += 1 }
        }
        return (added, counts.values.reduce(0, +))
    }

    static func lineHashes(_ data: Data, salt: UInt32) -> [UInt32] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        return lines.map { line in
            // FNV-1a, seeded with this Mac's salt: enough to tell lines apart.
            var hash: UInt32 = 2_166_136_261 ^ salt
            for byte in line.utf8 where byte != 13 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            return hash
        }
    }

    // MARK: Storage

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url), data.count <= 32 * 1_024 * 1_024,
              let value = try? BridgeJSON.decoder.decode(Stored.self, from: data), value.version == 1 else { return }
        stored = value
    }

    private func scheduleWrite() {
        guard url != nil, !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            let snapshot = stored
            writeScheduled = false
            lock.unlock()
            persist(snapshot)
        }
    }

    private func persist(_ value: Stored) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try BridgeJSON.compactEncoder.encode(value)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* History is optional; the next change retries. */ }
    }
}

/// One change to a context file: a version the Hub observed, a Git commit
/// that touched it, or both when they describe the same change.
public struct ContextFileChange: Identifiable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var date: Date
    public var added: Int?
    public var removed: Int?
    /// Line count of an observed version.
    public var lines: Int?
    /// 1-based number of an observed version, else nil.
    public var version: Int?
    public var isCurrent: Bool
    /// The first version observed: earlier history is unknown unless Git shows it.
    public var isFirstSeen: Bool
    public var commitID: String?
    public var commitSubject: String?
    public var coAuthors: [AgentName]
    /// When this change was in effect (until the next change or now).
    public var validUntil: Date?
}

public enum ContextFileTimeline {
    /// Git commits that changed `path`, from the scanned repository holding it.
    public static func commits(for path: String, in repositories: [ActivityRepository]) -> [(commit: ActivityCommit, file: ActivityCommitFile)] {
        let target = ShippedCodeReport.resolved(path)
        for repository in repositories where repository.commitHistoryAvailable == true {
            let roots = ([repository.root] + repository.worktrees.map(\.path)).map(ShippedCodeReport.resolved).sorted { $0.count > $1.count }
            guard let root = roots.first(where: { target.hasPrefix($0 + "/") }) else { continue }
            let relative = String(target.dropFirst(root.count + 1))
            return repository.commits.compactMap { commit in
                commit.files?.first { $0.path == relative }.map { (commit, $0) }
            }
        }
        return []
    }

    /// Observed versions and Git commits for one file, newest first. A commit
    /// that matches an observed version (same line counts, within a day) is
    /// folded into that version.
    public static func changes(path: String, record: ContextFileRecord?, repositories: [ActivityRepository], now: Date) -> [ContextFileChange] {
        var changes: [ContextFileChange] = []
        let versions = record?.versions ?? []
        for (index, version) in versions.enumerated() {
            changes.append(ContextFileChange(id: "v:\(path):\(version.id)", path: path, date: version.changedAt, added: version.added, removed: version.removed,
                                             lines: version.lines, version: index + 1, isCurrent: index == versions.count - 1,
                                             isFirstSeen: index == 0, commitID: nil, commitSubject: nil, coAuthors: [], validUntil: nil))
        }
        for (commit, file) in commits(for: path, in: repositories) {
            // The same edit seen twice: an observed version with the commit's line counts, within a day.
            if let index = changes.firstIndex(where: { change in
                change.version != nil && !change.isFirstSeen && change.commitID == nil
                    && change.added == file.additions && change.removed == file.deletions
                    && abs(change.date.timeIntervalSince(commit.timestamp)) <= 86_400
            }) {
                changes[index].commitID = commit.id
                changes[index].commitSubject = commit.subject
                changes[index].coAuthors = commit.coAuthors ?? []
                continue
            }
            changes.append(ContextFileChange(id: "g:\(path):\(commit.id)", path: path, date: commit.timestamp, added: file.additions, removed: file.deletions,
                                             lines: nil, version: nil, isCurrent: false, isFirstSeen: false, commitID: commit.id,
                                             commitSubject: commit.subject, coAuthors: commit.coAuthors ?? [], validUntil: nil))
        }
        changes.sort { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
        var next = now
        for index in changes.indices {
            changes[index].validUntil = next
            next = changes[index].date
        }
        return changes
    }
}
