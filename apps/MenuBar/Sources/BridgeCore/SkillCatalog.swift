import Foundation

/// One SKILL.md an agent can load. Read from the skill folders each agent
/// documents; provider settings and credential files are never opened.
public struct InstalledSkill: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable {
        /// In the person's own skills folder.
        case personal
        /// Checked into a project.
        case project
        /// Shipped by an installed plugin.
        case plugin
        /// Bundled with the agent itself.
        case system

        public var title: String {
            switch self {
            case .personal: return "Personal"
            case .project: return "Project"
            case .plugin: return "Plugin"
            case .system: return "Built in"
            }
        }
        /// Personal and project skills are the person's own to change.
        public var isOwned: Bool { self == .personal || self == .project }
    }

    public var id: String { path }
    public var key: String
    public var name: String
    public var summary: String
    public var provider: AgentName
    public var scope: Scope
    /// Plugin name, or the project folder for project skills.
    public var owner: String?
    public var path: String
    public var bytes: Int
    public var modifiedAt: Date?
    public var fingerprint: String
    /// Scripts, references and assets beside SKILL.md (bounded count).
    public var supportingFiles: Int

    public init(key: String, name: String, summary: String, provider: AgentName, scope: Scope, owner: String? = nil, path: String,
                bytes: Int, modifiedAt: Date? = nil, fingerprint: String, supportingFiles: Int = 0) {
        self.key = key; self.name = name; self.summary = summary; self.provider = provider; self.scope = scope
        self.owner = owner; self.path = path; self.bytes = bytes; self.modifiedAt = modifiedAt
        self.fingerprint = fingerprint; self.supportingFiles = supportingFiles
    }

    /// Rough tokens to load the skill's instructions (about four characters a
    /// token). Supporting files load only when the agent opens them.
    public var loadTokens: Int { max(1, bytes / 4) }
    /// Rough tokens the always-on skill list spends on this entry: its name
    /// and description (plus the file path Codex lists beside each one).
    public var listingTokens: Int {
        let characters = name.count + summary.count + (provider == .codex ? path.count : 0) + 8
        return max(1, characters / 4)
    }
}

public struct SkillCatalog: Equatable, Sendable {
    public var skills: [InstalledSkill]
    public var scannedAt: Date
    /// Plain-language coverage notes for the page's ⓘ.
    public var notes: [String]
    /// Versions seen of each SKILL.md, by path.
    public var history: [String: ContextFileRecord]
    /// Changes whenever any skill's identity, contents or location changes.
    public var revision: String

    public init(skills: [InstalledSkill], scannedAt: Date, notes: [String] = [], history: [String: ContextFileRecord] = [:]) {
        self.skills = skills; self.scannedAt = scannedAt; self.notes = notes; self.history = history
        revision = TraceCrypto.digest(skills.map { "\($0.path)|\($0.fingerprint)|\($0.scope.rawValue)" }.joined(separator: "\n"))
    }

    public static let empty = SkillCatalog(skills: [], scannedAt: .distantPast)
}

/// Reads skill folders on demand, at most once a minute, and only re-reads a
/// SKILL.md whose size or modification date changed.
public actor SkillCatalogReader {
    public static let shared = SkillCatalogReader(history: .shared)

    private struct Root {
        var url: URL
        var provider: AgentName
        var scope: InstalledSkill.Scope
        var owner: String?
    }
    private struct CachedFile {
        var signature: String
        var skill: InstalledSkill
    }

    private let home: URL
    private let codexSessions: URL
    private let history: ContextFileHistory?
    private var files: [String: CachedFile] = [:]
    private var last: (key: String, catalog: SkillCatalog)?
    private var listing: (signature: String, paths: Set<String>, checkedAt: Date)?
    private let skillLimit = 600
    private let fileByteLimit = 512 * 1_024

    /// `history` records each SKILL.md version it reads; nil keeps none.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, codexSessions: URL? = nil, history: ContextFileHistory? = nil) {
        self.home = home
        self.history = history
        self.codexSessions = codexSessions ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// `projects` adds each project's own skill folders. Results are reused
    /// for `maximumAge` seconds unless the project list changes.
    public func catalog(projects: [String], now: Date = Date(), maximumAge: TimeInterval = 60) -> SkillCatalog {
        let projectList = Array(Set(projects.filter { $0.hasPrefix("/") })).sorted().prefix(80)
        let key = projectList.joined(separator: "\n")
        if let last, last.key == key, (0 ..< maximumAge).contains(now.timeIntervalSince(last.catalog.scannedAt)) {
            return last.catalog
        }
        var notes: [String] = []
        var roots: [Root] = [
            Root(url: home.appendingPathComponent(".claude/skills"), provider: .claude, scope: .personal),
            Root(url: home.appendingPathComponent(".codex/skills"), provider: .codex, scope: .personal),
            Root(url: home.appendingPathComponent(".codex/skills/.system"), provider: .codex, scope: .system),
            Root(url: home.appendingPathComponent(".agents/skills"), provider: .codex, scope: .personal),
        ]
        for project in projectList {
            let url = URL(fileURLWithPath: project, isDirectory: true)
            // Never treat the home folder's own agent folders as a project's.
            guard url.standardizedFileURL.path != home.standardizedFileURL.path else { continue }
            roots.append(Root(url: url.appendingPathComponent(".claude/skills"), provider: .claude, scope: .project, owner: project))
            roots.append(Root(url: url.appendingPathComponent(".codex/skills"), provider: .codex, scope: .project, owner: project))
            roots.append(Root(url: url.appendingPathComponent(".agents/skills"), provider: .codex, scope: .project, owner: project))
        }
        let claudePlugins = pluginRoots(base: home.appendingPathComponent(".claude/plugins/cache"), provider: .claude)
        roots += claudePlugins
        if !claudePlugins.isEmpty {
            // Claude Code records enabled plugins in its settings, which the Hub doesn't open.
            notes.append("Claude Code plugin skills are listed from installed plugins; whether each plugin is turned on isn't read.")
        }
        // Compare resolved paths: the listing and the folder walk can name the
        // same file through different links (/var and /private/var, a linked ~/.codex).
        let enabledCodex = codexListing().map { Set($0.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) }
        let codexPlugins = pluginRoots(base: home.appendingPathComponent(".codex/plugins/cache"), provider: .codex)
        roots += codexPlugins
        if enabledCodex == nil && !codexPlugins.isEmpty {
            notes.append("Codex plugin skills are listed from the newest installed version; whether each plugin is turned on couldn't be confirmed.")
        }

        var found: [InstalledSkill] = []
        var bounded = false
        for root in roots {
            for file in skillFiles(in: root.url) {
                if found.count >= skillLimit { bounded = true; break }
                if root.scope == .plugin, root.provider == .codex, let enabledCodex,
                   !enabledCodex.contains(file.resolvingSymlinksInPath().path) { continue }
                guard let skill = read(file, root: root) else { continue }
                found.append(skill)
            }
        }
        let present = Set(found.map(\.path))
        files = files.filter { present.contains($0.key) }
        if bounded { notes.append("Showing the first \(skillLimit) skills found.") }
        // One entry per file. Symlinked folders can expose the same file twice.
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.path).inserted }
            .sorted { $0.key == $1.key ? ($0.provider.rawValue, $0.path) < ($1.provider.rawValue, $1.path) : $0.key < $1.key }
        let catalog = SkillCatalog(skills: unique, scannedAt: now, notes: notes, history: history?.records(for: unique.map(\.path)) ?? [:])
        last = (key, catalog)
        return catalog
    }

    // MARK: Discovery

    private func skillFiles(in root: URL) -> [URL] {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles]) else { return [] }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(400).compactMap { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            return manager.isReadableFile(atPath: file.path) ? file : nil
        }
    }

    /// `<base>/<marketplace>/<plugin>/<version>/skills`, newest version only.
    private func pluginRoots(base: URL, provider: AgentName) -> [Root] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        func folders(_ url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var roots: [Root] = []
        for marketplace in folders(base).prefix(40) {
            for plugin in folders(marketplace).prefix(200) {
                let versions = folders(plugin).filter { manager.fileExists(atPath: $0.appendingPathComponent("skills").path) }
                let newest = versions.max { lhs, rhs in
                    let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return l == r ? lhs.lastPathComponent < rhs.lastPathComponent : l < r
                }
                // Codex can enable an older cached version; keep every version
                // there and let its observed listing decide.
                let chosen = provider == .codex ? versions : newest.map { [$0] } ?? []
                for version in chosen {
                    roots.append(Root(url: version.appendingPathComponent("skills"), provider: provider, scope: .plugin, owner: plugin.lastPathComponent))
                }
            }
        }
        return roots
    }

    // MARK: Reading

    private func read(_ file: URL, root: Root) -> InstalledSkill? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate
        let signature = "\(size):\(modified?.timeIntervalSince1970 ?? 0):\(root.provider.rawValue):\(root.scope.rawValue):\(root.owner ?? "")"
        if let cached = files[file.path], cached.signature == signature { return cached.skill }
        guard size <= fileByteLimit, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: fileByteLimit) else { return nil }
        history?.observe(path: file.path, data: data, modifiedAt: modified)
        let text = String(decoding: data, as: UTF8.self)
        let front = SkillFrontMatter.parse(text)
        let folder = file.deletingLastPathComponent().lastPathComponent
        let name = front.name.flatMap(SkillReference.sanitizedName) ?? folder
        let skill = InstalledSkill(
            key: SkillReference.key(folder), name: name,
            summary: TraceRedactor.redact(front.description ?? "", maximumCharacters: 600),
            provider: root.provider, scope: root.scope, owner: root.owner, path: file.path,
            bytes: data.count, modifiedAt: modified, fingerprint: TraceCrypto.digest(data),
            supportingFiles: supportingFileCount(file.deletingLastPathComponent()))
        files[file.path] = CachedFile(signature: signature, skill: skill)
        return skill
    }

    private func supportingFileCount(_ folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var count = 0
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 400 { break }
            if url.lastPathComponent == "SKILL.md" && url.deletingLastPathComponent().path == folder.path { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        return count
    }

    /// The skill paths Codex listed as available in its newest session. Only
    /// SKILL.md locations are extracted; nothing else in the record is kept.
    private func codexListing() -> Set<String>? {
        guard let newest = newestRollout() else { return nil }
        let values = try? newest.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let signature = "\(newest.path):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        // Plugins are turned on and off rarely, while the newest session grows
        // every few seconds. Re-read the listing at most every ten minutes.
        if let listing, listing.signature == signature || Date().timeIntervalSince(listing.checkedAt) < 600 { return listing.paths }
        guard let handle = try? FileHandle(forReadingFrom: newest) else { return nil }
        defer { try? handle.close() }
        let window = 3 * 1_024 * 1_024
        var chunks: [Data] = []
        if let length = try? handle.seekToEnd() {
            try? handle.seek(toOffset: 0)
            if let head = try? handle.read(upToCount: window) { chunks.append(head) }
            if length > UInt64(window) {
                try? handle.seek(toOffset: max(UInt64(window), length - UInt64(window)))
                if let tail = try? handle.read(upToCount: window) { chunks.append(tail) }
            }
        }
        var latest: Set<String>?
        for chunk in chunks {
            for line in chunk.split(separator: 10) where line.range(of: Data("\"host_skills\"".utf8)) != nil {
                let paths = Self.listedPaths(String(decoding: line, as: UTF8.self))
                if !paths.isEmpty { latest = paths }
            }
        }
        if let latest { listing = (signature, latest, Date()) }
        return latest ?? listing?.paths
    }

    static func listedPaths(_ line: String) -> Set<String> {
        // Entries look like "[\"host\",\"host\",\"/…/SKILL.md\"]": {…, "shown": true}
        let pattern = #"\\"(/[^"\\]+/SKILL\.md)\\"\]"\s*:\s*\{[^{}]*?"shown"\s*:\s*true"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return Set(regex.matches(in: line, range: range).compactMap { match in
            Range(match.range(at: 1), in: line).map { String(line[$0]) }
        })
    }

    private func newestRollout() -> URL? {
        let manager = FileManager.default
        func newestChild(_ url: URL) -> URL? {
            ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { Int($0.lastPathComponent) != nil }
                .max { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard let year = newestChild(codexSessions), let month = newestChild(year), let day = newestChild(month) else { return nil }
        let files = ((try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        return files.max {
            let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
    }
}

/// The `name` and `description` of a SKILL.md's YAML front matter. Handles
/// plain, quoted and folded (`>`/`|`) values; anything else is ignored.
public enum SkillFrontMatter {
    public static func parse(_ text: String) -> (name: String?, description: String?) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var values: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { index += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            index += 1
            if [">", "|", ">-", "|-", ">+", "|+"].contains(value) || value.isEmpty {
                var parts: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty {
                    if lines[index].trimmingCharacters(in: .whitespaces) == "---" { break }
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = parts.filter { !$0.isEmpty }.joined(separator: " ")
            }
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if ["name", "description"].contains(key) { values[key] = value }
        }
        let description = values["description"].map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
        return (values["name"].flatMap { $0.isEmpty ? nil : $0 }, description.flatMap { $0.isEmpty ? nil : $0 })
    }
}
