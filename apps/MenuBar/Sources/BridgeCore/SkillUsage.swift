import Foundation

/// One observed skill load (or skill edit) inside a turn. Only the skill's
/// name and SKILL.md location are kept: skill text, arguments and command
/// lines never enter this record.
public struct ActivitySkillUse: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Trigger: String, Codable, Sendable {
        /// The model called Claude Code's Skill tool.
        case tool
        /// A person typed the skill as a slash command.
        case command
        /// The agent read the skill's SKILL.md (how Codex loads a skill).
        case read
        /// The agent changed the skill's SKILL.md. Not a load.
        case edit
    }

    /// Native tool-call or item identity, unique within its session.
    public var id: String
    /// As invoked, including any plugin namespace ("anthropic-skills:pdf").
    public var name: String
    public var trigger: Trigger
    /// SKILL.md or skill folder, when the record names one.
    public var path: String?
    public var timestamp: Date?
    /// Size of the skill text the provider injected, when its transcript
    /// records it. Absent for Codex, whose command output is never read.
    public var loadedCharacters: Int?

    public init(id: String, name: String, trigger: Trigger, path: String? = nil, timestamp: Date? = nil, loadedCharacters: Int? = nil) {
        self.id = id; self.name = name; self.trigger = trigger; self.path = path
        self.timestamp = timestamp; self.loadedCharacters = loadedCharacters
    }

    public var isLoad: Bool { trigger != .edit }
    /// Canonical identity shared by every copy of the skill across agents.
    public var key: String { SkillReference.key(name) }
}

public enum SkillReference {
    /// Skills are identified by their bare folder name, case-insensitively,
    /// so Claude's `plugin:name` and Codex's `.../name/SKILL.md` meet.
    public static func key(_ name: String) -> String {
        let bare = name.split(separator: ":").last.map(String.init) ?? name
        return bare.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A clean, bounded name for display and storage. Rejects anything that
    /// could not be a skill name (paths, prose, control characters).
    public static func sanitizedName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard (1...120).contains(value.count),
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:@-]*$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// The skill folder that owns a SKILL.md path, when it sits in a skills
    /// directory (`…/skills/<name>/SKILL.md`, `…/skills/.system/<name>/SKILL.md`
    /// or Claude Code's extracted `bundled-skills`). Copies elsewhere — a
    /// before/after snapshot, a scratch draft — are not skills an agent loads.
    public static func name(forSkillFile path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts.last == "SKILL.md" else { return nil }
        let folder = parts[parts.count - 2]
        let container = parts[parts.count - 3]
        let grand = parts.count >= 4 ? parts[parts.count - 4] : ""
        let inSkills = container == "skills" || (container == ".system" && grand == "skills")
        let bundled = parts.contains("bundled-skills")
        guard inSkills || bundled else { return nil }
        return sanitizedName(folder)
    }

    /// Skill folder named by Claude Code's "Base directory for this skill:" line.
    public static func name(forSkillDirectory path: String) -> String? {
        let last = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return sanitizedName(last)
    }

    private static let readers: Set<String> = ["cat", "sed", "head", "tail", "nl", "bat", "less", "more", "awk", "rg", "grep", "view", "get-content", "type"]
    private static let wrappers: Set<String> = ["sudo", "command", "env", "time", "nice", "xargs"]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env", "pwsh", "powershell"]
    private static let skillPath = try! NSRegularExpression(pattern: #"(?:~|\.{0,2}/|[A-Za-z0-9_.-]+/)[^\s'"`;|&<>(){}]*SKILL\.md\b"#)

    /// SKILL.md files a shell command reads. A redirect into SKILL.md, a copy,
    /// a move or a patch is an edit, not a load, and is reported separately.
    public static func references(inCommand command: String) -> (reads: [(name: String, path: String)], edits: [(name: String, path: String)]) {
        guard command.contains("SKILL.md"), command.utf8.count <= 64_000 else { return ([], []) }
        var reads: [(String, String)] = [], edits: [(String, String)] = []
        var seenReads = Set<String>(), seenEdits = Set<String>()
        for segment in segments(unwrapped(command)) {
            let paths = matches(in: segment)
            guard !paths.isEmpty else { continue }
            let verb = leadingVerb(segment)
            let redirects = segment.range(of: #">>?\s*['"]?[^\s'"]*SKILL\.md"#, options: .regularExpression) != nil
            for path in paths {
                guard let name = name(forSkillFile: path) else { continue }
                if redirects || ["cp", "mv", "tee", "rm", "apply_patch", "patch", "touch", "install", "ln"].contains(verb) {
                    if seenEdits.insert(path).inserted { edits.append((name, path)) }
                } else if readers.contains(verb) {
                    if seenReads.insert(path).inserted { reads.append((name, path)) }
                }
            }
        }
        return (reads, edits)
    }

    /// `/bin/zsh -lc "cat …"` → `cat …`. Quoting is removed only around the
    /// wrapped script, which is all the classification needs.
    static func unwrapped(_ command: String) -> String {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0 ..< 3 {
            let tokens = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard tokens.count == 3, shells.contains(tokens[0].lowercased()), tokens[1].hasPrefix("-"), tokens[1].contains("c") else { break }
            var script = tokens[2].trimmingCharacters(in: .whitespaces)
            if let first = script.first, first == "'" || first == "\"", script.last == first, script.count >= 2 {
                script = String(script.dropFirst().dropLast())
            }
            text = script
        }
        return text
    }

    private static func segments(_ command: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var previous: Character?
        for character in command {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "'" || character == "\"" {
                quote = character; current.append(character)
            } else if character == "\n" || character == ";" || (character == "|" ) || (character == "&" && previous == "&") {
                if character == "&" { current.removeLast() }
                result.append(current); current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func leadingVerb(_ segment: String) -> String {
        var tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = tokens.first, wrappers.contains(first.lowercased()) || first.contains("=") && !first.hasPrefix("-") {
            tokens.removeFirst()
        }
        let verb = (tokens.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "({'\""))
        return URL(fileURLWithPath: verb).lastPathComponent.lowercased()
    }

    private static func matches(in segment: String) -> [String] {
        let range = NSRange(segment.startIndex..., in: segment)
        return skillPath.matches(in: segment, range: range).compactMap { match in
            Range(match.range, in: segment).map { String(segment[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        }
    }

    /// Paths a file change touched that are skills.
    public static func edits(inPaths paths: [String]) -> [(name: String, path: String)] {
        paths.compactMap { path in name(forSkillFile: path).map { ($0, path) } }
    }
}

extension Array where Element == ActivitySkillUse {
    /// Union by identity. A bounded replay can miss earlier records of the same
    /// turn, so a newer observation never erases an older one; known sizes and
    /// paths fill in where the newer record lacks them.
    func mergingSkillUses(_ incoming: [ActivitySkillUse]) -> [ActivitySkillUse] {
        var byID = Dictionary(map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for use in incoming {
            if var prior = byID[use.id] {
                prior.name = use.name; prior.trigger = use.trigger
                prior.path = use.path ?? prior.path
                prior.timestamp = use.timestamp ?? prior.timestamp
                prior.loadedCharacters = use.loadedCharacters ?? prior.loadedCharacters
                byID[use.id] = prior
            } else { byID[use.id] = use }
        }
        return byID.values.sorted { ($0.timestamp ?? .distantPast, $0.id) < ($1.timestamp ?? .distantPast, $1.id) }
    }
}
