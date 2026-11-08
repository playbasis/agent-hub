import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

/// Developer probe, skipped unless `BRIDGE_SKILL_PROBE_OUT` names a folder.
/// Re-reads this Mac's Claude transcripts and recent Codex rollouts with the
/// current collectors, prints the Skills and instruction-file reports and writes a replay fixture
/// (`skills-fixture.json`) for `BRIDGE_REFRESH_FIXTURE` previews. Only the
/// metadata the collectors keep is written; nothing leaves the Mac.
final class SkillRealDataProbeTests: XCTestCase {
    func testProbeSkillsOnThisMac() async throws {
        guard let out = ProcessInfo.processInfo.environment["BRIDGE_SKILL_PROBE_OUT"], out.hasPrefix("/") else {
            throw XCTSkip("Set BRIDGE_SKILL_PROBE_OUT to run the real-data skills probe.")
        }
        let now = Date()
        var overview = await ActivitySnapshotCache.standard.load(now: now) ?? ActivityOverview(generatedAt: now)
        var byID = Dictionary(overview.sessions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })

        // Claude: the collector reads the same bounded transcript window the app does.
        let claude = await ClaudeActivityCollector().collect(now: now)
        for session in claude.sessions { byID[session.id] = session }

        // Codex: enrich recent saved tasks from their own rollouts.
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        var rollouts: [String: String] = [:]
        if let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let name = url.deletingPathExtension().lastPathComponent
                if name.count >= 36 { rollouts[String(name.suffix(36))] = url.path }
            }
        }
        var enriched = 0
        for (id, session) in byID where session.provider == .codex && session.updatedAt > now.addingTimeInterval(-8 * 86_400) {
            guard let path = rollouts[session.nativeID] else { continue }
            var value = CodexActivityParser.enrich(session, telemetry: CodexActivityTranscript.read(path: path, deadline: Date().addingTimeInterval(20)))
            // The app reaches whole histories over several refreshes; read them at once here.
            let steps = CodexModelStepReader.read(path: path, deadline: Date().addingTimeInterval(60), maximumBytes: 4 * 1_024 * 1_024 * 1_024, priority: true)
            value = CodexActivityParser.enrichModelSteps(value, telemetry: steps)
            if let start = CodexStartContextReader.read(path: path) { value.startContext = start }
            byID[id] = value
            enriched += 1
        }
        // Git: read-only commit history with line counts for the busiest projects.
        var seenPaths = Set<String>()
        let recentPaths = byID.values.sorted { $0.updatedAt > $1.updatedAt }.compactMap(\.projectPath).filter { seenPaths.insert($0).inserted }
        overview.repositories = await ActivityGitReader().read(paths: Array(recentPaths.prefix(12)), now: now)
        // Replay fixtures load through the 32 MB snapshot limit; keep the week.
        overview.sessions = byID.values.filter { $0.updatedAt > now.addingTimeInterval(-8 * 86_400) || $0.goal?.isOpen == true }
        overview.generatedAt = now

        // Whole-history model steps would push the fixture past the 32 MB
        // snapshot limit; the Skills page doesn't use them.
        var fixtureOverview = overview
        fixtureOverview.sessions = overview.sessions.map { session in
            var copy = session
            copy.turns = session.turns.map { var turn = $0; turn.modelSteps = nil; turn.modelStepsComplete = nil; return turn }
            return copy
        }
        let fixture = URL(fileURLWithPath: out).appendingPathComponent("skills-fixture.json")
        let data = try BridgeJSON.compactEncoder.encode(fixtureOverview)
        XCTAssertLessThan(data.count, 32 * 1_024 * 1_024, "Replay fixtures load through the snapshot size limit")
        try data.write(to: fixture, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.path)

        let projects = Array(Set(overview.sessions.compactMap(\.projectPath)))
        let catalog = await SkillCatalogReader(home: FileManager.default.homeDirectoryForCurrentUser).catalog(projects: projects, now: now)
        let report = SkillReport.build(.init(sessions: overview.sessions, catalog: catalog, from: now.addingTimeInterval(-7 * 86_400), to: now))
        var lines = ["Claude sessions \(claude.sessions.count) · Codex sessions enriched \(enriched) · installed skills \(catalog.skills.count)",
                     "Totals: \(report.totals)"]
        for row in report.rows.prefix(25) {
            lines.append("\(row.name) · loads \(row.loads) \(row.loadsByProvider.map { "\($0.key.rawValue)=\($0.value)" }.sorted()) · sessions \(row.sessions) · tokens/load \(row.tokensPerLoad ?? -1)\(row.tokensPerLoadMeasured ? " measured" : "") · copies \(row.copies.map { "\($0.provider.rawValue)/\($0.scope.rawValue)" }) · missing \(row.missingSessions.map { "\($0.key.rawValue)=\($0.value)" }) · differ \(row.copiesDiffer)")
        }
        for insight in report.insights { lines.append("INSIGHT [\(insight.highlight.kind.rawValue)] \(insight.highlight.value) — \(insight.highlight.title) — \(insight.highlight.detail)") }
        lines += report.coverage.map { "COVERAGE \($0)" }

        // Instruction files: what each agent reads per project, and what sessions recorded.
        let instructionCatalog = await InstructionCatalogReader(home: FileManager.default.homeDirectoryForCurrentUser).catalog(projects: projects, now: now)
        let instructions = InstructionReport.build(.init(sessions: overview.sessions, catalog: instructionCatalog, from: now.addingTimeInterval(-7 * 86_400), to: now))
        lines.append("INSTRUCTIONS totals \(instructions.totals)")
        for start in instructions.starts { lines.append("START \(start.agent.rawValue) sessions \(start.sessions) measured \(start.measuredSessions) parts \(start.parts.map { "\($0.key.rawValue)=\($0.value)" }.sorted())") }
        for row in instructions.rows.prefix(20) {
            let chains = [AgentName.claude, .codex].map { agent in
                "\(agent.rawValue)[" + (row.instructions?.chain(agent).links.map { "\($0.reason.rawValue):\(URL(fileURLWithPath: $0.path).lastPathComponent)=\($0.bytesRead)" }.joined(separator: ",") ?? "") + "]"
            }.joined(separator: " ")
            lines.append("ROW \(row.id) parity \(row.parity.rawValue) sessions \(row.sessions.map { "\($0.key.rawValue)=\($0.value)" }.sorted()) per \(row.perSession.map { "\($0.key.rawValue)=\($0.value)\(row.perSessionMeasured[$0.key] == true ? "m" : "")" }.sorted()) missing \(row.missingSessions.map { "\($0.key.rawValue)=\($0.value)" }) older \(row.olderClaudeSessions) edits \(row.edits.count) \(chains)")
        }
        for insight in instructions.insights { lines.append("I-INSIGHT [\(insight.highlight.kind.rawValue)] \(insight.highlight.value) — \(insight.highlight.title) — \(insight.highlight.detail)") }
        let shipped = ShippedCodeReport.build(.init(sessions: overview.sessions, repositories: overview.repositories, from: now.addingTimeInterval(-7 * 86_400), to: now))
        lines.append("SHIPPED repos \(shipped.totals.repositories) unavailable \(shipped.totals.unavailableRepositories) commits \(shipped.totals.commits) linked \(shipped.totals.linkedCommits) lines \(ShippedCodeReport.linesLabel(shipped.totals.lines)) linked \(ShippedCodeReport.linesLabel(shipped.totals.linkedLines)) sessions \(shipped.totals.sessions) withCommits \(shipped.totals.sessionsWithCommits) coauthored \(shipped.totals.coAuthoredCommits)")
        for project in shipped.projects { lines.append("SHIPPED-PROJECT \(project.name) available \(project.available) commits \(project.commits) linked \(project.linkedCommits) \(ShippedCodeReport.linesLabel(project.lines)) sessions \(project.sessions)/\(project.sessionsWithCommits)") }
        let text = lines.joined(separator: "\n")
        print(text)
        try text.write(to: URL(fileURLWithPath: out).appendingPathComponent("skills-probe.txt"), atomically: true, encoding: .utf8)
    }

    /// Preview fixture, skipped unless `BRIDGE_CONTEXT_HISTORY_OUT` names a
    /// scratch file: records an earlier, edited variant of a few real context
    /// files, then their current contents, so previews show a version history.
    func testWriteContextHistoryFixture() throws {
        guard let out = ProcessInfo.processInfo.environment["BRIDGE_CONTEXT_HISTORY_OUT"], out.hasPrefix("/") else {
            throw XCTSkip("Set BRIDGE_CONTEXT_HISTORY_OUT to write a preview version history.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = (ProcessInfo.processInfo.environment["BRIDGE_CONTEXT_HISTORY_FILES"] ?? "").split(separator: ",").map { String($0).replacingOccurrences(of: "~", with: home) }
        let history = ContextFileHistory(url: URL(fileURLWithPath: out))
        let now = Date()
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? now
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            if lines.count > 6 { lines.removeLast(min(4, lines.count / 3)) }
            if lines.count > 2 { lines[1] = lines[1] + " (earlier wording)" }
            history.observe(path: path, data: Data(lines.joined(separator: "\n").utf8), modifiedAt: modified.addingTimeInterval(-3 * 86_400), now: now.addingTimeInterval(-3 * 86_400))
            history.observe(path: path, data: data, modifiedAt: modified, now: now)
        }
        let deadline = Date().addingTimeInterval(6)
        while !FileManager.default.fileExists(atPath: out), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
    }
}
