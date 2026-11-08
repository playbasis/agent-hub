import Foundation

/// Passive, incremental usage checkpoints from an already-known native rollout.
/// Only context, lifecycle and token counters survive parsing. Messages, tool
/// bodies and hidden reasoning are neither retained nor returned.
enum CodexModelStepReader {
    struct Turn {
        var modelSteps: [ActivityModelStep] = []
        var modelStepsComplete = false
        var model: String?
        var effort: String?
        var startedAt: Date?
        var completedAt: Date?
        var status = "unknown"
        /// Skill loads and edits recorded in this turn (names and paths only).
        var skills: [ActivitySkillUse] = []
    }

    struct Result {
        var turns: [String: Turn] = [:]
        var warnings: [String] = []
        var finished = false
        var hitBudget = false
        var hitDeadline = false
        var hitLimit = false
        /// Progress through this file; includes a bounded pending line.
        var readOffset: UInt64 = 0
        var bytesRead: UInt64 = 0
    }

    static func read(path: String?, deadline: Date, maximumBytes: UInt64 = 128 * 1_024 * 1_024, priority: Bool = false) -> Result {
        cache.read(path: path, deadline: deadline, maximumBytes: maximumBytes, priority: priority)
    }

    private static let cache = Store()
    private static let maximumLineBytes = 1_024 * 1_024
    private static let maximumSteps = 50_000
    private static let maximumTurns = 2_048
    private static let relevantMarkers = ["\"turn_context\"", "\"task_started\"", "\"task_complete\"", "\"task_failed\"", "\"turn_aborted\"", "\"token_count\""].map { Data($0.utf8) }
    /// Skill reads are rare; a line is decoded for them only when it names a
    /// SKILL.md and is a completed item. Codex reads skills early in long
    /// sessions, so the whole-history pass is the one that can see them.
    private static let skillMarker = Data("SKILL.md".utf8)
    private static let itemMarker = Data("\"item_completed\"".utf8)
    private static let maximumSkillUses = 20_000

    private struct Checkpoint {
        var usage: TokenUsage
        var total: Int
        var signature: String {
            [usage.input, usage.cachedInput, usage.cacheWriteInput, usage.output, usage.reasoning, usage.total]
                .map { $0.map(String.init) ?? "?" }.joined(separator: ",")
        }
    }

    private struct PrivateTurn {
        var value = Turn()
        var began = false
        var closed = false
        var gaps = false
        var segment = 0
        var replaying = false
        var seenIDs = Set<String>()
        var signatures: [String: Int] = [:]
    }

    private struct State {
        var turns: [String: PrivateTurn] = [:]
        var turnOrder: [String] = []
        var skills: [String: [String: ActivitySkillUse]] = [:]
        var skillCount = 0
        var currentTurn: String?
        var previous: Checkpoint?
        var offset: UInt64 = 0
        var pending = Data()
        var discarding = false
        var discardedRelevant = false
        var discardMarkerTail = Data()
        var warnings = Set<String>()
        var unattributedUsage = false
        var limited = false
        var stepCount = 0
        var stepLimit = CodexModelStepReader.maximumSteps
        var turnLimit = CodexModelStepReader.maximumTurns

        mutating func ensure(_ id: String) {
            guard turns[id] == nil else { return }
            if turns.count >= turnLimit, let oldest = turnOrder.first {
                stepCount -= turns.removeValue(forKey: oldest)?.value.modelSteps.count ?? 0
                skillCount -= skills.removeValue(forKey: oldest)?.count ?? 0
                turnOrder.removeFirst()
                limited = true
                warnings.insert("Older turn metadata reached the reader limit; retained model-step counts are lower bounds.")
            }
            turns[id] = PrivateTurn()
            turnOrder.append(id)
        }

        mutating func gap(_ warning: String) {
            warnings.insert(warning)
            if let id = currentTurn { turns[id]?.gaps = true }
            else { unattributedUsage = true }
        }

        mutating func loseContext(_ warning: String) {
            gap(warning)
            // The skipped record could have started a different native turn.
            // Preserve existing receipts, but do not lend that turn's identity
            // to later updates until another explicit context restores it.
            currentTurn = nil
            unattributedUsage = true
        }

        mutating func consume(_ root: [String: Any]) {
            guard let payload = root["payload"] as? [String: Any], let type = root["type"] as? String else { return }
            let timestamp = CodexActivityParser.date(root["timestamp"])
            if type == "turn_context", let id = nativeID(payload["turn_id"]) {
                ensure(id)
                currentTurn = id
                let model = trimmed(payload["model"])
                if let model {
                    if turns[id]?.value.model != model { turns[id]?.value.effort = nil }
                    turns[id]?.value.model = model
                }
                let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
                if let effort = trimmed(payload["effort"]) ?? trimmed(settings?["reasoning_effort"]) { turns[id]?.value.effort = effort }
                return
            }
            // Compaction changes context, not the usage-counter epoch. Native
            // rollouts repeat the prior cumulative snapshot afterward.
            if type == "compacted" { return }
            guard type == "event_msg", let event = payload["type"] as? String else { return }
            switch event {
            case "task_started":
                guard let id = nativeID(payload["turn_id"]) else { gap("A lifecycle record had no native turn ID."); return }
                ensure(id)
                currentTurn = id
                var turn = turns.removeValue(forKey: id) ?? PrivateTurn()
                if turn.began && !turn.value.modelSteps.isEmpty { turn.replaying = true }
                turn.began = true
                turn.closed = false
                turn.value.status = "running"
                let start = CodexActivityParser.date(payload["started_at"]) ?? timestamp
                turn.value.startedAt = [turn.value.startedAt, start].compactMap { $0 }.min()
                turns[id] = turn
            case "task_complete", "task_failed", "turn_aborted":
                guard let id = nativeID(payload["turn_id"]) ?? currentTurn else { gap("A lifecycle record had no native turn ID."); return }
                ensure(id)
                var turn = turns.removeValue(forKey: id) ?? PrivateTurn()
                turn.closed = true
                turn.value.status = event == "task_complete" ? "completed" : event == "task_failed" ? "failed" : "interrupted"
                turn.value.startedAt = turn.value.startedAt ?? CodexActivityParser.date(payload["started_at"])
                turn.value.completedAt = CodexActivityParser.date(payload["completed_at"]) ?? timestamp
                turns[id] = turn
                if currentTurn == id { currentTurn = nil }
            case "context_compacted":
                break
            case "token_count":
                consumeUsage(payload, timestamp: timestamp)
            default: break
            }
        }

        mutating func consumeSkills(_ root: [String: Any]) {
            guard root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any],
                  let itemID = nativeID(item["id"]), let turn = nativeID(payload["turn_id"]) ?? currentTurn,
                  skillCount < CodexModelStepReader.maximumSkillUses else { return }
            let uses = CodexActivityParser.skillUses(item, itemID: itemID) { CodexActivityParser.date(root["timestamp"]) }
            for use in uses where skills[turn]?[use.id] == nil {
                skills[turn, default: [:]][use.id] = use
                skillCount += 1
            }
        }

        mutating func consumeUsage(_ payload: [String: Any], timestamp: Date?) {
            guard let info = payload["info"] as? [String: Any],
                  let cumulative = info["total_token_usage"] as? [String: Any],
                  let checkpoint = CodexModelStepReader.checkpoint(cumulative) else {
                gap("Some usage checkpoints were malformed; model-step coverage is partial."); return
            }
            let prior = previous
            previous = checkpoint
            let identifiedTurn = nativeID(payload["turn_id"]) ?? currentTurn
            // A quota-only update or a corrected cache split is not a model call.
            // Compaction does not change that rule or establish a zero baseline.
            if let prior, checkpoint.signature == prior.signature { return }
            guard let id = identifiedTurn else {
                if let prior, checkpoint.total > prior.total {
                    unattributedUsage = true
                    warnings.insert("Some usage checkpoints had no native turn context and remain unattributed.")
                }
                return
            }
            ensure(id)
            var turn = turns.removeValue(forKey: id) ?? PrivateTurn()
            defer { turns[id] = turn }
            let signature = checkpoint.signature
            let signatureHash = TraceCrypto.digest(signature)
            if turn.replaying, turn.signatures[signatureHash] != nil { return }
            if let prior, checkpoint.total == prior.total { return }
            let reset = prior.map { checkpoint.total < $0.total } ?? false
            if reset {
                turn.segment += 1
                if turn.signatures[signatureHash] != nil {
                    // A lower previously seen tuple could be a replay or a real
                    // reset. Do not manufacture another request from ambiguity.
                    turn.replaying = true
                    turn.gaps = true
                    warnings.insert("A counter reset overlapped replayed checkpoints; ambiguous updates were not counted twice.")
                    return
                }
                warnings.insert("Native usage counters reset; later advances are tracked in a new counter segment.")
            }
            turn.replaying = false
            guard let last = info["last_token_usage"] as? [String: Any], let usage = CodexModelStepReader.checkpoint(last), usage.total > 0 else {
                if checkpoint.total > (prior?.total ?? 0) { turn.gaps = true }
                return
            }
            if prior == nil && usage.total != checkpoint.total {
                // On opening a rollout the first event may only repeat an old
                // last-usage snapshot. No preceding checkpoint proves that it
                // consumed tokens at this timestamp. Establish the baseline,
                // but wait for a measurable advance before counting a step.
                turn.gaps = true
                warnings.insert("The initial usage baseline was ambiguous; that snapshot was not counted as a new model step.")
                return
            }
            let advance = reset || prior == nil ? checkpoint.total : checkpoint.total - (prior?.total ?? 0)
            guard advance > 0, usage.total <= advance else {
                turn.gaps = true
                warnings.insert("Some usage increments did not reconcile; those model steps were excluded.")
                return
            }
            // Cache/reasoning breakdowns can be corrected in a replay without
            // another request. Counter total, native turn and reset segment
            // own identity; the full tuple above validates/deduplicates data.
            let stepID = "codex:step:\(id):\(turn.segment):\(checkpoint.total)"
            guard turn.seenIDs.insert(stepID).inserted else { return }
            guard stepCount < stepLimit else {
                turn.seenIDs.remove(stepID)
                turn.gaps = true
                limited = true
                warnings.insert("The model-step memory limit was reached; counts are lower bounds.")
                return
            }
            let model = trimmed(info["model"]) ?? trimmed(payload["model"]) ?? turn.value.model
            let effort = trimmed(info["effort"]) ?? trimmed(payload["effort"]) ?? turn.value.effort
            let partial = usage.total != advance || model == nil || timestamp == nil || usage.usage.provenance != .providerReported
            if partial {
                turn.gaps = true
                warnings.insert("Some model steps have incomplete identity, timing or usage coverage.")
            }
            turn.value.modelSteps.append(ActivityModelStep(id: stepID, timestamp: timestamp, model: model, effort: effort,
                                                          usage: usage.usage, usageIsPartial: partial))
            turn.signatures[signatureHash] = turn.segment
            stepCount += 1
        }

        func result(size: UInt64, bytesRead: UInt64, hitBudget: Bool, hitDeadline: Bool) -> Result {
            let finished = offset >= size && pending.isEmpty && !discarding && !hitBudget && !hitDeadline
            var values: [String: Turn] = [:]
            for (id, stored) in turns {
                var value = stored.value
                value.modelStepsComplete = finished && stored.began && stored.closed && !stored.gaps && !unattributedUsage
                    && value.startedAt != nil && value.completedAt != nil && !value.modelSteps.isEmpty
                value.skills = skills[id].map { Array($0.values) } ?? []
                values[id] = value
            }
            for (id, uses) in skills where values[id] == nil {
                var value = Turn()
                value.skills = Array(uses.values)
                values[id] = value
            }
            var messages = warnings
            if !pending.isEmpty { messages.insert("A trailing model-step record is incomplete; the next refresh will continue it.") }
            if hitBudget { messages.insert("Model-step backfill reached its byte budget; the next refresh resumes at the saved offset.") }
            if hitDeadline { messages.insert("Model-step backfill reached its time budget; the next refresh resumes at the saved offset.") }
            return Result(turns: values, warnings: messages.sorted(), finished: finished, hitBudget: hitBudget,
                          hitDeadline: hitDeadline, hitLimit: limited, readOffset: offset, bytesRead: bytesRead)
        }
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(200))
    }

    private static func nativeID(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 512 else { return nil }
        return text
    }

    private static func checkpoint(_ raw: [String: Any]) -> Checkpoint? {
        let usage = CodexActivityTranscript.usage(raw)
        guard let total = usage.total, total >= 0 else { return nil }
        return Checkpoint(usage: usage, total: total)
    }

    private struct Identity {
        var inode: UInt64?
        var device: UInt64?
        var size: UInt64
        var modified: Date
    }

    private struct Entry {
        var identity: Identity
        var state: State
        var boundaryDigest: String?
        var priority = false
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var order: [String] = []
        private let stepLimit: Int
        private let turnLimit: Int
        private let pathLimit: Int

        init(maximumSteps: Int = 50_000, maximumTurns: Int = 2_048, maximumPaths: Int = 8) {
            stepLimit = max(1, min(maximumSteps, CodexModelStepReader.maximumSteps))
            turnLimit = max(1, min(maximumTurns, CodexModelStepReader.maximumTurns))
            pathLimit = max(1, min(maximumPaths, 8))
        }

        private func freshState() -> State {
            var state = State()
            state.stepLimit = stepLimit; state.turnLimit = turnLimit
            return state
        }

        func read(path: String?, deadline: Date, maximumBytes: UInt64 = 128 * 1_024 * 1_024, priority: Bool = false) -> Result {
            lock.lock(); defer { lock.unlock() }
            guard let path, path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension == "jsonl",
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date,
                  let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                return Result(warnings: ["The known native rollout is unavailable; model-step counts remain unknown."])
            }
            defer { try? file.close() }
            let identity = Identity(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                                    device: (attributes[.systemNumber] as? NSNumber)?.uint64Value, size: size, modified: modified)
            var entry = entries.removeValue(forKey: path) ?? Entry(identity: identity, state: freshState())
            order.removeAll { $0 == path }
            let rotated = identity.inode != entry.identity.inode || identity.device != entry.identity.device
                || size < entry.state.offset || size < entry.identity.size
                || (size == entry.identity.size && modified != entry.identity.modified)
            let boundaryChanged = entry.boundaryDigest.map { digest in
                boundary(file, offset: entry.state.offset) != digest
            } ?? false
            if rotated || boundaryChanged { entry = Entry(identity: identity, state: freshState()) }
            var state = entry.state
            var bytesRead: UInt64 = 0
            var hitDeadline = false
            do {
                try file.seek(toOffset: state.offset)
                while state.offset < size && bytesRead < maximumBytes {
                    if Date() >= deadline || Task.isCancelled { hitDeadline = true; break }
                    let count = Int(min(65_536, min(size - state.offset, maximumBytes - bytesRead)))
                    let read: Data? = try autoreleasepool { try file.read(upToCount: count) }
                    guard let chunk = read, !chunk.isEmpty else { break }
                    state.offset += UInt64(chunk.count)
                    bytesRead += UInt64(chunk.count)
                    consume(chunk, state: &state)
                    // Retain at most 50k checkpoints globally, not per path.
                    while state.stepCount + entries.values.reduce(0, { $0 + $1.state.stepCount }) > stepLimit
                            || state.turns.count + entries.values.reduce(0, { $0 + $1.state.turns.count }) > turnLimit {
                        guard let victim = evictionCandidate() else { break }
                        entries.removeValue(forKey: victim); order.removeAll { $0 == victim }
                        state.warnings.insert("Older reader checkpoints were evicted to keep memory bounded; their persisted evidence is unchanged.")
                    }
                }
            } catch {
                state.gap("The rollout could not be fully read; retained model-step counts are partial.")
            }
            let hitBudget = state.offset < size && bytesRead >= maximumBytes
            // Caller intent is refreshed, not sticky. A formerly active goal
            // can become cold; a recent unclosed native turn remains hot even
            // when the caller did not identify it as a goal.
            entry = Entry(identity: identity, state: state, boundaryDigest: boundary(file, offset: state.offset), priority: priority)
            entries[path] = entry
            order.append(path)
            while order.count > pathLimit {
                guard let victim = evictionCandidate() else { break }
                entries.removeValue(forKey: victim); order.removeAll { $0 == victim }
                if victim == path { state.warnings.insert("All reader slots are backfilling earlier files; this file's next refresh may restart its backfill.") }
            }
            return state.result(size: size, bytesRead: bytesRead, hitBudget: hitBudget, hitDeadline: hitDeadline)
        }

        private func evictionCandidate() -> String? {
            func hot(_ entry: Entry) -> Bool {
                if entry.priority { return true }
                let age = Date().timeIntervalSince(entry.identity.modified)
                guard age >= 0, age <= 900, let current = entry.state.currentTurn else { return false }
                return entry.state.turns[current]?.closed == false
            }
            // Retain large priority goals after EOF too. Otherwise a minute's
            // small-file sweep evicts them and forces a full re-scan every time.
            return order.first { path in
                guard let entry = entries[path] else { return true }
                return !hot(entry) && entry.state.offset >= entry.identity.size && entry.state.pending.isEmpty && !entry.state.discarding
            } ?? order.reversed().first { path in
                entries[path].map { !hot($0) } ?? true
            } ?? order.first
        }

        private func boundary(_ file: FileHandle, offset: UInt64) -> String? {
            guard offset > 0 else { return nil }
            do {
                let start = offset > 128 ? offset - 128 : 0
                try file.seek(toOffset: start)
                guard let bytes = try file.read(upToCount: Int(offset - start)) else { return nil }
                return TraceCrypto.digest(bytes)
            } catch { return nil }
        }

        private func consume(_ chunk: Data, state: inout State) {
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                let newline = chunk[cursor...].firstIndex(of: 10)
                let end = newline ?? chunk.endIndex
                let piece = chunk[cursor..<end]
                if state.discarding {
                    var probe = state.discardMarkerTail
                    probe.append(piece)
                    if !state.discardedRelevant, relevantMarkers.contains(where: { probe.range(of: $0) != nil }) {
                        state.loseContext("An oversized relevant record was skipped; model-step coverage is partial.")
                        state.discardedRelevant = true
                    }
                    state.discardMarkerTail = Data(probe.suffix(64))
                    if newline != nil {
                        state.discarding = false; state.discardedRelevant = false
                        state.discardMarkerTail.removeAll(keepingCapacity: false)
                    }
                } else if piece.count > maximumLineBytes - state.pending.count {
                    var probe = Data(state.pending.suffix(64))
                    probe.append(piece)
                    let relevant = relevantMarkers.contains { state.pending.range(of: $0) != nil || probe.range(of: $0) != nil }
                    if relevant { state.loseContext("An oversized relevant record was skipped; model-step coverage is partial.") }
                    state.pending.removeAll(keepingCapacity: false)
                    state.discarding = newline == nil
                    state.discardedRelevant = relevant && newline == nil
                    state.discardMarkerTail = newline == nil ? Data(probe.suffix(64)) : Data()
                } else {
                    state.pending.append(piece)
                    if newline != nil {
                        if relevantMarkers.contains(where: { state.pending.range(of: $0) != nil }) {
                            autoreleasepool {
                                if let object = try? JSONSerialization.jsonObject(with: state.pending) as? [String: Any] { state.consume(object) }
                                else { state.loseContext("A relevant usage record was malformed; coverage is partial.") }
                            }
                        }
                        if state.pending.range(of: skillMarker) != nil, state.pending.range(of: itemMarker) != nil {
                            autoreleasepool {
                                if let object = try? JSONSerialization.jsonObject(with: state.pending) as? [String: Any] { state.consumeSkills(object) }
                            }
                        }
                        state.pending.removeAll(keepingCapacity: true)
                    }
                }
                cursor = newline.map { chunk.index(after: $0) } ?? chunk.endIndex
            }
        }
    }
}
