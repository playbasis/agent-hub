import Foundation
import XCTest
@testable import BridgeCore

/// Synthetic app-server responses only: no native helper, credentials, model
/// invocation, files, or live thread operations are used by these tests.
final class CodexDiscoveryPaginationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSecondRootPageDiscoversAstraAndSolSessions() async {
        let collector = makeCollector()
        var cursors: [String] = []
        var reads: [String] = []
        let result = await collect(collector, onRead: { reads.append($0) }) { params in
            if params["ancestorThreadId"] != nil { return ["data": []] }
            let cursor = params["cursor"] as? String
            cursors.append(cursor ?? "head")
            if cursor == nil { return ["data": [self.thread("recent")], "nextCursor": "older"] }
            var astra = self.thread("astra"); astra["model"] = "gpt-6-astra"
            var sol = self.thread("sol"); sol["model"] = "gpt-6.1-sol"
            return ["data": [astra, sol]]
        }
        XCTAssertEqual(cursors, ["head", "older"])
        XCTAssertEqual(Set(result.sessions.map(\.nativeID)), ["recent", "astra", "sol"])
        XCTAssertTrue(Set(reads).isSuperset(of: ["astra", "sol"]))
        XCTAssertTrue(result.health.message.contains("Root history is paginated"))
    }

    func testGlobalListingDiscoversSolSubagentOfNonGoalRootWhileAnotherGoalIsOpen() async {
        let collector = makeCollector()
        var expandedAncestors: [String] = []
        let result = await collector.collect(now: now, knownSessions: []) { method, params in
            let params = params ?? [:]
            let id = params["threadId"] as? String ?? ""
            switch method {
            case "account/usage/read": return ["summary": [:]]
            case "thread/list":
                let kinds = Set(params["sourceKinds"] as? [String] ?? [])
                XCTAssertTrue(kinds.isSuperset(of: ["subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther"]))
                if let ancestor = params["ancestorThreadId"] as? String {
                    expandedAncestors.append(ancestor)
                    return ["data": []]
                }
                return ["data": [self.thread("open-goal"), self.thread("sol-child", parent: "non-goal-root")]]
            case "thread/goal/get":
                if id == "open-goal" { return ["goal": ["objective": "Fixture goal", "status": "active", "createdAt": 100, "updatedAt": 200]] }
                return ["goal": NSNull()]
            case "thread/read":
                var thread = self.thread(id, parent: id == "sol-child" ? "non-goal-root" : nil)
                if id == "sol-child" { thread["model"] = "gpt-6.1-sol"; thread["reasoningEffort"] = "ultra" }
                return ["thread": thread]
            case "thread/turns/list": return ["data": []]
            default: XCTFail("Unexpected non-reporting method \(method)"); return [:]
            }
        }
        XCTAssertEqual(expandedAncestors, ["open-goal"])
        XCTAssertTrue(result.sessions.contains { $0.nativeID == "sol-child" && $0.parentSessionID == "codex:non-goal-root" })
        XCTAssertEqual(Set(result.sessions.map(\.nativeID)), ["open-goal", "sol-child"])
    }

    func testRootProgressKeepsFreshHeadButAdvancesOlderPagesAcrossRefreshes() async {
        let collector = makeCollector()
        var cursors: [String] = []
        let list: ([String: Any]) throws -> [String: Any] = { params in
            if params["ancestorThreadId"] != nil { return ["data": []] }
            let cursor = params["cursor"] as? String
            cursors.append(cursor ?? "head")
            switch cursor {
            case nil: return ["data": [self.thread("fresh")], "nextCursor": "page-1"]
            case "page-1": return ["data": [self.thread("older-a")], "nextCursor": "page-2"]
            case "page-2": return ["data": [self.thread("older-b")]]
            default: XCTFail("Unexpected discovery cursor"); return ["data": []]
            }
        }
        let first = await collect(collector, list: list)
        let second = await collect(collector, list: list)
        XCTAssertEqual(cursors, ["head", "page-1", "head", "page-2"])
        XCTAssertTrue(first.sessions.contains { $0.nativeID == "older-a" })
        XCTAssertTrue(second.sessions.contains { $0.nativeID == "older-b" })
        XCTAssertTrue(second.sessions.contains { $0.nativeID == "fresh" })
    }

    func testMoreThanFiftyDescendantsFitInTwoBoundedPages() async {
        let collector = makeCollector()
        var childLimits: [Int] = []
        let result = await collect(collector, goals: ["root"]) { params in
            guard params["ancestorThreadId"] != nil else { return ["data": [self.thread("root")]] }
            let limit = params["limit"] as? Int ?? 0
            childLimits.append(limit)
            return self.children(params, count: 60)
        }
        XCTAssertEqual(result.sessions.count, 61)
        XCTAssertTrue(result.sessions.contains { $0.nativeID == "child-59" })
        XCTAssertEqual(childLimits, [50, 39])
        XCTAssertTrue(result.health.message.contains("Descendant history is paginated"))
    }

    func testDescendantCursorAdvancesEvenWhenFreshChildrenFillCollectionLimit() async {
        let collector = makeCollector()
        var childCursors: [String] = []
        let list: ([String: Any]) throws -> [String: Any] = { params in
            guard params["ancestorThreadId"] != nil else { return ["data": [self.thread("root")]] }
            childCursors.append(params["cursor"] as? String ?? "head")
            return self.children(params, count: 150)
        }
        let first = await collect(collector, goals: ["root"], list: list)
        let second = await collect(collector, known: first.sessions, goals: ["root"], list: list)
        XCTAssertEqual(first.sessions.count, 90)
        XCTAssertLessThanOrEqual(second.sessions.count, 90)
        XCTAssertTrue(childCursors.contains("89"), "Second refresh must read past the old first 89 children")
        XCTAssertTrue(second.sessions.contains { $0.nativeID == "child-100" })
        XCTAssertTrue(first.health.message.contains("90-task refresh limit"))
    }

    func testRepeatedAndInvalidRootCursorsResetWithoutLosingGoodPage() async {
        for invalid in [false, true] {
            let state = CodexDiscoveryPagination()
            let collector = makeCollector(state)
            let result = await collect(collector) { params in
                if params["ancestorThreadId"] != nil { return ["data": []] }
                if params["cursor"] == nil { return ["data": [self.thread("good")], "nextCursor": "loop"] }
                if invalid { return ["data": [["status": "missing-id"]]] }
                return ["data": [self.thread("older")], "nextCursor": "loop"]
            }
            XCTAssertTrue(result.sessions.contains { $0.nativeID == "good" })
            XCTAssertNil(state.snapshot().root.next)
            XCTAssertTrue(result.health.message.contains(invalid ? "unavailable or invalid" : "cursor repeated"))
        }
    }

    func testPriorityDeduplicatesBeforeCapAndRotatesOverflowGoals() async {
        let collector = makeCollector()
        let goals = Set((0 ..< 31).map { "goal-\($0)" })
        let known = (0 ..< 31).map { self.known("goal-\($0)", goal: true) }
        var firstReads: [String] = [], secondReads: [String] = []
        let first = await collect(collector, known: [known[0]] + known, goals: goals, onRead: { firstReads.append($0) }) { _ in ["data": []] }
        let second = await collect(collector, known: [known[0]] + known, goals: goals, onRead: { secondReads.append($0) }) { _ in ["data": []] }
        XCTAssertEqual(firstReads.first, "goal-0")
        XCTAssertEqual(secondReads.first, "goal-0")
        XCTAssertTrue(firstReads.contains("goal-24"), "Duplicate pinned goal must not consume a priority slot")
        XCTAssertTrue(secondReads.contains("goal-30"), "Overflow goals must not be permanently excluded")
        XCTAssertEqual(Set(firstReads).count, firstReads.count)
        XCTAssertLessThanOrEqual(first.sessions.count, 90)
        XCTAssertLessThanOrEqual(second.sessions.count, 90)
        XCTAssertTrue(first.health.message.contains("priority tasks"))
    }

    func testOlderKnownSessionsRotateWithoutLeavingPinnedSessionBehind() async {
        let collector = makeCollector()
        let known = [self.known("pinned")] + (0 ..< 20).map { self.known("old-\($0)") }
        var union = Set<String>()
        for _ in 0 ..< 4 {
            let result = await collect(collector, known: known) { _ in ["data": []] }
            XCTAssertTrue(result.sessions.contains { $0.nativeID == "pinned" })
            union.formUnion(result.sessions.map(\.nativeID))
        }
        XCTAssertEqual(union, Set(known.map(\.nativeID)))
    }

    func testDeferredFailedHydrationGetsPriorityOnNextRefresh() async {
        let state = CodexDiscoveryPagination()
        let collector = makeCollector(state)
        var failOlder = true
        var readOrder: [String] = []
        let list: ([String: Any]) throws -> [String: Any] = { params in
            if params["ancestorThreadId"] != nil { return ["data": []] }
            if params["cursor"] == nil { return ["data": [self.thread("fresh")], "nextCursor": "old"] }
            return ["data": [self.thread("deferred")]]
        }
        _ = await collect(collector, onRead: { id in
            if id == "deferred", failOlder { throw CodexAppServerSession.RPCError(message: "Fixture read failure") }
        }, list: list)
        XCTAssertEqual(state.snapshot().deferredIDs, ["deferred"])
        failOlder = false
        let second = await collect(collector, onRead: { readOrder.append($0) }, list: list)
        XCTAssertEqual(readOrder.first, "deferred")
        XCTAssertTrue(second.sessions.contains { $0.nativeID == "deferred" })
        XCTAssertTrue(state.snapshot().deferredIDs.isEmpty)
    }

    func testOversizedCursorsAreRejectedAndProgressStorageStaysBounded() async {
        let state = CodexDiscoveryPagination()
        let collector = makeCollector(state)
        let result = await collect(collector) { _ in ["data": [self.thread("invalid-page")], "nextCursor": String(repeating: "x", count: 8_193)] }
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.health.status, "unavailable")
        var progress = state.snapshot()
        for i in 0 ..< 64 { progress.rememberDescendants(.init(next: "page-\(i)"), for: "goal-\(i)") }
        state.store(progress)
        XCTAssertEqual(state.snapshot().descendants.count, 32)
        var newer = state.snapshot(), stale = state.snapshot()
        newer.root = .init(next: "newer")
        stale.root = .init(next: "stale")
        state.store(newer); state.store(stale)
        XCTAssertEqual(state.snapshot().root.next, "newer", "An overlapping read must not rewind discovery")
    }

    private func makeCollector(_ state: CodexDiscoveryPagination = CodexDiscoveryPagination()) -> CodexActivityCollector {
        CodexActivityCollector(configuration: AgentConfiguration(), pagination: state)
    }

    private func collect(_ collector: CodexActivityCollector, known: [ActivitySession] = [], goals: Set<String> = [], onRead: ((String) throws -> Void)? = nil,
                         list: ([String: Any]) throws -> [String: Any]) async -> ActivityCollection {
        await collector.collect(now: now, knownSessions: known) { method, params in
            let params = params ?? [:]
            let id = params["threadId"] as? String ?? ""
            switch method {
            case "account/usage/read": return ["summary": [:]]
            case "thread/list":
                XCTAssertEqual(params["sortKey"] as? String, "updated_at")
                XCTAssertEqual(params["useStateDbOnly"] as? Bool, true)
                XCTAssertLessThanOrEqual(params["limit"] as? Int ?? 0, params["ancestorThreadId"] == nil ? 25 : 50)
                return try list(params)
            case "thread/goal/get":
                if goals.contains(id) { return ["goal": ["objective": "Fixture goal", "status": "active", "createdAt": 100, "updatedAt": 200]] }
                return ["goal": NSNull()]
            case "thread/read":
                XCTAssertEqual(params["includeTurns"] as? Bool, false)
                try onRead?(id)
                return ["thread": thread(id)]
            case "thread/turns/list":
                XCTAssertEqual(params["itemsView"] as? String, "summary")
                return ["data": []]
            default: XCTFail("Unexpected non-reporting method \(method)"); return [:]
            }
        }
    }

    private func thread(_ id: String, parent: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "createdAt": 100, "updatedAt": 200, "status": ["type": "notLoaded"]]
        if let parent { value["parentThreadId"] = parent }
        return value
    }

    private func children(_ params: [String: Any], count: Int) -> [String: Any] {
        let start = Int(params["cursor"] as? String ?? "0") ?? 0
        let end = min(count, start + (params["limit"] as? Int ?? 0))
        var page: [String: Any] = ["data": (start ..< end).map { thread("child-\($0)", parent: "root") }]
        if end < count { page["nextCursor"] = "\(end)" }
        return page
    }

    private func known(_ id: String, goal: Bool = false) -> ActivitySession {
        ActivitySession(id: "codex:\(id)", provider: .codex, nativeID: id, title: "Fixture", createdAt: now, updatedAt: now,
                        goal: goal ? ActivityGoal(id: "goal:\(id)", sessionID: "codex:\(id)", objective: "Fixture", status: "active", createdAt: now, updatedAt: now) : nil,
                        source: "fixture")
    }
}
