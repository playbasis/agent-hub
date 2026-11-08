import Foundation

/// What a session was handed before its first request: the standing
/// instruction files (AGENTS.md, CLAUDE.md, rules, memory) and the skill
/// list. Sizes and locations only; file contents are never kept.
public struct ActivityStartContext: Codable, Equatable, Sendable {
    /// Instruction files as the agent recorded them. Claude Code lists each
    /// file; Codex records one combined block for the folder it started in.
    public var instructions: [ActivityInstructionLoad]
    /// False when the agent's record doesn't say what it loaded (older
    /// versions); the report then works it out from the files on disk.
    public var instructionsRecorded: Bool
    /// Characters of the skill names and descriptions listed at the start.
    public var skillListCharacters: Int?
    public var skillListCount: Int?
    public var clientVersion: String?

    public init(instructions: [ActivityInstructionLoad] = [], instructionsRecorded: Bool = false, skillListCharacters: Int? = nil,
                skillListCount: Int? = nil, clientVersion: String? = nil) {
        self.instructions = instructions; self.instructionsRecorded = instructionsRecorded
        self.skillListCharacters = skillListCharacters; self.skillListCount = skillListCount; self.clientVersion = clientVersion
    }

    public var instructionCharacters: Int { instructions.reduce(0) { $0 + $1.characters } }

    /// A later observation of the same session. A moving transcript window can
    /// miss the start, so known facts are kept and newer sizes win.
    public func merging(_ incoming: ActivityStartContext) -> ActivityStartContext {
        var value = self
        var byID = Dictionary(instructions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        for load in incoming.instructions { byID[load.id] = byID[load.id].map { $0.merging(load) } ?? load }
        value.instructions = byID.values.sorted(by: ActivityInstructionLoad.loadOrder)
        value.instructionsRecorded = instructionsRecorded || incoming.instructionsRecorded
        value.skillListCharacters = skillListCharacters ?? incoming.skillListCharacters
        value.skillListCount = skillListCount ?? incoming.skillListCount
        value.clientVersion = incoming.clientVersion ?? clientVersion
        return value
    }
}

public struct ActivityInstructionLoad: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Checked into the project: CLAUDE.md, AGENTS.md, rules.
        case project
        /// The person's private project file (CLAUDE.local.md).
        case local
        /// The person's own file for every project (~/.claude/CLAUDE.md).
        case personal
        /// Set by an organization.
        case managed
        /// Claude Code's auto memory index (MEMORY.md).
        case memory
        /// Codex's combined AGENTS.md text: personal and project files together.
        case combined
    }

    /// Redacted file path. For `.combined`, the folder Codex gathered the
    /// files for, or empty when only the personal file was loaded.
    public var path: String
    public var kind: Kind
    public var characters: Int
    /// The file that imported this one with an @-reference.
    public var parent: String?
    /// Distinct sizes seen in the session; more than one means the file
    /// changed while the session ran.
    public var versions: Int
    public var firstSeen: Date?
    public var lastSeen: Date?

    public init(path: String, kind: Kind, characters: Int, parent: String? = nil, versions: Int = 1, firstSeen: Date? = nil, lastSeen: Date? = nil) {
        self.path = path; self.kind = kind; self.characters = characters; self.parent = parent
        self.versions = versions; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }

    public var id: String { "\(kind.rawValue):\(path)" }

    func merging(_ incoming: ActivityInstructionLoad) -> ActivityInstructionLoad {
        var value = self
        let newer = (incoming.lastSeen ?? .distantPast) >= (lastSeen ?? .distantPast)
        if newer { value.characters = incoming.characters; value.parent = incoming.parent ?? parent }
        value.versions = max(versions, incoming.versions, characters != incoming.characters ? 2 : 1)
        value.firstSeen = [firstSeen, incoming.firstSeen].compactMap { $0 }.min()
        value.lastSeen = [lastSeen, incoming.lastSeen].compactMap { $0 }.max()
        return value
    }

    /// Organization, personal, project, private, memory: the order agents load them.
    static func loadOrder(_ lhs: ActivityInstructionLoad, _ rhs: ActivityInstructionLoad) -> Bool {
        func rank(_ kind: Kind) -> Int {
            switch kind {
            case .managed: return 0
            case .personal: return 1
            case .combined: return 2
            case .project: return 3
            case .local: return 4
            case .memory: return 5
            }
        }
        return rank(lhs.kind) == rank(rhs.kind) ? lhs.path < rhs.path : rank(lhs.kind) < rank(rhs.kind)
    }
}

/// Recognizes the instruction files agents load on their own.
public enum InstructionReference {
    public static let codexNames = ["AGENTS.override.md", "AGENTS.md"]
    public static let claudeNames = ["CLAUDE.md", "CLAUDE.local.md"]

    /// Whether a path names a file an agent reads at the start of a session.
    public static func isInstructionFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if codexNames.contains(name) || claudeNames.contains(name) { return true }
        return name.hasSuffix(".md") && path.contains("/.claude/rules/")
    }

    /// Claude Code's own transcript names for each kind of instruction file.
    static func claudeKind(_ type: String?) -> ActivityInstructionLoad.Kind {
        switch type {
        case "Local": return .local
        case "User": return .personal
        case "Managed": return .managed
        case let value? where value.hasPrefix("AutoMem"): return .memory
        default: return .project
        }
    }

    /// Text between Codex's `<INSTRUCTIONS>` markers, or the whole message.
    static func codexInstructions(_ text: String) -> (folder: String?, characters: Int)? {
        let header = "# AGENTS.md instructions"
        if text.hasPrefix(header) {
            let firstLine = text.prefix { $0 != "\n" }
            var folder: String?
            if let range = firstLine.range(of: " for ") {
                let value = firstLine[range.upperBound...].trimmingCharacters(in: .whitespaces)
                folder = value.hasPrefix("/") && value.count <= 2_048 ? value : nil
            }
            if let open = text.range(of: "<INSTRUCTIONS>"), let close = text.range(of: "</INSTRUCTIONS>", options: .backwards),
               open.upperBound <= close.lowerBound {
                return (folder, text[open.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).count)
            }
            return (folder, text.count)
        }
        if text.hasPrefix("<user_instructions>") {
            let inner = text.replacingOccurrences(of: "<user_instructions>", with: "").replacingOccurrences(of: "</user_instructions>", with: "")
            return (nil, inner.trimmingCharacters(in: .whitespacesAndNewlines).count)
        }
        return nil
    }

    /// Claude Code versions that record their instruction files. Earlier
    /// versions leave no record, so a missing record says nothing.
    public static func claudeRecordsInstructions(_ version: String?) -> Bool {
        guard let version else { return false }
        return compare(version, "2.1.260") >= 0
    }

    /// Claude Code versions known to read AGENTS.md when a project has no CLAUDE.md.
    public static func claudeReadsAgentsFile(_ version: String?) -> Bool {
        guard let version else { return false }
        return compare(version, "2.1.299") >= 0
    }

    static func compare(_ lhs: String, _ rhs: String) -> Int {
        func parts(_ value: String) -> [Int] {
            value.split(whereSeparator: { !$0.isNumber }).prefix(4).map { Int($0) ?? 0 }
        }
        let a = parts(lhs), b = parts(rhs)
        for index in 0 ..< max(a.count, b.count) {
            let l = index < a.count ? a[index] : 0, r = index < b.count ? b[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

/// Reads the start of a Codex rollout for the instructions and skill list
/// the session began with. Codex writes both before the first turn, after
/// any history a sub-agent inherits from its parent; that inherited copy is
/// skipped unread. A rollout's start never changes, so each file is read once.
enum CodexStartContextReader {
    private static let store = Store()
    private static let maximumLineBytes = 2 * 1_024 * 1_024
    private static let maximumScanBytes: UInt64 = 32 * 1_024 * 1_024
    private static let turnMarker = Data("\"turn_context\"".utf8)
    private static let metaMarker = Data("\"session_meta\"".utf8)
    private static let instructionMarkers = ["AGENTS.md instructions", "<user_instructions>"].map { Data($0.utf8) }
    private static let skillsMarker = Data("<skills_instructions>".utf8)

    static func read(path: String?) -> ActivityStartContext? {
        guard let path, path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension == "jsonl" else { return nil }
        return store.read(path)
    }

    private struct Entry {
        var inode: UInt64?
        var value: ActivityStartContext?
        var complete: Bool
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func read(_ path: String) -> ActivityStartContext? {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            lock.lock()
            if let entry = entries[path], entry.inode == inode, entry.complete { lock.unlock(); return entry.value }
            lock.unlock()
            let (value, complete) = CodexStartContextReader.scan(path)
            lock.lock()
            if entries.count > 6_000 { entries.removeAll(keepingCapacity: true) }
            entries[path] = Entry(inode: inode, value: value, complete: complete)
            lock.unlock()
            return value
        }
    }

    /// Returns what was found and whether the start of the file is complete
    /// (the first turn began, or the scan bound was reached).
    static func scan(_ path: String) -> (ActivityStartContext?, Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, false) }
        defer { try? handle.close() }
        var pending = Data()
        var discarding = false
        var scanned: UInt64 = 0
        var context = ActivityStartContext()
        var foundInstructions = false
        var foundSkills = false
        var complete = false

        func consume(_ line: Data) -> Bool {
            if line.range(of: turnMarker) != nil { return true }
            let isMeta = context.clientVersion == nil && line.range(of: metaMarker) != nil
            let isInstructions = instructionMarkers.contains { line.range(of: $0) != nil }
            let isSkills = line.range(of: skillsMarker) != nil
            guard isMeta || isInstructions || isSkills else { return false }
            autoreleasepool {
                guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = root["payload"] as? [String: Any] else { return }
                if root["type"] as? String == "session_meta" {
                    context.clientVersion = (payload["cli_version"] as? String).flatMap { $0.count <= 40 ? $0 : nil }
                    return
                }
                guard root["type"] as? String == "response_item", payload["type"] as? String == "message" else { return }
                let timestamp = CodexActivityParser.date(root["timestamp"])
                for block in payload["content"] as? [[String: Any]] ?? [] {
                    guard let text = block["text"] as? String else { continue }
                    if let found = InstructionReference.codexInstructions(text) {
                        foundInstructions = true
                        let folder = found.folder.map { TraceRedactor.redact($0, maximumCharacters: 1_024) } ?? ""
                        let load = ActivityInstructionLoad(path: folder, kind: .combined, characters: found.characters,
                                                           firstSeen: timestamp, lastSeen: timestamp)
                        context = context.merging(ActivityStartContext(instructions: [load]))
                    } else if text.hasPrefix("<skills_instructions>"), !foundSkills {
                        foundSkills = true
                        context.skillListCharacters = text.count
                    }
                }
            }
            return false
        }

        scanLoop: while scanned < maximumScanBytes {
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 65_536) }
            guard let chunk, !chunk.isEmpty else { break }
            scanned += UInt64(chunk.count)
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                let newline = chunk[cursor...].firstIndex(of: 10)
                let end = newline ?? chunk.endIndex
                if discarding {
                    if newline != nil { discarding = false }
                } else if pending.count + (end - cursor) > maximumLineBytes {
                    // Inherited history from a parent task: not this session's start.
                    pending.removeAll(keepingCapacity: false)
                    discarding = newline == nil
                } else {
                    pending.append(chunk[cursor ..< end])
                    if newline != nil {
                        if consume(pending) { complete = true; break scanLoop }
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                cursor = newline.map { chunk.index(after: $0) } ?? chunk.endIndex
            }
        }
        if scanned >= maximumScanBytes { complete = true }
        guard foundInstructions || foundSkills else { return (nil, complete) }
        // Codex sends its AGENTS.md block before the first turn whenever a
        // file exists, so a complete start without one recorded none.
        context.instructionsRecorded = foundInstructions || complete
        return (context, complete)
    }
}
