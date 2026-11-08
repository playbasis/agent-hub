@testable import BridgeCore
import Foundation
import XCTest

final class InstructionReferenceTests: XCTestCase {
    func testCodexInstructionBlocksReportFolderAndInnerLengthOnly() throws {
        let body = "Rule one.\nRule two."
        let found = try XCTUnwrap(InstructionReference.codexInstructions("# AGENTS.md instructions for /Users/me/app\n\n<INSTRUCTIONS>\n\(body)\n</INSTRUCTIONS>"))
        XCTAssertEqual(found.folder, "/Users/me/app")
        XCTAssertEqual(found.characters, body.count)
        let personal = try XCTUnwrap(InstructionReference.codexInstructions("# AGENTS.md instructions\n\n<INSTRUCTIONS>\nBe brief.\n</INSTRUCTIONS>"))
        XCTAssertNil(personal.folder)
        XCTAssertEqual(InstructionReference.codexInstructions("<user_instructions>\nOld format\n</user_instructions>")?.characters, 10)
        XCTAssertNil(InstructionReference.codexInstructions("<skills_instructions>…"))
    }

    func testVersionsAndInstructionFileNames() {
        XCTAssertTrue(InstructionReference.claudeRecordsInstructions("2.1.260"))
        XCTAssertFalse(InstructionReference.claudeRecordsInstructions("2.1.258"))
        XCTAssertTrue(InstructionReference.claudeReadsAgentsFile("2.1.311"))
        XCTAssertFalse(InstructionReference.claudeReadsAgentsFile("2.1.260"))
        XCTAssertFalse(InstructionReference.claudeReadsAgentsFile(nil))
        XCTAssertTrue(InstructionReference.isInstructionFile("/p/AGENTS.md"))
        XCTAssertTrue(InstructionReference.isInstructionFile("/p/sub/CLAUDE.local.md"))
        XCTAssertTrue(InstructionReference.isInstructionFile("/p/.claude/rules/tests.md"))
        XCTAssertFalse(InstructionReference.isInstructionFile("/p/docs/AGENTS-guide.md"))
        XCTAssertFalse(InstructionReference.isInstructionFile("/p/README.md"))
    }

    func testStartContextMergeKeepsKnownFactsAndCountsChangedFiles() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let first = ActivityStartContext(instructions: [ActivityInstructionLoad(path: "/p/AGENTS.md", kind: .project, characters: 700, firstSeen: early, lastSeen: early)],
                                         instructionsRecorded: true, skillListCharacters: 15_000)
        let second = ActivityStartContext(instructions: [ActivityInstructionLoad(path: "/p/AGENTS.md", kind: .project, characters: 900, firstSeen: late, lastSeen: late)],
                                          clientVersion: "2.1.311")
        let merged = first.merging(second)
        XCTAssertEqual(merged.instructions.first?.characters, 900)
        XCTAssertEqual(merged.instructions.first?.versions, 2)
        XCTAssertEqual(merged.instructions.first?.firstSeen, early)
        XCTAssertTrue(merged.instructionsRecorded)
        XCTAssertEqual(merged.skillListCharacters, 15_000)
        XCTAssertEqual(merged.clientVersion, "2.1.311")
    }
}

final class InstructionCollectorTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("instruction-collector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func stamp(_ offset: Double) -> String { ISO8601.withFractional.string(from: now.addingTimeInterval(offset)) }

    private func write(_ rows: [[String: Any]], to name: String) throws {
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: root.appendingPathComponent(name))
    }

    private func reply(_ id: String, at offset: Double, cwd: String = "/projects/app") -> [String: Any] {
        ["type": "assistant", "sessionId": "s-\(id)", "cwd": cwd, "timestamp": stamp(offset), "requestId": id, "version": "2.1.311",
         "message": ["id": "m-\(id)", "role": "assistant", "model": "claude-sonnet-5", "stop_reason": "end_turn",
                     "content": [["type": "text", "text": "ok"]], "usage": ["input_tokens": 1, "output_tokens": 1]]]
    }

    func testClaudeRecordsInstructionFilesAndSkillListSizesWithoutText() async throws {
        let agents = "PRIVATE_RULES " + String(repeating: "r", count: 700)
        let memory = "PRIVATE_MEMORY " + String(repeating: "m", count: 300)
        try write([
            ["type": "attachment", "sessionId": "s-a", "cwd": "/projects/app", "timestamp": stamp(-60), "version": "2.1.311",
             "attachment": ["type": "instructions", "files": [
                ["path": "/projects/app/AGENTS.md", "type": "Project", "content": agents],
                ["path": "/Users/me/.claude/projects/-projects-app/memory/MEMORY.md", "type": "AutoMem", "content": memory]]]],
            ["type": "attachment", "sessionId": "s-a", "cwd": "/projects/app", "timestamp": stamp(-60),
             "attachment": ["type": "skill_listing", "isInitial": true, "skillCount": 30, "content": "- PRIVATE_SKILL: " + String(repeating: "s", count: 1_000)]],
            ["type": "user", "sessionId": "s-a", "cwd": "/projects/app/sub", "timestamp": stamp(-50), "uuid": "p", "message": ["role": "user", "content": "go"]],
            reply("a", at: -40, cwd: "/projects/app/sub"),
        ], to: "a.jsonl")
        let sessions = await ClaudeActivityCollector(root: root).collect(now: now).sessions
        let session = try XCTUnwrap(sessions.first)
        let context = try XCTUnwrap(session.startContext)
        XCTAssertTrue(context.instructionsRecorded)
        XCTAssertEqual(context.instructions.map(\.kind), [.project, .memory])
        XCTAssertEqual(context.instructions.first { $0.kind == .project }?.characters, agents.count)
        XCTAssertEqual(context.skillListCount, 30)
        XCTAssertEqual(context.clientVersion, "2.1.311")
        XCTAssertEqual(session.projectPath, "/projects/app", "A session belongs to the folder it started in")
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_"))
    }

    func testRecordingVersionsWithoutARecordMeanNoFilesButOlderVersionsSayNothing() async throws {
        try write([["type": "user", "sessionId": "s-n", "cwd": "/projects/app", "timestamp": stamp(-50), "uuid": "p", "message": ["role": "user", "content": "go"]],
                   reply("n", at: -40)], to: "new.jsonl")
        var old = reply("o", at: -40)
        old["version"] = "2.1.250"
        old["sessionId"] = "s-o"
        try write([old], to: "old.jsonl")
        let sessions = await ClaudeActivityCollector(root: root).collect(now: now).sessions
        XCTAssertEqual(sessions.first { $0.nativeID == "s-n" }?.startContext?.instructionsRecorded, true)
        XCTAssertEqual(sessions.first { $0.nativeID == "s-n" }?.startContext?.instructions.isEmpty, true)
        XCTAssertEqual(sessions.first { $0.nativeID == "s-o" }?.startContext?.instructionsRecorded, false)
    }

    func testCodexStartSkipsInheritedHistoryAndReadsOwnInstructions() throws {
        func line(_ object: [String: Any]) throws -> Data { var data = try JSONSerialization.data(withJSONObject: object); data.append(10); return data }
        func message(_ role: String, _ text: String) -> [String: Any] {
            ["type": "response_item", "timestamp": "2026-11-05T10:00:00.000Z", "payload": ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]]
        }
        var data = try line(["type": "session_meta", "payload": ["cli_version": "0.80.0", "cwd": "/Users/me/app"]])
        // A sub-agent's copy of its parent's history: oversized and not this session's start.
        data.append(try line(message("user", "# AGENTS.md instructions for /parent\n\n<INSTRUCTIONS>\nPARENT " + String(repeating: "p", count: 2_200_000) + "\n</INSTRUCTIONS>")))
        data.append(try line(message("developer", "<skills_instructions>\n- one: does one thing\n</skills_instructions>")))
        data.append(try line(message("user", "# AGENTS.md instructions for /Users/me/app\n\n<INSTRUCTIONS>\nPRIVATE rules\n</INSTRUCTIONS>")))
        data.append(try line(["type": "turn_context", "payload": ["turn_id": "t1", "cwd": "/Users/me/app"]]))
        let url = root.appendingPathComponent("rollout.jsonl")
        try data.write(to: url)
        let (context, complete) = CodexStartContextReader.scan(url.path)
        let value = try XCTUnwrap(context)
        XCTAssertTrue(complete)
        XCTAssertTrue(value.instructionsRecorded)
        XCTAssertEqual(value.instructions.count, 1)
        XCTAssertEqual(value.instructions.first?.kind, .combined)
        XCTAssertEqual(value.instructions.first?.path, "/Users/[REDACTED]/app", "Stored paths are redacted like other saved paths")
        XCTAssertEqual(value.instructions.first?.characters, "PRIVATE rules".count)
        XCTAssertEqual(value.skillListCharacters, "<skills_instructions>\n- one: does one thing\n</skills_instructions>".count)
        XCTAssertEqual(value.clientVersion, "0.80.0")
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE"))

        // A rollout that hasn't reached its first turn is read again later.
        let partial = root.appendingPathComponent("partial.jsonl")
        try line(["type": "session_meta", "payload": ["cli_version": "0.80.0"]]).write(to: partial)
        XCTAssertFalse(CodexStartContextReader.scan(partial.path).1)
    }
}

final class InstructionCatalogTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("instruction-catalog-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func project(_ name: String, git: Bool = true) throws -> String {
        let url = root.appendingPathComponent("work/\(name)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(git ? ".git" : "."), withIntermediateDirectories: true)
        return url.path
    }

    func testEachAgentsChainFollowsItsOwnDiscoveryRules() async throws {
        try file("home/.codex/AGENTS.md", "Prefer small diffs.")
        let shared = try project("shared")
        try file("work/shared/AGENTS.md", "Run make check before handing off.")
        try file("work/shared/CLAUDE.md", "@AGENTS.md\n")
        let fallback = try project("fallback")
        try file("work/fallback/AGENTS.md", "Use semantic colours.")
        let split = try project("split")
        try file("work/split/AGENTS.md", "Codex rules here.")
        try file("work/split/CLAUDE.md", "Claude has its own, different rules that nobody synced.")
        let claudeOnly = try project("claude-only")
        try file("work/claude-only/CLAUDE.md", "Only Claude reads this file; Codex does not.")
        let big = try project("big")
        try file("work/big/AGENTS.md", String(repeating: "a", count: 40 * 1_024))
        let mono = try project("mono")
        try file("work/mono/AGENTS.md", "Monorepo rules.")
        try file("work/mono/app/AGENTS.md", "App rules.")
        let app = root.appendingPathComponent("work/mono/app").path
        try file("home/.claude/projects/\(InstructionCatalogReader.claudeProjectFolder(fallback))/memory/MEMORY.md", "- remembered fact")

        let catalog = await InstructionCatalogReader(home: home).catalog(projects: [shared, fallback, split, claudeOnly, big, app])
        XCTAssertEqual(catalog.personal.codex.links.map { ($0.path as NSString).lastPathComponent }, ["AGENTS.md"])
        XCTAssertEqual(catalog.personal.parity, .codexOnly)

        let sharedRow = try XCTUnwrap(catalog.projects[shared])
        XCTAssertEqual(sharedRow.parity, .same, "A CLAUDE.md that only imports AGENTS.md shares its rules")
        XCTAssertEqual(sharedRow.claude.links.map(\.reason), [.project, .imported])
        XCTAssertTrue(try XCTUnwrap(catalog.file(sharedRow.claude.links[0].path)).isPointer)

        let fallbackRow = try XCTUnwrap(catalog.projects[fallback])
        XCTAssertEqual(fallbackRow.claude.links.map(\.reason), [.fallback, .memory])
        XCTAssertEqual(fallbackRow.parity, .same)

        XCTAssertEqual(catalog.projects[split]?.parity, .different)
        XCTAssertEqual(catalog.projects[claudeOnly]?.parity, .claudeOnly)
        XCTAssertEqual(catalog.projects[big]?.codex.truncatedBytes, 8 * 1_024)
        let monoRow = try XCTUnwrap(catalog.projects[app])
        XCTAssertEqual(monoRow.codex.projectLinks.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent }, ["mono", "app"],
                       "Codex reads from the repository root down to the folder")
        XCTAssertEqual(mono, root.appendingPathComponent("work/mono").path)
    }

    func testImportsIgnoreCodeAndMissingFiles() throws {
        let folder = try file("work/x/notes.md", "n").deletingLastPathComponent()
        let text = "See @notes.md.\n`@inline.md` and @missing.md\n```\n@notes.md\n```\nemail me@example.com"
        let found = InstructionCatalogReader.imports(in: text, relativeTo: folder, home: home)
        XCTAssertEqual(found.paths.map { ($0 as NSString).lastPathComponent }, ["notes.md"])
        XCTAssertGreaterThan(found.remaining, 24)
        XCTAssertTrue(InstructionCatalogReader.hasPathsFrontMatter("---\npaths:\n  - src/**\n---\nRule"))
        XCTAssertFalse(InstructionCatalogReader.hasPathsFrontMatter("# Rule"))
    }
}

final class InstructionReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func file(_ path: String, _ characters: Int, kind: InstructionFile.Kind = .agents, imports: [String] = [], substantive: Int? = nil) -> InstructionFile {
        InstructionFile(path: path, kind: kind, bytes: characters, characters: characters, fingerprint: "fp:\(path)", imports: imports, substantiveCharacters: substantive)
    }

    private func catalog() -> InstructionCatalog {
        let personal = file("/home/.codex/AGENTS.md", 200)
        let splitClaude = file("/work/split/CLAUDE.md", 1_600, kind: .claude)
        let splitCodex = file("/work/split/AGENTS.md", 2_400)
        let claudeOnly = file("/work/claude-only/CLAUDE.md", 900, kind: .claude)
        let agentsOnly = file("/work/agents-only/AGENTS.md", 800)
        let files = Dictionary(uniqueKeysWithValues: [personal, splitClaude, splitCodex, claudeOnly, agentsOnly].map { ($0.path, $0) })
        let personalLink = InstructionLink(path: personal.path, reason: .personal, bytesRead: 200)
        func codex(_ links: [InstructionLink]) -> InstructionChain { InstructionChain(agent: .codex, links: [personalLink] + links) }
        let projects: [String: ProjectInstructions] = [
            "/work/split": ProjectInstructions(path: "/work/split",
                claude: InstructionChain(agent: .claude, links: [InstructionLink(path: splitClaude.path, reason: .project, bytesRead: 1_600)]),
                codex: codex([InstructionLink(path: splitCodex.path, reason: .project, bytesRead: 2_400)]), parity: .different),
            "/work/claude-only": ProjectInstructions(path: "/work/claude-only",
                claude: InstructionChain(agent: .claude, links: [InstructionLink(path: claudeOnly.path, reason: .project, bytesRead: 900)]),
                codex: codex([]), parity: .claudeOnly),
            "/work/agents-only": ProjectInstructions(path: "/work/agents-only",
                claude: InstructionChain(agent: .claude, links: [InstructionLink(path: agentsOnly.path, reason: .fallback, bytesRead: 800)]),
                codex: codex([InstructionLink(path: agentsOnly.path, reason: .project, bytesRead: 800)]), parity: .same),
        ]
        let personalProject = ProjectInstructions(path: "~", claude: InstructionChain(agent: .claude), codex: codex([]), parity: .codexOnly)
        return InstructionCatalog(files: files, projects: projects, personal: personalProject, scannedAt: now)
    }

    private func session(_ id: String, _ provider: AgentName, project: String, context: ActivityStartContext?, artifacts: [ActivityArtifact] = []) -> ActivitySession {
        let turn = ActivityTurn(id: "\(id):t", startedAt: now.addingTimeInterval(-600), completedAt: now.addingTimeInterval(-500), status: "completed", artifacts: artifacts)
        return ActivitySession(id: id, provider: provider, nativeID: id, title: id, projectPath: project, createdAt: now.addingTimeInterval(-700),
                               updatedAt: now.addingTimeInterval(-400), turns: [turn], source: "fixture", startContext: context)
    }

    private func codexContext(_ folder: String, _ characters: Int) -> ActivityStartContext {
        ActivityStartContext(instructions: [ActivityInstructionLoad(path: folder, kind: .combined, characters: characters)], instructionsRecorded: true, skillListCharacters: 30_000)
    }

    func testReportJoinsRecordsWithFilesAndFindsGaps() {
        let sessions = [
            session("claude-split", .claude, project: "/work/split", context: ActivityStartContext(
                instructions: [ActivityInstructionLoad(path: "/work/split/CLAUDE.md", kind: .project, characters: 1_600)], instructionsRecorded: true, skillListCharacters: 14_000),
                artifacts: [ActivityArtifact(id: "e1", path: "CLAUDE.md", status: "edit_requested")]),
            session("codex-split", .codex, project: "/work/split", context: codexContext("/work/split", 2_600),
                    artifacts: [ActivityArtifact(id: "e2", path: "/Users/[REDACTED]/notes/AGENTS.md")]),
            session("codex-gap-1", .codex, project: "/work/claude-only", context: codexContext("", 200)),
            session("codex-gap-2", .codex, project: "/work/claude-only", context: codexContext("", 200)),
            session("claude-old-1", .claude, project: "/work/agents-only", context: ActivityStartContext(clientVersion: "2.1.250")),
            session("claude-old-2", .claude, project: "/work/agents-only", context: ActivityStartContext(clientVersion: "2.1.250")),
        ]
        let result = InstructionReport.build(.init(sessions: sessions, catalog: catalog(), from: now.addingTimeInterval(-7 * 86_400), to: now))
        XCTAssertEqual(result.rows.first?.id, "~", "Personal files come first")
        let split = result.rows.first { $0.id == "/work/split" }
        XCTAssertEqual(split?.parity, .different)
        XCTAssertEqual(split?.perSession[.codex], 2_600)
        XCTAssertEqual(split?.perSessionMeasured[.codex], true)
        XCTAssertEqual(result.rows.first { $0.id == "/work/claude-only" }?.missingSessions[.codex], 2)
        XCTAssertEqual(result.rows.first { $0.id == "/work/agents-only" }?.olderClaudeSessions, 2)
        XCTAssertEqual(result.rows.first { $0.id == "/work/agents-only" }?.perSessionMeasured[.claude], false)
        XCTAssertEqual(result.totals.projects, 3)
        XCTAssertEqual(result.totals.projectsSame, 1)
        XCTAssertEqual(result.totals.edits, 2)
        XCTAssertTrue(result.edits.contains { $0.path == "/work/split/CLAUDE.md" })
        XCTAssertTrue(result.edits.contains { $0.path.hasSuffix("/notes/AGENTS.md") && !$0.path.contains("[REDACTED]") })

        let codex = result.starts.first { $0.agent == .codex }
        XCTAssertEqual(codex?.parts[.skills], 30_000)
        XCTAssertEqual(codex?.parts[.personal], 200, "Codex's combined text is split into your file and the project's")
        let kinds = Set(result.insights.map(\.highlight.kind))
        XCTAssertTrue(kinds.contains(.instructionsDiffer))
        XCTAssertTrue(kinds.contains(.instructionsMissing))
        XCTAssertTrue(kinds.contains(.instructionsEdited))
        XCTAssertFalse(kinds.contains(.instructionsShared))
    }

    func testSubAgentsInheritTheirParentsRecordedStart() {
        var child = session("child", .codex, project: "/work/split", context: nil)
        child.parentSessionID = "parent"
        let parent = session("parent", .codex, project: "/work/split", context: codexContext("/work/split", 2_600))
        let result = InstructionReport.build(.init(sessions: [parent, child], catalog: catalog(), from: nil, to: now))
        XCTAssertEqual(result.totals.measuredSessions, 2)
        XCTAssertEqual(result.rows.first { $0.id == "/work/split" }?.charactersLoaded, 5_200)
    }

    func testDatabaseKeepsAStartSeenEarlierWhenALaterWindowMissesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("instruction-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ActivityDatabase(url: directory.appendingPathComponent("activity.sqlite"))
        let health = ActivitySourceHealth(id: "claude", status: "ready", message: "Fixture")
        var first = session("s", .claude, project: "/work/split", context: ActivityStartContext(
            instructions: [ActivityInstructionLoad(path: "/work/split/CLAUDE.md", kind: .project, characters: 1_600)], instructionsRecorded: true))
        first.observedAt = now
        try database.merge([ActivityCollection(sessions: [first], health: health)], now: now)
        var later = first
        later.startContext = nil
        later.observedAt = now.addingTimeInterval(60)
        try database.merge([ActivityCollection(sessions: [later], health: health)], now: now.addingTimeInterval(60))
        XCTAssertEqual(try database.overview().sessions.first?.startContext?.instructions.first?.characters, 1_600)
    }
}
