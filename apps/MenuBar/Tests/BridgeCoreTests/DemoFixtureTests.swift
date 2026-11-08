import Foundation
import XCTest
@testable import BridgeCore

/// Invented activity for the README screenshots, and for trying the Hub on a
/// Mac with no agent history. Nothing here is read from disk: projects live
/// under /Users/example, titles and goals are generic, and the same seed always
/// produces the same weeks. Write it with `make screenshots` or:
///   BRIDGE_DEMO_FIXTURE_OUT=/absolute/path.json swift test --filter DemoFixtureTests
enum DemoActivity {
    struct Project {
        var name: String
        var claudeShare: Double
        var titles: [String]
        var files: [String]
        var path: String { "/Users/example/code/\(name)" }
    }

    static let projects: [Project] = [
        Project(name: "storefront-web", claudeShare: 0.55,
                titles: ["Add checkout retry with backoff", "Fix cart total rounding", "Responsive product grid", "Speed up image loading", "Add order history filters", "Tidy checkout form validation", "Lazy-load the reviews widget", "Fix sticky header on iOS", "Add wishlist sharing", "Replace the date picker", "Cache product search results", "Improve the 404 page", "Add a promo code field", "Fix flicker on route change", "Split the checkout bundle", "Add keyboard navigation to the menu"],
                files: ["src/checkout/retry.ts", "src/cart/totals.ts", "src/components/ProductGrid.tsx", "src/pages/orders.tsx", "tests/checkout.test.ts"]),
        Project(name: "ledger-api", claudeShare: 0.15,
                titles: ["Add idempotency keys to payments", "Paginate the transactions endpoint", "Migrate the invoices table", "Fix timezone bug in monthly reports", "Add an audit log for refunds", "Rate limit the export endpoint", "Index slow ledger queries", "Add currency rounding tests", "Handle duplicate webhook deliveries", "Soft-delete closed accounts", "Add CSV export for statements", "Fix N+1 in the balances view", "Validate IBAN input", "Retry failed payouts", "Document error codes", "Remove the legacy v1 routes"],
                files: ["app/payments.py", "app/reports.py", "migrations/0042_invoices.sql", "tests/test_payments.py", "app/audit.py"]),
        Project(name: "mobile-app", claudeShare: 0.4,
                titles: ["Offline mode for saved items", "Fix crash on rotation", "Notification settings screen", "Dark mode polish", "Speed up app launch", "Add biometric unlock", "Fix keyboard overlap on the login form", "Cache profile images", "Add pull to refresh", "Localize the onboarding flow", "Fix scroll jank in the feed", "Add an accessibility pass", "Update the share sheet", "Handle low storage gracefully"],
                files: ["Sources/Offline/Store.swift", "Sources/Settings/Notifications.swift", "Sources/Theme/Colors.swift", "Tests/StoreTests.swift"]),
        Project(name: "docs-site", claudeShare: 0.65,
                titles: ["Rewrite the getting started guide", "Fix broken links", "Add API reference for webhooks", "Add a troubleshooting page", "Improve search ranking", "Add code samples in three languages", "Fix the mobile navigation", "Document rate limits", "Add a changelog page", "Redesign the landing page hero", "Add a glossary", "Fix dark mode code blocks"],
                files: ["docs/getting-started.md", "docs/webhooks.md", "docs/index.md"]),
        Project(name: "infra-scripts", claudeShare: 0.3,
                titles: ["Rotate staging certificates", "Speed up the CI cache", "Add a deploy dry-run flag", "Add a nightly backup check", "Cut the Docker image size", "Pin action versions", "Add a rollback script", "Alert on failed cron jobs", "Clean up stale branches", "Add health checks to deploy", "Document the release process", "Parallelize the lint job"],
                files: ["scripts/deploy.sh", ".github/workflows/ci.yml", "scripts/rotate-certs.sh"]),
    ]

    static let claudeModels: [(String, Double)] = [("claude-sonnet-5-5", 0.55), ("claude-opus-5-5", 0.33), ("claude-haiku-5-5", 0.12)]
    static let codexModels: [(String, Double)] = [("gpt-6.1-terra", 0.45), ("gpt-6.1-sol", 0.35), ("gpt-6-astra", 0.20)]
    static var allModels: Set<String> { Set((claudeModels + codexModels).map(\.0)) }

    static let goalObjectives = [
        "Ship idempotency keys for the payments API: add the column, enforce it in the handler, backfill existing rows, and keep every test green. Stop when verified.",
        "Make the checkout flow resilient to network failures with retries and clear error states, then verify with the full test suite.",
        "Add offline mode to the mobile app so saved items work without a connection. Build it, test it, stop when verified.",
        "Rewrite the getting started guide and fix every broken link in the docs site.",
    ]
    static let repeatPrefixes = ["Continue: ", "Review: ", "Add tests: ", "Polish: ", "Follow up: "]
    static let childTitles = ["Explore: find all call sites", "Review: changed files", "Explore: map the data model", "Check: run the test suite", "Research: compare retry libraries", "Explore: trace the failing request"]
    static let hourWeights: [Double] = [3, 1, 1, 0, 0, 0, 1, 2, 6, 12, 16, 16, 10, 9, 14, 16, 15, 12, 6, 5, 7, 7, 5, 3]

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    struct Dice {
        var generator: SplitMix
        init(seed: UInt64) { generator = SplitMix(state: seed) }
        mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &generator) }
        mutating func double(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &generator) }
        /// Whole seconds, so a saved fixture decodes to exactly what was generated.
        mutating func seconds(_ range: ClosedRange<Double>) -> Double { double(range).rounded() }
        mutating func chance(_ probability: Double) -> Bool { double(0 ... 1) < probability }
        mutating func pick<T>(_ items: [T]) -> T { items[int(0 ... items.count - 1)] }
        mutating func weighted<T>(_ items: [(T, Double)]) -> T {
            let total = items.reduce(0) { $0 + $1.1 }
            var roll = double(0 ... total)
            for (item, weight) in items {
                if roll <= weight { return item }
                roll -= weight
            }
            return items[items.count - 1].0
        }
        mutating func hex(_ length: Int) -> String {
            var text = ""
            while text.count < length { text += String(generator.next(), radix: 16) }
            return String(text.prefix(length))
        }
    }

    private static func add(_ a: TokenUsage, _ b: TokenUsage) -> TokenUsage {
        func sum(_ x: Int?, _ y: Int?) -> Int? { x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0) }
        return TokenUsage(input: sum(a.input, b.input), output: sum(a.output, b.output), cachedInput: sum(a.cachedInput, b.cachedInput),
                          cacheWriteInput: sum(a.cacheWriteInput, b.cacheWriteInput), reasoning: sum(a.reasoning, b.reasoning),
                          total: sum(a.total, b.total), provenance: .providerReported)
    }

    /// Claude reports cache reads and writes beside fresh input; Codex counts
    /// cached tokens inside its input. Both match what the collectors record.
    private static func stepUsage(_ provider: AgentName, _ dice: inout Dice) -> TokenUsage {
        if provider == .claude {
            let input = dice.int(5 ... 400), cached = dice.int(40_000 ... 320_000)
            let write = dice.int(200 ... 9_000), output = dice.int(250 ... 2_400)
            return TokenUsage(input: input, output: output, cachedInput: cached, cacheWriteInput: write, total: input + cached + write + output, provenance: .providerReported)
        }
        let input = dice.int(120_000 ... 460_000), output = dice.int(180 ... 950)
        let cached = Int(Double(input) * dice.double(0.90 ... 0.985))
        let reasoning = Int(Double(output) * dice.double(0.2 ... 0.7))
        return TokenUsage(input: input, output: output, cachedInput: cached, cacheWriteInput: 0, reasoning: reasoning, total: input + output, provenance: .providerReported)
    }

    private static func categories(_ provider: AgentName, tools: Int, _ dice: inout Dice) -> [String: Int] {
        let weights: [(String, Double)] = provider == .claude
            ? [("inspection", 0.38), ("implementation", 0.22), ("execution", 0.22), ("research", 0.06), ("delegation", 0.04), ("other", 0.08)]
            : [("research", 0.35), ("implementation", 0.20), ("tests", 0.15), ("review", 0.08), ("other tools", 0.22)]
        var counts: [String: Int] = [:]
        for _ in 0 ..< tools { counts[dice.weighted(weights), default: 0] += 1 }
        return counts
    }

    struct Built {
        var session: ActivitySession
        var project: Project
        var title: String
    }

    private static func turns(
        sessionID: String, provider: AgentName, project: Project, start: Date, count: Int, autonomous: Bool,
        primary: String, effort: String, running: Bool, now: Date, dice: inout Dice, durations: ClosedRange<Double>? = nil
    ) -> [ActivityTurn] {
        var result: [ActivityTurn] = []
        var cursor = start
        let alternatives = (provider == .claude ? claudeModels : codexModels).map(\.0)
        for index in 0 ..< count {
            if index > 0 { cursor = cursor.addingTimeInterval(autonomous ? dice.seconds(5 ... 40) : dice.seconds(60 ... 1_500)) }
            let duration = dice.seconds(durations ?? (autonomous ? 90 ... 900 : 20 ... 420))
            let begin = cursor
            var end = begin.addingTimeInterval(duration)
            guard begin < now.addingTimeInterval(-60) else { break }
            var inProgress = false
            if end > now {
                guard running else { break }
                end = now
                inProgress = true
            }
            let span = end.timeIntervalSince(begin)
            let stepCount = max(1, min(14, Int(span / dice.double(30 ... 70))))
            let model = dice.chance(0.88) ? primary : dice.pick(alternatives)
            var steps: [ActivityModelStep] = []
            var total = TokenUsage()
            for step in 0 ..< stepCount {
                let usage = stepUsage(provider, &dice)
                total = add(total, usage)
                let at = begin.addingTimeInterval((span * Double(step + 1) / Double(stepCount + 1)).rounded())
                steps.append(ActivityModelStep(id: "\(sessionID)-t\(index)-s\(step)", timestamp: at, model: model, effort: effort, usage: usage,
                                               evidence: provider == .claude ? "claude-message-usage/1" : "codex-usage-advance/1", usageIsPartial: false))
            }
            let tools = stepCount * dice.int(1 ... 3)
            let counts = categories(provider, tools: tools, &dice)
            var artifacts: [ActivityArtifact] = []
            if let edits = counts["implementation"], edits > 0 {
                for (offset, file) in project.files.shuffled(using: &dice.generator).prefix(min(edits, dice.int(1 ... 3))).enumerated() {
                    artifacts.append(ActivityArtifact(id: "\(sessionID)-t\(index)-f\(offset)", path: file, kind: "file", status: provider == .claude ? "edit_requested" : "observed"))
                }
            }
            var skills: [ActivitySkillUse]?
            if dice.chance(provider == .claude ? 0.15 : 0.10) {
                let name = dice.pick(["code-review", "frontend-design", "release-checklist"])
                skills = [provider == .claude
                    ? ActivitySkillUse(id: "\(sessionID)-t\(index)-skill", name: name, trigger: .tool, path: "/Users/example/.claude/skills/\(name)/SKILL.md", timestamp: begin, loadedCharacters: dice.int(3_000 ... 9_000))
                    : ActivitySkillUse(id: "\(sessionID)-t\(index)-skill", name: name, trigger: .read, path: "/Users/example/.codex/skills/\(name)/SKILL.md", timestamp: begin)]
            } else { skills = [] }
            result.append(ActivityTurn(
                id: "\(sessionID)-t\(index)", startedAt: begin, completedAt: inProgress ? nil : end, durationSeconds: inProgress ? nil : span,
                status: inProgress ? "inProgress" : "completed", promptCount: 1, humanPromptCount: autonomous && index > 0 ? 0 : 1, toolCount: tools,
                model: model, effort: effort, usage: total, categories: counts, artifacts: artifacts, usageIsPartial: false,
                modelSteps: steps, modelStepsComplete: !inProgress, skills: skills))
            cursor = end
        }
        return result
    }

    static func overview(now requested: Date, seed: UInt64 = 20_261_108) -> ActivityOverview {
        let now = Date(timeIntervalSince1970: requested.timeIntervalSince1970.rounded(.down))
        var dice = Dice(seed: seed)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let today = utc.startOfDay(for: now)
        var built: [Built] = []
        var serial = 0
        var used: [String: Int] = [:]

        func makeSession(project: Project, provider: AgentName, start: Date, turnCount: Int, goalObjective: String?, goalStatus: String, running: Bool, longRunning: Bool = false) {
            serial += 1
            let nativeID = "demo-\(String(format: "%03d", serial))"
            let id = "\(provider.rawValue):\(nativeID)"
            let primary = dice.weighted(provider == .claude ? claudeModels : codexModels)
            let effort = dice.weighted(provider == .claude
                ? [("high", 0.5), ("medium", 0.25), ("xhigh", 0.15), ("max", 0.10)]
                : [("high", 0.5), ("medium", 0.2), ("xhigh", 0.3)])
            var base = dice.pick(project.titles)
            // Prefer a title this project hasn't used yet; repeats read as follow-ups.
            for _ in 0 ..< 12 where used[project.name + base, default: 0] > 0 { base = dice.pick(project.titles) }
            let seen = used[project.name + base, default: 0]
            used[project.name + base] = seen + 1
            let title = seen == 0 ? base : (seen <= repeatPrefixes.count ? repeatPrefixes[seen - 1] + base : "\(base) (part \(seen + 1))")
            let list = turns(sessionID: id, provider: provider, project: project, start: start, count: turnCount, autonomous: goalObjective != nil || longRunning,
                             primary: primary, effort: effort, running: running, now: now, dice: &dice)
            guard let last = list.last else { return }
            let finished = last.completedAt ?? now
            var goal: ActivityGoal?
            if let goalObjective {
                goal = ActivityGoal(id: "goal-\(nativeID)", sessionID: id, objective: goalObjective, status: goalStatus, createdAt: start,
                                    updatedAt: finished, providerTimeSeconds: list.reduce(0) { $0 + ($1.durationSeconds ?? now.timeIntervalSince($1.startedAt ?? now)) },
                                    tokensUsed: list.reduce(0) { $0 + ($1.usage.total ?? 0) }, tokenBudget: goalStatus == "active" ? 12_000_000 : nil)
            }
            let session = ActivitySession(
                id: id, provider: provider, nativeID: nativeID, title: title, projectPath: project.path, createdAt: start, updatedAt: finished, observedAt: now,
                runtimeState: running ? "active" : (provider == .codex ? "idle" : "unknown"), models: list.compactMap(\.model).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                efforts: [effort], goal: goal, turns: list, historyComplete: true, source: "demo-fixture/1")
            built.append(Built(session: session, project: project, title: base))
            var children = 0
            if provider == .claude, list.count >= 4 {
                children = dice.chance(0.4) ? dice.int(1 ... 3) : 0
            } else if goalObjective != nil {
                children = dice.chance(0.6) ? dice.int(1 ... 2) : 0
            } else if dice.chance(0.15) {
                children = 1
            }
            for child in 0 ..< children {
                let childStart = start.addingTimeInterval(dice.seconds(60 ... max(120, finished.timeIntervalSince(start) * 0.8)))
                guard childStart < now.addingTimeInterval(-300) else { continue }
                let childID = "\(provider.rawValue):\(nativeID)-c\(child)"
                let childModel = provider == .claude ? dice.weighted([("claude-haiku-5-5", 0.7), ("claude-sonnet-5-5", 0.3)]) : "gpt-6.1-terra"
                let childTurns = turns(sessionID: childID, provider: provider, project: project, start: childStart, count: 1, autonomous: true,
                                       primary: childModel, effort: "medium", running: false, now: now, dice: &dice, durations: 25 ... 150)
                guard !childTurns.isEmpty else { continue }
                let childSession = ActivitySession(
                    id: childID, provider: provider, nativeID: "\(nativeID)-c\(child)", title: dice.pick(childTitles), projectPath: project.path, createdAt: childStart,
                    updatedAt: childTurns[0].completedAt ?? childStart, observedAt: now, runtimeState: provider == .codex ? "idle" : "unknown", parentSessionID: id,
                    models: [childModel], efforts: ["medium"], turns: childTurns, historyComplete: true, source: "demo-fixture/1")
                built.append(Built(session: childSession, project: project, title: childSession.title))
            }
        }

        // (day offset, objective index); each objective belongs to one project.
        var goalsLeft = [(9, 3), (7, 2), (4, 1), (2, 0)]
        let goalProjects = [1, 0, 2, 3]
        for dayOffset in stride(from: 13, through: 0, by: -1) {
            let day = utc.date(byAdding: .day, value: -dayOffset, to: today) ?? today
            let weekday = utc.component(.weekday, from: day)
            let count = weekday == 1 || weekday == 7 ? dice.int(3 ... 6) : dice.int(14 ... 22)
            for slot in 0 ..< count {
                let hour = dice.weighted(hourWeights.enumerated().map { ($0.offset, $0.element) })
                let start = day.addingTimeInterval(Double(hour) * 3_600 + Double(dice.int(0 ... 3_599)))
                guard start < now.addingTimeInterval(-900) else { continue }
                let project = dice.pick(projects)
                if slot == 0, let goal = goalsLeft.first, goal.0 == dayOffset {
                    goalsLeft.removeFirst()
                    makeSession(project: projects[goalProjects[goal.1]], provider: .codex, start: start, turnCount: dice.int(8 ... 13),
                                goalObjective: goalObjectives[goal.1], goalStatus: "complete", running: false)
                    continue
                }
                let provider: AgentName = dice.chance(project.claudeShare) ? .claude : .codex
                // Many Codex runs go on unattended for a while; Claude Code sessions are mostly interactive.
                let unattended = provider == .codex && dice.chance(0.4)
                makeSession(project: project, provider: provider, start: start, turnCount: unattended ? dice.int(5 ... 12) : dice.int(3 ... 10),
                            goalObjective: nil, goalStatus: "", running: false, longRunning: unattended)
            }
        }
        // Two sessions at work right now: an autonomous Codex goal and a Claude Code session.
        makeSession(project: projects[1], provider: .codex, start: now.addingTimeInterval(-95 * 60), turnCount: 10,
                    goalObjective: "Add an audit log for refunds, with tests, then verify with the full suite. Stop when verified.", goalStatus: "active", running: true)
        let activeGoalID = built.last(where: { $0.session.goal?.status == "active" })?.session.id
        makeSession(project: projects[0], provider: .claude, start: now.addingTimeInterval(-22 * 60), turnCount: 3, goalObjective: nil, goalStatus: "", running: true)

        // Commits: most agent sessions that edited files end in a commit, with a co-author trailer.
        var commits: [String: [ActivityCommit]] = [:]
        for item in built where !item.session.isChild && item.session.runtimeState != "active" {
            let paths = Array(Set(item.session.turns.flatMap(\.artifacts).map(\.path))).sorted()
            guard !paths.isEmpty, dice.chance(0.65), let end = item.session.turns.last?.completedAt else { continue }
            let files = paths.map { ActivityCommitFile(path: $0, additions: dice.int(4 ... 160), deletions: dice.int(0 ... 60)) }
            let trailer: [AgentName] = item.session.provider == .claude ? (dice.chance(0.8) ? [.claude] : []) : (dice.chance(0.6) ? [.codex] : [])
            commits[item.project.name, default: []].append(ActivityCommit(
                id: dice.hex(40), subject: item.title, timestamp: end.addingTimeInterval(dice.seconds(120 ... 2_400)), paths: paths,
                additions: files.reduce(0) { $0 + ($1.additions ?? 0) }, deletions: files.reduce(0) { $0 + ($1.deletions ?? 0) },
                filesChanged: files.count, files: files, coAuthors: trailer))
        }
        for project in projects {
            for subject in ["Bump dependencies", "Update the README", "Fix a typo in the config"].prefix(dice.int(1 ... 2)) {
                let at = now.addingTimeInterval(-dice.seconds(86_400 ... 12 * 86_400))
                commits[project.name, default: []].append(ActivityCommit(
                    id: dice.hex(40), subject: subject, timestamp: at, paths: ["package.json"], additions: dice.int(2 ... 30), deletions: dice.int(1 ... 20),
                    filesChanged: 1, files: nil, coAuthors: []))
            }
        }
        let repositories = projects.map { project -> ActivityRepository in
            let list = (commits[project.name] ?? []).filter { $0.timestamp <= now }.sorted { $0.timestamp > $1.timestamp }
            return ActivityRepository(
                id: project.name, name: project.name, root: project.path,
                worktrees: [ActivityWorktree(path: project.path, branch: "main", head: list.first.map { String($0.id.prefix(7)) }, changedFiles: dice.int(0 ... 4))],
                commits: list, observedAt: now, commitHistoryAvailable: true)
        }

        let sessions = built.map(\.session).sorted { $0.updatedAt > $1.updatedAt }
        let health = ["claude", "codex"].map {
            ActivitySourceHealth(id: $0, status: "ready", checkedAt: now, lastSuccessAt: now, message: "Synthetic demo data; no real activity.")
        }
        return ActivityOverview(generatedAt: now, sessions: sessions, sources: health, repositories: repositories, pinnedSessionID: activeGoalID)
    }
}

final class DemoFixtureTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_793_700_000)

    func testDemoActivityIsDeterministicAndEntirelyInvented() throws {
        let first = DemoActivity.overview(now: anchor)
        XCTAssertEqual(first, DemoActivity.overview(now: anchor))
        let text = String(decoding: try BridgeJSON.compactEncoder.encode(first), as: UTF8.self)
        // Only the made-up /Users/example home may appear.
        XCTAssertNil(text.range(of: #"/Users/(?!example/)"#, options: .regularExpression))
        XCTAssertNil(text.range(of: #"/(home|var|private)/"#, options: .regularExpression))
        XCTAssertTrue(first.sessions.allSatisfy { ($0.projectPath ?? "/Users/example/").hasPrefix("/Users/example/") })
        XCTAssertTrue(first.sessions.allSatisfy { $0.source == "demo-fixture/1" })
        let decoded = try BridgeJSON.decoder.decode(ActivityOverview.self, from: BridgeJSON.compactEncoder.encode(first))
        XCTAssertEqual(decoded, first)
    }

    func testDemoActivityCoversWhatTheScreenshotsNeed() {
        let overview = DemoActivity.overview(now: anchor)
        XCTAssertGreaterThan(overview.sessions.count, 60)
        XCTAssertEqual(Set(overview.sessions.map(\.provider)), [.claude, .codex])
        XCTAssertTrue(overview.sessions.contains { $0.isChild })
        XCTAssertEqual(overview.sessions.filter { $0.runtimeState == "active" }.count, 2)
        XCTAssertEqual(overview.activeGoals.count, 1)
        XCTAssertEqual(overview.pinnedSession?.goal?.status, "active")
        XCTAssertGreaterThanOrEqual(overview.goals.filter { $0.status == "complete" }.count, 3)
        XCTAssertTrue(overview.sessions.contains { $0.updatedAt > anchor.addingTimeInterval(-86_400) })
        let models = Set(overview.sessions.flatMap(\.turns).flatMap { $0.modelSteps ?? [] }.compactMap(\.model))
        XCTAssertTrue(models.isSubset(of: DemoActivity.allModels))
        XCTAssertGreaterThanOrEqual(models.count, 5)
        // The Overview's "steps by Codex" highlight needs a clear (>= 60%) but not total majority.
        let weekAgo = anchor.addingTimeInterval(-7 * 86_400)
        var steps: [AgentName: Int] = [:]
        for session in overview.sessions {
            steps[session.provider, default: 0] += session.turns.flatMap { $0.modelSteps ?? [] }.filter { ($0.timestamp ?? .distantPast) >= weekAgo }.count
        }
        let codexShare = Double(steps[.codex] ?? 0) / Double(max(1, (steps[.codex] ?? 0) + (steps[.claude] ?? 0)))
        XCTAssertTrue((0.63 ... 0.85).contains(codexShare), "Codex share \(codexShare)")
        let commits = overview.repositories.flatMap(\.commits)
        XCTAssertTrue(commits.contains { $0.coAuthors == [.claude] })
        XCTAssertTrue(commits.contains { $0.coAuthors == [.codex] })
        XCTAssertTrue(commits.allSatisfy { $0.timestamp <= anchor })
    }

    func testDemoTurnUsageEqualsItsStepsSoAccountingReconciles() {
        for session in DemoActivity.overview(now: anchor).sessions {
            for turn in session.turns {
                let steps = turn.modelSteps ?? []
                XCTAssertEqual(turn.usage.total, steps.reduce(0) { $0 + ($1.usage.total ?? 0) }, turn.id)
                XCTAssertEqual(turn.usage.output, steps.reduce(0) { $0 + ($1.usage.output ?? 0) }, turn.id)
                XCTAssertTrue(steps.allSatisfy { ($0.timestamp ?? .distantPast) <= anchor }, turn.id)
            }
        }
    }

    /// Opt-in writer used by `make screenshots`.
    func testWriteDemoFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGE_DEMO_FIXTURE_OUT"], path.hasPrefix("/") else {
            throw XCTSkip("Opt-in: set BRIDGE_DEMO_FIXTURE_OUT to an absolute path for the synthetic activity JSON")
        }
        let now = ProcessInfo.processInfo.environment["BRIDGE_DEMO_NOW"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let url = URL(fileURLWithPath: path)
        try BridgeJSON.compactEncoder.encode(DemoActivity.overview(now: now)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
