@testable import BridgeCore
import Foundation
import XCTest

final class GitLineCountTests: XCTestCase {
    func testNumstatHistoryCarriesLinesFilesAndAgentCoAuthors() throws {
        let raw = "\u{1e}aaa111\u{1f}1790000000\u{1f}Add skills page\u{1f}Claude Opus 5.5 <noreply@anthropic.com>\u{1d}Sam <sam@example.com>\n\n"
            + "120\t4\tSources/Skills.swift\n-\t-\tAssets/icon.png\n30\t0\tpackage-lock.json\n2\t1\tsrc/{old => new}/Name.swift\n"
            + "\u{1e}bbb222\u{1f}1790003600\u{1f}Empty merge note\u{1f}\n\n"
        let commits = ActivityGitReader.commits(raw)
        XCTAssertEqual(commits.count, 2)
        let first = try XCTUnwrap(commits.first)
        XCTAssertEqual(first.additions, 152)
        XCTAssertEqual(first.deletions, 5)
        XCTAssertEqual(first.filesChanged, 4)
        XCTAssertEqual(first.coAuthors, [.claude])
        XCTAssertEqual(first.paths, ["Sources/Skills.swift", "Assets/icon.png", "package-lock.json", "src/new/Name.swift"])
        XCTAssertNil(first.files?[1].additions, "Binary files have no line counts")
        XCTAssertEqual(commits[1].linesChanged, 0, "A counted commit with no files changed nothing")
        XCTAssertNil(ActivityGitReader.commits(raw, countsLines: false)[1].additions, "Without counts, nothing is claimed")
    }

    func testShortstatRenamesAndCoAuthorNames() {
        let totals = ActivityGitReader.shortstat(" 3 files changed, 10 insertions(+), 2 deletions(-)")
        XCTAssertEqual(totals?.files, 3); XCTAssertEqual(totals?.additions, 10); XCTAssertEqual(totals?.deletions, 2)
        XCTAssertEqual(ActivityGitReader.shortstat(" 1 file changed, 1 deletion(-)")?.additions, 0)
        XCTAssertEqual(ActivityGitReader.renamedPath("docs/{a.md => b.md}"), "docs/b.md")
        XCTAssertEqual(ActivityGitReader.renamedPath("{lib => src}/x.swift"), "src/x.swift")
        XCTAssertEqual(ActivityGitReader.renamedPath("old.txt => new.txt"), "new.txt")
        XCTAssertEqual(ActivityGitReader.coAuthors("Codex <codex@openai.com>\u{1d}Claude Sonnet <noreply@anthropic.com>"), [.claude, .codex])
        XCTAssertEqual(ActivityGitReader.coAuthors("Jordan <j@example.com>"), [])
        // The older header-only format still parses.
        XCTAssertEqual(ActivityGitReader.commits("abc\u{1f}1788000000\u{1f}Build artifact\u{1e}").first?.additions, nil)
    }
}

final class ShippedCodeReportTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let home = "/Users/tester"

    private func session(_ id: String, _ provider: AgentName, path: String, start: Double, end: Double, edits: [String] = []) -> ActivitySession {
        let artifacts = edits.enumerated().map { ActivityArtifact(id: "\(id)-\($0.offset)", path: $0.element, status: "edit_requested") }
        let turn = ActivityTurn(id: "\(id):t", startedAt: base.addingTimeInterval(start), completedAt: base.addingTimeInterval(end), status: "completed", artifacts: artifacts)
        return ActivitySession(id: id, provider: provider, nativeID: id, title: id, projectPath: path, createdAt: base.addingTimeInterval(start),
                               updatedAt: base.addingTimeInterval(end), turns: [turn], source: "fixture")
    }

    private func commit(_ id: String, at offset: Double, files: [(String, Int, Int)], coAuthors: [AgentName] = []) -> ActivityCommit {
        ActivityCommit(id: id, subject: "Commit \(id)", timestamp: base.addingTimeInterval(offset), paths: files.map(\.0),
                       additions: files.reduce(0) { $0 + $1.1 }, deletions: files.reduce(0) { $0 + $1.2 }, filesChanged: files.count,
                       files: files.map { ActivityCommitFile(path: $0.0, additions: $0.1, deletions: $0.2) }, coAuthors: coAuthors)
    }

    func testCommitsLinkToSessionsByTheStrongestEvidence() throws {
        let repo = ActivityRepository(id: "/repo/.git", name: "repo", root: "/repo",
                                      worktrees: [ActivityWorktree(path: "/repo"), ActivityWorktree(path: "/worktrees/repo-feature")],
                                      commits: [
                                        commit("c1", at: 500, files: [("Sources/A.swift", 100, 10)], coAuthors: [.claude]),
                                        commit("c2", at: 1_500, files: [("Sources/B.swift", 40, 4), ("package-lock.json", 300, 200)]),
                                        commit("c3", at: 2_200, files: [("README.md", 5, 1)]),
                                        commit("c4", at: 90_000, files: [("Late.swift", 7, 0)]),
                                      ],
                                      observedAt: base.addingTimeInterval(100_000), commitHistoryAvailable: true)
        let sessions = [
            session("claude-1", .claude, path: "/repo/app", start: 0, end: 1_000, edits: ["Sources/A.swift"].map { "../" + $0 }),
            session("codex-1", .codex, path: "/worktrees/repo-feature", start: 1_000, end: 2_000, edits: ["\(home)/x", "/worktrees/repo-feature/Sources/B.swift"]),
            session("codex-idle", .codex, path: "/repo", start: 50_000, end: 51_000),
            session("elsewhere", .claude, path: "/other", start: 0, end: 1_000),
        ]
        let result = ShippedCodeReport.build(.init(sessions: sessions, repositories: [repo], from: nil, to: base.addingTimeInterval(200_000),
                                                   tokensBySession: ["claude-1": 6_000, "codex-1": 3_000, "codex-idle": 1_000, "elsewhere": 9_999], home: home))
        let byID = Dictionary(uniqueKeysWithValues: result.commits.map { ($0.commit.id, $0) })
        XCTAssertEqual(byID["c1"]?.link, .coAuthored)
        XCTAssertEqual(byID["c1"]?.sessionIDs, ["claude-1"])
        XCTAssertEqual(byID["c2"]?.link, .sameFiles, "A worktree session that edited the file")
        XCTAssertEqual(byID["c2"]?.sessionIDs, ["codex-1"])
        XCTAssertEqual(byID["c3"]?.link, .duringSession, "Within two hours of the session's last activity")
        XCTAssertNil(byID["c4"]?.link, "Nothing was running")
        let totals = result.totals
        XCTAssertEqual(totals.commits, 4)
        XCTAssertEqual(totals.linkedCommits, 3)
        XCTAssertEqual(totals.lines.additions, 452)
        XCTAssertEqual(totals.lines.deletions, 215)
        XCTAssertEqual(totals.generatedLines.total, 500)
        XCTAssertEqual(totals.sessions, 3, "Sessions outside scanned repositories don't count")
        XCTAssertEqual(totals.sessionsWithCommits, 2)
        XCTAssertEqual(totals.tokensWithoutCommits, 1_000)
        XCTAssertEqual(totals.tokens, 10_000)
        XCTAssertEqual(try XCTUnwrap(totals.tokensPerLine), 10_000.0 / 660.0, accuracy: 0.001)
        XCTAssertEqual(result.sessions["claude-1"]?.lines.additions, 105, "Its co-authored commit and the one during it")
        XCTAssertEqual(result.project(containing: "/worktrees/repo-feature/sub")?.id, repo.id)
        XCTAssertEqual(totals.coAuthoredByAgent[.claude], 1)
    }

    func testSessionsStartedAboveARepositoryJoinItThroughTheFilesTheyEdit() {
        let repo = ActivityRepository(id: "/work/app/.git", name: "app", root: "/work/app",
                                      commits: [commit("c1", at: 100, files: [("Sources/X.swift", 9, 1)])], observedAt: base, commitHistoryAvailable: true)
        let parent = session("codex-parent", .codex, path: "/work", start: 0, end: 200, edits: ["/work/app/Sources/X.swift"])
        let unrelated = session("codex-other", .codex, path: "/work", start: 0, end: 200, edits: ["/work/notes.md"])
        let result = ShippedCodeReport.build(.init(sessions: [parent, unrelated], repositories: [repo], from: nil, to: base.addingTimeInterval(1_000)))
        XCTAssertEqual(result.commits.first?.link, .sameFiles)
        XCTAssertEqual(result.commits.first?.sessionIDs, ["codex-parent"])
        XCTAssertEqual(result.totals.sessions, 1, "Edits elsewhere keep a parent-folder session out")
        // With no recorded edits, the one repository inside its folder is where it worked.
        let quiet = session("codex-quiet", .codex, path: "/work", start: 0, end: 200)
        let byTime = ShippedCodeReport.build(.init(sessions: [quiet], repositories: [repo], from: nil, to: base.addingTimeInterval(1_000)))
        XCTAssertEqual(byTime.commits.first?.link, .duringSession)
        let second = ActivityRepository(id: "/work/lib/.git", name: "lib", root: "/work/lib", observedAt: base, commitHistoryAvailable: true)
        let ambiguous = ShippedCodeReport.build(.init(sessions: [quiet], repositories: [repo, second], from: nil, to: base.addingTimeInterval(1_000)))
        XCTAssertNil(ambiguous.commits.first?.link, "Two repositories in its folder: no guess")
    }

    func testUnreadHistoryIsNotAZeroAndPeriodsBoundCommits() {
        let unread = ActivityRepository(id: "/x", name: "x", root: "/x", observedAt: base, commitHistoryAvailable: false)
        let repo = ActivityRepository(id: "/repo/.git", name: "repo", root: "/repo",
                                      commits: [commit("old", at: -86_400 * 3, files: [("a", 1, 1)]), commit("new", at: 10, files: [("b", 2, 0)])],
                                      observedAt: base, commitHistoryAvailable: true)
        let sessions = [session("s", .claude, path: "/x", start: 0, end: 10)]
        let result = ShippedCodeReport.build(.init(sessions: sessions, repositories: [unread, repo], from: base.addingTimeInterval(-60), to: base.addingTimeInterval(60)))
        XCTAssertEqual(result.totals.unavailableRepositories, 1)
        XCTAssertEqual(result.totals.repositories, 1)
        XCTAssertEqual(result.totals.commits, 1, "Only commits inside the period")
        XCTAssertEqual(result.totals.lines.additions, 2)
        XCTAssertEqual(ShippedCodeReport.linesLabel(.init(additions: 158_031, deletions: 16_874)), "+\(158_031.formatted()) / −\(16_874.formatted())")
        XCTAssertTrue(ShippedCodeReport.isGenerated("web/yarn.lock"))
        XCTAssertFalse(ShippedCodeReport.isGenerated("Sources/App.swift"))
    }
}

final class ContextFileHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testVersionsCountChangedLinesWithoutKeepingText() throws {
        let history = ContextFileHistory(url: nil)
        let first = Data("# Rules\nUse tabs.\nRun make check.\n".utf8)
        history.observe(path: "/p/AGENTS.md", data: first, modifiedAt: now, now: now)
        history.observe(path: "/p/AGENTS.md", data: first, modifiedAt: now.addingTimeInterval(5), now: now.addingTimeInterval(5))
        XCTAssertEqual(history.records(for: ["/p/AGENTS.md"])["/p/AGENTS.md"]?.versions.count, 1, "Unchanged contents add no version")
        let second = Data("# Rules\nUse spaces.\nRun make check.\nAdd tests.\n".utf8)
        let record = history.observe(path: "/p/AGENTS.md", data: second, modifiedAt: now.addingTimeInterval(60), now: now.addingTimeInterval(70))
        XCTAssertEqual(record.versions.count, 2)
        XCTAssertNil(record.versions[0].added, "Earlier history of the first version isn't known")
        XCTAssertEqual(record.versions[1].added, 2)
        XCTAssertEqual(record.versions[1].removed, 1)
        XCTAssertEqual(record.versions[1].lines, 4)
        XCTAssertEqual(record.versions[1].changedAt, now.addingTimeInterval(60), "Dated by the file, not by when it was read")
        let encoded = String(decoding: try BridgeJSON.compactEncoder.encode(record), as: UTF8.self)
        XCTAssertFalse(encoded.contains("spaces"))
        XCTAssertEqual(ContextFileHistory.difference(old: [1, 2, 2, 3], new: [2, 3, 1, 4]).added, 1, "Moved lines are unchanged")
    }

    func testHistoryPersistsAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("context-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = ContextFileHistory(url: url)
        writer.observe(path: "/p/SKILL.md", data: Data("a\nb\n".utf8), modifiedAt: now, now: now)
        writer.observe(path: "/p/SKILL.md", data: Data("a\nc\n".utf8), modifiedAt: now.addingTimeInterval(1), now: now.addingTimeInterval(1))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        let reader = ContextFileHistory(url: url)
        let record = try XCTUnwrap(reader.records(for: ["/p/SKILL.md"])["/p/SKILL.md"])
        XCTAssertEqual(record.versions.count, 2)
        // The stored salt carries over, so the next change still diffs correctly.
        let third = reader.observe(path: "/p/SKILL.md", data: Data("a\nc\nd\n".utf8), modifiedAt: now.addingTimeInterval(2), now: now.addingTimeInterval(2))
        XCTAssertEqual(third.versions.last?.added, 1)
        XCTAssertEqual(third.versions.last?.removed, 0)
    }

    func testTimelineFoldsMatchingCommitsAndAddsOlderGitHistory() {
        let history = ContextFileHistory(url: nil)
        history.observe(path: "/repo/AGENTS.md", data: Data("a\nb\n".utf8), modifiedAt: now, now: now)
        history.observe(path: "/repo/AGENTS.md", data: Data("a\nb\nc\nd\n".utf8), modifiedAt: now.addingTimeInterval(3_600), now: now.addingTimeInterval(3_600))
        let record = history.records(for: ["/repo/AGENTS.md"])["/repo/AGENTS.md"]
        let repo = ActivityRepository(id: "/repo/.git", name: "repo", root: "/repo", commits: [
            ActivityCommit(id: "match111", subject: "Add two rules", timestamp: now.addingTimeInterval(3_700), paths: ["AGENTS.md"], additions: 2, deletions: 0,
                           filesChanged: 1, files: [ActivityCommitFile(path: "AGENTS.md", additions: 2, deletions: 0)], coAuthors: [.codex]),
            ActivityCommit(id: "older222", subject: "Create rules", timestamp: now.addingTimeInterval(-86_400 * 5), paths: ["AGENTS.md"], additions: 2, deletions: 0,
                           filesChanged: 1, files: [ActivityCommitFile(path: "AGENTS.md", additions: 2, deletions: 0)]),
            ActivityCommit(id: "other333", subject: "Unrelated", timestamp: now, paths: ["x.swift"], additions: 1, deletions: 0,
                           filesChanged: 1, files: [ActivityCommitFile(path: "x.swift", additions: 1, deletions: 0)]),
        ], observedAt: now, commitHistoryAvailable: true)
        let changes = ContextFileTimeline.changes(path: "/repo/AGENTS.md", record: record, repositories: [repo], now: now.addingTimeInterval(7_200))
        XCTAssertEqual(changes.map(\.version), [2, 1, nil])
        XCTAssertEqual(changes[0].commitID, "match111", "The commit is the same change as version 2")
        XCTAssertEqual(changes[0].coAuthors, [.codex])
        XCTAssertTrue(changes[0].isCurrent)
        XCTAssertEqual(changes[2].commitID, "older222")
        XCTAssertEqual(changes[0].validUntil, now.addingTimeInterval(7_200))
        XCTAssertEqual(changes[1].validUntil, changes[0].date)
    }

    func testCatalogReadersRecordVersionsOnlyWhenGivenAHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("home/.claude/skills/demo/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo skill\n---\nStep one\n".write(to: skill, atomically: true, encoding: .utf8)
        let history = ContextFileHistory(url: nil)
        let catalog = await SkillCatalogReader(home: root.appendingPathComponent("home"), history: history).catalog(projects: [])
        XCTAssertEqual(catalog.history.count, 1)
        XCTAssertEqual(catalog.history.values.first?.versions.count, 1)
        let untracked = await SkillCatalogReader(home: root.appendingPathComponent("home")).catalog(projects: [])
        XCTAssertTrue(untracked.history.isEmpty)
    }
}
