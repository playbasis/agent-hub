import Foundation
import CoreFoundation
import Darwin

/// On-demand inspection, separate from the metadata accounting database.
/// Visible text is opt-in, bounded and redacted in memory; hidden reasoning
/// is never returned. No read resumes a thread or starts a provider turn.
public struct WorkEvidenceItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case request, response, toolCall, toolResult, fileChange, plan, handoff, notice }
    public var id: String
    public var nativeID: String?
    public var kind: Kind
    public var title: String
    public var status: String
    public var timestamp: Date?
    public var relatedID: String?
    public var exitCode: Int?
    public var durationSeconds: Double?
    public var preview: String?
    public var digest: String?
    public var relatedSessionIDs: [String] = []
}

public struct WorkEvidenceBatch: Sendable {
    public var items: [WorkEvidenceItem]
    public var isPartial: Bool
    public var message: String
    public var adapterVersion: String
    public var nextCursor: String? = nil
}

public enum WorkEvidencePrivacy {
    /// Best-effort display protection, not a guarantee that arbitrary project
    /// text is safe to share. Callers must not persist or export previews.
    public static func preview(_ value: Any, maximumCharacters: Int = 4_000) -> String {
        func clean(_ value: Any, depth: Int = 0) -> Any {
            guard depth < 12 else { return "[Nested payload omitted]" }
            if let object = value as? [String: Any] {
                return object.mapValues { $0 }.reduce(into: [String: Any]()) { output, pair in
                    let key = pair.key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                    if key == "token" || key == "key" || ["password", "secret", "apikey", "authorization", "cookie", "accesstoken", "refreshtoken", "privatekey"].contains(where: key.contains) {
                        output[pair.key] = "[REDACTED]"
                    } else { output[pair.key] = clean(pair.value, depth: depth + 1) }
                }
            }
            if let array = value as? [Any] { return Array(array.prefix(80)).map { clean($0, depth: depth + 1) } }
            return value
        }
        let sanitized = clean(value)
        var text: String
        if let string = sanitized as? String { text = string }
        else if JSONSerialization.isValidJSONObject(sanitized), let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys, .withoutEscapingSlashes]) {
            text = String(decoding: data, as: UTF8.self)
        } else { text = "Text unavailable" }
        for pattern in [#"(?i)--(?:api[-_]?key|token|password|secret)(?:\s+|=)\S+"#,
                        #"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----"#,
                        #"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#] {
            text = text.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return TraceRedactor.redact(text, maximumCharacters: max(0, min(maximumCharacters, 8_000)))
    }
}

public enum WorkEvidenceParser {
    public static let maximumItems = 80

    public static func codex(_ result: [String: Any], includeText: Bool, expectedTurnID: String? = nil) -> WorkEvidenceBatch {
        let records = result["data"] as? [[String: Any]] ?? result["items"] as? [[String: Any]] ?? []
        var items: [WorkEvidenceItem] = [], seen = Set<String>(), unsupported = 0
        var previewBudget = 24_000
        for (index, wrapper) in records.prefix(maximumItems).enumerated() {
            if let expectedTurnID, let returnedTurnID = string(wrapper["turnId"]), returnedTurnID != expectedTurnID { unsupported += 1; continue }
            let raw = wrapper["item"] as? [String: Any] ?? wrapper
            guard let type = string(raw["type"]) else { unsupported += 1; continue }
            // Never even digest or copy hidden analysis/chain-of-thought.
            if ["analysis", "compaction", "contextCompaction"].contains(type) { continue }
            let kind: WorkEvidenceItem.Kind
            let title: String
            var payload: Any?
            switch type {
            case "reasoning":
                // Only the explicitly public provider summary, never content
                // or encrypted/private reasoning fields.
                let summary = raw["summary"] as? [String] ?? []
                guard !summary.isEmpty else { continue }
                kind = .notice; title = "Provider-supplied reasoning summary"; payload = summary.joined(separator: "\n")
            case "userMessage": kind = .request; title = "Request"; payload = visibleText(raw["content"])
            case "agentMessage":
                if string(raw["phase"]) == "analysis" { continue }
                kind = .response; title = "Agent response"; payload = raw["text"]
            case "commandExecution": kind = .toolCall; title = "Command"; payload = ["command": raw["command"] ?? NSNull(), "output": raw["aggregatedOutput"] ?? NSNull()]
            case "mcpToolCall", "dynamicToolCall": kind = .toolCall; title = string(raw["tool"]) ?? string(raw["toolName"]) ?? "Tool call"; payload = ["arguments": raw["arguments"] ?? NSNull(), "result": raw["result"] ?? NSNull(), "error": raw["error"] ?? NSNull()]
            case "fileChange": kind = .fileChange; title = "File change"; payload = raw["changes"]
            case "functionCallOutput": kind = .toolResult; title = string(raw["name"]) ?? "Tool result"; payload = raw["output"]
            case "plan": kind = .plan; title = "Recorded plan"; payload = raw["text"] ?? raw["plan"]
            case "collabAgentToolCall": kind = .handoff; title = "Agent handoff"; payload = ["tool": raw["tool"] ?? NSNull(), "receiverThreadIds": raw["receiverThreadIds"] ?? NSNull(), "status": raw["status"] ?? NSNull()]
            case "webSearch": kind = .toolCall; title = "Web search"; payload = raw["query"]
            case "imageView", "imageGeneration", "sleep": kind = .toolCall; title = type; payload = nil
            default: unsupported += 1; continue
            }
            let nativeID = string(raw["id"]) ?? string(wrapper["id"])
            let rawID = nativeID ?? "missing-id-\(index)"
            if nativeID == nil { unsupported += 1 }
            guard seen.insert(rawID).inserted else { continue }
            var preview: String?
            if includeText, let payload, previewBudget > 0 {
                preview = WorkEvidencePrivacy.preview(payload, maximumCharacters: min(4_000, previewBudget))
                previewBudget -= preview?.count ?? 0
            }
            let digest = payload.flatMap(payloadDigest)
            let exit = integer(raw["exitCode"])
            let duration = (raw["durationMs"] as? NSNumber)?.doubleValue
            let seconds = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 / 1_000 : nil }
            var status = string(raw["status"]) ?? (exit.map { $0 == 0 ? "completed" : "failed" } ?? "not recorded")
            if kind == .toolCall || kind == .toolResult {
                // Codex's 'completed' means the item ended. A nonzero shell
                // exit or explicit MCP error remains an execution failure.
                if let exit, status.lowercased() == "completed" { status = exit == 0 ? "completed" : "failed" }
                let result = raw["result"] as? [String: Any]
                let error = raw["error"]
                let hasError = (error as? [String: Any]).map { !$0.isEmpty } == true
                    || (error as? String).map { !$0.isEmpty } == true
                    || (error as? Bool) == true
                if hasError || raw["isError"] as? Bool == true || result?["isError"] as? Bool == true || result?["is_error"] as? Bool == true {
                    status = "failed"
                }
            }
            let receivers = (raw["receiverThreadIds"] as? [String] ?? []).filter { !$0.isEmpty && $0.utf8.count <= 4_096 }
            items.append(.init(id: "codex:item:" + rawID, nativeID: nativeID, kind: kind,
                title: WorkEvidencePrivacy.preview(title, maximumCharacters: 100), status: status,
                timestamp: date(wrapper["startedAtMs"] ?? wrapper["completedAtMs"] ?? wrapper["createdAt"] ?? raw["timestamp"]), relatedID: string(raw["callId"]),
                exitCode: exit, durationSeconds: seconds, preview: preview, digest: digest,
                relatedSessionIDs: Array(Set(receivers.prefix(128))).sorted()))
        }
        let partial = result["nextCursor"] is String || result["next_cursor"] is String || records.count > maximumItems || unsupported > 0
        return .init(items: items, isPartial: partial,
            message: items.isEmpty ? "No supported visible items in this page. Empty history does not prove no work." :
                "Persisted native items, not inferred stages. \(partial ? "This is a partial page; some detail is unavailable." : "This page has no continuation cursor.") Hidden reasoning is excluded.",
            adapterVersion: "codex-items/2", nextCursor: result["nextCursor"] as? String ?? result["next_cursor"] as? String)
    }

    /// Bounded local Claude records. A tool result is attached only through
    /// its explicit tool_use_id; requests only through parentUuid, never time.
    public static func claude(_ lines: [Data], nativeTurnID: String, includeText: Bool, truncated: Bool) -> WorkEvidenceBatch {
        let target = nativeTurnID.hasPrefix("claude-request:") ? String(nativeTurnID.dropFirst("claude-request:".count)) : nativeTurnID
        var malformed = lines.count > 20_000
        let records = lines.prefix(20_000).compactMap { line -> [String: Any]? in
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { malformed = true; return nil }
            return value
        }
        var byUUID: [String: [String: Any]] = [:]
        for root in records { if let uuid = string(root["uuid"]) { byUUID[uuid] = root } }
        var items: [WorkEvidenceItem] = [], toolIDs = Set<String>(), seen = Set<String>(), budget = 24_000
        func add(_ id: String, kind: WorkEvidenceItem.Kind, title: String, status: String, root: [String: Any], related: String? = nil, payload: Any? = nil) {
            guard items.count < maximumItems, seen.insert(id).inserted else { return }
            let preview = includeText && payload != nil && budget > 0 ? WorkEvidencePrivacy.preview(payload!, maximumCharacters: min(4_000, budget)) : nil
            budget -= preview?.count ?? 0
            let digest = payload.flatMap(payloadDigest)
            items.append(.init(id: "claude:item:" + id, nativeID: id, kind: kind, title: WorkEvidencePrivacy.preview(title, maximumCharacters: 100), status: status,
                timestamp: date(root["timestamp"]), relatedID: related, exitCode: nil, durationSeconds: nil, preview: preview, digest: digest))
        }
        for root in records {
            let message = root["message"] as? [String: Any] ?? root
            guard string(root["type"]) == "assistant" || string(message["role"]) == "assistant" else { continue }
            let identity = string(root["requestId"]) ?? string(root["request_id"]) ?? string(message["id"]) ?? string(root["uuid"])
            guard identity == target else { continue }
            if let parent = string(root["parentUuid"]), let request = byUUID[parent] {
                let m = request["message"] as? [String: Any] ?? request
                if string(request["type"]) == "user", let text = visibleText(m["content"]), !text.isEmpty {
                    add(parent, kind: .request, title: "Linked request", status: "recorded", root: request, payload: text)
                }
            }
            let messageID = string(message["id"]) ?? string(root["uuid"]) ?? target
            for (index, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                switch string(block["type"]) {
                case "text": add(messageID + ":text:\(index)", kind: .response, title: "Agent response", status: string(message["stop_reason"]) ?? "recorded", root: root, payload: block["text"])
                case "tool_use":
                    guard let id = string(block["id"]), let name = string(block["name"]) else { continue }
                    toolIDs.insert(id)
                    add(id, kind: .toolCall, title: name, status: "result not recorded", root: root, payload: block["input"])
                default: continue
                }
            }
        }
        for root in records {
            let message = root["message"] as? [String: Any] ?? root
            for block in message["content"] as? [[String: Any]] ?? [] where string(block["type"]) == "tool_result" {
                guard let id = string(block["tool_use_id"]), toolIDs.contains(id) else { continue }
                let status = block["is_error"] as? Bool == true ? "failed" : "completed"
                if let index = items.firstIndex(where: { $0.nativeID == id && $0.kind == .toolCall }) { items[index].status = status }
                add(id + ":result", kind: .toolResult, title: "Tool result", status: status, root: root, related: id, payload: block["content"])
            }
        }
        let chronological = items.enumerated().sorted { left, right in
            switch (left.element.timestamp, right.element.timestamp) {
            case let (a?, b?): return a == b ? left.offset < right.offset : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
        return .init(items: chronological, isPartial: truncated || malformed || items.count >= maximumItems,
            message: "Known local transcript window; tool links use explicit IDs. \(truncated ? "Older records may be outside the bounded window." : "") Hidden reasoning is excluded.", adapterVersion: "claude-items/1")
    }

    private static func visibleText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        return blocks.filter { ["text", "inputText", "input_text", "output_text"].contains(string($0["type"]) ?? "") }.compactMap { string($0["text"]) }.joined(separator: "\n")
    }
    private static func payloadDigest(_ value: Any) -> String? {
        if let text = value as? String { return TraceCrypto.digest(text) }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])).map(TraceCrypto.digest)
    }
    private static func string(_ value: Any?) -> String? { guard let text = value as? String, !text.isEmpty else { return nil }; return text }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= Double(Int.min), double < Double(Int.max), double.rounded(.towardZero) == double else { return nil }
        return number.intValue
    }
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return ISO8601.date(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, abs(raw) < 253_402_300_800_000 else { return nil }
        return Date(timeIntervalSince1970: abs(raw) > 10_000_000_000 ? raw / 1_000 : raw)
    }
}

public enum WorkEvidenceReader {
    /// Collector request IDs are scoped as `<session.id>:claude-request:<id>`.
    /// Remove only this exact session prefix; never guess from a suffix or
    /// allow one session's saved turn to resolve another session's record.
    static func claudeRequestID(sessionID: String, turnID: String) -> String? {
        let prefix = sessionID + ":"
        let local = turnID.hasPrefix(prefix) ? String(turnID.dropFirst(prefix.count)) : turnID
        let value = local.hasPrefix("claude-request:") ? String(local.dropFirst("claude-request:".count)) : local
        guard !value.isEmpty, value.utf8.count <= 200,
              value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    public static func read(session: ActivitySession, turn: ActivityTurn, configuration: AgentConfiguration, includeText: Bool, cursor: String? = nil) async throws -> WorkEvidenceBatch {
        guard session.turns.contains(where: { $0.id == turn.id }) else { throw BridgeError.invalidRequest("Choose a saved turn from this session.") }
        if session.provider == .codex {
            let prefix = "codex:turn:"
            guard turn.id.hasPrefix(prefix), turn.id.count > prefix.count else { throw BridgeError.invalidRequest("Native turn ID unavailable; no history was guessed.") }
            let directory = BridgePaths.providerProbeDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let connection = try await CodexAppServerSession(executable: CodexActivityCollector.reportingExecutable(configuration.codexCommand), currentDirectory: directory,
                clientName: "bridge-evidence-reader", clientVersion: "evidence/1")
            defer { connection.close() }
            guard cursor.map({ $0.utf8.count <= 8_192 }) ?? true else { throw BridgeError.invalidRequest("The native history cursor exceeded its safe limit.") }
            var params: [String: Any] = ["threadId": session.nativeID, "turnId": String(turn.id.dropFirst(prefix.count)), "limit": 40, "sortDirection": "desc"]
            if let cursor { params["cursor"] = cursor }
            let result = try await connection.request("thread/items/list", params: params, timeoutSeconds: 12)
            var batch = WorkEvidenceParser.codex(result, includeText: includeText, expectedTurnID: String(turn.id.dropFirst(prefix.count)))
            // Show one bounded latest/earlier page in chronological order.
            batch.items.reverse()
            return batch
        }
        if session.provider == .claude {
            guard let requestID = claudeRequestID(sessionID: session.id, turnID: turn.id) else {
                throw BridgeError.invalidRequest("This Claude turn has no safely resolvable request identity.")
            }
            return try await Task.detached(priority: .utility) {
                let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
                let parts = session.nativeID.split(separator: "/").map(String.init)
                guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.count < 160 && $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }) else {
                    throw BridgeError.invalidRequest("This native transcript identity cannot be resolved safely.")
                }
                let folders = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).prefix(500)
                for folder in folders {
                    let candidate = parts.count == 1 ? folder.appendingPathComponent(parts[0] + ".jsonl") : folder.appendingPathComponent(parts[0]).appendingPathComponent("subagents").appendingPathComponent(parts[1] + ".jsonl")
                    let path = candidate.resolvingSymlinksInPath()
                    guard path.path.hasPrefix(base.resolvingSymlinksInPath().path + "/"), FileManager.default.fileExists(atPath: path.path) else { continue }
                    let (data, truncated) = try readBoundedRegularFile(path)
                    var lines: [Data] = Array(data).split(separator: UInt8(10)).map { Data($0) }
                    if truncated && !lines.isEmpty { lines.removeFirst() }
                    return WorkEvidenceParser.claude(lines, nativeTurnID: requestID, includeText: includeText, truncated: truncated)
                }
                return WorkEvidenceBatch(items: [], isPartial: true, message: "Known transcript not found within the bounded local search. No file outside Claude's transcript directory was opened.", adapterVersion: "claude-items/1")
            }.value
        }
        return .init(items: [], isPartial: true, message: "Detailed local history is not connected for this provider. Metadata above remains available.", adapterVersion: "unavailable/1")
    }

    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int = 2 * 1_024 * 1_024) throws -> (Data, Bool) {
        var named = stat()
        guard maximumBytes > 0, maximumBytes <= 2 * 1_024 * 1_024,
              lstat(url.path, &named) == 0, named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), named.st_uid == geteuid() else {
            throw BridgeError.invalidRequest("The native evidence path is not an owned regular file.")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeError.invalidRequest("The native evidence file could not be opened safely.") }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), opened.st_uid == geteuid(),
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino, opened.st_size >= 0 else {
            close(fd); throw BridgeError.invalidRequest("The native evidence file changed during validation.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let count = UInt64(opened.st_size), maximum = UInt64(maximumBytes)
        try handle.seek(toOffset: count > maximum ? count - maximum : 0)
        return (try handle.read(upToCount: maximumBytes) ?? Data(), count > maximum)
    }
}
