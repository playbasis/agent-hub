import Foundation

public final class ProjectStore: @unchecked Sendable {
    public let project: URL
    public let context: URL
    public let bridgeFile: URL
    public let changesFile: URL
    public let eventsFile: URL
    public let decisionsFile: URL
    public let runtimeFile: URL
    public let traceFile: URL
    public let traceSummaryFile: URL

    private var knownEventIDs: Set<UUID> = []

    public init(projectPath: String) throws {
        project = URL(fileURLWithPath: projectPath).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BridgeError.invalidProject(project.path)
        }
        context = project.appendingPathComponent("CONTEXT", isDirectory: true)
        bridgeFile = project.appendingPathComponent("BRIDGE.md")
        changesFile = project.appendingPathComponent("CHANGES.log")
        eventsFile = context.appendingPathComponent("events.jsonl")
        decisionsFile = context.appendingPathComponent("decisions.jsonl")
        runtimeFile = context.appendingPathComponent("runtime.json")
        traceFile = context.appendingPathComponent("trace.jsonl")
        traceSummaryFile = context.appendingPathComponent("trace-summary.json")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        knownEventIDs = loadEventIDs()
    }

    public func initialize(session: RuntimeSession) throws {
        if !FileManager.default.fileExists(atPath: changesFile.path) {
            try writeProtected(
                Data("# ClaudeCodexBridge hand-off log\n".utf8),
                to: changesFile
            )
        }
        try saveRuntime(session)
        try updateBridge(session: session, decision: nil)
    }

    @discardableResult
    public func append(event: BridgeEvent) throws -> Bool {
        guard !knownEventIDs.contains(event.id) else { return false }
        try appendLine(BridgeJSON.compactEncoder.encode(event), to: eventsFile)
        knownEventIDs.insert(event.id)
        return true
    }

    public func appendDecision(
        event: BridgeEvent,
        decision: Decision,
        fromAgent: AgentName,
        coordinator: ProviderHealth
    ) throws {
        let record = DecisionRecord(
            timestamp: Date(),
            eventID: event.id.uuidString,
            fromAgent: fromAgent,
            toAgent: decision.nextAgent,
            coordinator: coordinator,
            decision: decision
        )
        try appendLine(BridgeJSON.compactEncoder.encode(record), to: decisionsFile)

        var prompt = decision.refinedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.count > 4_000 {
            prompt = String(prompt.prefix(4_000)) + "\n[…truncated in Markdown log]"
        }
        var markdown = """

        ## \(ISO8601.withFractional.string(from: Date())) — \(fromAgent.rawValue) → \(decision.nextAgent.rawValue)
        - Label: `\(decision.label.rawValue)`
        - Action: `\(decision.action.rawValue)`
        - Confidence: `\(String(format: "%.2f", decision.confidence))`
        - Coordinator: `\(coordinator.provider)`\(coordinator.fallbackActive ? " → `rules` fallback" : "")
        - Summary: \(decision.summaryForLog)
        - Reason: \(decision.reason)

        """
        if !prompt.isEmpty {
            markdown += "### Next prompt\n\n\(prompt)\n"
        }
        try appendData(Data(markdown.utf8), to: changesFile)
    }

    public func saveRuntime(_ session: RuntimeSession) throws {
        try writeProtected(BridgeJSON.encoder.encode(session), to: runtimeFile)
    }

    public func loadRuntime() throws -> RuntimeSession? {
        guard FileManager.default.fileExists(atPath: runtimeFile.path) else { return nil }
        return try BridgeJSON.decoder.decode(RuntimeSession.self, from: Data(contentsOf: runtimeFile))
    }

    public func updateBridge(session: RuntimeSession, decision: Decision?) throws {
        let remaining = max(0, Int(session.deadline.timeIntervalSinceNow))
        let latest: String
        if let decision {
            latest = """
            - Action: `\(decision.action.rawValue)`
            - Next agent: `\(decision.nextAgent.rawValue)`
            - Label: `\(decision.label.rawValue)`
            - Reason: \(decision.reason)
            """
        } else {
            latest = "No routing decision has been recorded yet."
        }
        let content = """
        # ClaudeCodexBridge

        This file is managed by the local bridge. Agents may read it but must not
        edit the session metadata below.

        ## Current goal

        \(session.goal)

        ## Session

        - ID: `\(session.id)`
        - State: `\(session.state.rawValue)`
        - Active agent: `\(session.activeAgent.rawValue)`
        - Deadline: `\(ISO8601.withFractional.string(from: session.deadline))`
        - Remaining seconds at last update: `\(remaining)`
        - Turn count: `\(session.turnCount)`

        ## Invariants

        1. Work only inside the selected project unless the user expands scope.
        2. Preserve user changes and inspect existing state before editing.
        3. Run focused verification before declaring completion.
        4. End a verified final response with `<bridge:complete>`.
        5. End a non-final hand-off with `<bridge:continue>`.
        6. If user action is indispensable, emit
           `<bridge:blocked>concise reason</bridge:blocked>`.

        ## Latest routing decision

        \(latest)

        ## Context index

        - `CHANGES.log`: append-only hand-off summaries
        - `CONTEXT/events.jsonl`: canonical event stream
        - `CONTEXT/decisions.jsonl`: validated routing decisions
        - `CONTEXT/runtime.json`: recoverable session snapshot
        - `CONTEXT/trace.jsonl`: hash-chained provider receipts
        - `CONTEXT/trace-summary.json`: derived provider proof
        """
        try writeProtected(Data((content + "\n").utf8), to: bridgeFile)
    }

    public func recentDecisionValues(limit: Int) -> [JSONValue] {
        guard let data = try? Data(contentsOf: decisionsFile),
              let content = String(data: data, encoding: .utf8)
        else { return [] }
        return content
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line in
                try? BridgeJSON.decoder.decode(JSONValue.self, from: Data(line.utf8))
            }
    }

    public func recentEvents(limit: Int) -> [BridgeEvent] {
        guard let data = try? Data(contentsOf: eventsFile),
              let content = String(data: data, encoding: .utf8)
        else { return [] }
        return content
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line in
                try? BridgeJSON.decoder.decode(BridgeEvent.self, from: Data(line.utf8))
            }
    }

    @discardableResult
    public func appendTrace(_ candidate: TraceRecord) throws -> TraceRecord {
        let existing = traceRecords(limit: Int.max)
        var record = candidate
        record.sequence = (existing.last?.sequence ?? 0) + 1
        record.previousHash = existing.last?.recordHash
        record.recordHash = ""
        let canonical = try BridgeJSON.compactEncoder.encode(record)
        record.recordHash = TraceCrypto.digest(
            Data((record.previousHash ?? "").utf8) + canonical
        )
        try appendLine(BridgeJSON.compactEncoder.encode(record), to: traceFile)
        try writeProtected(
            BridgeJSON.encoder.encode(traceSummary(records: existing + [record])),
            to: traceSummaryFile
        )
        return record
    }

    public func traceRecords(limit: Int = 500) -> [TraceRecord] {
        guard let data = try? Data(contentsOf: traceFile),
              let content = String(data: data, encoding: .utf8)
        else { return [] }
        let lines = content.split(separator: "\n")
        let selected = limit == Int.max ? lines[...] : lines.suffix(max(0, limit))
        return selected.compactMap {
            try? BridgeJSON.decoder.decode(TraceRecord.self, from: Data($0.utf8))
        }
    }

    public func currentTraceSummary() -> TraceSummary {
        traceSummary(records: traceRecords(limit: Int.max))
    }

    public func verifyTrace() -> Bool {
        let records = traceRecords(limit: Int.max)
        var previous: String?
        for source in records {
            guard source.previousHash == previous else { return false }
            var record = source
            let expected = record.recordHash
            record.recordHash = ""
            guard let canonical = try? BridgeJSON.compactEncoder.encode(record) else {
                return false
            }
            let actual = TraceCrypto.digest(Data((previous ?? "").utf8) + canonical)
            guard actual == expected else { return false }
            previous = expected
        }
        return true
    }

    public func sanitizedTraceExport() throws -> Data {
        let records = traceRecords(limit: Int.max)
        let envelope = TraceExport(
            exportedAt: Date(),
            projectName: project.lastPathComponent,
            summary: traceSummary(records: records),
            records: records
        )
        return try BridgeJSON.encoder.encode(envelope)
    }

    /// Imports provider metadata for a legacy runtime without claiming that
    /// historical routing or completion can be fully reconstructed.
    @discardableResult
    public func backfillLegacyTrace(
        configuration: BridgeConfiguration
    ) throws -> Int {
        guard let runtime = try loadRuntime() else {
            throw BridgeError.configuration("The project has no persisted runtime to backfill.")
        }
        let existing = traceRecords(limit: Int.max)
        var imported = 0
        for provider in [TraceProvider.claude, .codex] {
            guard let nativeID = runtime.agentSessionIDs[provider.rawValue],
                  !existing.contains(where: {
                      $0.provider == provider && $0.nativeSessionID == nativeID
                  })
            else { continue }
            let telemetry = provider == .claude
                ? ClaudeTranscriptReader.telemetry(sessionID: nativeID)
                : CodexTranscriptReader.telemetry(sessionID: nativeID)
            let requestedIdentity = ProviderIdentity(
                requestedModel: provider == .claude
                    ? configuration.agents.claudeModel : configuration.agents.codexModel,
                resolvedModel: telemetry.identity.resolvedModel,
                requestedEffort: provider == .claude
                    ? configuration.agents.claudeEffort
                    : configuration.agents.codexReasoningEffort,
                resolvedEffort: telemetry.identity.resolvedEffort,
                modelProvider: telemetry.identity.modelProvider,
                serviceTier: telemetry.identity.serviceTier,
                contextWindow: telemetry.identity.contextWindow,
                sandbox: provider == .codex ? configuration.agents.codexSandbox : "safe-mode",
                permissionMode: provider == .claude
                    ? configuration.agents.claudePermissionMode : nil
            )
            _ = try appendTrace(TraceRecord(
                id: UUID().uuidString,
                sequence: 0,
                timestamp: Date(),
                bridgeSessionID: runtime.id,
                turnID: "legacy-\(provider.rawValue)-\(nativeID)",
                eventID: nil,
                provider: provider,
                nativeSessionID: nativeID,
                nativeTurnID: telemetry.nativeTurnID,
                identity: requestedIdentity,
                usage: telemetry.usage,
                tools: telemetry.tools,
                durationMilliseconds: nil,
                timeToFirstTokenMilliseconds: nil,
                outcome: "historical",
                exitCode: nil,
                completeness: .legacy,
                warnings: telemetry.warnings + [
                    "Backfilled from a native transcript; historical turn boundaries may be incomplete.",
                ],
                budgetReserved: nil,
                budgetRemaining: nil,
                estimatedCostUSD: nil,
                costProvenance: .unavailable,
                adapterVersion: "legacy-backfill/1",
                previousHash: nil,
                recordHash: ""
            ))
            imported += 1
        }
        return imported
    }

    private func traceSummary(records: [TraceRecord]) -> TraceSummary {
        var providers: [String: Int] = [:]
        var successful: Set<String> = []
        var total = 0
        var hasTotal = false
        var partial = false
        var legacyGeminiEvidence: Set<TraceProvider> = []
        var grokCoordinatorEvidence: Set<TraceProvider> = []
        var grokExecuted = false
        for record in records {
            providers[record.provider.rawValue, default: 0] += 1
            if record.outcome == "success" {
                successful.insert(record.provider.rawValue)
                if record.provider == .grok, record.evidenceProviders == nil {
                    grokExecuted = true
                }
            }
            if let value = record.usage.total {
                total += value
                hasTotal = true
            }
            partial = partial || record.completeness != .complete
            if record.provider == .gemini {
                legacyGeminiEvidence.formUnion(record.evidenceProviders ?? [])
            }
            if record.provider == .grok, let evidence = record.evidenceProviders {
                grokCoordinatorEvidence.formUnion(evidence)
            }
        }
        let claude = successful.contains(TraceProvider.claude.rawValue)
        let codex = successful.contains(TraceProvider.codex.rawValue)
        let legacyGemini = successful.contains(TraceProvider.gemini.rawValue)
            && legacyGeminiEvidence.contains(.claude)
            && legacyGeminiEvidence.contains(.codex)
        let grokCoordinatedPair = grokCoordinatorEvidence.contains(.claude)
            && grokCoordinatorEvidence.contains(.codex)
        let grokCoordinatedAll = grokCoordinatedPair
            && grokCoordinatorEvidence.contains(.grok)
        return TraceSummary(
            bridgeSessionID: records.last?.bridgeSessionID,
            records: records.count,
            providers: providers,
            successfulProviders: successful.sorted(),
            totalTokens: hasTotal ? total : nil,
            toolCalls: records.reduce(0) { $0 + $1.tools.count },
            budgetRemaining: records.last?.budgetRemaining,
            threeProviderVerified: claude && codex && grokExecuted
                && grokCoordinatedAll && !partial,
            dualProviderVerified: claude && codex
                && (grokCoordinatedPair || legacyGemini) && !partial,
            traceVerified: verify(records),
            completeness: records.isEmpty || partial ? .partial : .complete,
            updatedAt: Date()
        )
    }

    private func verify(_ records: [TraceRecord]) -> Bool {
        var previous: String?
        for source in records {
            guard source.previousHash == previous else { return false }
            var record = source
            let expected = record.recordHash
            record.recordHash = ""
            guard let canonical = try? BridgeJSON.compactEncoder.encode(record) else {
                return false
            }
            guard TraceCrypto.digest(Data((previous ?? "").utf8) + canonical) == expected
            else { return false }
            previous = expected
        }
        return true
    }

    private func loadEventIDs() -> Set<UUID> {
        Set(recentEvents(limit: 10_000).map(\.id))
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        var payload = data
        payload.append(0x0A)
        try appendData(payload, to: url)
    }

    private func appendData(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private struct TraceExport: Codable {
    var schemaVersion = "1.0"
    var exportedAt: Date
    var projectName: String
    var summary: TraceSummary
    var records: [TraceRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case projectName = "project_name"
        case summary, records
    }
}

private struct DecisionRecord: Codable {
    var timestamp: Date
    var eventID: String
    var fromAgent: AgentName
    var toAgent: AgentName
    var coordinator: ProviderHealth
    var decision: Decision

    enum CodingKeys: String, CodingKey {
        case timestamp
        case eventID = "event_id"
        case fromAgent = "from_agent"
        case toAgent = "to_agent"
        case coordinator
        case decision
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(fromAgent, forKey: .fromAgent)
        try container.encode(toAgent, forKey: .toAgent)
        try container.encode(coordinator, forKey: .coordinator)
        try container.encode(decision, forKey: .decision)
    }
}
