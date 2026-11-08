@testable import BridgeCore
import Foundation
import XCTest

final class AgentPersonaTests: XCTestCase {
    private func session(_ id: String, created: TimeInterval = 0, parent: String? = nil, goal: Bool = false, categories: [String: Int] = [:], provider: AgentName = .codex) -> ActivitySession {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + created)
        return ActivitySession(
            id: "\(provider.rawValue):\(id)", provider: provider, nativeID: id, title: id,
            createdAt: date, updatedAt: date, observedAt: date, parentSessionID: parent,
            goal: goal ? ActivityGoal(id: "g", sessionID: "\(provider.rawValue):\(id)", objective: "Ship", status: "active", createdAt: date, updatedAt: date) : nil,
            turns: categories.isEmpty ? [] : [ActivityTurn(id: "\(id)-t", categories: categories)],
            source: "test"
        )
    }

    func testCatalogParsesEveryBundledPortrait() {
        XCTAssertEqual(AgentPersonaCatalog.all.count, AgentPersonaCatalog.slugs.count, "every file parses")
        XCTAssertGreaterThanOrEqual(AgentPersonaCatalog.all.count, 60)
        for role in AgentRole.allCases {
            XCTAssertFalse(AgentPersonaCatalog.personas(for: role).isEmpty, "\(role) has portraits")
        }
        let maya = AgentPersonaCatalog.parse("coordinator-maya-chen")
        XCTAssertEqual(maya?.role, .coordinator)
        XCTAssertEqual(maya?.fullName, "Maya Chen")
        let aisha = AgentPersonaCatalog.parse("specialist-healthcare-aisha-rahman")
        XCTAssertEqual(aisha?.fullName, "Aisha Rahman", "domain segment is skipped")
        XCTAssertEqual(AgentPersonaCatalog.parse("studio-operator-hana-tanaka")?.firstName, "Hana")
    }

    func testRoleFollowsEvidence() {
        XCTAssertEqual(AgentRole.infer(session("g", goal: true), hasChildren: false), .coordinator)
        XCTAssertEqual(AgentRole.infer(session("p"), hasChildren: true), .coordinator)
        XCTAssertEqual(AgentRole.infer(session("a", categories: ["research": 5, "execution": 2]), hasChildren: false), .analyst)
        XCTAssertEqual(AgentRole.infer(session("o", categories: ["execution": 4, "implementation": 3, "tests": 5]), hasChildren: false), .`operator`)
        XCTAssertEqual(AgentRole.infer(session("r", categories: ["review": 2, "tests": 6, "execution": 3]), hasChildren: false), .reviewer)
        XCTAssertEqual(AgentRole.infer(session("s", categories: ["other tools": 9]), hasChildren: false), .specialist)
        XCTAssertEqual(AgentRole.infer(session("e"), hasChildren: false), .specialist)
    }

    func testAssignmentIsStableUniqueAndAppendOnly() {
        let base = (0 ..< 8).map { session("op\($0)", created: Double($0), categories: ["execution": 3]) }
        let first = AgentPersonaCatalog.assign(base)
        let again = AgentPersonaCatalog.assign(base.reversed())
        XCTAssertEqual(first, again, "input order does not matter")
        let faces = base.compactMap { first[$0.id]?.persona?.slug }
        XCTAssertEqual(Set(faces).count, faces.count, "no duplicate faces while the pool lasts")
        XCTAssertTrue(faces.allSatisfy { AgentPersonaCatalog.parse($0)?.role == .operator })

        let later = AgentPersonaCatalog.assign(base + [session("new", created: 100, categories: ["execution": 1])])
        for item in base { XCTAssertEqual(later[item.id], first[item.id], "a newer session never changes an older face") }
    }

    func testStableHashIsProcessIndependent() {
        XCTAssertEqual(AgentPersonaCatalog.stableHash("codex:abc"), 0x49367fd3bb81cfae, "pinned FNV-1a value")
        XCTAssertEqual(AgentPersonaCatalog.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertNotEqual(AgentPersonaCatalog.stableHash("a"), AgentPersonaCatalog.stableHash("b"))
    }

    func testPoolExhaustionReusesRatherThanFailing() {
        let count = AgentPersonaCatalog.personas(for: .reviewer).count + 3
        let reviewers = (0 ..< count).map { session("rv\($0)", created: Double($0), categories: ["review": 1]) }
        let assigned = AgentPersonaCatalog.assign(reviewers)
        XCTAssertEqual(assigned.count, count)
        XCTAssertTrue(assigned.values.allSatisfy { $0.persona != nil })
        let counts = Dictionary(grouping: assigned.values.compactMap(\.persona), by: \.slug).values.map(\.count)
        XCTAssertLessThanOrEqual((counts.max() ?? 0) - (counts.min() ?? 0), 1, "exhausted pools distribute reuse evenly")
    }

    func testMalformedSlugsAreRejectedBeforeResourceLookup() {
        for slug in ["", "analyst", "analyst-maya", "-analyst-maya-chen", "analyst-maya-chen-", "analyst--maya-chen", "../analyst-maya-chen", "team/analyst-maya-chen", "studio-ANALYST-maya-chen", "team-extra-analyst-maya-chen", "specialist-healthcare"] {
            XCTAssertNil(AgentPersonaCatalog.parse(slug), slug)
        }
        XCTAssertEqual(AgentPersonaCatalog.parse("specialist-mary-ann-smith")?.fullName, "Mary Ann Smith", "only declared domain prefixes are stripped")
        XCTAssertEqual(Set(AgentPersonaCatalog.all.map(\.slug)).count, AgentPersonaCatalog.all.count)
    }

    func testLargeCategoryCountsDoNotOverflowOrLoseDominance() {
        let item = session("large", categories: ["research": Int.max, "execution": Int.max, "implementation": 1, "review": -1])
        XCTAssertEqual(AgentRole.infer(item, hasChildren: false), .operator)
        XCTAssertEqual(AgentRole.infer(session("trim", categories: [" RESEARCH\n": 2]), hasChildren: false), .analyst)
        XCTAssertEqual(AgentRole.infer(session("tie", categories: ["review": 2, "execution": 2]), hasChildren: false), .operator)
    }

    func testRawParentIDsAreScopedToTheirProvider() {
        let codex = session("shared")
        let claude = session("shared", provider: .claude)
        let child = session("child", parent: "shared")
        let assignments = AgentPersonaCatalog.assign([codex, claude, child])
        XCTAssertEqual(assignments[codex.id]?.role, .coordinator)
        XCTAssertEqual(assignments[claude.id]?.role, .specialist)
        let explicit = session("explicit", parent: claude.id)
        XCTAssertEqual(AgentPersonaCatalog.assign([codex, claude, explicit])[claude.id]?.role, .coordinator)
    }

    func testChildRoleExcludesInheritedAncestorWorkWithoutChangingItsPortrait() {
        var parent = session("ancestor", categories: ["execution": 100])
        parent.turns = [ActivityTurn(id: "ancestor-work", categories: ["execution": 100])]
        var child = session("fork", created: 10, parent: parent.nativeID)
        child.turns = parent.turns + [ActivityTurn(id: "child-work", categories: ["research": 2])]
        XCTAssertEqual(AgentRole.infer(child, hasChildren: false), .operator, "standalone inference still uses exactly the evidence supplied")
        let store = AgentPersonaAssignmentStore(fileURL: nil)
        let beforeBackfill = store.assignments(for: [child])[child.id]
        let assignments = store.assignments(for: [child, parent])
        XCTAssertEqual(assignments[parent.id]?.role, .coordinator)
        XCTAssertEqual(assignments[child.id]?.role, .analyst, "parent execution receipts must not dominate the child's own research")
        XCTAssertEqual(assignments[child.id]?.persona, beforeBackfill?.persona, "improved ownership evidence changes the role, never the portrait identity")
        XCTAssertEqual(AgentPersonaCatalog.assign([parent, child])[child.id]?.role, .analyst)
    }

    func testDuplicateSessionsDoNotConsumeExtraPortraits() {
        let unique = (0..<7).map { session("duplicate-\($0)", created: Double($0), categories: ["review": 1]) }
        XCTAssertEqual(AgentPersonaCatalog.assign(unique + [unique[0], unique[2]]), AgentPersonaCatalog.assign(unique))
        var revised = unique[0]
        revised.updatedAt = revised.updatedAt.addingTimeInterval(10)
        revised.turns = [ActivityTurn(id: "new-evidence", categories: ["research": 1])]
        let forward = AgentPersonaCatalog.assign([unique[0], revised])
        let reverse = AgentPersonaCatalog.assign([revised, unique[0]])
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward[revised.id]?.role, .analyst)
    }

    func testStoreRetainsFacesAcrossBackfillFilteringAndRoleChanges() {
        let store = AgentPersonaAssignmentStore(fileURL: nil)
        let original = (0..<8).map { session("stable-\($0)", created: Double($0 + 100), categories: ["execution": 3]) }
        let first = store.assignments(for: original)
        let older = session("late-backfill", created: -100, categories: ["execution": 1])
        let backfilled = store.assignments(for: [older] + original.reversed())
        for item in original { XCTAssertEqual(backfilled[item.id]?.persona, first[item.id]?.persona) }
        _ = store.assignments(for: [older])
        let restored = store.assignments(for: original)
        XCTAssertEqual(first, restored, "temporarily absent sessions keep their portrait reservation")

        var coordinating = original[0]
        coordinating.goal = ActivityGoal(id: "new-goal", sessionID: coordinating.id, objective: "Ship", status: "active", createdAt: coordinating.createdAt, updatedAt: coordinating.updatedAt)
        let promoted = store.assignments(for: [coordinating])
        XCTAssertEqual(promoted[coordinating.id]?.role, .coordinator)
        XCTAssertEqual(promoted[coordinating.id]?.persona, first[coordinating.id]?.persona, "role is observed independently from portrait identity")
    }

    func testInactiveHistoryDoesNotCauseAvoidableVisibleCollisions() {
        let store = AgentPersonaAssignmentStore(fileURL: nil)
        let size = AgentPersonaCatalog.personas(for: .operator).count
        let historical = (0..<(size * 3)).map { session("history-\($0)", created: Double($0), categories: ["execution": 1]) }
        _ = store.assignments(for: historical)
        let current = Array(historical.prefix(2)) + (0..<(size - 2)).map { session("current-\($0)", created: Double(1_000 + $0), categories: ["execution": 1]) }
        let faces = store.assignments(for: current).values.compactMap { $0.persona?.slug }
        XCTAssertEqual(Set(faces).count, size)
    }

    func testStorePersistsReservationsAcrossRestartWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("personas.json")
        let items = (0..<10).map { session("persist-\($0)", created: Double($0), categories: ["review": 1]) }
        let store = AgentPersonaAssignmentStore(fileURL: url)
        let first = store.assignments(for: items)
        XCTAssertNil(store.persistenceError)
        let restarted = AgentPersonaAssignmentStore(fileURL: url)
        XCTAssertEqual(restarted.assignments(for: items.reversed()), first)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMalformedStoredEntriesDoNotPoisonValidReservations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("personas.json")
        let retained = AgentPersonaCatalog.personas(for: .analyst)[0]
        let entries: [String: Any] = ["codex:retained": retained.slug, "codex:unknown": "../private", "codex:wrong-type": 4, "": retained.slug]
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "assignments": entries]).write(to: url)
        let store = AgentPersonaAssignmentStore(fileURL: url)
        let result = store.assignments(for: [session("retained", categories: ["execution": 1]), session("new")])
        XCTAssertEqual(result["codex:retained"]?.persona, retained)
        XCTAssertEqual(result["codex:retained"]?.role, .operator)
        XCTAssertNotNil(result["codex:new"]?.persona)
        XCTAssertNil(store.persistenceError)
    }

    func testCorruptOrFutureStoreIsPreservedAndMemoryRemainsStable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("personas.json")
        let item = session("in-memory", categories: ["execution": 1])
        for bytes in [Data("broken".utf8), try JSONSerialization.data(withJSONObject: ["schema_version": 2, "assignments": [:]])] {
            try bytes.write(to: url)
            let store = AgentPersonaAssignmentStore(fileURL: url, persistenceRetryInterval: 0)
            let first = store.assignments(for: [item])
            XCTAssertNotNil(store.persistenceError)
            XCTAssertEqual(try Data(contentsOf: url), bytes, "failed decoding must not overwrite the existing store")
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(store.assignments(for: [item]), first, "retry after recovery keeps the shown identity")
            XCTAssertNil(store.persistenceError)
        }
    }

    func testConcurrentReadersAndWritersShareOneStableIdentityMap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("personas.json")
        let store = AgentPersonaAssignmentStore(fileURL: url)
        let items = (0..<20).map { session("concurrent-\($0)", created: Double($0), categories: ["research": 1]) }
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            _ = store.assignments(for: [items[index]])
        }
        let combined = store.assignments(for: items)
        XCTAssertEqual(combined.count, items.count)
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(AgentPersonaAssignmentStore(fileURL: url).assignments(for: items), combined)
    }

    func testSeparateStoreInstancesMergeReservations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("personas.json")
        let left = AgentPersonaAssignmentStore(fileURL: url)
        let right = AgentPersonaAssignmentStore(fileURL: url)
        let a = session("from-left", categories: ["execution": 1])
        let b = session("from-right", categories: ["execution": 1])
        let first = left.assignments(for: [a])[a.id]
        let second = right.assignments(for: [b])[b.id]
        let combined = AgentPersonaAssignmentStore(fileURL: url).assignments(for: [a, b])
        XCTAssertEqual(combined[a.id], first)
        XCTAssertEqual(combined[b.id], second)
        XCTAssertNotEqual(first?.persona, second?.persona)
    }

    func testPersistenceFailureBackoffStillUpdatesObservedRolesInMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("personas.json")
        let broken = Data("broken".utf8)
        try broken.write(to: url)
        let store = AgentPersonaAssignmentStore(fileURL: url, persistenceRetryInterval: 3_600)
        let item = session("backoff", categories: ["execution": 1])
        let initial = store.assignments(for: [item])
        var revised = item
        revised.turns = [ActivityTurn(id: "research", categories: ["research": 3])]
        let changed = store.assignments(for: [revised])
        XCTAssertEqual(changed[item.id]?.role, .analyst)
        XCTAssertEqual(changed[item.id]?.persona, initial[item.id]?.persona)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testSymlinkedStoreDoesNotOverwriteItsTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("original.json")
        let bytes = Data("untouched".utf8)
        try bytes.write(to: target)
        let url = directory.appendingPathComponent("personas.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = AgentPersonaAssignmentStore(fileURL: url)
        XCTAssertNotNil(store.assignments(for: [session("symlink")])["codex:symlink"]?.persona)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
    }
}
