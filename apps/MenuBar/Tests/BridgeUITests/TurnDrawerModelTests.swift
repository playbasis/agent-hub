import AppKit
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

private actor DrawerEvidenceFixture {
    let date: Date
    var hold: Bool
    let cancels: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requested: [String] = []
    private(set) var maximumActive = 0
    private var active = 0

    init(date: Date, hold: Bool = false, cancels: Bool = false) {
        self.date = date; self.hold = hold; self.cancels = cancels
    }

    func read(_ session: ActivitySession, _ turn: ActivityTurn, _ includeText: Bool) async throws -> WorkEvidenceBatch {
        requested.append(turn.id); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if hold { await withCheckedContinuation { continuation = $0 } }
        if cancels { throw CancellationError() }
        let item = WorkEvidenceItem(id: "native:" + turn.id, nativeID: turn.id, kind: .response,
                                    title: "Reply", status: "completed", timestamp: date,
                                    relatedID: nil, exitCode: nil, durationSeconds: nil,
                                    preview: includeText ? "opted-in text" : nil, digest: nil)
        return WorkEvidenceBatch(items: [item], isPartial: false, message: "Fixture", adapterVersion: "test")
    }

    func release() { hold = false; continuation?.resume(); continuation = nil }
}

final class TurnDrawerModelTests: XCTestCase {
    @MainActor func testSteppingReusesOneCanonicalProjectionUntilSourceRevisionChanges() {
        let model = TurnDrawerModel()
        let identity = UUID(), overview = snapshot()
        for id in ["t1", "t2", "t3", "t1"] {
            model.resolve(TurnInspectionSelection(overview: overview, sessionID: "lead", turnID: id, id: identity, snapshotRevision: 7))
        }
        XCTAssertEqual(model.recordsBuildCount, 1)
        model.resolve(TurnInspectionSelection(overview: overview, sessionID: "lead", turnID: "t1", id: identity, snapshotRevision: 8))
        XCTAssertEqual(model.recordsBuildCount, 2)
    }

    private let now = Date(timeIntervalSince1970: 1_793_750_400)

    private func snapshot() -> ActivityOverview {
        let turns = (1 ... 3).map { index in
            ActivityTurn(id: "t\(index)", startedAt: now.addingTimeInterval(Double(index * 20 - 100)),
                         completedAt: now.addingTimeInterval(Double(index * 20 - 90)), status: "completed")
        }
        let lead = ActivitySession(id: "lead", provider: .codex, nativeID: "native-lead", title: "Lead",
                                   createdAt: now.addingTimeInterval(-600), updatedAt: now, observedAt: now,
                                   turns: turns, source: "fixture")
        return ActivityOverview(generatedAt: now, sessions: [lead])
    }

    @MainActor private func eventually(_ predicate: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 1_000 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for fixture", file: file, line: line)
    }

    @MainActor func testExplicitUnknownTurnIsUnavailableAndNeverRead() async {
        let fixture = DrawerEvidenceFixture(date: now)
        let model = TurnDrawerModel(reader: { try await fixture.read($0, $1, $2) }, debounceNanoseconds: 0)
        model.resolve(TurnInspectionSelection(overview: snapshot(), sessionID: "lead", turnID: "missing"))
        XCTAssertNotNil(model.context)
        XCTAssertNil(model.context?.index)
        XCTAssertNil(model.context?.turn)
        model.load(includeText: false)
        XCTAssertFalse(model.reading)
        let requested = await fixture.requested
        XCTAssertTrue(requested.isEmpty)
    }

    @MainActor func testDrawerUsesMergedInheritedReceiptAndCanonicalNativeAliasOwner() {
        var overview = snapshot()
        overview.sessions[0].observedAt = now.addingTimeInterval(-20)
        let correction = ActivityTurn(id: "t1", completedAt: now.addingTimeInterval(-70), status: "failed", toolCount: 0)
        let child = ActivitySession(id: "child", provider: .codex, nativeID: "native-child", title: "Child",
                                    createdAt: now.addingTimeInterval(-700), updatedAt: now, observedAt: now,
                                    parentSessionID: "native-lead", turns: [correction], source: "fixture")
        overview.sessions.append(child)
        let model = TurnDrawerModel()
        model.resolve(TurnInspectionSelection(overview: overview, sessionID: "child", turnID: "t1"))
        XCTAssertEqual(model.context?.parent?.id, "lead")
        XCTAssertEqual(model.context?.copiedFrom?.id, "lead")
        XCTAssertEqual(model.context?.turn?.startedAt, overview.sessions[0].turns[0].startedAt)
        XCTAssertEqual(model.context?.turn?.status, "failed")
        XCTAssertEqual(model.context?.turn?.toolCount, 0)
        overview.sessions[1].parentSessionID = nil
        model.resolve(TurnInspectionSelection(overview: overview, sessionID: "child", turnID: "t1"))
        XCTAssertNil(model.context?.copiedFrom, "an unrelated duplicate ID is not an inherited turn")
    }

    @MainActor func testClosedMetadataCorrectionsAndSameClockSourceRevisionsInvalidateReadCache() async {
        let fixture = DrawerEvidenceFixture(date: now.addingTimeInterval(10))
        let model = TurnDrawerModel(reader: { try await fixture.read($0, $1, $2) }, debounceNanoseconds: 0,
                                    clock: { self.now.addingTimeInterval(30) })
        let identity = UUID()
        var overview = snapshot()
        model.resolve(TurnInspectionSelection(overview: overview, sessionID: "lead", turnID: "t1", id: identity))
        model.load(includeText: false)
        await eventually { !model.reading }
        XCTAssertEqual(model.entries.first?.timestamp, now.addingTimeInterval(10), "native evidence keeps its real date")
        overview.generatedAt = now.addingTimeInterval(1)
        overview.sessions[0].turns[0].toolCount = 4
        model.resolve(TurnInspectionSelection(overview: overview, sessionID: "lead", turnID: "t1", id: identity))
        model.load(includeText: false)
        await eventually { !model.reading }
        let secondCount = await fixture.requested.count
        XCTAssertEqual(secondCount, 2, "a corrected closed receipt must not reuse its earlier native page")
        model.resolve(TurnInspectionSelection(overview: overview, sessionID: "lead", turnID: "t1", id: identity, snapshotRevision: 1))
        model.load(includeText: false)
        await eventually { !model.reading }
        let revisionCount = await fixture.requested.count
        XCTAssertEqual(revisionCount, 3, "same-clock source corrections are distinct snapshots")
        XCTAssertEqual(model.context?.revision, 1)
    }

    @MainActor func testHidingTextPurgesCurrentPageEntriesAndTextCacheBeforeReread() async {
        let fixture = DrawerEvidenceFixture(date: now)
        let model = TurnDrawerModel(reader: { try await fixture.read($0, $1, $2) }, debounceNanoseconds: 0)
        model.resolve(TurnInspectionSelection(overview: snapshot(), sessionID: "lead", turnID: "t1"))
        model.load(includeText: true)
        await eventually { !model.reading }
        XCTAssertEqual(model.batch?.items.first?.preview, "opted-in text")
        model.forgetText()
        XCTAssertNil(model.batch)
        XCTAssertTrue(model.entries.isEmpty)
        model.load(includeText: true)
        await eventually { !model.reading }
        let reads = await fixture.requested.count
        XCTAssertEqual(reads, 2, "hiding text removes the reusable text page too")
        model.cancel()
        XCTAssertNil(model.batch)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.reading)
    }

    @MainActor func testSteppingCoalescesBehindOneActiveReaderAndDropsCancelledText() async {
        let fixture = DrawerEvidenceFixture(date: now, hold: true)
        let model = TurnDrawerModel(reader: { try await fixture.read($0, $1, $2) }, debounceNanoseconds: 0)
        let overview = snapshot()
        let identity = UUID()
        model.resolve(TurnInspectionSelection(overview: overview, sessionID: "lead", turnID: "t1", id: identity))
        model.load(includeText: true)
        await eventually { await fixture.requested.count == 1 }
        model.forgetText()
        XCTAssertFalse(model.reading)
        for turn in ["t2", "t3"] {
            model.resolve(TurnInspectionSelection(overview: overview, sessionID: "lead", turnID: turn, id: identity))
            model.load(includeText: false)
        }
        await fixture.release()
        await eventually { !model.reading }
        let requested = await fixture.requested
        let maximumActive = await fixture.maximumActive
        XCTAssertEqual(requested, ["t1", "t3"], "intermediate pending turns never start a read")
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(model.batch?.items.first?.id, "native:t3")
        XCTAssertNil(model.batch?.items.first?.preview, "a late opted-in read cannot republish hidden text")
    }

    @MainActor func testReaderCancellationNeverLeavesLoadingStuck() async {
        let fixture = DrawerEvidenceFixture(date: now, cancels: true)
        let model = TurnDrawerModel(reader: { try await fixture.read($0, $1, $2) }, debounceNanoseconds: 0)
        model.resolve(TurnInspectionSelection(overview: snapshot(), sessionID: "lead", turnID: "t1"))
        model.load(includeText: false)
        await eventually { !model.reading }
        XCTAssertNil(model.error)
        XCTAssertNil(model.batch)
    }

    @MainActor func testKeyboardNavigationOnlyUsesUnmodifiedHorizontalArrowsOutsideControlsAndSheets() {
        XCTAssertEqual(DrawerKeyNavigation.key(code: 123, modifiers: [], responder: nil, hasSheet: false), .earlier)
        XCTAssertEqual(DrawerKeyNavigation.key(code: 124, modifiers: [], responder: nil, hasSheet: false), .later)
        for code in [UInt16(125), 126] {
            XCTAssertNil(DrawerKeyNavigation.key(code: code, modifiers: [], responder: nil, hasSheet: false))
        }
        for modifier in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            XCTAssertNil(DrawerKeyNavigation.key(code: 123, modifiers: modifier, responder: nil, hasSheet: false))
        }
        for responder in [NSTextView(), NSButton(), NSPopUpButton(), NSSlider(), NSSegmentedControl()] as [NSResponder] {
            XCTAssertNil(DrawerKeyNavigation.key(code: 123, modifiers: [], responder: responder, hasSheet: false))
        }
        XCTAssertNil(DrawerKeyNavigation.key(code: 123, modifiers: [], responder: nil, hasSheet: true))
    }
}
