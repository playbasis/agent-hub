@testable import BridgeCore
import Foundation
import XCTest

final class SkillReferenceTests: XCTestCase {
    private func reads(_ command: String) -> [String] { SkillReference.references(inCommand: command).reads.map(\.name) }
    private func edits(_ command: String) -> [String] { SkillReference.references(inCommand: command).edits.map(\.name) }

    func testCodexLoadsAreReadsOfSkillFilesInSkillsFolders() {
        XCTAssertEqual(reads("/bin/zsh -lc cat /Users/me/.codex/skills/release-sample-site/SKILL.md /Users/me/.codex/attachments/goal.md"), ["release-sample-site"])
        XCTAssertEqual(reads("/bin/zsh -lc \"sed -n '1,120p' /Users/me/.codex/skills/.system/skill-creator/SKILL.md\""), ["skill-creator"])
        XCTAssertEqual(reads("cd /repo && nl -ba .codex/skills/intake/SKILL.md | head -50"), ["intake"])
        XCTAssertEqual(reads("cat /Users/me/.codex/plugins/cache/openai-curated-remote/figma/17.0.0/skills/figma-use/SKILL.md"), ["figma-use"])
        XCTAssertEqual(reads("sed -n 1,80p ~/.claude/skills/a/SKILL.md; sed -n 1,80p ~/.claude/skills/b/SKILL.md"), ["a", "b"])
        XCTAssertEqual(reads("cat ~/.codex/skills/a/SKILL.md ~/.codex/skills/a/SKILL.md"), ["a"], "One command reading a file twice is one load")
    }

    func testWritesCopiesAndLookalikesAreNotLoads() {
        XCTAssertEqual(reads("cat > ~/.codex/skills/new-skill/SKILL.md <<'EOF'"), [])
        XCTAssertEqual(edits("cat > ~/.codex/skills/new-skill/SKILL.md <<'EOF'"), ["new-skill"])
        XCTAssertEqual(edits("cp /tmp/draft/SKILL.md ~/.codex/skills/bar/SKILL.md"), ["bar"])
        XCTAssertEqual(reads("cat /Users/me/.config/sample/skill-before/SKILL.md"), [], "A copy outside a skills folder isn't a skill")
        XCTAssertEqual(reads("rg -n foo ~/.codex/skills/*/SKILL.md"), [], "Globs name no single skill")
        XCTAssertEqual(reads("ls ~/.codex/skills/a/SKILL.md"), [], "Listing isn't reading")
        XCTAssertEqual(reads("python3 tools/check.py"), [])
    }

    func testKeysJoinPluginNamespacesAndCase() {
        XCTAssertEqual(SkillReference.key("anthropic-skills:pdf"), "pdf")
        XCTAssertEqual(SkillReference.key("Release-Sample-Site"), "release-sample-site")
        XCTAssertNil(SkillReference.sanitizedName("../etc/passwd"))
        XCTAssertNil(SkillReference.sanitizedName("two words"))
        XCTAssertEqual(SkillReference.name(forSkillDirectory: "/private/tmp/claude-501/bundled-skills/2.1.227/abc/dataviz"), "dataviz")
    }

    func testFrontMatterReadsPlainQuotedAndFoldedValues() {
        XCTAssertEqual(SkillFrontMatter.parse("---\nname: pdf\ndescription: Read and write PDFs.\n---\n# Body").name, "pdf")
        XCTAssertEqual(SkillFrontMatter.parse("---\nname: \"x\"\ndescription: 'Quoted: yes'\n---").description, "Quoted: yes")
        XCTAssertEqual(SkillFrontMatter.parse("---\nname: y\ndescription: >\n  First line\n  second line\nlicense: MIT\n---").description, "First line second line")
        XCTAssertNil(SkillFrontMatter.parse("# No front matter\nname: z").name)
    }

    func testMergingKeepsEarlierUsesAndFillsMeasuredSize() {
        let early = ActivityTurn(id: "t", status: "completed", skills: [ActivitySkillUse(id: "a", name: "pdf", trigger: .tool, loadedCharacters: 4_000)])
        var tail = early
        tail.skills = [ActivitySkillUse(id: "b", name: "docx", trigger: .tool)]
        XCTAssertEqual(early.merging(tail).skills?.map(\.id), ["a", "b"])
        var unmeasured = early
        unmeasured.skills = nil
        XCTAssertEqual(early.merging(unmeasured).skills?.first?.loadedCharacters, 4_000, "Missing fields never erase evidence")
        let legacy = ActivityTurn(id: "t", status: "completed")
        XCTAssertEqual(legacy.merging(early).skills?.count, 1)
    }
}

final class SkillCollectorTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-collector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func stamp(_ offset: Double) -> String { ISO8601.withFractional.string(from: now.addingTimeInterval(offset)) }

    func testClaudeRecordsSkillToolLoadsSlashCommandsAndInjectedSizeOnly() async throws {
        let skillText = "Base directory for this skill: /Users/me/.claude/skills/dataviz\n\n# Data visualization\nPRIVATE_SKILL_BODY " + String(repeating: "x", count: 3_960)
        let rows: [[String: Any]] = [
            ["type": "user", "sessionId": "s", "cwd": "/projects/app", "timestamp": stamp(-30), "uuid": "p1",
             "message": ["role": "user", "content": "make a chart"]],
            ["type": "assistant", "sessionId": "s", "cwd": "/projects/app", "timestamp": stamp(-29), "requestId": "r1",
             "message": ["id": "m1", "role": "assistant", "model": "claude-sonnet-5", "stop_reason": "tool_use",
                         "content": [["type": "tool_use", "id": "toolu_1", "name": "Skill", "input": ["skill": "dataviz", "args": "PRIVATE_ARGS"]]],
                         "usage": ["input_tokens": 1, "output_tokens": 1]]],
            ["type": "user", "sessionId": "s", "cwd": "/projects/app", "timestamp": stamp(-28), "uuid": "res1", "sourceToolAssistantUUID": "a1",
             "toolUseResult": ["success": true], "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "Launching skill: dataviz"]]]],
            ["type": "user", "sessionId": "s", "cwd": "/projects/app", "timestamp": stamp(-28), "uuid": "meta1", "isMeta": true, "sourceToolUseID": "toolu_1",
             "message": ["role": "user", "content": [["type": "text", "text": skillText]]]],
            ["type": "user", "sessionId": "s", "cwd": "/projects/app", "timestamp": stamp(-10), "uuid": "p2",
             "message": ["role": "user", "content": "<command-name>/review-pr</command-name>"]],
            ["type": "user", "sessionId": "s", "cwd": "/projects/app", "timestamp": stamp(-10), "uuid": "meta2", "isMeta": true,
             "message": ["role": "user", "content": [["type": "text", "text": "Base directory for this skill: /projects/app/.claude/skills/review-pr\n\nSteps"]]]],
            ["type": "assistant", "sessionId": "s", "cwd": "/projects/app", "timestamp": stamp(-9), "requestId": "r2",
             "message": ["id": "m2", "role": "assistant", "model": "claude-sonnet-5", "stop_reason": "end_turn",
                         "content": [["type": "text", "text": "done"]], "usage": ["input_tokens": 1, "output_tokens": 1]]],
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: root.appendingPathComponent("s.jsonl"))
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        let session = try XCTUnwrap(collection.sessions.first)
        let uses = session.turns.flatMap { $0.skills ?? [] }
        XCTAssertEqual(uses.map(\.name).sorted(), ["dataviz", "review-pr"])
        let tool = try XCTUnwrap(uses.first { $0.name == "dataviz" })
        XCTAssertEqual(tool.trigger, .tool)
        XCTAssertEqual(tool.loadedCharacters, skillText.count)
        XCTAssertEqual(uses.first { $0.name == "review-pr" }?.trigger, .command)
        XCTAssertEqual(session.turns.first { $0.id.hasSuffix("r2") }?.skills?.map(\.name), ["review-pr"], "A slash skill belongs to the response it started")
        XCTAssertEqual(session.turns.reduce(0) { $0 + ($1.promptCount ?? 0) }, 2, "Injected skill text is not a prompt")
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_"))
    }

    func testCodexTranscriptRecordsSkillReadsWithTimesAndDiscardsCommands() throws {
        var transcript = CodexActivityTranscript()
        transcript.consume(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "t", "started_at": 100]])
        let read: [String: Any] = ["type": "event_msg", "timestamp": "2026-11-03T07:39:04.963Z", "payload": ["type": "item_completed", "turn_id": "t",
            "item": ["type": "CommandExecution", "id": "exec-1", "command": ["/bin/zsh", "-lc", "cat /Users/me/.codex/skills/release-app/SKILL.md PRIVATE_FILE"],
                     "aggregated_output": "PRIVATE_SKILL_TEXT"]]]
        transcript.consume(read)
        transcript.consume(read)
        transcript.consume(["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "t",
            "item": ["type": "FileChange", "id": "patch-1", "changes": [["path": "/Users/me/.codex/skills/release-app/SKILL.md", "diff": "PRIVATE_DIFF"]]]]])
        let turn = try XCTUnwrap(CodexActivityParser.turn(["id": "t", "items": [], "itemsView": "summary"], telemetry: transcript))
        let skills = try XCTUnwrap(turn.skills)
        XCTAssertEqual(skills.filter(\.isLoad).map(\.name), ["release-app"])
        XCTAssertEqual(skills.filter { !$0.isLoad }.map(\.name), ["release-app"])
        XCTAssertNotNil(skills.first { $0.isLoad }?.timestamp)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(turn), as: UTF8.self).contains("PRIVATE_"))

        let full = try XCTUnwrap(CodexActivityParser.turn(["id": "u", "status": "completed", "itemsView": "full", "items": [
            ["id": "c1", "type": "commandExecution", "command": "sed -n '1,200p' /Users/me/.codex/skills/playwright/SKILL.md"],
        ]]))
        XCTAssertEqual(full.skills?.map(\.name), ["playwright"])
        let none = try XCTUnwrap(CodexActivityParser.turn(["id": "v", "status": "completed", "itemsView": "full", "items": []]))
        XCTAssertEqual(none.skills, [], "A full item view measures zero skills")
    }

    func testCatalogReadsEachAgentsFoldersAndOnlyTheListedCodexPluginVersion() async throws {
        func skill(_ path: String, _ body: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        try skill(".claude/skills/shared/SKILL.md", "---\nname: shared\ndescription: Claude copy\n---\nA")
        try skill(".codex/skills/shared/SKILL.md", "---\nname: shared\ndescription: Codex copy\n---\nB")
        try skill(".codex/skills/shared/scripts/run.sh", "echo")
        try skill(".codex/skills/.system/skill-creator/SKILL.md", "---\nname: skill-creator\ndescription: Make skills\n---")
        try skill(".codex/plugins/cache/market/figma/1.0.0/skills/figma-use/SKILL.md", "---\nname: figma-use\ndescription: old\n---")
        try skill(".codex/plugins/cache/market/figma/2.0.0/skills/figma-use/SKILL.md", "---\nname: figma-use\ndescription: new\n---")
        try skill(".codex/plugins/cache/market/expo/1.0.0/skills/expo-run/SKILL.md", "---\nname: expo-run\ndescription: off\n---")
        let project = root.appendingPathComponent("work/app")
        try skill("work/app/.claude/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Ship it\n---")
        let listed = root.appendingPathComponent(".codex/plugins/cache/market/figma/2.0.0/skills/figma-use/SKILL.md").path
        let line = #"{"type":"world_state","payload":{"host_skills":{"version":1,"entries":{"[\"host\",\"host\",\"\#(listed)\"]":{"fingerprint":"f","shown":true}}}}}"#
        try skill(".codex/sessions/2026/11/05/rollout-1.jsonl", line + "\n")

        let catalog = await SkillCatalogReader(home: root).catalog(projects: [project.path], now: now)
        let byKey = Dictionary(grouping: catalog.skills, by: \.key)
        XCTAssertEqual(Set(byKey.keys), ["shared", "skill-creator", "figma-use", "deploy"], "Unlisted plugins are off")
        XCTAssertEqual(byKey["figma-use"]?.map(\.summary), ["new"])
        XCTAssertEqual(byKey["shared"]?.count, 2)
        XCTAssertEqual(byKey["shared"]?.first { $0.provider == .codex }?.supportingFiles, 1)
        XCTAssertEqual(byKey["skill-creator"]?.first?.scope, .system)
        XCTAssertEqual(byKey["deploy"]?.first?.scope, .project)
        XCTAssertEqual(byKey["deploy"]?.first?.owner, project.path)
    }
}

final class SkillReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    private func installed(_ name: String, _ provider: AgentName, scope: InstalledSkill.Scope = .personal, bytes: Int = 4_000,
                           fingerprint: String = "same", modified: Date? = nil) -> InstalledSkill {
        InstalledSkill(key: name, name: name, summary: "\(name) helps", provider: provider, scope: scope,
                       path: "/home/.\(provider.rawValue)/skills/\(name)/SKILL.md", bytes: bytes, modifiedAt: modified ?? now.addingTimeInterval(-40 * 86_400),
                       fingerprint: fingerprint)
    }

    private func session(_ id: String, _ provider: AgentName, project: String = "/work/slim", loads: [(String, Double)], status: String = "completed") -> ActivitySession {
        var turns: [ActivityTurn] = []
        for (index, load) in loads.enumerated() {
            let at = now.addingTimeInterval(load.1)
            turns.append(ActivityTurn(id: "\(id):t\(index)", startedAt: at, completedAt: at.addingTimeInterval(60), durationSeconds: 60, status: status,
                                      artifacts: [ActivityArtifact(id: "\(id):a\(index)", path: "src/file\(index).swift")],
                                      skills: [ActivitySkillUse(id: "\(id):u\(index)", name: load.0, trigger: provider == .codex ? .read : .tool, timestamp: at)]))
        }
        if loads.isEmpty {
            turns.append(ActivityTurn(id: "\(id):t0", startedAt: now.addingTimeInterval(-3_600), status: "completed", skills: []))
        }
        return ActivitySession(id: id, provider: provider, nativeID: id, title: id, projectPath: project, createdAt: now.addingTimeInterval(-86_400),
                               updatedAt: now, turns: turns, historyComplete: true, source: "test")
    }

    func testJoinsCatalogAndLoadsAndFindsWhatNeedsALook() {
        let catalog = SkillCatalog(skills: [
            installed("release", .codex),
            installed("bridge", .claude, fingerprint: "c1"), installed("bridge", .codex, fingerprint: "x2"),
            installed("idle-one", .codex), installed("figma-use", .codex, scope: .plugin),
        ], scannedAt: now)
        let sessions = [
            session("codex:a", .codex, loads: [("release", -7_200), ("release", -7_000), ("release", -6_900), ("release", -6_800)]),
            session("codex:b", .codex, loads: [("release", -3_000), ("release", -2_900), ("release", -2_800)]),
            session("claude:c", .claude, loads: [("anthropic-skills:pdf", -1_000)]),
            session("claude:d", .claude, loads: []),
        ]
        let report = SkillReport.build(.init(sessions: sessions, catalog: catalog, from: now.addingTimeInterval(-7 * 86_400), to: now))
        let release = try! XCTUnwrap(report.rows.first)
        XCTAssertEqual(release.id, "release")
        XCTAssertEqual(release.loads, 7)
        XCTAssertEqual(release.sessions, 2)
        XCTAssertEqual(release.turns, 7)
        XCTAssertEqual(release.tokensPerLoad, 1_000)
        XCTAssertEqual(release.tokensLoaded, 7_000)
        XCTAssertEqual(release.outcomes.finished, 7)
        XCTAssertEqual(release.missingSessions[.claude], 2, "Claude worked in the same project without the skill")
        XCTAssertEqual(release.buckets.reduce(0, +), 7)

        let pdf = try! XCTUnwrap(report.rows.first { $0.id == "pdf" })
        XCTAssertTrue(pdf.copies.isEmpty, "Loaded skills from elsewhere still appear")
        XCTAssertNil(pdf.scope)
        XCTAssertTrue(report.rows.first { $0.id == "bridge" }!.copiesDiffer)
        XCTAssertFalse(report.rows.first { $0.id == "idle-one" }!.isUsed)

        XCTAssertEqual(report.totals.installed, 4)
        XCTAssertEqual(report.totals.used, 2)
        XCTAssertEqual(report.totals.installedUsed, 1, "pdf was loaded from elsewhere")
        XCTAssertEqual(report.totals.loads, 8)
        XCTAssertEqual(report.totals.loadsByProvider[.codex], 7)
        XCTAssertEqual(report.totals.idleOwned, 2, "bridge and idle-one are personal and unused")
        let kinds = report.insights.map(\.highlight.kind)
        XCTAssertEqual(kinds.first, .skillGap)
        XCTAssertTrue(kinds.contains(.skillReread))
        XCTAssertTrue(kinds.contains(.skillDrift))
        XCTAssertLessThanOrEqual(kinds.count, 4)
        XCTAssertEqual(report.insights.first?.skillKey, "release")
    }

    func testProviderAndProjectFiltersApplyToTheCatalog() {
        let catalog = SkillCatalog(skills: [
            installed("a", .claude), installed("b", .codex),
            InstalledSkill(key: "c", name: "c", summary: "", provider: .codex, scope: .project, owner: "/work/other", path: "/work/other/.codex/skills/c/SKILL.md", bytes: 10, fingerprint: "f"),
        ], scannedAt: now)
        let codexOnly = SkillReport.build(.init(sessions: [], catalog: catalog, from: nil, to: now, provider: "codex", project: "/work/slim"))
        XCTAssertEqual(codexOnly.rows.map(\.id), ["b"])
        let everything = SkillReport.build(.init(sessions: [], catalog: catalog, from: nil, to: now))
        XCTAssertEqual(Set(everything.rows.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(everything.totals.listingTokens[.codex], installed("b", .codex).listingTokens, "Project skills aren't in every session's list")
    }

    func testUnmeasuredTurnsAreCoverageNotZeroLoads() {
        var legacy = session("codex:old", .codex, loads: [])
        legacy.turns = [ActivityTurn(id: "codex:old:t", startedAt: now.addingTimeInterval(-600), status: "completed")]
        let report = SkillReport.build(.init(sessions: [legacy], catalog: .empty, from: now.addingTimeInterval(-86_400), to: now, hourly: true))
        XCTAssertEqual(report.totals.turnsInPeriod, 1)
        XCTAssertEqual(report.totals.turnsMeasured, 0)
        XCTAssertTrue(report.coverage.contains { $0.contains("before skill tracking") })
        XCTAssertEqual(report.bucketStarts.count, 24)
    }
}
