import Foundation

/// One instruction file on disk that an agent reads at the start of a
/// session. Contents are read for size, a fingerprint and @-imports only;
/// provider settings and credential files are never opened.
public struct InstructionFile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case agents, agentsOverride, claude, claudeLocal, rule, memory, other

        public var title: String {
            switch self {
            case .agents: return "AGENTS.md"
            case .agentsOverride: return "AGENTS.override.md"
            case .claude: return "CLAUDE.md"
            case .claudeLocal: return "CLAUDE.local.md"
            case .rule: return "Rule"
            case .memory: return "Memory"
            case .other: return "File"
            }
        }
    }

    public var path: String
    public var kind: Kind
    public var bytes: Int
    public var characters: Int
    public var lines: Int
    public var modifiedAt: Date?
    public var fingerprint: String
    /// Files it pulls in with `@path` references (Claude Code only).
    public var imports: [String]
    /// Characters other than @-references and whitespace. A CLAUDE.md that
    /// only says `@AGENTS.md` is a pointer, not a second set of rules.
    public var substantiveCharacters: Int
    /// A rule with `paths:` front matter loads only beside matching files.
    public var conditional: Bool

    public var id: String { path }
    public var tokens: Int { max(1, characters / 4) }
    public var isPointer: Bool { substantiveCharacters < 24 && !imports.isEmpty }

    public init(path: String, kind: Kind, bytes: Int, characters: Int, lines: Int = 0, modifiedAt: Date? = nil, fingerprint: String,
                imports: [String] = [], substantiveCharacters: Int? = nil, conditional: Bool = false) {
        self.path = path; self.kind = kind; self.bytes = bytes; self.characters = characters; self.lines = lines
        self.modifiedAt = modifiedAt; self.fingerprint = fingerprint; self.imports = imports
        self.substantiveCharacters = substantiveCharacters ?? characters; self.conditional = conditional
    }

    static func kind(for path: String) -> Kind {
        switch (path as NSString).lastPathComponent {
        case "AGENTS.md": return .agents
        case "AGENTS.override.md": return .agentsOverride
        case "CLAUDE.md": return .claude
        case "CLAUDE.local.md": return .claudeLocal
        case "MEMORY.md" where path.contains("/memory/"): return .memory
        default: return path.contains("/.claude/rules/") ? .rule : .other
        }
    }
}

/// Why an agent reads a file, in the order it reads them.
public struct InstructionLink: Equatable, Identifiable, Sendable {
    public enum Reason: String, Sendable {
        /// The person's own file for every project.
        case personal
        /// Checked into the project.
        case project
        /// The person's private file for this project (CLAUDE.local.md).
        case local
        /// A project rule in .claude/rules.
        case rule
        /// Pulled in by an @-reference in another file.
        case imported
        /// AGENTS.md read by Claude Code because the project has no CLAUDE.md.
        case fallback
        /// Claude Code's auto memory for the project.
        case memory
    }

    public var path: String
    public var reason: Reason
    public var importedBy: String?
    /// Bytes the agent reads; less than the file when a limit cuts it off.
    public var bytesRead: Int
    public var id: String { "\(reason.rawValue):\(path)" }
    public var isPersonal: Bool { reason == .personal || (reason == .imported && importedFromPersonal) }
    var importedFromPersonal = false
}

/// The files one agent reads at the start of a session in one folder.
public struct InstructionChain: Equatable, Sendable {
    public var agent: AgentName
    public var links: [InstructionLink]
    /// Project text past Codex's default 32 KB limit, which it never reads.
    public var truncatedBytes = 0

    public init(agent: AgentName, links: [InstructionLink] = [], truncatedBytes: Int = 0) {
        self.agent = agent; self.links = links; self.truncatedBytes = truncatedBytes
    }

    public var projectLinks: [InstructionLink] { links.filter { !$0.isPersonal && $0.reason != .memory } }
    public var bytesRead: Int { links.reduce(0) { $0 + $1.bytesRead } }
    public func bytesRead(_ reasons: Set<InstructionLink.Reason>) -> Int {
        links.filter { reasons.contains($0.reason) }.reduce(0) { $0 + $1.bytesRead }
    }
}

/// What each agent reads in one project, and whether they get the same rules.
public struct ProjectInstructions: Equatable, Identifiable, Sendable {
    public enum Parity: String, Sendable {
        /// Both agents read the same project rules.
        case same
        /// They share some rules; one reads more.
        case overlap
        /// Each reads its own, different rules.
        case different
        case claudeOnly, codexOnly
        /// No project rules for either agent.
        case none

        public var needsLook: Bool { self == .different || self == .claudeOnly || self == .codexOnly }
    }

    public var path: String
    public var claude: InstructionChain
    public var codex: InstructionChain
    public var parity: Parity
    public var id: String { path }

    public func chain(_ agent: AgentName) -> InstructionChain { agent == .claude ? claude : codex }
}

public struct InstructionCatalog: Equatable, Sendable {
    /// Every file in any chain, by path.
    public var files: [String: InstructionFile]
    public var projects: [String: ProjectInstructions]
    /// What each agent reads in every project, before any project files.
    public var personal: ProjectInstructions
    public var scannedAt: Date
    public var notes: [String]
    /// Versions seen of each instruction file, by path (memory isn't tracked).
    public var history: [String: ContextFileRecord]
    public var revision: String

    public init(files: [String: InstructionFile], projects: [String: ProjectInstructions], personal: ProjectInstructions,
                scannedAt: Date, notes: [String] = [], history: [String: ContextFileRecord] = [:]) {
        self.files = files; self.projects = projects; self.personal = personal; self.scannedAt = scannedAt; self.notes = notes
        self.history = history
        let fileLines = files.values.map { "\($0.path)|\($0.fingerprint)|\($0.bytes)" }.sorted()
        let projectLines = projects.values.map { "\($0.path)|\($0.parity.rawValue)|\($0.claude.links.map(\.id))|\($0.codex.links.map(\.id))" }.sorted()
        revision = TraceCrypto.digest((fileLines + projectLines).joined(separator: "\n"))
    }

    public static let empty = InstructionCatalog(files: [:], projects: [:],
        personal: ProjectInstructions(path: "~", claude: InstructionChain(agent: .claude), codex: InstructionChain(agent: .codex), parity: .none),
        scannedAt: .distantPast)

    public func file(_ path: String) -> InstructionFile? { files[path] }
}

/// Works out, per project, which instruction files Claude Code and Codex
/// read, following each agent's documented discovery rules. Re-reads a file
/// only when its size or modification date changes.
public actor InstructionCatalogReader {
    public static let shared = InstructionCatalogReader(history: .shared)
    /// Codex's default `project_doc_max_bytes`.
    public static let codexProjectLimit = 32 * 1_024

    private struct CachedFile {
        var signature: String
        var file: InstructionFile
    }

    private let home: URL
    private let history: ContextFileHistory?
    private var cache: [String: CachedFile] = [:]
    private var last: (key: String, catalog: InstructionCatalog)?
    private let fileByteLimit = 256 * 1_024

    /// `history` records each instruction file version it reads; nil keeps none.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, history: ContextFileHistory? = nil) {
        self.home = home.standardizedFileURL
        self.history = history
    }

    public func catalog(projects: [String], now: Date = Date(), maximumAge: TimeInterval = 60) -> InstructionCatalog {
        let list = Array(Set(projects.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted().prefix(80)
        let key = list.joined(separator: "\n")
        if let last, last.key == key, (0 ..< maximumAge).contains(now.timeIntervalSince(last.catalog.scannedAt)) {
            return last.catalog
        }
        var files: [String: InstructionFile] = [:]
        var results: [String: ProjectInstructions] = [:]
        let personalClaude = claudePersonal(files: &files)
        let personalCodex = codexPersonal(files: &files)
        let personal = ProjectInstructions(path: "~", claude: InstructionChain(agent: .claude, links: personalClaude),
                                           codex: InstructionChain(agent: .codex, links: personalCodex),
                                           parity: Self.parity(claude: personalClaude, codex: personalCodex, files: files))
        for project in list {
            let claude = claudeChain(project, personal: personalClaude, files: &files)
            let codex = codexChain(project, personal: personalCodex, files: &files)
            let parity = Self.parity(claude: claude.projectLinks, codex: codex.projectLinks, files: files)
            results[project] = ProjectInstructions(path: project, claude: claude, codex: codex, parity: parity)
        }
        let present = Set(files.keys)
        cache = cache.filter { present.contains($0.key) }
        let notes = [
            "Claude Code reads CLAUDE.md, CLAUDE.local.md and .claude/rules in the project folder and every folder above it, plus files they import with @. A project with no CLAUDE.md gets its AGENTS.md instead (Claude Code 2.1.299 and later, by default).",
            "Codex reads ~/.codex/AGENTS.md, then one AGENTS.override.md or AGENTS.md per folder from the repository root down, up to 32 KB of project text. Other file names set in Codex's own settings aren't read by the Hub.",
        ]
        let tracked = files.values.filter { $0.kind != .memory }.map(\.path)
        let catalog = InstructionCatalog(files: files, projects: results, personal: personal, scannedAt: now, notes: notes,
                                         history: history?.records(for: tracked) ?? [:])
        last = (key, catalog)
        return catalog
    }

    // MARK: Claude Code

    private func claudePersonal(files: inout [String: InstructionFile]) -> [InstructionLink] {
        var links: [InstructionLink] = []
        var seen = Set<String>()
        let base = home.appendingPathComponent(".claude")
        add(base.appendingPathComponent("CLAUDE.md").path, reason: .personal, to: &links, seen: &seen, files: &files, followImports: true)
        for rule in ruleFiles(base.appendingPathComponent("rules")) {
            add(rule, reason: .personal, to: &links, seen: &seen, files: &files, followImports: true, skipConditional: true)
        }
        return links
    }

    private func claudeChain(_ project: String, personal: [InstructionLink], files: inout [String: InstructionFile]) -> InstructionChain {
        var links = personal
        var seen = Set(personal.map { resolved($0.path) })
        let ancestors = Self.ancestors(of: project)
        let personalFile = home.appendingPathComponent(".claude/CLAUDE.md").path
        var hasClaudeFile = false
        for folder in ancestors {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            for candidate in [url.appendingPathComponent("CLAUDE.md").path, url.appendingPathComponent(".claude/CLAUDE.md").path]
            where candidate != personalFile {
                if add(candidate, reason: .project, to: &links, seen: &seen, files: &files, followImports: true) { hasClaudeFile = true }
            }
            if url.standardizedFileURL.path != home.path {
                for rule in ruleFiles(url.appendingPathComponent(".claude/rules")) {
                    add(rule, reason: .rule, to: &links, seen: &seen, files: &files, followImports: true, skipConditional: true)
                }
            }
            if add(url.appendingPathComponent("CLAUDE.local.md").path, reason: .local, to: &links, seen: &seen, files: &files, followImports: true) {
                hasClaudeFile = true
            }
        }
        if !hasClaudeFile {
            for folder in ancestors where folder != home.path {
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                for candidate in [url.appendingPathComponent("AGENTS.md").path, url.appendingPathComponent(".claude/AGENTS.md").path] {
                    add(candidate, reason: .fallback, to: &links, seen: &seen, files: &files, followImports: true)
                }
            }
        }
        let memory = home.appendingPathComponent(".claude/projects")
            .appendingPathComponent(Self.claudeProjectFolder(project)).appendingPathComponent("memory/MEMORY.md").path
        add(memory, reason: .memory, to: &links, seen: &seen, files: &files, followImports: false)
        return InstructionChain(agent: .claude, links: links)
    }

    // MARK: Codex

    private func codexPersonal(files: inout [String: InstructionFile]) -> [InstructionLink] {
        var links: [InstructionLink] = []
        var seen = Set<String>()
        let base = home.appendingPathComponent(".codex")
        // An override replaces the personal file rather than adding to it.
        if !add(base.appendingPathComponent("AGENTS.override.md").path, reason: .personal, to: &links, seen: &seen, files: &files, followImports: false) {
            add(base.appendingPathComponent("AGENTS.md").path, reason: .personal, to: &links, seen: &seen, files: &files, followImports: false)
        }
        return links
    }

    private func codexChain(_ project: String, personal: [InstructionLink], files: inout [String: InstructionFile]) -> InstructionChain {
        var links = personal
        var seen = Set(personal.map { resolved($0.path) })
        let ancestors = Self.ancestors(of: project)
        let manager = FileManager.default
        // From the repository root down to the folder; without one, the folder only.
        let rootIndex = ancestors.lastIndex { manager.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent(".git").path) }
        let folders = rootIndex.map { Array(ancestors[$0...]) } ?? [project]
        var total = 0
        var truncated = 0
        for folder in folders where folder != home.path {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            for name in InstructionReference.codexNames {
                var probe = links
                guard add(url.appendingPathComponent(name).path, reason: .project, to: &probe, seen: &seen, files: &files, followImports: false),
                      var link = probe.last else { continue }
                let bytes = files[link.path]?.bytes ?? 0
                let room = max(0, Self.codexProjectLimit - total)
                link.bytesRead = min(bytes, room)
                truncated += bytes - link.bytesRead
                total += bytes
                links.append(link)
                break
            }
        }
        return InstructionChain(agent: .codex, links: links, truncatedBytes: truncated)
    }

    // MARK: Files

    /// Adds a readable, non-empty file once, then any files it imports.
    @discardableResult
    private func add(_ path: String, reason: InstructionLink.Reason, to links: inout [InstructionLink], seen: inout Set<String>,
                     files: inout [String: InstructionFile], followImports: Bool, skipConditional: Bool = false,
                     importedBy: String? = nil, depth: Int = 0) -> Bool {
        let real = resolved(path)
        guard !seen.contains(real), let file = read(path), file.bytes > 0 else { return false }
        if skipConditional && file.conditional { return false }
        seen.insert(real)
        files[path] = file
        var link = InstructionLink(path: path, reason: importedBy == nil ? reason : .imported, importedBy: importedBy, bytesRead: file.bytes)
        link.importedFromPersonal = importedBy != nil && reason == .personal
        links.append(link)
        if followImports, depth < 5 {
            for target in file.imports {
                add(target, reason: reason, to: &links, seen: &seen, files: &files, followImports: true, importedBy: path, depth: depth + 1)
            }
        }
        return true
    }

    private func read(_ path: String) -> InstructionFile? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate
        let signature = "\(size):\(modified?.timeIntervalSince1970 ?? 0)"
        if let cached = cache[path], cached.signature == signature { return cached.file }
        let kind = InstructionFile.kind(for: path)
        let file: InstructionFile
        if kind == .memory {
            // The memory index is the person's own notes: its size is enough.
            file = InstructionFile(path: path, kind: kind, bytes: size, characters: size, modifiedAt: modified, fingerprint: signature)
        } else {
            guard size <= fileByteLimit, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: fileByteLimit) else { return nil }
            history?.observe(path: path, data: data, modifiedAt: modified)
            let text = String(decoding: data, as: UTF8.self)
            let imports = Self.imports(in: text, relativeTo: url.deletingLastPathComponent(), home: home)
            file = InstructionFile(path: path, kind: kind, bytes: data.count, characters: text.count,
                                   lines: text.split(separator: "\n", omittingEmptySubsequences: false).count,
                                   modifiedAt: modified, fingerprint: TraceCrypto.digest(data),
                                   imports: imports.paths, substantiveCharacters: imports.remaining,
                                   conditional: kind == .rule && Self.hasPathsFrontMatter(text))
        }
        cache[path] = CachedFile(signature: signature, file: file)
        return file
    }

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func ruleFiles(_ folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            paths.append(url.path)
            if paths.count >= 100 { break }
        }
        return paths.sorted()
    }

    // MARK: Parsing

    /// `@path` references outside code, resolved against the file's folder.
    /// Returns the referenced files that exist and the characters left over.
    static func imports(in text: String, relativeTo folder: URL, home: URL) -> (paths: [String], remaining: Int) {
        var paths: [String] = []
        var remaining = 0
        var fenced = false
        let manager = FileManager.default
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); remaining += line.count; continue }
            if fenced { remaining += line.count; continue }
            var outside = line
            // Inline code is quoted text, not a reference.
            outside = outside.replacingOccurrences(of: #"`[^`]*`"#, with: " ", options: .regularExpression)
            var stripped = outside
            for token in outside.split(whereSeparator: { $0 == " " || $0 == "\t" }) where token.hasPrefix("@") && token.count > 1 {
                var reference = String(token.dropFirst())
                // Sentence punctuation after a reference isn't part of the path.
                while let last = reference.last, ".,;:)]".contains(last) { reference.removeLast() }
                guard reference.count <= 512, reference.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
                let target: URL
                if reference.hasPrefix("~/") { target = home.appendingPathComponent(String(reference.dropFirst(2))) }
                else if reference.hasPrefix("/") { target = URL(fileURLWithPath: reference) }
                else { target = folder.appendingPathComponent(reference) }
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                let path = target.standardizedFileURL.path
                if !paths.contains(path) { paths.append(path) }
                stripped = stripped.replacingOccurrences(of: String(token), with: "")
                if paths.count >= 20 { break }
            }
            remaining += stripped.trimmingCharacters(in: .whitespaces).count
        }
        return (paths, remaining)
    }

    static func hasPathsFrontMatter(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "---" else { return false }
        for line in lines.dropFirst() {
            if line == "---" { return false }
            if line.hasPrefix("paths:") || line.hasPrefix("globs:") { return true }
        }
        return false
    }

    /// The folder and every folder above it, outermost first.
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            result.append(url.path)
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path || result.count > 40 { break }
            url = parent
        }
        return result.reversed()
    }

    /// Claude Code keeps each project's data in a folder named after its path.
    static func claudeProjectFolder(_ path: String) -> String {
        path.replacingOccurrences(of: #"[^A-Za-z0-9]"#, with: "-", options: .regularExpression)
    }

    // MARK: Parity

    /// Compares the substance of each agent's project rules: a CLAUDE.md
    /// that only imports AGENTS.md shares AGENTS.md's rules.
    static func parity(claude: [InstructionLink], codex: [InstructionLink], files: [String: InstructionFile]) -> ProjectInstructions.Parity {
        func rules(_ links: [InstructionLink]) -> Set<String> {
            Set(links.compactMap { link in
                guard link.reason != .memory, let file = files[link.path], !file.isPointer else { return nil }
                return file.fingerprint
            })
        }
        let a = rules(claude), b = rules(codex)
        switch (a.isEmpty, b.isEmpty) {
        case (true, true): return .none
        case (false, true): return .claudeOnly
        case (true, false): return .codexOnly
        default: return a == b ? .same : (a.isDisjoint(with: b) ? .different : .overlap)
        }
    }
}
