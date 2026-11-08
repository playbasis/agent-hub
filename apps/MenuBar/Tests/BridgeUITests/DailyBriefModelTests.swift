import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class DailyBriefModelTests: XCTestCase {

    // These expectations are written for Bangkok (UTC+7) day boundaries; pin the
    // reporting zone so they hold on a Mac in any time zone.
    private var hostReportingZone = ActivityAnalytics.reportingTimeZone
    override func setUp() {
        super.setUp()
        hostReportingZone = ActivityAnalytics.reportingTimeZone
        ActivityAnalytics.reportingTimeZone = TimeZone(identifier: "Asia/Bangkok")!
    }
    override func tearDown() {
        ActivityAnalytics.reportingTimeZone = hostReportingZone
        super.tearDown()
    }
    private func entry(_ revision: Int = 1) -> ActivityJournalEntry {
        ActivityJournalEntry(id: "2026-11-03:\(revision)", date: "2026-11-03", revision: revision,
            generatedAt: Date(timeIntervalSince1970: 1_793_664_000 + Double(revision)),
            previousID: nil, supersedesID: revision > 1 ? "2026-11-03:\(revision - 1)" : nil,
            timezone: "Asia/Bangkok", snapshotDigest: "fixture", outcomes: ["One saved request."],
            continuingGoalIDs: [], evidenceIDs: ["fixture-turn"], markdown: "# Brief\n\n## Summary\nOne request.\n")
    }

    @MainActor
    func testAcknowledgedBriefIsShownImmediatelyAndRepeatedSaveExplainsNoChange() async {
        let saved = entry()
        let model = DailyBriefModel(operations: .init(load: { [] }, publish: { saved }))
        await model.publish()
        XCTAssertEqual(model.entries, [saved])
        XCTAssertEqual(model.openedID, saved.id)
        XCTAssertEqual(model.hasLoaded, true)
        XCTAssertTrue(model.notice?.contains("saved") == true)
        let firstOpen = model.openRevision
        await model.publish()
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertTrue(model.notice?.contains("already up to date") == true)
        XCTAssertGreaterThan(model.openRevision, firstOpen, "The same saved ID still requests reopening after the user collapses it")
        XCTAssertFalse(model.isPublishing)
    }

    @MainActor
    func testFailureKeepsSavedHistoryAndExposesActionableError() async {
        let saved = entry()
        let model = DailyBriefModel(operations: .init(load: { [saved] }, publish: { throw FixtureError.unavailable }))
        await model.load(); await model.publish()
        XCTAssertEqual(model.entries, [saved])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isPublishing)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testUnavailableConnectionDoesNotSilentlyIgnorePublication() async {
        let model = DailyBriefModel()
        await model.publish()
        XCTAssertTrue(model.errorMessage?.contains("connecting") == true)
        XCTAssertFalse(model.isPublishing)
        await model.load()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.hasLoaded)
    }

    @MainActor
    func testStaleListCannotHideAJustPublishedBrief() async {
        let gate = BriefLoadGate()
        let saved = entry(2), old = entry()
        let model = DailyBriefModel(operations: .init(load: { await gate.read() }, publish: { saved }))
        let load = Task { await model.load() }
        while !(await gate.started) { await Task.yield() }
        await model.publish()
        await gate.finish([old])
        await load.value
        XCTAssertEqual(model.entries, [saved])
        XCTAssertEqual(model.openedID, saved.id)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testDuplicateConcurrentCreationStartsOneRequest() async {
        let gate = BriefLoadGate()
        let saved = entry()
        let model = DailyBriefModel(operations: .init(load: { [] }, publish: {
            _ = await gate.read()
            return saved
        }))
        let publish = Task { await model.publish() }
        while !(await gate.started) { await Task.yield() }
        await model.publish()
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.finish([]); await publish.value
        XCTAssertEqual(model.entries, [saved])
    }

    @MainActor
    func testCancelledLoadDoesNotReplaceLastKnownHistory() async {
        let gate = BriefLoadGate()
        let saved = entry()
        let model = DailyBriefModel(operations: .init(load: { await gate.read() }, publish: { saved }))
        let load = Task { await model.load() }
        while !(await gate.started) { await Task.yield() }
        load.cancel(); await gate.finish([entry()]); await load.value
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testOldConnectionSuccessCannotReplaceNewConnectionAcknowledgement() async {
        let gate = BriefLoadGate()
        let old = entry(), current = entry(2)
        let model = DailyBriefModel(operations: .init(load: { [] }, publish: {
            _ = await gate.read(); return old
        }))
        let oldPublish = Task { await model.publish() }
        while !(await gate.started) { await Task.yield() }
        model.connect(operations: .init(load: { [current] }, publish: { current }), id: UUID())
        await model.load(); await model.publish()
        let acknowledgement = model.notice, openRevision = model.openRevision
        await gate.finish([]); await oldPublish.value
        XCTAssertEqual(model.entries, [current])
        XCTAssertEqual(model.notice, acknowledgement)
        XCTAssertEqual(model.openedID, current.id)
        XCTAssertEqual(model.openRevision, openRevision)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isPublishing)
    }

    @MainActor
    func testOldConnectionFailureCannotClearNewInFlightPublicationOrSetAnError() async {
        let oldGate = BriefLoadGate(), newGate = BriefLoadGate()
        let saved = entry(2)
        let model = DailyBriefModel(operations: .init(load: { [] }, publish: {
            _ = await oldGate.read(); throw FixtureError.unavailable
        }))
        let oldPublish = Task { await model.publish() }
        while !(await oldGate.started) { await Task.yield() }
        model.connect(operations: .init(load: { [] }, publish: {
            _ = await newGate.read(); return saved
        }), id: UUID())
        let newPublish = Task { await model.publish() }
        while !(await newGate.started) { await Task.yield() }
        await oldGate.finish([]); await oldPublish.value
        XCTAssertTrue(model.isPublishing, "An obsolete task's defer must not clear the current task's progress")
        XCTAssertNil(model.errorMessage)
        await newGate.finish([]); await newPublish.value
        XCTAssertEqual(model.entries, [saved])
        XCTAssertFalse(model.isPublishing)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCancelledCallerStillKeepsAnAuthoritativelyAcknowledgedSave() async {
        let gate = BriefLoadGate()
        let saved = entry()
        let model = DailyBriefModel(operations: .init(load: { [] }, publish: {
            _ = await gate.read(); return saved
        }))
        let publication = Task { await model.publish() }
        while !(await gate.started) { await Task.yield() }
        publication.cancel()
        await gate.finish([]); await publication.value
        XCTAssertEqual(model.entries, [saved])
        XCTAssertEqual(model.openedID, saved.id)
        XCTAssertTrue(model.notice?.contains("saved") == true)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isPublishing)
    }

    func testPlainDisplayUnescapesProviderTextAndRetainsExactMeasurements() {
        XCTAssertEqual(DailyBriefText.plain(#"- /tmp/team\-project · 1,250 tokens · \[client\]\(notes\)"#),
                       "• /tmp/team-project · 1,250 tokens · [client](notes)")
        XCTAssertEqual(DailyBriefText.plain(#"R&amp;D &lt;draft&gt; &#x27;quote&#39;"#), "R&D <draft> 'quote'")
        XCTAssertEqual(DailyBriefText.plain(#"\<script\> · C:\\project"#), #"<script> · C:\project"#)
        XCTAssertEqual(DailyBriefText.plain("- evidence `native-id`; **120 tokens**"), "• evidence native-id; 120 tokens")
    }

    func testPlainDisplayDropsLinkAndImageActionsRatherThanCreatingRichText() {
        let label: String = DailyBriefText.plain("[Research](https://example.com/private)")
        XCTAssertEqual(label, "Research")
        let image: String = DailyBriefText.plain("![diagram](https://example.com/image.png)")
        XCTAssertFalse(image.contains("https://example.com"))
        XCTAssertEqual(DailyBriefText.plain(#"\[literal\]\(https://example.com\)"#), "[literal](https://example.com)",
                       "Escaped provider input stays literal text, not a link")
    }

    func testEscapedLiteralMarkdownIsRestoredOnlyAfterInlineParsing() {
        XCTAssertEqual(DailyBriefText.plain(##"\*\*literal\*\* \`code\` \!\[image\]\(https://example.com\) \#heading"##),
                       "**literal** `code` ![image](https://example.com) #heading")
        XCTAssertEqual(DailyBriefText.plain(#"[Research](https://example.com) · \[literal\]\(https://example.com\)"#),
                       "Research · [literal](https://example.com)")
        XCTAssertEqual(DailyBriefText.plain(#"C:\work\project · C:\\work\\project"#), #"C:\work\project · C:\work\project"#)
        XCTAssertEqual(DailyBriefText.plain("HUBLITERAL0123L0Z · 120 tokens"), "HUBLITERAL0123L0Z · 120 tokens")
    }

    func testDocumentParsingPreservesValuesAndGroupsTechnicalDepth() {
        let parsed = DailyBriefSection.parse("# Brief\n\n## Time and usage\n- Tokens: 100\n\n## Source coverage\npartial\n\n## Time and usage\n- Requests: 2\n")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].lines, ["- Tokens: 100", "- Requests: 2"])
        XCTAssertFalse(parsed[0].isTechnical)
        XCTAssertTrue(parsed[1].isTechnical)
    }

    func testGaugePreservesBoundariesAndRejectsInvalidMeasurements() {
        XCTAssertEqual(RingGauge.remainingRatio(0), 1)
        XCTAssertEqual(RingGauge.remainingRatio(1), 0)
        XCTAssertEqual(RingGauge.remainingRatio(0.25), 0.75)
        for value in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertNil(RingGauge.remainingRatio(value))
        }
    }

    func testReportPeriodsKeepDailyChartsAlignedToLocalCalendar() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-11-03T06:00:00Z"))
        XCTAssertEqual(ReportPeriod.week.cutoff(at: now), formatter.date(from: "2026-10-27T17:00:00Z"))
        XCTAssertEqual(ReportPeriod.month.cutoff(at: now), formatter.date(from: "2026-10-04T17:00:00Z"))
        // Whole-hour plotting must not shorten the actual trailing day.
        XCTAssertEqual(ReportPeriod.day.cutoff(at: now), now.addingTimeInterval(-86_400))
        XCTAssertEqual(ReportPeriod.day.cutoff(at: now.addingTimeInterval(25 * 60)), now.addingTimeInterval(25 * 60 - 86_400))
        XCTAssertNil(ReportPeriod.all.cutoff(at: now))
    }
}

private enum FixtureError: Error { case unavailable }
private actor BriefLoadGate {
    private var continuation: CheckedContinuation<[ActivityJournalEntry], Never>?
    private(set) var started = false
    private(set) var calls = 0
    func read() async -> [ActivityJournalEntry] {
        calls += 1; started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ result: [ActivityJournalEntry]) {
        continuation?.resume(returning: result); continuation = nil
    }
}
