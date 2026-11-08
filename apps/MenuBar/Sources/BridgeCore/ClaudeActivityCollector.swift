import Foundation

/// Passive metadata adapter. It never starts Claude or reads its credential store.
/// Collection covers a bounded set of recent local transcripts, not the account.
public struct ClaudeActivityCollector: Sendable {
    private let cache: ClaudeActivityCache

    public init(root: URL? = nil) {
        cache = ClaudeActivityCache(root: root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true))
    }

    public func collect(now: Date = Date()) async -> ActivityCollection {
        await cache.collect(now: now)
    }
}

private actor ClaudeActivityCache {
    private let root: URL
    private var previous: ActivityCollection?
    private var files: [String: CachedFile] = [:]
    private let fileLimit = 40
    private let enumerationLimit = 25_000
    private let byteLimit = 2 * 1_024 * 1_024

    private struct CachedFile {
        var signature: String
        var session: ActivitySession?
    }

    init(root: URL) { self.root = root }

    func collect(now: Date) -> ActivityCollection {
        if let previous, (0..<60).contains(now.timeIntervalSince(previous.health.checkedAt)) {
            return previous
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            return save(ActivityCollection(sessions: [], health: ActivitySourceHealth(
                id: "claude.activity", status: "unavailable", checkedAt: now,
                message: "No local Claude project transcripts found. Connection state is unknown.")))
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]
        var enumerationError = false
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in
                enumerationError = true; return true
            }) else {
            return save(ActivityCollection(sessions: [], health: ActivitySourceHealth(
                id: "claude.activity", status: "unavailable", checkedAt: now,
                message: "Local Claude transcripts could not be enumerated.")))
        }
        let cutoff = now.addingTimeInterval(-14 * 86_400)
        var candidates: [(url: URL, modified: Date, signature: String)] = []
        var visited = 0
        var enumerationBound = false
        for case let url as URL in enumerator {
            visited += 1
            if visited > enumerationLimit { enumerationBound = true; break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                enumerationError = true; continue
            }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl",
                  url.lastPathComponent != "journal.jsonl",
                  let modified = values.contentModificationDate, modified >= cutoff else { continue }
            let signature = "\(modified.timeIntervalSince1970):\(values.fileSize ?? -1):\(String(describing: values.fileResourceIdentifier))"
            candidates.append((url, modified, signature))
        }
        candidates.sort { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }
        let selected = Array(candidates.prefix(fileLimit))
        var sessions: [String: ActivitySession] = [:]
        var nextFiles: [String: CachedFile] = [:]
        var failed = 0
        for candidate in selected {
            let cached: CachedFile
            if let old = files[candidate.url.path], old.signature == candidate.signature {
                cached = old
            } else {
                do {
                    cached = CachedFile(signature: candidate.signature,
                        session: try ClaudeActivityParser.read(candidate.url, byteLimit: byteLimit,
                            fallbackDate: candidate.modified, observedAt: now))
                } catch { failed += 1; continue }
            }
            nextFiles[candidate.url.path] = cached
            if var session = cached.session {
                session.observedAt = now
                // Copied transcripts sometimes retain native identity. Keep one view.
                if sessions[session.id].map({ $0.updatedAt <= session.updatedAt }) ?? true {
                    sessions[session.id] = session
                }
            }
        }
        files = nextFiles
        let sorted = sessions.values.sorted { $0.updatedAt > $1.updatedAt }
        let partialFiles = sorted.filter { !$0.historyComplete }.count
        var coverage = "Local transcript metadata only: \(selected.count) recent files, modified within 14 days; refreshes at most once per minute. Live runtime state and human prompt origin may be unknown."
        if candidates.count > fileLimit { coverage += " Limited to the newest \(fileLimit) files." }
        if partialFiles > 0 { coverage += " \(partialFiles) sessions have partial history; measurements are lower bounds." }
        if failed > 0 || enumerationError { coverage += " Some files could not be read." }
        if enumerationBound { coverage += " Directory discovery reached its safety bound." }
        return save(ActivityCollection(sessions: sorted, health: ActivitySourceHealth(
            id: "claude.activity", status: sorted.isEmpty ? "unavailable" : "partial",
            checkedAt: now, lastSuccessAt: sorted.isEmpty ? previous?.health.lastSuccessAt : now,
            message: coverage)))
    }

    private func save(_ collection: ActivityCollection) -> ActivityCollection {
        previous = collection
        return collection
    }
}

private struct ClaudeActivityParser {
    private struct Request {
        var turn: ActivityTurn
        var tools: [String: (category: String, artifact: ActivityArtifact?)] = [:]
        var skills: [String: ActivitySkillUse] = [:]
    }

    static func read(_ url: URL, byteLimit: Int, fallbackDate: Date, observedAt: Date) throws -> ActivitySession? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let truncated = length > UInt64(byteLimit)
        try handle.seek(toOffset: 0)
        var segments: [(data: Data, metadataOnly: Bool)] = []
        if truncated {
            // Preserve initial identity/cwd metadata, and the instruction files
            // and skill list recorded at the start, as well as the recent tail.
            let head = try handle.read(upToCount: 524_288) ?? Data()
            if let newline = head.lastIndex(of: 10) { segments.append((Data(head.prefix(through: newline)), true)) }
            try handle.seek(toOffset: length - UInt64(byteLimit))
            let tail = try handle.read(upToCount: byteLimit) ?? Data()
            if let newline = tail.firstIndex(of: 10) { segments.append((Data(tail.suffix(from: tail.index(after: newline))), false)) }
        } else { segments.append((try handle.read(upToCount: byteLimit) ?? Data(), false)) }

        var nativeID: String?
        var project: String?
        var title: String?
        var earliest: Date?
        var latest: Date?
        var requests: [String: Request] = [:]
        var promptIDs: Set<String> = []
        var pendingPrompts = 0
        var pendingHumans: Int?
        var pendingTimestamp: Date?
        // Skill tool calls by tool ID, so the injected skill text that follows
        // can report its size. Slash-invoked skills wait for their response.
        var skillOwners: [String: String] = [:]
        var pendingSkills: [ActivitySkillUse] = []
        // What the session started with: sizes and paths, never contents.
        var startContext = ActivityStartContext()
        var sawStart = false
        var clientVersion: String?
        var malformed = false
        var unknownTimestamp = false
        var unknownIdentity = false
        var hasTranscript = false
        let components = url.pathComponents
        let subagentIndex = components.firstIndex(of: "subagents")
        let parentFromPath = subagentIndex.flatMap { $0 > 0 ? components[$0 - 1] : nil }
        let agentFromPath = url.deletingPathExtension().lastPathComponent
        let child = subagentIndex != nil || agentFromPath.hasPrefix("agent-")
        var explicitParent: String?

        for segment in segments {
            for line in segment.data.split(separator: 10, omittingEmptySubsequences: true) {
                guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    malformed = true; continue
                }
                let message = root["message"] as? [String: Any] ?? root
                let type = string(root["type"]) ?? string(message["role"])
                let timestamp = date(root["timestamp"]) ?? date(root["created_at"])
                if let timestamp {
                    earliest = min(earliest ?? timestamp, timestamp)
                    latest = max(latest ?? timestamp, timestamp)
                }
                nativeID = string(root["sessionId"]) ?? string(root["session_id"]) ?? nativeID
                // A session belongs to the folder it started in; later lines
                // follow the shell as it moves into subfolders.
                project = project ?? path(root["cwd"])
                explicitParent = string(root["parentSessionId"]) ?? string(root["parent_session_id"]) ?? explicitParent
                if type == "summary", let summary = string(root["summary"]) {
                    title = TraceRedactor.redact(summary, maximumCharacters: 120)
                }
                if let custom = string(root["customTitle"]) ?? string(root["custom_title"]) {
                    title = TraceRedactor.redact(custom, maximumCharacters: 120)
                }
                if let version = string(root["version"]), version.count <= 40 { clientVersion = version }
                // Start-of-session records sit in the head; later ones mean a file changed.
                if type == "attachment", let attachment = root["attachment"] as? [String: Any] {
                    if record(attachment, timestamp: timestamp, into: &startContext) { sawStart = true }
                    continue
                }

                // Never attach an old head prompt to a tail response across a gap.
                if segment.metadataOnly { continue }

                if type == "user" || string(message["role"]) == "user" {
                    hasTranscript = true
                    if let loaded = skillText(message) {
                        // Only the folder and the text's length are kept.
                        let directory = path(loaded.directory).map { TraceRedactor.redact($0, maximumCharacters: 1_024) }
                        if let toolID = string(root["sourceToolUseID"]), let owner = skillOwners[toolID],
                           var request = requests[owner], var use = request.skills[toolID] {
                            use.path = directory ?? use.path
                            use.loadedCharacters = loaded.characters
                            request.skills[toolID] = use
                            request.turn.skills = request.skills.values.sorted { $0.id < $1.id }
                            requests[owner] = request
                        } else if let directory, let name = SkillReference.name(forSkillDirectory: loaded.directory) {
                            let id = string(root["uuid"]) ?? TraceCrypto.digest(Data(line))
                            pendingSkills.append(ActivitySkillUse(id: "claude-skill:\(id)", name: name, trigger: .command,
                                path: directory, timestamp: timestamp, loadedCharacters: loaded.characters))
                        }
                        continue
                    }
                    guard isPrompt(root: root, message: message) else { continue }
                    let key = string(root["uuid"]) ?? string(root["promptId"]) ?? TraceCrypto.digest(Data(line))
                    guard promptIDs.insert(key).inserted else { continue }
                    pendingPrompts += 1
                    pendingTimestamp = pendingTimestamp ?? timestamp
                    if string(root["source"]) == "human" || string(root["userType"]) == "human" {
                        pendingHumans = (pendingHumans ?? 0) + 1
                    }
                    continue
                }
                guard type == "assistant" || string(message["role"]) == "assistant" else { continue }
                hasTranscript = true
                let model = string(message["model"]) ?? string(root["model"])
                guard model != "<synthetic>", model != "synthetic" else { continue }
                let requestID = string(root["requestId"]) ?? string(root["request_id"])
                    ?? string(message["id"]) ?? string(root["uuid"])
                guard let requestID else { unknownIdentity = true; continue }
                if timestamp == nil { unknownTimestamp = true }
                var request = requests[requestID] ?? Request(turn: ActivityTurn(
                    id: "claude-request:\(requestID)", startedAt: timestamp, status: "observed",
                    promptCount: 0, model: model))
                if requests[requestID] == nil, pendingPrompts > 0 {
                    request.turn.promptCount = pendingPrompts
                    request.turn.humanPromptCount = pendingHumans
                    pendingPrompts = 0; pendingHumans = nil; pendingTimestamp = nil
                }
                if requests[requestID] == nil, !pendingSkills.isEmpty {
                    for use in pendingSkills { request.skills[use.id] = use }
                    pendingSkills = []
                }
                request.turn.model = model ?? request.turn.model
                request.turn.effort = string(root["effort"]) ?? string(message["effort"]) ?? request.turn.effort
                if let usage = message["usage"] as? [String: Any] ?? root["usage"] as? [String: Any] {
                    request.turn.usage = mergeUsage(usage, previous: request.turn.usage)
                }
                // A response snapshot's timestamp is an observation, not a start/end pair.
                if let milliseconds = number(root["duration_ms"]) ?? number(message["duration_ms"]), milliseconds >= 0,
                   let timestamp, milliseconds / 1_000 <= timestamp.timeIntervalSince1970 {
                    request.turn.durationSeconds = milliseconds / 1_000
                    request.turn.completedAt = timestamp
                    request.turn.startedAt = timestamp.addingTimeInterval(-milliseconds / 1_000)
                }
                if let reason = string(message["stop_reason"]), reason == "end_turn" || reason == "stop_sequence" {
                    request.turn.status = "completed"
                }
                let blocks = message["content"] as? [[String: Any]] ?? []
                for (index, block) in blocks.enumerated() where string(block["type"]) == "tool_use" {
                    guard let name = string(block["name"]) else { continue }
                    let toolID = string(block["id"]) ?? "\(string(message["id"]) ?? requestID):\(index):\(name)"
                    request.tools[toolID] = (category(name), artifact(block, name: name, project: project, id: toolID))
                    // Streamed snapshots repeat blocks; keep the size learned since.
                    if request.skills[toolID] == nil, let use = skillUse(block, name: name, id: toolID, timestamp: timestamp) {
                        request.skills[toolID] = use
                        if use.trigger == .tool { skillOwners[toolID] = requestID }
                    }
                }
                if message["content"] != nil || !request.tools.isEmpty { request.turn.toolCount = request.tools.count }
                request.turn.categories = request.tools.values.reduce(into: [:]) { $0[$1.category, default: 0] += 1 }
                request.turn.artifacts = request.tools.values.compactMap(\.artifact).sorted { $0.id < $1.id }
                // Content-bearing responses establish a measured list, even empty.
                if message["content"] != nil || !request.skills.isEmpty {
                    request.turn.skills = request.skills.values.sorted { $0.id < $1.id }
                }
                requests[requestID] = request
            }
        }
        guard hasTranscript else { return nil }
        let parent = explicitParent ?? (child ? (parentFromPath ?? nativeID) : nil)
        let identity = child ? "\(parent ?? "unknown")/\(agentFromPath)" : (nativeID ?? agentFromPath)
        let sessionID = "claude:\(identity)"
        var turns = requests.values.map(\.turn)
        if pendingPrompts > 0 {
            turns.append(ActivityTurn(id: "\(sessionID):pending-prompts", startedAt: pendingTimestamp,
                status: "submission_observed", promptCount: pendingPrompts, humanPromptCount: pendingHumans,
                skills: pendingSkills.isEmpty ? nil : pendingSkills))
        }
        turns.sort { ($0.startedAt ?? .distantPast, $0.id) < ($1.startedAt ?? .distantPast, $1.id) }
        let turnBound = turns.count > 2_000
        if turnBound { turns = Array(turns.suffix(2_000)) }
        // Namespace even provider request IDs to prevent parent/child collisions.
        turns = turns.map { var turn = $0; turn.id = "\(sessionID):\(turn.id)"; return turn }
        // Versions that record instruction files leave no record when there
        // are none, but only a whole transcript shows that. Sub-agents
        // inherit theirs without a record of their own.
        startContext.instructionsRecorded = startContext.instructionsRecorded
            || (!child && !truncated && InstructionReference.claudeRecordsInstructions(clientVersion))
        startContext.clientVersion = clientVersion
        var warnings = ["Local transcript observations do not establish whether Claude is currently running. Human origin is unknown unless explicitly recorded."]
        if truncated { warnings.append("Large transcript: initial metadata and the latest 2 MiB only. Counts are lower bounds.") }
        if turnBound { warnings.append("Only the latest 2,000 observed requests are retained.") }
        if malformed { warnings.append("Incomplete or unrecognized JSON lines were skipped; refresh will retry changed files.") }
        if unknownTimestamp || unknownIdentity { warnings.append("Some request timestamps or identities were unavailable.") }
        let fallbackTitle = "\(project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude") · \(identity.suffix(8))"
        return ActivitySession(id: sessionID, provider: .claude, nativeID: identity,
            title: title ?? fallbackTitle, projectPath: project,
            createdAt: earliest ?? fallbackDate, updatedAt: latest ?? fallbackDate, observedAt: observedAt,
            runtimeState: "unknown", parentSessionID: parent.map { "claude:\($0)" },
            models: Array(Set(turns.compactMap(\.model))).sorted(),
            efforts: Array(Set(turns.compactMap(\.effort))).sorted(), turns: turns,
            historyComplete: !truncated && !turnBound && !malformed && !unknownIdentity && !unknownTimestamp,
            source: "claude-local-transcript/1", warnings: warnings,
            startContext: sawStart || clientVersion != nil ? startContext : nil)
    }

    /// Claude Code records the instruction files it loaded (path, kind and
    /// text) and the skill list it showed. Only lengths and paths are kept.
    private static func record(_ attachment: [String: Any], timestamp: Date?, into context: inout ActivityStartContext) -> Bool {
        switch string(attachment["type"]) {
        case "instructions":
            let loads = (attachment["files"] as? [[String: Any]] ?? []).compactMap { file -> ActivityInstructionLoad? in
                guard let raw = path(file["path"]) else { return nil }
                let characters = (file["content"] as? String)?.count ?? 0
                return ActivityInstructionLoad(path: TraceRedactor.redact(raw, maximumCharacters: 1_024),
                                               kind: InstructionReference.claudeKind(string(file["type"])), characters: characters,
                                               parent: path(file["parent"]).map { TraceRedactor.redact($0, maximumCharacters: 1_024) },
                                               firstSeen: timestamp, lastSeen: timestamp)
            }
            context = context.merging(ActivityStartContext(instructions: loads, instructionsRecorded: true))
            return true
        case "skill_listing":
            guard attachment["isInitial"] as? Bool == true, context.skillListCharacters == nil else { return false }
            context.skillListCharacters = (attachment["content"] as? String)?.count
            context.skillListCount = integer(attachment["skillCount"])
            return true
        default:
            return false
        }
    }

    /// Claude Code injects a loaded skill as a meta user message that starts
    /// with its folder. Returns that folder and the text's size, nothing else.
    private static func skillText(_ message: [String: Any]) -> (directory: String, characters: Int)? {
        let prefix = "Base directory for this skill: "
        let text: String?
        if let content = message["content"] as? String { text = content }
        else { text = (message["content"] as? [[String: Any]])?.first { string($0["type"]) == "text" }.flatMap { $0["text"] as? String } }
        guard let text, text.hasPrefix(prefix) else { return nil }
        let line = text.dropFirst(prefix.count).prefix { $0 != "\n" }
        return (String(line).trimmingCharacters(in: .whitespaces), text.count)
    }

    /// The Skill tool names the skill it loads; a write to a SKILL.md edits one.
    private static func skillUse(_ block: [String: Any], name: String, id: String, timestamp: Date?) -> ActivitySkillUse? {
        let input = block["input"] as? [String: Any]
        if name == "Skill" {
            guard let skill = string(input?["skill"]) ?? string(input?["command"]), let clean = SkillReference.sanitizedName(skill) else { return nil }
            return ActivitySkillUse(id: id, name: clean, trigger: .tool, timestamp: timestamp)
        }
        guard ["write", "edit", "multiedit"].contains(name.lowercased()), let file = path(input?["file_path"]),
              let skill = SkillReference.name(forSkillFile: file) else { return nil }
        return ActivitySkillUse(id: id, name: skill, trigger: .edit, path: TraceRedactor.redact(file, maximumCharacters: 1_024), timestamp: timestamp)
    }

    private static func isPrompt(root: [String: Any], message: [String: Any]) -> Bool {
        guard root["isMeta"] as? Bool != true, root["toolUseResult"] == nil,
              root["sourceToolAssistantUUID"] == nil else { return false }
        if let content = message["content"] as? String { return !content.isEmpty }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        guard !blocks.contains(where: { string($0["type"]) == "tool_result" }) else { return false }
        return blocks.contains { ["text", "image", "document"].contains(string($0["type"]) ?? "") }
    }

    private static func mergeUsage(_ value: [String: Any], previous: TokenUsage) -> TokenUsage {
        var usage = previous
        usage.input = integer(value["input_tokens"]) ?? usage.input
        usage.output = integer(value["output_tokens"]) ?? usage.output
        usage.cachedInput = integer(value["cache_read_input_tokens"]) ?? usage.cachedInput
        let creation = value["cache_creation"] as? [String: Any]
        let components = [integer(creation?["ephemeral_5m_input_tokens"]), integer(creation?["ephemeral_1h_input_tokens"])]
        usage.cacheWriteInput = integer(value["cache_creation_input_tokens"])
            ?? sum(components)
            ?? usage.cacheWriteInput
        usage.reasoning = integer(value["reasoning_tokens"]) ?? integer(value["reasoning_output_tokens"]) ?? usage.reasoning
        if let total = integer(value["total_tokens"]) {
            usage.total = total
            usage.provenance = .providerReported
        }
        else if let input = usage.input, let output = usage.output,
                let cache = usage.cachedInput, let write = usage.cacheWriteInput {
            // Claude reports cache separately; reasoning is an output subset.
            usage.total = sum([input, output, cache, write])
            usage.provenance = .derived
        }
        else if usage.total == nil && [usage.input, usage.output, usage.cachedInput, usage.cacheWriteInput, usage.reasoning].contains(where: { $0 != nil }) {
            usage.provenance = .providerReported
        }
        return usage
    }

    private static func category(_ name: String) -> String {
        switch name.lowercased() {
        case "read", "glob", "grep", "ls": return "inspection"
        case "write", "edit", "multiedit", "notebookedit": return "implementation"
        case "bash", "bashoutput": return "execution"
        case "websearch", "webfetch": return "research"
        case "task", "agent": return "delegation"
        default: return "other"
        }
    }

    private static func artifact(_ block: [String: Any], name: String, project: String?, id: String) -> ActivityArtifact? {
        guard ["write", "edit", "multiedit", "notebookedit"].contains(name.lowercased()),
              let input = block["input"] as? [String: Any],
              let raw = path(input["file_path"]) ?? path(input["notebook_path"]), let project else { return nil }
        let projectURL = URL(fileURLWithPath: project).standardizedFileURL
        let fileURL = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : projectURL.appendingPathComponent(raw)).standardizedFileURL
        let prefix = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
        guard fileURL.path.hasPrefix(prefix) else { return nil }
        let relative = String(fileURL.path.dropFirst(prefix.count))
        let sensitive = [".env", ".ssh", ".aws", ".gnupg", "credentials", "credentials.json", "auth.json", "id_rsa", "id_ed25519"]
        guard !relative.split(separator: "/").contains(where: { component in
            sensitive.contains(String(component).lowercased()) || component.lowercased().hasPrefix(".env.")
        }) else { return nil }
        return ActivityArtifact(id: "claude-tool:\(id)", path: relative, status: "edit_requested")
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
    private static func path(_ value: Any?) -> String? {
        guard let value = string(value), value.count <= 2_048,
              value.rangeOfCharacter(from: .controlCharacters) == nil, !value.contains("://") else { return nil }
        return value
    }
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite { return value.doubleValue }
        if let value = value as? String, let number = Double(value), number.isFinite { return number }
        return nil
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number >= 0, number < Double(Int.max), number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }
    private static func sum(_ values: [Int?]) -> Int? {
        var total = 0
        for value in values {
            guard let value else { return nil }
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
    private static func date(_ value: Any?) -> Date? {
        guard let value = string(value) else { return nil }
        guard let date = ISO8601.date(value),
              (0...253_402_300_799.0).contains(date.timeIntervalSince1970) else { return nil }
        return date
    }
}
