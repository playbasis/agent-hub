import Darwin
import Foundation
import XCTest
@testable import BridgeCore

final class AccountingSurfaceContractTests: XCTestCase {
    private let asOf = Date(timeIntervalSince1970: 1_793_686_620) // :17 past the hour, frozen.

    func testToolbarAPICLIAndModelsUseIdenticalNormalizedReceiptsAndTotals() async throws {
        let (service, overview, _) = try await savedFixture()
        let cli = try ActivityAccountingCLIRequest(arguments: ["view"])
        let expected = try cli.query.report(overview: overview)
        let core = ActivityAccounting.build(overview: overview, from: asOf.addingTimeInterval(-86_400), to: asOf)
        let router = makeRouter(service)
        let response = await router.handle(request("/activity/accounting"))
        XCTAssertEqual(response.status, 200)
        let actual = try BridgeJSON.decoder.decode(ActivityAccounting.Report.self, from: response.body)
        XCTAssertEqual(actual.scope, expected.scope)
        XCTAssertEqual(actual.receipts, core.receipts)
        XCTAssertEqual(actual.modelRows, expected.modelRows)
        XCTAssertEqual(actual.totals.usage, expected.totals.usage)
        XCTAssertEqual(actual.totals.tokensKnown, 275, "Cache reads and reasoning subsets are not additional tokens")
        XCTAssertEqual(actual.totals.outputKnown, 32)
        XCTAssertEqual(actual.modelRows.compactMap(\.tokens).reduce(0, +), 275)
        XCTAssertNil(actual.totals.weightedEquivalent, "One authoritative total without composition cannot be silently replaced by zero components")

        let chartResponse = await router.handle(request("/usage/series"))
        XCTAssertEqual(chartResponse.status, 200)
        let chart = try BridgeJSON.decoder.decode(TokenSeriesSnapshot.self, from: chartResponse.body)
        XCTAssertEqual(chart.generatedAt, actual.scope.asOf)
        XCTAssertEqual(chart.hourlyScope, actual.scope)
        XCTAssertEqual(chart.hourly.authoritativeTotals, actual.totals.usage)
        XCTAssertEqual(chart.hourly.authoritativeTotals?.tokensKnown, 275)
        XCTAssertEqual(chart.hourly.authoritativeTotals?.outputKnown, 32)
        XCTAssertNil(chart.hourly.authoritativeTotals?.weightedEquivalent)
        XCTAssertEqual(chart.hourly.points.count, 25)
        XCTAssertEqual(chart.daily.points.count, 14)
        XCTAssertEqual(chart.hourly.points.first?.start, actual.scope.from)
        XCTAssertEqual(chart.hourly.points.last?.end, actual.scope.to)
        let points = chart.hourly.points.compactMap { $0.authoritativeTotals?.tokensKnown }.reduce(0, +)
        XCTAssertEqual(points + (chart.hourly.unallocated?.tokensKnown ?? 0), 275)
        let stored = try await service.overview()
        XCTAssertEqual(stored.generatedAt, asOf, "GET did not refresh a provider or change the saved snapshot")
        XCTAssertEqual(stored.accountUsage?.lifetimeTokens, 99_999_999, "Provider account totals remain a separate population")
    }

    func testKnownReportedTotalsSurviveMissingCompositionInNewTokenDTO() throws {
        let snapshot = TokenAccountingSeriesAdapter.build(overview: fixture())
        let last = try XCTUnwrap(snapshot.hourly.points.last)
        XCTAssertEqual(last.authoritativeByAgent?["codex"]?.tokensKnown, 170)
        XCTAssertEqual(last.authoritativeByAgent?["codex"]?.outputKnown, 27)
        XCTAssertNil(last.authoritativeByAgent?["codex"]?.weightedEquivalent)
        XCTAssertNil(last.byAgent["codex"], "Unknown components must not be represented by invented zero fields")
        XCTAssertEqual(last.authoritativeByAgent?["claude"]?.tokensKnown, 105)
        XCTAssertEqual(snapshot.sourceScope, .localNativeHistory)
        XCTAssertEqual(snapshot.accountingSchemaVersion, "accounting/1")
        let encoded = try BridgeJSON.compactEncoder.encode(snapshot)
        XCTAssertEqual(try BridgeJSON.decoder.decode(TokenSeriesSnapshot.self, from: encoded), snapshot)
    }

    func testSubMillisecondQueryAndTokenSnapshotMatchPublicWirePrecision() throws {
        var overview = fixture()
        overview.generatedAt = asOf.addingTimeInterval(0.0002)
        let query = ActivityAccountingQuery(from: asOf.addingTimeInterval(-60 + 0.0001), to: asOf.addingTimeInterval(0.0003))
        XCTAssertEqual(ActivityAccountingPrecision.date(overview.generatedAt), ActivityAccountingPrecision.date(query.to!))
        let direct = try query.report(overview: overview)
        let publicQuery = try ActivityAccountingQuery.parse(target: query.path())
        let publicReport = try publicQuery.report(overview: overview)
        XCTAssertEqual(direct.scope, publicReport.scope)
        XCTAssertEqual(direct.receipts, publicReport.receipts)
        XCTAssertEqual(direct.totals.usage, publicReport.totals.usage)
        let snapshot = TokenAccountingSeriesAdapter.build(overview: overview)
        XCTAssertEqual(snapshot.generatedAt, snapshot.hourlyScope?.asOf)
        XCTAssertEqual(snapshot.generatedAt, snapshot.dailyScope?.asOf)
        XCTAssertEqual(snapshot.generatedAt, ActivityAccountingPrecision.date(overview.generatedAt))
        let collapsed = ActivityAccountingQuery(from: asOf.addingTimeInterval(0.0001), to: asOf.addingTimeInterval(0.0003))
        XCTAssertThrowsError(try collapsed.report(overview: overview))
        XCTAssertThrowsError(try ActivityAccountingQuery.parse(target: collapsed.path()).report(overview: overview))
    }

    func testScopesAndSelectorsValidateWithoutFilesystemOrProviderProbes() throws {
        let overview = fixture()
        let query = try ActivityAccountingQuery(queryItems: [
            .init(name: "window", value: "all"), .init(name: "provider", value: "codex"),
            .init(name: "project", value: "/fixture/Project A"), .init(name: "session", value: "codex:one"),
        ])
        let report = try query.report(overview: overview)
        XCTAssertNil(report.scope.from)
        XCTAssertEqual(report.scope.sessionIDs, ["codex:one"])
        XCTAssertEqual(report.totals.tokensKnown, 170)
        let roundTrip = try ActivityAccountingQuery.parse(target: query.path())
        XCTAssertEqual(roundTrip, query)
        XCTAssertThrowsError(try ActivityAccountingQuery(provider: AgentName.none).resolve(overview: overview))
        XCTAssertThrowsError(try ActivityAccountingQuery(session: "codex:missing").resolve(overview: overview))
        XCTAssertThrowsError(try ActivityAccountingQuery(project: "/fixture/missing").resolve(overview: overview))
        XCTAssertThrowsError(try ActivityAccountingQuery(from: asOf, to: asOf).resolve(overview: overview))
        XCTAssertThrowsError(try ActivityAccountingQuery(to: asOf.addingTimeInterval(1)).resolve(overview: overview))
        XCTAssertThrowsError(try ActivityAccountingQuery(from: Date(timeIntervalSince1970: .nan)).resolve(overview: overview))
        XCTAssertThrowsError(try ActivityAccountingQuery.parse(target: "/activity/accounting?window=all&window=24h"))
        XCTAssertThrowsError(try ActivityAccountingQuery.parse(target: "/activity/accounting?unknown=value"))
        XCTAssertThrowsError(try ActivityAccountingQuery.parse(target: "/activity/accounting?provider=not-a-provider"))
        XCTAssertThrowsError(try ActivityAccountingQuery.parse(target: "/activity/accounting?from=not-a-date"))
        XCTAssertThrowsError(try ActivityAccountingQuery.parseDate("2026-02-30T00:00:00Z"))
        XCTAssertThrowsError(try ActivityAccountingQuery.parseDate("2026-11-03T25:00:00Z"))
        XCTAssertThrowsError(try ActivityAccountingQuery.parse(target: "/activity/accounting?from=2026-01-01T00:00:00Z&window=all"))
    }

    func testEndpointAuthInvalidQueriesAndEmptySourceFailExplicitly() async throws {
        let (service, _, _) = try await savedFixture()
        let router = makeRouter(service)
        let unauthorized = await router.handle(request("/activity/accounting", authorized: false))
        XCTAssertEqual(unauthorized.status, 401)
        let bad = await router.handle(request("/activity/accounting?window=tomorrow"))
        XCTAssertEqual(bad.status, 400)
        let future = try ActivityAccountingQuery(to: asOf.addingTimeInterval(60)).path()
        let futureResponse = await router.handle(request(future))
        XCTAssertEqual(futureResponse.status, 400)

        let directory = try temporaryDirectory()
        let empty = ActivityReportingService(databaseURL: directory.appendingPathComponent("empty.sqlite"))
        let emptyRouter = makeRouter(empty)
        let response = await emptyRouter.handle(request("/activity/accounting"))
        XCTAssertEqual(response.status, 503)
        let noToken = await emptyRouter.handle(request("/activity/accounting", authorized: false))
        XCTAssertEqual(noToken.status, 401)
        let series = await emptyRouter.handle(request("/usage/series"))
        let value = try BridgeJSON.decoder.decode(TokenSeriesSnapshot.self, from: series.body)
        XCTAssertTrue(value.hourly.points.isEmpty)
        XCTAssertTrue(value.daily.points.isEmpty)
        XCTAssertNil(value.hourlyScope)
        XCTAssertNil(value.hourly.authoritativeTotals)
        XCTAssertEqual(value.statusMessage, TokenSeriesSnapshot.empty.statusMessage)
        XCTAssertEqual(value.status, "unavailable")
        let emptyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: series.body) as? [String: Any])
        XCTAssertTrue(emptyJSON["hourly_scope"] is NSNull)
    }

    func testUnattributedProjectIsAnExplicitGroupAndProjectTotalsConserve() throws {
        var overview = fixture()
        var missing = overview.sessions[0]
        missing.id = "codex:unattributed"; missing.nativeID = "unattributed"; missing.projectPath = nil
        missing.turns = missing.turns.map { value in
            var value = value
            value.id = "unattributed-" + value.id
            value.modelSteps = value.modelSteps?.map { step in var step = step; step.id = "unattributed-" + step.id; return step }
            return value
        }
        overview.sessions.append(missing)
        let selector = ActivityAccountingQuery.unattributedProjectID
        let unknown = try ActivityAccountingQuery(project: selector).report(overview: overview)
        XCTAssertEqual(unknown.scope.sessionIDs, [missing.id])
        XCTAssertEqual(unknown.totals.tokensKnown, 170)
        let a = try ActivityAccountingQuery(project: "/fixture/Project A").report(overview: overview)
        let b = try ActivityAccountingQuery(project: "/fixture/Project B").report(overview: overview)
        let all = try ActivityAccountingQuery().report(overview: overview)
        XCTAssertEqual([a, b, unknown].compactMap { $0.totals.tokensKnown }.reduce(0, +), all.totals.tokensKnown)
        let incompatible = try ActivityAccountingQuery(provider: .claude, project: selector).report(overview: overview)
        XCTAssertTrue(incompatible.scope.sessionIDs.isEmpty)
        XCTAssertNil(incompatible.totals.tokensKnown, "Empty grouped selection must not become all projects")
        let parsed = try ActivityAccountingQuery.parse(target: "/activity/accounting?project=" + selector)
        XCTAssertEqual(parsed.project, selector)
    }

    func testPrimaryTokenStoreReadsSavedActivityEvenWhenForceIsRequested() async throws {
        let (service, overview, _) = try await savedFixture()
        let store = TokenLedgerStore(activityService: service)
        let first = await store.series(now: asOf.addingTimeInterval(1_000_000), force: true)
        XCTAssertEqual(first, TokenAccountingSeriesAdapter.build(overview: overview))
        XCTAssertEqual(first.generatedAt, asOf, "The consumer clock cannot re-date the accounting source")
    }

    func testCalendarFourteenDaysAtMidnightRemainFourteenCompleteBins() throws {
        var overview = fixture()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ActivityAnalytics.reportingTimeZone
        overview.generatedAt = calendar.startOfDay(for: asOf)
        let snapshot = TokenAccountingSeriesAdapter.build(overview: overview)
        XCTAssertEqual(snapshot.daily.points.count, 14)
        XCTAssertEqual(snapshot.daily.windowTo, overview.generatedAt)
        XCTAssertEqual(snapshot.daily.points.last?.end, overview.generatedAt)
    }

    func testLegacyTokenJSONStillDecodesWithoutPretendingItHasCanonicalMeasurements() throws {
        let json = """
        {"hourly":{"bucket":"hour","points":[{"start":"2026-11-03T08:00:00.000Z","by_agent":{"codex":{"fresh_input":1,"cache_read":2,"cache_write":0,"output":3}}}]},"daily":{"bucket":"day","points":[]},"generated_at":"2026-11-03T08:17:00.000Z","bucket_count":1}
        """
        let value = try BridgeJSON.decoder.decode(TokenSeriesSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(value.accountingSchemaVersion)
        XCTAssertNil(value.hourly.authoritativeTotals)
        XCTAssertNil(value.hourly.points[0].authoritativeByAgent)
        XCTAssertEqual(value.hourly.points[0].byAgent["codex"]?.output, 3)
    }

    func testMetricsCLIOptionsAreReadOnlyStrictAndShareDateParsing() throws {
        let request = try ActivityAccountingCLIRequest(arguments: ["export", "--window", "all", "--provider", "codex", "--output", "metrics.json", "--overwrite"])
        XCTAssertEqual(request.action, .export)
        XCTAssertEqual(request.query.window, .all)
        XCTAssertTrue(request.overwrite)
        XCTAssertEqual(request.output, "metrics.json")
        XCTAssertThrowsError(try ActivityAccountingCLIRequest(arguments: ["refresh"]))
        XCTAssertThrowsError(try ActivityAccountingCLIRequest(arguments: ["view", "--output", "metrics.json"]))
        XCTAssertThrowsError(try ActivityAccountingCLIRequest(arguments: ["view", "--refresh"]))
        XCTAssertThrowsError(try ActivityAccountingCLIRequest(arguments: ["--provider", "codex", "--provider", "claude"]))
        XCTAssertThrowsError(try ActivityAccountingCLIRequest(arguments: ["--to"]))
        XCTAssertThrowsError(try ActivityAccountingCLIRequest(arguments: ["--window", "all", "--from", "2026-11-03T00:00:00Z"]))
    }

    func testMetricsExportsAreAtomicPrivateAndRefuseUnexpectedTargets() throws {
        let directory = try temporaryDirectory()
        let report = try ActivityAccountingQuery().report(overview: fixture())
        let destination = directory.appendingPathComponent("metrics.json")
        try ActivityAccountingExport.write(report, to: destination)
        let original = try Data(contentsOf: destination)
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertThrowsError(try ActivityAccountingExport.write(report, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try ActivityAccountingExport.write(report, to: destination, overwrite: true)
        let decoded = try BridgeJSON.decoder.decode(ActivityAccounting.Report.self, from: Data(contentsOf: destination))
        XCTAssertEqual(decoded.receipts, report.receipts)
        XCTAssertEqual(decoded.scope, report.scope)
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try ActivityAccountingExport.write(report, to: link, overwrite: true))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".hub-metrics-") }
        XCTAssertTrue(leftovers.isEmpty)
        let text = String(decoding: original, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_GOAL"))
        XCTAssertFalse(text.contains("PRIVATE_TITLE"))
    }

    private func savedFixture() async throws -> (ActivityReportingService, ActivityOverview, URL) {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("activity.sqlite")
        let database = try ActivityDatabase(url: url)
        let value = fixture()
        try database.merge([ActivityCollection(sessions: value.sessions, health: value.sources[0], accountUsage: value.accountUsage)], now: asOf)
        let service = ActivityReportingService(databaseURL: url)
        return (service, try await service.overview(), directory)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountingSurfaces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func fixture() -> ActivityOverview {
        let codex = TokenUsage(input: 100, output: 20, cachedInput: 80, cacheWriteInput: 0, reasoning: 5, total: 120, provenance: .providerReported)
        let claude = TokenUsage(input: 30, output: 5, cachedInput: 60, cacheWriteInput: 10, total: 105, provenance: .providerReported)
        let unknown = TokenUsage(output: 7, total: 50, provenance: .providerReported)
        func turn(_ id: String, _ model: String, _ usage: TokenUsage, seconds: Double) -> ActivityTurn {
            let at = asOf.addingTimeInterval(seconds)
            return ActivityTurn(id: id, startedAt: at.addingTimeInterval(-1), completedAt: at, durationSeconds: 1,
                status: "completed", promptCount: 1, toolCount: 0, usage: usage, usageIsPartial: false,
                modelSteps: [ActivityModelStep(id: "step-\(id)", timestamp: at, model: model, usage: usage, usageIsPartial: false)], modelStepsComplete: true)
        }
        let one = ActivitySession(id: "codex:one", provider: .codex, nativeID: "one", title: "PRIVATE_TITLE", projectPath: "/fixture/Project A",
            createdAt: asOf.addingTimeInterval(-100), updatedAt: asOf, observedAt: asOf,
            turns: [turn("one", "gpt-6-astra", codex, seconds: -20), turn("two", "gpt-6.1-sol", unknown, seconds: -5)], historyComplete: true, source: "fixture")
        let two = ActivitySession(id: "claude:two", provider: .claude, nativeID: "two", title: "PRIVATE_TITLE", projectPath: "/fixture/Project B",
            createdAt: asOf.addingTimeInterval(-100), updatedAt: asOf, observedAt: asOf,
            turns: [turn("three", "claude-sonnet-5", claude, seconds: -10)], historyComplete: true, source: "fixture")
        return ActivityOverview(generatedAt: asOf, sessions: [one, two],
            sources: [ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: asOf, lastSuccessAt: asOf, message: "Fixture")],
            accountUsage: ActivityAccountUsage(observedAt: asOf, lifetimeTokens: 99_999_999))
    }
    private func makeRouter(_ service: ActivityReportingService) -> BridgeRouter {
        var configuration = BridgeConfiguration(server: ServerConfiguration(bearerToken: "accounting-fixture-token"))
        configuration.agents.claudeCommand = "/fixture/never-invoke-claude"
        configuration.agents.codexCommand = "/fixture/never-invoke-codex"
        configuration.agents.grokCommand = "/fixture/never-invoke-grok"
        let orchestrator = Orchestrator(configuration: configuration, claudeRunner: AccountingNeverRunner(agent: .claude),
            codexRunner: AccountingNeverRunner(agent: .codex), grokRunner: AccountingNeverRunner(agent: .grok), configurationSaver: { _ in })
        return BridgeRouter(configuration: configuration, orchestrator: orchestrator, activityService: service)
    }
    private func request(_ target: String, authorized: Bool = true) -> HTTPRequest {
        HTTPRequest(method: "GET", target: target, headers: authorized ? ["authorization": "Bearer accounting-fixture-token"] : [:], body: Data())
    }
}

private struct AccountingNeverRunner: AgentRunner {
    var agent: AgentName
    func run(project: URL, prompt: String, nativeSessionID: String?, bridgeSessionID: String) async throws -> AgentResult {
        throw BridgeError.processFailed("A reporting GET must never execute a provider.")
    }
}
