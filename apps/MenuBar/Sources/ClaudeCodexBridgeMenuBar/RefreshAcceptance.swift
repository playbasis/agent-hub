import AppKit
import BridgeCore
import CryptoKit
import Darwin
import Foundation
import SwiftUI

enum RefreshAcceptancePolicy {
    enum Mode: String, Codable { case replay, live }
    enum Outcome: String, Codable { case complete, partial, unsupported, failed }
    static let pages = ["overview", "now", "goals", "agents", "projects", "models", "journal", "provider-proof", "accounts", "credits", "logs", "settings", "team-chat", "glm-chat", "panel"]
    struct Configuration: Codable {
        var mode: Mode
        var pages: [String]
        var cycles: Int
        var warmupCycles: Int
        var budgetSeconds: Double
        var maximumLiveRefreshes: Int
        var maximumSteadyGrowthMB: Double
        init(environment: [String: String]) throws {
            guard let mode = Mode(rawValue: environment["BRIDGE_REFRESH_MODE"] ?? "replay") else { throw Failure("Mode must be replay or live.") }
            self.mode = mode
            let requested = (environment["BRIDGE_REFRESH_PAGES"] ?? RefreshAcceptancePolicy.pages.joined(separator: ","))
                .split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !requested.isEmpty, requested.allSatisfy(RefreshAcceptancePolicy.pages.contains), Set(requested).count == requested.count else { throw Failure("Use unique supported page IDs, including glm-chat or panel.") }
            pages = requested
            func integer(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
                guard let value = Int(environment[key] ?? "\(fallback)"), range.contains(value) else { throw Failure("Invalid bounded setting: \(key).") }
                return value
            }
            cycles = try integer("BRIDGE_REFRESH_CYCLES", 3, 2 ... 5)
            warmupCycles = try integer("BRIDGE_REFRESH_WARMUP_CYCLES", 1, 0 ... 1)
            maximumLiveRefreshes = try integer("BRIDGE_REFRESH_MAX_LIVE", 45, 1 ... 70)
            guard let budget = Double(environment["BRIDGE_REFRESH_TIMEOUT"] ?? (mode == .replay ? "300" : "1200")), budget.isFinite, (30 ... 3600).contains(budget),
                  let growth = Double(environment["BRIDGE_REFRESH_MEMORY_MB"] ?? "96"), growth.isFinite, (0 ... 2048).contains(growth) else { throw Failure("Invalid bounded time or memory setting.") }
            budgetSeconds = budget; maximumSteadyGrowthMB = growth
        }
    }
    struct Failure: Error, LocalizedError { var message: String; init(_ value: String) { message = value }; var errorDescription: String? { message } }
    static func outcome(cyclesRequested: Int, completed: Int, failed: Bool, requiredUnsupported: Bool) -> Outcome {
        if failed { return .failed }
        if completed == 0 { return .unsupported }
        if cyclesRequested < 2 || completed != cyclesRequested || requiredUnsupported { return .partial }
        return .complete
    }
    static func preserved(_ before: [String: String], _ after: [String: String], keys: Set<String>) -> Bool {
        !keys.isEmpty && keys.allSatisfy { before[$0] != nil && before[$0] == after[$0] }
    }
    static func renderedCurrent(_ state: [String: String], revision: UInt64) -> Bool {
        state["preparing"] == "false" && state["preparedMatchesInputs"] == "true" && state["renderedRevision"] == String(revision)
    }
    struct Target: Codable, Equatable {
        var revision: UInt64
        var asOf: Date
        func matches(revision: UInt64, asOf: Date) -> Bool { self.revision == revision && self.asOf == asOf }
    }
    enum RenderState: Equatable { case waiting, complete, interference }
    enum ServiceReadiness: String { case pending, loading, ready, empty, error, unsupported }
    static func serviceReadiness(_ state: [String: String]) -> ServiceReadiness {
        if state["transient.unsupported"] == "true" { return .unsupported }
        if state["transient.error"] == "true" { return .error }
        if state["transient.loading"] == "true" { return .loading }
        if state["transient.ready"] == "true" { return state["transient.hasData"] == "true" ? .ready : .empty }
        return .pending
    }
    static func phaseDeadline(start: Double, overallEnd: Double) -> Double { min(overallEnd, start + 180) }
    static func renderState(target: Target, revision: UInt64, asOf: Date, projectionBusy: Bool,
                            renderedRevision: String?, preparedMatches: Bool, preparing: Bool) -> RenderState {
        guard target.matches(revision: revision, asOf: asOf) else { return .interference }
        return !projectionBusy && !preparing && preparedMatches && renderedRevision == String(target.revision) ? .complete : .waiting
    }
    struct Memory: Codable {
        var status: Outcome
        var validSamples: Int
        var peakMB: Double?
        var steadyFirstMB: Double?
        var steadyLastMB: Double?
        var steadyGrowthMB: Double?
        var limitMB: Double
        var samplingMethod = "instantaneous/1"
        var rawSteadyGrowthMB: Double?
        var processLifetimePeakMB: Double?
        var explanation = "Per-page post-warmup footprint observation, not proof of absence of leaks."
    }
    static func memory(samples: [(cycle: Int, mb: Double?)], warmup: Int, limit: Double) -> Memory {
        let valid = samples.compactMap { $0.mb }.filter { $0.isFinite && $0 >= 0 }
        let steady = samples.filter { $0.cycle > warmup }.compactMap(\.mb).filter { $0.isFinite && $0 >= 0 }
        let growth = steady.count >= 2 ? max(0, steady.last! - steady.first!) : nil
        return Memory(status: growth.map { $0 > limit ? .failed : .complete } ?? .partial, validSamples: valid.count,
                      peakMB: valid.max(), steadyFirstMB: steady.first, steadyLastMB: steady.last, steadyGrowthMB: growth, limitMB: limit)
    }
    struct IdleReading: Codable, Equatable {
        var seconds: Double
        var footprintMB: Double?
        var processLifetimePeakMB: Double?
        var idle: Bool
    }
    struct Settlement: Codable {
        var stable: Bool
        var postIdleMB: Double?
        var observedPeakMB: Double?
        var processLifetimePeakMB: Double?
        var elapsedSeconds: Double
        var readings: [IdleReading]
    }
    /// Fixed policy: at least three continuous idle seconds, then a stable
    /// terminal four-sample window. Never choose the minimum observed value.
    static func settlement(_ samples: [IdleReading]) -> Settlement {
        func valid(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } == true }
        let terminal = Array(samples.suffix(4))
        var quietStart = samples.count
        while quietStart > 0, samples[quietStart - 1].idle, valid(samples[quietStart - 1].footprintMB) { quietStart -= 1 }
        let quietSeconds = quietStart < samples.count ? (samples.last!.seconds - samples[quietStart].seconds) : 0
        let values = terminal.compactMap(\.footprintMB).filter { $0.isFinite && $0 >= 0 }.sorted()
        let stable = terminal.count == 4 && values.count == 4 && terminal.allSatisfy(\.idle)
            && quietSeconds >= 3 && (values.last! - values.first!) <= 2
        let median = stable ? values[1] / 2 + values[2] / 2 : nil
        return Settlement(stable: stable, postIdleMB: median,
                          observedPeakMB: samples.compactMap(\.footprintMB).filter { $0.isFinite && $0 >= 0 }.max(),
                          processLifetimePeakMB: samples.compactMap(\.processLifetimePeakMB).filter { $0.isFinite && $0 >= 0 }.max(),
                          elapsedSeconds: samples.last?.seconds ?? 0, readings: samples)
    }
}

/// In-process, preview-only acceptance. Replay changes only an isolated view
/// model; live mode requests bounded passive metadata refreshes. Neither mode
/// signs in, sends chat, saves settings, or controls native goals/model turns.
@MainActor
enum RefreshAcceptance {
    static var reportPath: String? {
        let env = ProcessInfo.processInfo.environment
        guard env["BRIDGE_UI_PREVIEW"] == "1", let path = env["BRIDGE_REFRESH_ACCEPTANCE"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return path
    }
    /// Unknown modes fail configuration, never accidentally enable live work.
    static var isReplayMode: Bool { reportPath != nil && ProcessInfo.processInfo.environment["BRIDGE_REFRESH_MODE"] != "live" }
    struct Check: Codable {
        var feature: String
        var status: RefreshAcceptancePolicy.Outcome
        var required: Bool
        var detail: String
    }
    struct Snapshot: Codable {
        var cycle: Int
        var generatedAt: Date
        var scrollOffset: Double?
        var scrollViewIdentity: Int?
        var hubState: [String: String]
        var states: [String: [String: String]]
        var unmounted: [String: Int]
        var loadingShown: Int
        var footprintMB: Double?
        var seconds: Double
        var refreshCompleted: Bool
        var inputSize: InputSize
        /// footprintMB remains the original immediate post-render reading.
        /// Only the separate stable terminal-window value is used for the
        /// post-idle policy; raw observations and peaks are never discarded.
        var postIdleFootprintMB: Double?
        var memorySettled = false
        var memoryIdleSeconds: Double = 0
        var sampledPeakMB: Double?
        var processLifetimePeakMB: Double?
        var memoryReadings: [RefreshAcceptancePolicy.IdleReading] = []
    }
    struct InputSize: Codable, Equatable {
        var sessions: Int
        var storedNativeRecords: Int?
        var storedModelSteps: Int?
        var basis = "Stored input array entries, including copied evidence; not deduplicated model-call or token metrics."
        init(_ overview: ActivityOverview) {
            sessions = overview.sessions.count
            var records = 0, steps = 0, recordOverflow = false, stepOverflow = false
            for session in overview.sessions {
                let next = records.addingReportingOverflow(session.turns.count)
                records = next.partialValue; recordOverflow = recordOverflow || next.overflow
                for turn in session.turns {
                    let next = steps.addingReportingOverflow(turn.modelSteps?.count ?? 0)
                    steps = next.partialValue; stepOverflow = stepOverflow || next.overflow
                }
            }
            storedNativeRecords = recordOverflow ? nil : records
            storedModelSteps = stepOverflow ? nil : steps
        }
    }
    struct PageResult: Codable {
        var page: String
        var status: RefreshAcceptancePolicy.Outcome
        var setUp: [String]
        var checks: [Check]
        var snapshots: [Snapshot]
        var preserved: Bool
        var memory: RefreshAcceptancePolicy.Memory?
        var notes: [String]
        var liveRefreshesUsed = 0
        var phase = "setting-up"
        var cycleProgress: [CycleProgress] = []
        var serviceReadiness: [String: String]?
    }
    struct CycleProgress: Codable {
        var cycle: Int
        var phase = "source"
        var sourceSeconds: Double?
        var renderSeconds: Double?
        var target: RefreshAcceptancePolicy.Target?
        var interference = false
        var failure: String?
    }
    struct Report: Codable {
        var reportVersion = "refresh-acceptance/3"
        var startedAt = Date()
        var finishedAt: Date?
        var status: RefreshAcceptancePolicy.Outcome = .partial
        var phase = "starting"
        var configuration: RefreshAcceptancePolicy.Configuration?
        var fixture = "unknown"
        var sessionCount = 0
        var inputSize: InputSize?
        var preferencesIsolated = true
        var liveRefreshes = 0
        var results: [PageResult] = []
        var failures: [String] = []
        mutating func markReady(mode: RefreshAcceptancePolicy.Mode, fixtureLabel: String, overview: ActivityOverview) {
            fixture = mode == .replay ? fixtureLabel : "live-passive-metadata"
            sessionCount = overview.sessions.count
            inputSize = InputSize(overview)
        }
    }
    private static var running = false
    private static var fixtureLabel = "synthetic"

    /// Called by App startup with automaticallyConnect:false in replay mode.
    /// A caller-selected saved fixture is bounded; fallback is explicit and
    /// deterministic, never a provider read or a fabricated live connection.
    static func loadReplayFixture() async -> ActivityOverview {
        if let path = ProcessInfo.processInfo.environment["BRIDGE_REFRESH_FIXTURE"], !path.isEmpty {
            if path.hasPrefix("/"), let value = await ActivitySnapshotCache(url: URL(fileURLWithPath: path)).load() {
                fixtureLabel = "saved-local-fixture"; return value
            }
            fixtureLabel = "synthetic-fallback-unreadable-fixture"
        }
        return syntheticFixture()
    }
    private static func syntheticFixture() -> ActivityOverview {
        let time = Date(timeIntervalSince1970: 1_793_686_620)
        var sessions: [ActivitySession] = []
        for index in 0 ..< 26 {
            let provider: AgentName = index % 3 == 0 ? .claude : .codex
            let id = "\(provider.rawValue):acceptance-\(index)"
            let at = time.addingTimeInterval(Double(-3600 + index * 60))
            let usage = TokenUsage(input: 100, output: 20, cachedInput: 40, cacheWriteInput: 0, reasoning: 5, total: 120, provenance: .providerReported)
            let step = ActivityModelStep(id: "step-\(index)", timestamp: at, model: provider == .claude ? "claude-sonnet-5" : "gpt-6.1-sol", effort: "high", usage: usage, usageIsPartial: false)
            let turn = ActivityTurn(id: "turn-\(index)", startedAt: at.addingTimeInterval(-40), completedAt: at, durationSeconds: 40, status: "completed", promptCount: 1, humanPromptCount: nil, toolCount: 2, usage: usage, categories: ["implementation": 1, "tests": 1], usageIsPartial: false, modelSteps: [step], modelStepsComplete: true)
            let objective = "Acceptance fixture goal. " + String(repeating: "Preserve filters, expanded sections and selections while reporting recorded evidence. ", count: 3)
            let goal = index == 1 ? ActivityGoal(id: "fixture-goal", sessionID: id, objective: objective, status: "active", createdAt: time.addingTimeInterval(-7200), updatedAt: time) : nil
            sessions.append(ActivitySession(id: id, provider: provider, nativeID: "acceptance-\(index)", title: "Acceptance \(index == 1 ? "goal" : "agent") \(index)", projectPath: index == 25 ? nil : "/acceptance/Acceptance-project", createdAt: time.addingTimeInterval(-7200), updatedAt: at, observedAt: time,
                parentSessionID: index > 1 && index < 20 ? "codex:acceptance-1" : nil, goal: goal, turns: [turn], historyComplete: true, source: "acceptance-fixture/1"))
        }
        return ActivityOverview(generatedAt: time, sessions: sessions, sources: [ActivitySourceHealth(id: "acceptance-fixture", status: "ready", checkedAt: time, lastSuccessAt: time, message: "Deterministic metadata fixture; no provider execution.")], pinnedSessionID: "codex:acceptance-1")
    }

    static func run(model: BridgeViewModel) async {
        guard let path = reportPath, !running else { return }
        running = true
        var report = Report()
        defer { running = false; AcceptanceProbe.cleanupDefaults() }
        do {
            guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension == "json" else { throw RefreshAcceptancePolicy.Failure("Acceptance report must be an absolute .json artifact path.") }
            let config = try RefreshAcceptancePolicy.Configuration(environment: ProcessInfo.processInfo.environment)
            report.configuration = config; report.fixture = config.mode == .replay ? "loading-replay-fixture" : "live-passive-metadata"
            try checkpoint(report, to: path)
            let end = ProcessInfo.processInfo.systemUptime + config.budgetSeconds
            let ready = await waitUntil(timeout: config.mode == .live ? 90 : 20, end: end) {
                model.activityOverview.generatedAt != .distantPast && (config.mode == .replay || model.isReady)
            }
            guard ready else { throw RefreshAcceptancePolicy.Failure("Startup readiness timed out; no page was accepted as tested.") }
            // The fixture is loaded asynchronously by App startup. Do not
            // freeze its manifest label before the source is actually ready.
            report.markReady(mode: config.mode, fixtureLabel: fixtureLabel, overview: model.activityOverview)
            let source = model.activityOverview
            for id in config.pages {
                guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < end else {
                    report.failures.append("Run budget ended; remaining requested pages are untested."); break
                }
                report.phase = "setting-up:\(id)"
                report.results.append(PageResult(page: id, status: .partial, setUp: [], checks: [], snapshots: [], preserved: false, memory: nil, notes: ["Setup in progress."]))
                try checkpoint(report, to: path)
                let priorReport = report
                let result = await exercise(page: id, model: model, source: source, configuration: config, end: end,
                    liveAllowance: max(0, config.maximumLiveRefreshes - report.liveRefreshes)) { partial in
                    var checkpointReport = priorReport
                    checkpointReport.phase = "\(id):\(partial.phase)"
                    checkpointReport.liveRefreshes += partial.liveRefreshesUsed
                    checkpointReport.results[checkpointReport.results.count - 1] = partial
                    try checkpoint(checkpointReport, to: path)
                }
                report.results[report.results.count - 1] = result
                report.liveRefreshes += result.liveRefreshesUsed
                try checkpoint(report, to: path)
            }
            let outcomes = report.results.map(\.status)
            report.status = !report.failures.isEmpty || outcomes.contains(.failed) ? .failed
                : (report.results.count == config.pages.count && outcomes.allSatisfy { $0 == .complete } && !report.fixture.contains("fallback") ? .complete : .partial)
        } catch {
            report.status = .failed
            report.failures.append("Acceptance could not finish: \(error.localizedDescription)")
        }
        report.phase = "finished"; report.finishedAt = Date()
        do { try checkpoint(report, to: path) }
        catch {
            // Do not terminate quietly after losing the only result. A new,
            // private recovery artifact is attempted in the system temp folder.
            let recovery = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hub-acceptance-recovery-\(UUID().uuidString).json")
            report.status = .failed; report.failures.append("Primary report persistence failed.")
            do { try writePrivate(report, to: recovery); progress("FAILED; recovery report: \(recovery.path)") }
            catch { progress("FAILED: neither primary nor recovery report could be saved.") }
        }
        progress("finished: \(report.status.rawValue), \(report.results.count) pages, \(report.liveRefreshes) passive live refreshes")
        NSApp.terminate(nil)
    }

    private static func exercise(page: String, model: BridgeViewModel, source: ActivityOverview, configuration: RefreshAcceptancePolicy.Configuration, end: Double,
                                 liveAllowance: Int, save: (PageResult) throws -> Void) async -> PageResult {
        var result = PageResult(page: page, status: .partial, setUp: [], checks: [], snapshots: [], preserved: false, memory: nil, notes: [])
        let controller = ActivityReportsController.shared
        let isPanel = page == "panel"
        if isPanel { model.panelTab = .activity; GlassPreviewWindow.showIfRequested(model: model) }
        else { controller.navigate(to: BridgePage.restored(page)); controller.selectedSessionID = nil }
        guard let root = isPanel ? GlassPreviewWindow.hostView : NSApp.windows.first(where: { ObjectIdentifier($0) == controller.windowIdentity })?.contentView else {
            result.status = .failed; result.notes.append("Required hosting root was unavailable; page was not skipped."); return result
        }
        let mountedName = isPanel ? "panel.hud" : "page.\(page)"
        guard await waitUntil(timeout: 180, end: end, { AcceptanceProbe.visible(mountedName) > 0 && loadingVisible == 0 }) else {
            result.status = .failed; result.notes.append("Page content did not mount before the deadline."); return result
        }
        var expected: [String: [String: String]] = [:]
        func apply(_ feature: String, command: String, value: String? = nil, scope: String = "hub", key: String, target: String, required: Bool = true) async {
            let response = await transact(command, value: value, scope: scope, end: end)
            guard let response else { result.checks.append(Check(feature: feature, status: .unsupported, required: required, detail: "No state hook acknowledged the command.")); return }
            guard response.supported else { result.checks.append(Check(feature: feature, status: .unsupported, required: required, detail: "The page reports this interaction unsupported.")); return }
            let applied = await waitUntil(timeout: 8, end: end) {
                AcceptanceProbe.send("report", scope: scope)
                return AcceptanceProbe.states[scope]?[key] == target
            }
            result.checks.append(Check(feature: feature, status: applied ? .complete : .failed, required: required, detail: applied ? "Applied and observed through the state hook." : "Command was acknowledged but the requested state was not observed."))
            if applied { expected[scope, default: [:]][key] = target; result.setUp.append(feature) }
        }
        if !isPanel, BridgePage.restored(page).showsActivityFilters {
            _ = await transact("state.reset", scope: "hub", end: end)
            let candidate = source.sessions.first(where: { $0.provider == .codex && $0.goal != nil }) ?? source.sessions.first
            if let candidate {
                await apply("provider", command: "filter.provider", value: candidate.provider.rawValue, key: "provider", target: candidate.provider.rawValue)
                let project = candidate.projectPath ?? ActivityAccountingQuery.unattributedProjectID
                await apply("project", command: "filter.project", value: project, key: "project", target: project)
                await apply("period", command: "filter.period", value: ReportPeriod.all.rawValue, key: "period", target: ReportPeriod.all.rawValue)
                let search = fixtureLabel.hasPrefix("synthetic") && configuration.mode == .replay ? "Acceptance" : (candidate.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(candidate.nativeID.prefix(8)))
                await apply("search", command: "filter.query", value: search, key: "query", target: search)
                let filtered = await waitUntil(timeout: 180, end: end) {
                    AcceptanceProbe.send("report", scope: "hub")
                    return RefreshAcceptancePolicy.renderedCurrent(AcceptanceProbe.states["hub"] ?? [:], revision: model.activityRevision)
                }
                guard filtered else { result.status = .failed; result.notes.append("Filtered report did not settle before inspector setup."); return result }
                if page == "goals" {
                    let goalScope = "goal:\(candidate.id)"
                    let response = await transact("exercise.safe", scope: goalScope, end: end)
                    if let response, response.supported, response.state["range"] == "6h", response.state["group"] == "Role" {
                        expected[goalScope] = ["range": "6h", "group": "Role"]
                        result.checks.append(Check(feature: "goal range and grouping", status: .complete, required: true, detail: "6-hour range and Role grouping were observed."))
                        if response.state["objectiveApplicable"] == "true" {
                            let open = response.state["objective"] == "true"
                            if open { expected[goalScope]?["objective"] = "true" }
                            result.checks.append(Check(feature: "goal objective expansion", status: open ? .complete : .failed, required: true, detail: open ? "Applicable objective disclosure expanded." : "Objective disclosure did not expand."))
                        } else {
                            result.checks.append(Check(feature: "goal objective expansion", status: .unsupported, required: false, detail: "Objective fits without a disclosure; expansion is not applicable."))
                        }
                    } else {
                        result.checks.append(Check(feature: "goal range and grouping", status: response?.supported == true ? .failed : .unsupported, required: true, detail: "No matching goal range/group state was confirmed."))
                    }
                }
                if BridgePage.restored(page).supportsSessionInspector {
                let response = await transact("inspect.first", scope: "hub", end: end)
                if let selected = response?.state["selected"], response?.supported == true, !selected.isEmpty,
                   await waitUntil(timeout: 15, end: end, { AcceptanceProbe.visible("inspector") > 0 }) {
                    expected["hub", default: [:]]["selected"] = selected
                    result.checks.append(Check(feature: "inspector", status: .complete, required: true, detail: "Selection and mounted inspector were both observed."))
                } else { result.checks.append(Check(feature: "inspector", status: .unsupported, required: true, detail: "No matching session/inspector was available.")) }
                }
            } else { result.checks.append(Check(feature: "filters", status: .unsupported, required: true, detail: "No saved session could provide nonempty filter values.")) }
            if page == "now" {
                let response = await transact("expand.first", scope: "hub", end: end)
                if let expanded = response?.state["expanded"], response?.supported == true, !expanded.isEmpty {
                    expected["hub", default: [:]]["expanded"] = expanded
                    result.checks.append(Check(feature: "sub-agent expander", status: .complete, required: true, detail: "A nonempty expanded group was observed."))
                } else { result.checks.append(Check(feature: "sub-agent expander", status: .unsupported, required: true, detail: "No matching expandable group was observed.")) }
            }
            if page == "agents" {
                let response = await transact("exercise.safe", scope: "agents", end: end)
                if let response, response.supported, let filter = response.state["filter"], filter != "all",
                   let sort = response.state["sort"], sort == "Most recent" {
                    expected["agents"] = ["filter": filter, "sort": sort]
                    result.checks.append(Check(feature: "roster filter and sort", status: .complete, required: true, detail: "A non-default role filter and recent sort were observed."))
                } else {
                    result.checks.append(Check(feature: "roster filter and sort", status: response?.supported == true ? .failed : .unsupported, required: true, detail: "No applicable roster filter/sort state was confirmed."))
                }
            }
            if page == "overview" { await apply("source disclosure", command: "about.open", key: "aboutOpen", target: "true") }
            if page == "credits" {
                if let response = await transact("exercise.safe", scope:"credits", end:end), response.supported {
                    expected["credits"] = response.state
                    result.checks.append(Check(feature:"credit period, dimension, disclosure and chart selection",status:.complete,required:true,detail:"Isolated fixture controls were observed; no provider calls or writes."))
                } else {
                    result.checks.append(Check(feature:"credit local state",status:.unsupported,required:true,detail:"Credit state hook did not acknowledge the fixture."))
                }
            }
        }
        if isPanel {
            await apply("token disclosure", command: "disclosure.open", scope: "panel", key: "expanded", target: "true")
            await apply("chart window", command: "chart.window", value: "day", scope: "panel-chart", key: "bucket", target: "day")
            await apply("chart selection", command: "chart.metric", value: "output", scope: "panel-chart", key: "metric", target: "output")
            _ = await waitUntil(timeout: 10, end: end) { AcceptanceProbe.visible("panel.token-chart") > 0 }
        } else if !BridgePage.restored(page).showsActivityFilters {
            // Service pages opt into safe state-only commands. No authentication,
            // send, save, publish or native-session command exists in this set.
            let scope = page
            var response: AcceptanceProbe.Response?
            var readinessCheckAdded = false
            if ["journal", "provider-proof", "team-chat"].contains(page) {
                result.phase = "service-readiness"
                do { try save(result) }
                catch { result.status = .failed; result.notes.append("Service-readiness checkpoint failed."); return result }
                let ready = await serviceExercise(scope: scope, end: end)
                response = ready.response
                result.serviceReadiness = AcceptanceProbe.states[scope]?.filter { $0.key.hasPrefix("transient.") }
                if ready.readiness != .ready {
                    let unavailable = ready.completed && [.empty, .unsupported].contains(ready.readiness)
                    result.checks.append(Check(feature: "page-local state", status: unavailable ? .unsupported : .partial, required: true,
                        detail: unavailable ? "Service settled with \(ready.readiness.rawValue); no stateful data was available."
                            : "Service readiness \(ready.readiness.rawValue) did not establish usable data within its bounded wait; this is not proof of an empty service."))
                    readinessCheckAdded = true
                }
                do { try save(result) }
                catch { result.status = .failed; result.notes.append("Service-readiness result checkpoint failed."); return result }
            } else { response = await transact("exercise.safe", scope: scope, end: end) }
            if let response, response.supported, !response.state.isEmpty {
                expected[scope] = response.state.filter { !$0.key.hasPrefix("transient.") }
                result.checks.append(Check(feature: "page-local state", status: .complete, required: true, detail: "Safe local controls acknowledged; no write/send action requested."))
            } else if !readinessCheckAdded { result.checks.append(Check(feature: "page-local state", status: .unsupported, required: true, detail: "Page mounted, but it exposes no supported state-only acceptance hook.")) }
        }
        let needsPreparedReport = !isPanel && BridgePage.restored(page).showsActivityFilters
        _ = await transact("report", scope: isPanel ? "panel-chart" : "hub", end: end)
        let hasReadinessHook = needsPreparedReport ? AcceptanceProbe.states["hub"]?["renderedRevision"] != nil && AcceptanceProbe.states["hub"]?["preparedMatchesInputs"] != nil
            : (isPanel ? AcceptanceProbe.states["panel-chart"]?["asOfMS"] != nil : true)
        if !hasReadinessHook { result.checks.append(Check(feature: "rendered dataset readiness", status: .unsupported, required: true, detail: "No render-version hook; a model timestamp alone cannot prove new content was displayed.")) }
        func settled(target: RefreshAcceptancePolicy.Target? = nil) -> Bool {
            AcceptanceProbe.send("report", scope: needsPreparedReport ? "hub" : (isPanel ? "panel-chart" : page))
            if let target, !target.matches(revision: model.activityRevision, asOf: model.activityOverview.generatedAt) { return false }
            guard loadingVisible == 0, !model.isProjectingTokenSeries,
                  configuration.mode == .replay || !model.isRefreshingActivity else { return false }
            if needsPreparedReport, hasReadinessHook {
                let state = AcceptanceProbe.states["hub"] ?? [:]
                let expected = target ?? .init(revision: model.activityRevision, asOf: model.activityOverview.generatedAt)
                return RefreshAcceptancePolicy.renderState(target: expected, revision: model.activityRevision, asOf: model.activityOverview.generatedAt,
                    projectionBusy: model.isProjectingTokenSeries, renderedRevision: state["renderedRevision"],
                    preparedMatches: state["preparedMatchesInputs"] == "true", preparing: state["preparing"] != "false") == .complete
            }
            if isPanel, hasReadinessHook {
                let expected = String(Int64((model.activityOverview.generatedAt.timeIntervalSince1970 * 1000).rounded()))
                return AcceptanceProbe.states["panel-chart"]?["asOfMS"] == expected
            }
            return true
        }
        guard await waitUntil(timeout: 180, end: end, { settled() }) else {
            result.status = .failed; result.notes.append("Setup preparation did not settle."); return result
        }
        if let scroll = mainScrollView(in: root) {
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            if maximum > 20 {
                let target = min(600, maximum * 0.6).rounded()
                scrollTo(target, in: scroll)
                result.setUp.append("nonzero scroll")
                result.checks.append(Check(feature: "scroll", status: .complete, required: true, detail: "Nonzero scroll was applied and will be measured."))
            } else { result.checks.append(Check(feature: "scroll", status: .unsupported, required: false, detail: "Content fits the viewport; scrolling is not applicable.")) }
        } else { result.checks.append(Check(feature: "scroll", status: .unsupported, required: false, detail: "No scrollable surface on this page.")) }
        try? await Task.sleep(for: .milliseconds(150))
        var baselineUnmounts = AcceptanceProbe.unmounts, baselineLoading = AcceptanceProbe.mounts["loading", default: 0]
        let watch = Set([mountedName] + (expected["hub"]?["selected"] != nil ? ["inspector"] : []) + (isPanel && expected["panel"]?["expanded"] == "true" ? ["panel.token-chart"] : []))
        var completed = 0
        var initialSnapshot = await sampledSnapshot(cycle: 0, root: root, model: model, expected: expected, baseline: baselineUnmounts, loading: baselineLoading, watch: watch, seconds: 0, finished: true, end: end, idle: { settled() })
        baselineUnmounts = AcceptanceProbe.unmounts; baselineLoading = AcceptanceProbe.mounts["loading", default: 0]
        initialSnapshot.unmounted = [:]; initialSnapshot.loadingShown = 0
        result.snapshots.append(initialSnapshot)
        do { try save(result) }
        catch { result.status = .failed; result.notes.append("Baseline checkpoint could not be saved; no refresh cycle was started."); return result }
        for cycle in 1 ... configuration.cycles {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < end else { result.notes.append("Run budget/cancellation ended before all requested cycles."); break }
            let started = ProcessInfo.processInfo.systemUptime
            let previous = model.activityOverview.generatedAt
            var timing = CycleProgress(cycle: cycle)
            result.phase = "cycle-\(cycle):source"
            result.cycleProgress.append(timing)
            do { try save(result) }
            catch { result.status = .failed; result.notes.append("Source-start checkpoint failed; refresh was not started."); return result }
            var target: RefreshAcceptancePolicy.Target?
            if configuration.mode == .replay {
                var replay = source
                replay.generatedAt = max(previous, source.generatedAt).addingTimeInterval(0.001)
                if model.acceptRuntimeActivity(replay), model.activityOverview.generatedAt > previous {
                    target = .init(revision: model.activityRevision, asOf: model.activityOverview.generatedAt)
                } else { timing.failure = "Replay source was not accepted as a new snapshot." }
            } else if result.liveRefreshesUsed < liveAllowance {
                let sourceEnd = RefreshAcceptancePolicy.phaseDeadline(start: started, overallEnd: end)
                let idle = await waitUntil(timeout: 180, end: sourceEnd) { !model.isRefreshingActivity }
                if idle {
                    let beforeRequest = model.activityOverview.generatedAt
                    model.refreshActivity(force: true)
                    if model.isRefreshingActivity { result.liveRefreshesUsed += 1 }
                    let received = await waitUntil(timeout: 180, interval: 0.1, end: sourceEnd) {
                        guard model.activityOverview.generatedAt > beforeRequest, !model.isRefreshingActivity, model.activityError == nil else { return false }
                        // Capture at source completion, before another actor
                        // turn could accept a different data version.
                        target = .init(revision: model.activityRevision, asOf: model.activityOverview.generatedAt)
                        return true
                    }
                    if !received { timing.failure = "Source refresh did not complete successfully within its 180-second bound." }
                } else { timing.failure = "Another source refresh did not become idle within the source phase bound." }
            } else { result.notes.append("Bounded live-refresh allowance exhausted; remaining cycles were not run."); break }
            timing.sourceSeconds = ProcessInfo.processInfo.systemUptime - started
            timing.target = target
            timing.phase = target == nil ? "source-failed" : "render"
            result.phase = "cycle-\(cycle):\(timing.phase)"
            result.cycleProgress[result.cycleProgress.count - 1] = timing
            do { try save(result) }
            catch { result.status = .failed; result.notes.append("Source-completion checkpoint failed."); return result }
            var finished = false
            if let target {
                let renderingStarted = ProcessInfo.processInfo.systemUptime
                let renderEnd = RefreshAcceptancePolicy.phaseDeadline(start: renderingStarted, overallEnd: end)
                let renderFinished = await waitUntil(timeout: 180, interval: 0.1, end: renderEnd) {
                    if !target.matches(revision: model.activityRevision, asOf: model.activityOverview.generatedAt) {
                        timing.interference = true
                        timing.failure = "Unexpected accepted source input changed the captured target; the harness did not retarget."
                        return true
                    }
                    return settled(target: target)
                }
                finished = renderFinished && !timing.interference && settled(target: target)
                timing.renderSeconds = ProcessInfo.processInfo.systemUptime - renderingStarted
                if !finished && timing.failure == nil { timing.failure = "Exact target projection/render did not settle within its 180-second bound." }
            }
            timing.phase = finished ? "complete" : (timing.interference ? "interference" : "failed")
            result.phase = "cycle-\(cycle):\(timing.phase)"
            result.cycleProgress[result.cycleProgress.count - 1] = timing
            do { try save(result) }
            catch { result.status = .failed; result.notes.append("Render-completion checkpoint failed."); return result }
            if finished { completed += 1 }
            else { result.notes.append("Cycle \(cycle) did not reach a confirmed refreshed, settled state.") }
            for scope in expected.keys { _ = await transact("report", scope: scope, end: end) }
            try? await Task.sleep(for: .milliseconds(150))
            result.snapshots.append(await sampledSnapshot(cycle: cycle, root: root, model: model, expected: expected, baseline: baselineUnmounts, loading: baselineLoading, watch: watch, seconds: ProcessInfo.processInfo.systemUptime - started, finished: finished, end: end, idle: { settled(target: target) }))
            do { try save(result) }
            catch { result.status = .failed; result.notes.append("Checkpoint persistence failed; run must not be accepted."); return result }
            if !finished { break }
        }
        let initial = result.snapshots[0]
        let changed = result.snapshots.dropFirst().contains { later in
            !later.refreshCompleted || later.loadingShown > 0 || !later.unmounted.isEmpty
                || expected.contains { scope, values in !RefreshAcceptancePolicy.preserved(values, later.states[scope] ?? [:], keys: Set(values.keys)) }
                || (initial.scrollOffset != nil && (later.scrollViewIdentity != initial.scrollViewIdentity || abs((later.scrollOffset ?? -.infinity) - initial.scrollOffset!) >= 1))
        }
        let rawMemory = RefreshAcceptancePolicy.memory(samples: result.snapshots.map { ($0.cycle, $0.footprintMB) }, warmup: configuration.warmupCycles, limit: configuration.maximumSteadyGrowthMB)
        var memory = RefreshAcceptancePolicy.memory(samples: result.snapshots.map { ($0.cycle, $0.postIdleFootprintMB) }, warmup: configuration.warmupCycles, limit: configuration.maximumSteadyGrowthMB)
        memory.samplingMethod = "post-render-idle/1"
        memory.rawSteadyGrowthMB = rawMemory.steadyGrowthMB
        memory.peakMB = result.snapshots.compactMap(\.sampledPeakMB).max()
        memory.processLifetimePeakMB = result.snapshots.compactMap(\.processLifetimePeakMB).max()
        memory.explanation = "Strict threshold on stable terminal-window medians after three continuous idle seconds (250ms samples, 2MB stability span, 8s bound). Raw render samples and process peak remain separate; no minimum selection or forced reclamation."
        if memory.status != .failed, result.snapshots.contains(where: { $0.cycle > configuration.warmupCycles && !$0.memorySettled }) {
            memory.status = .partial
            memory.explanation += " At least one post-warmup sample did not stabilize before its bound."
        }
        let steadySizes = result.snapshots.filter { $0.cycle > configuration.warmupCycles }.map(\.inputSize)
        if configuration.mode == .live, let first = steadySizes.first, steadySizes.contains(where: { $0 != first }) {
            memory.status = .partial
            memory.explanation = "Live input sizes changed; footprint growth cannot be attributed to a leak from this run. Counts describe stored payload size, not usage metrics."
        }
        result.memory = memory
        let failed = changed || result.checks.contains { $0.status == .failed } || memory.status == .failed
        let unsupported = result.checks.contains { $0.required && $0.status != .complete } || expected.isEmpty || memory.status != .complete
        result.status = RefreshAcceptancePolicy.outcome(cyclesRequested: configuration.cycles, completed: completed, failed: failed, requiredUnsupported: unsupported)
        result.preserved = result.status == .complete
        return result
    }

    private static func transact(_ name: String, value: String? = nil, scope: String, end: Double) async -> AcceptanceProbe.Response? {
        let id = AcceptanceProbe.send(name, value: value, scope: scope)
        _ = await waitUntil(timeout: 2, interval: 0.025, end: end) { AcceptanceProbe.responses[id] != nil }
        return AcceptanceProbe.responses[id]
    }
    private static func serviceExercise(scope: String, end: Double) async -> (response: AcceptanceProbe.Response?, readiness: RefreshAcceptancePolicy.ServiceReadiness, completed: Bool) {
        let deadline = min(end, ProcessInfo.processInfo.systemUptime + 60)
        var readiness = RefreshAcceptancePolicy.ServiceReadiness.pending
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            let report = await transact("report", scope: scope, end: deadline)
            readiness = RefreshAcceptancePolicy.serviceReadiness(report?.state ?? [:])
            switch readiness {
            case .ready:
                let response = await transact("exercise.safe", scope: scope, end: deadline)
                if response?.supported == true { return (response, .ready, true) }
                let after = RefreshAcceptancePolicy.serviceReadiness(response?.state ?? [:])
                if after != .pending && after != .loading { return (response, after, true) }
                readiness = after // A new load raced the readiness report.
            case .empty, .unsupported, .error: return (nil, readiness, true)
            case .pending, .loading: break
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        return (nil, readiness, false)
    }
    private static var loadingVisible: Int { AcceptanceProbe.visible("loading") }
    private static func snapshot(cycle: Int, root: NSView, model: BridgeViewModel, expected: [String: [String: String]], baseline: [String: Int], loading: Int, watch: Set<String>, seconds: Double, finished: Bool) -> Snapshot {
        var unmounted: [String: Int] = [:]
        for name in watch {
            let delta = AcceptanceProbe.unmounts[name, default: 0] - baseline[name, default: 0]
            if delta > 0 { unmounted[name] = delta }
        }
        let scroll = mainScrollView(in: root)
        let states = Dictionary(uniqueKeysWithValues: expected.keys.map { ($0, AcceptanceProbe.states[$0] ?? [:]) })
        return Snapshot(cycle: cycle, generatedAt: model.activityOverview.generatedAt, scrollOffset: scroll.map(offset), scrollViewIdentity: scroll.map { ObjectIdentifier($0).hashValue }, hubState: AcceptanceProbe.hubState,
                        states: states, unmounted: unmounted, loadingShown: max(0, AcceptanceProbe.mounts["loading", default: 0] - loading), footprintMB: measuredFootprintMB(), seconds: seconds, refreshCompleted: finished, inputSize: InputSize(model.activityOverview))
    }
    private static func sampledSnapshot(cycle: Int, root: NSView, model: BridgeViewModel, expected: [String: [String: String]], baseline: [String: Int], loading: Int, watch: Set<String>, seconds: Double, finished: Bool, end: Double, idle: () -> Bool) async -> Snapshot {
        let raw = snapshot(cycle: cycle, root: root, model: model, expected: expected, baseline: baseline, loading: loading, watch: watch, seconds: seconds, finished: finished)
        let revision = model.activityRevision
        let started = ProcessInfo.processInfo.systemUptime
        var readings = [RefreshAcceptancePolicy.IdleReading(seconds: 0, footprintMB: raw.footprintMB, processLifetimePeakMB: measuredResources().peak, idle: idle())]
        var settlement = RefreshAcceptancePolicy.settlement(readings)
        while !Task.isCancelled, !settlement.stable, ProcessInfo.processInfo.systemUptime < min(end, started + 8), readings.count < 34 {
            let delay = min(0.25, max(0, min(end, started + 8) - ProcessInfo.processInfo.systemUptime))
            guard delay > 0 else { break }
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            let resources = measuredResources()
            readings.append(.init(seconds: ProcessInfo.processInfo.systemUptime - started, footprintMB: resources.current, processLifetimePeakMB: resources.peak,
                                  idle: revision == model.activityRevision && idle()))
            settlement = RefreshAcceptancePolicy.settlement(readings)
        }
        var value = snapshot(cycle: cycle, root: root, model: model, expected: expected, baseline: baseline, loading: loading, watch: watch, seconds: seconds + settlement.elapsedSeconds, finished: finished)
        value.footprintMB = raw.footprintMB
        value.postIdleFootprintMB = settlement.postIdleMB
        value.memorySettled = settlement.stable
        value.memoryIdleSeconds = settlement.elapsedSeconds
        value.sampledPeakMB = settlement.observedPeakMB
        value.processLifetimePeakMB = settlement.processLifetimePeakMB
        value.memoryReadings = settlement.readings
        return value
    }
    private static func mainScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = [], stack = [root], visited = 0
        while let view = stack.popLast(), visited < 4096 {
            visited += 1
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, scroll.documentView != nil, scroll.bounds.width >= 200, scroll.bounds.height >= 100 {
                let frame = scroll.convert(scroll.bounds, to: root)
                // Never call sidebar scrolling evidence that a page retained
                // its content position. The inspector can be a valid surface.
                if root.bounds.width < 700 || frame.maxX > root.bounds.width * 0.35 { found.append(scroll) }
            }
            stack.append(contentsOf: view.subviews)
        }
        return found.max {
            let a = ($0.documentView?.frame.height ?? 0) - $0.contentView.bounds.height > 20
            let b = ($1.documentView?.frame.height ?? 0) - $1.contentView.bounds.height > 20
            return a == b ? $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height : !a && b
        }
    }
    private static func scrollTo(_ offset: Double, in scroll: NSScrollView) {
        let y = scroll.documentView?.isFlipped != false ? offset : max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height - offset)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private static func offset(_ scroll: NSScrollView) -> Double {
        let y = scroll.contentView.bounds.origin.y
        return scroll.documentView?.isFlipped != false ? y : max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height - y)
    }
    static func footprintMB() -> Double { measuredFootprintMB() ?? -1 }
    private static func measuredFootprintMB() -> Double? { measuredResources().current }
    private static func measuredResources() -> (current: Double?, peak: Double?) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        guard result == KERN_SUCCESS else { return (nil, nil) }
        let current = (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10
        let peak = info.ledger_phys_footprint_peak > 0 ? (Double(info.ledger_phys_footprint_peak) / 1_048_576 * 10).rounded() / 10 : nil
        return (current, peak)
    }
    private static func waitUntil(timeout: Double, interval: Double = 0.05, end: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = min(end, ProcessInfo.processInfo.systemUptime + timeout)
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            do { try await Task.sleep(for: .seconds(interval)) } catch { return false }
        }
        return !Task.isCancelled && ProcessInfo.processInfo.systemUptime <= deadline && condition()
    }
    private static func checkpoint(_ report: Report, to path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
              URL(fileURLWithPath: path).pathExtension == "json" else { throw RefreshAcceptancePolicy.Failure("Report path is not a bounded absolute JSON path.") }
        try writePrivate(report, to: URL(fileURLWithPath: path))
    }
    static func writePrivate(_ report: Report, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(), info.st_size <= 8 * 1024 * 1024 else { throw RefreshAcceptancePolicy.Failure("Refusing an unexpected report target.") }
            let old = try Data(contentsOf: destination)
            let object = try JSONSerialization.jsonObject(with: old)
            let current = ((object as? [String: Any])?["reportVersion"] as? String).map { ["refresh-acceptance/2", "refresh-acceptance/3"].contains($0) } == true
            let legacy = (object as? [[String: Any]])?.first.map { $0["page"] != nil && $0["snapshots"] != nil && $0["preserved"] != nil } == true
            guard current || legacy else { throw RefreshAcceptancePolicy.Failure("Existing target is not an acceptance report.") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        guard data.count <= 8 * 1024 * 1024 else { throw RefreshAcceptancePolicy.Failure("Acceptance report exceeded its size bound.") }
        var template = Array(parent.appendingPathComponent(".hub-acceptance-\(UUID().uuidString).XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw RefreshAcceptancePolicy.Failure("Could not create private report checkpoint.") }
        let temporary = String(cString: template)
        defer { close(fd); unlink(temporary) }
        guard fchmod(fd, 0o600) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw RefreshAcceptancePolicy.Failure("Could not protect report checkpoint.") }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RefreshAcceptancePolicy.Failure("Report checkpoint write failed.") }
                written += count
            }
        }
        guard fsync(fd) == 0, rename(temporary, destination.path) == 0 else { throw RefreshAcceptancePolicy.Failure("Report checkpoint publication failed.") }
    }
    private static func progress(_ text: String) { FileHandle.standardOutput.write(Data("[acceptance] \(text)\n".utf8)) }
}

/// All controls are gated and scoped. The ACK token prevents stale state from
/// another page/command being accepted as evidence that setup actually ran.
@MainActor
enum AcceptanceProbe {
    nonisolated static let isActive = requested(environment: ProcessInfo.processInfo.environment)
    nonisolated static func requested(environment: [String: String]) -> Bool {
        guard environment["BRIDGE_UI_PREVIEW"] == "1" else { return false }
        return environment["BRIDGE_REFRESH_ACCEPTANCE"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || environment["BRIDGE_GOAL_REPLAY_PREVIEW"] == "1" || environment["BRIDGE_HYDRATION_PREVIEW"] != nil
    }
    static let command = Notification.Name("dev.claudecodexbridge.acceptance-command")
    static var mounts: [String: Int] = [:]
    static var unmounts: [String: Int] = [:]
    static var hubState: [String: String] = [:]
    static var states: [String: [String: String]] = [:]
    struct Response { var scope: String; var state: [String: String]; var supported: Bool }
    static var responses: [String: Response] = [:]
    private static var responseOrder: [String] = []
    private static let suite = "dev.playbasis.hub.acceptance.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
    static let defaults: UserDefaults = {
        guard isActive else { return .standard }
        guard let value = UserDefaults(suiteName: suite) else { preconditionFailure("Cannot isolate acceptance preferences; refusing a user-settings fallback.") }
        value.removePersistentDomain(forName: suite)
        return value
    }()
    static func cleanupDefaults() { if isActive { defaults.removePersistentDomain(forName: suite) } }
    static func visible(_ name: String) -> Int { max(0, mounts[name, default: 0] - unmounts[name, default: 0]) }
    static func stateDigest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func requestName(_ note: Notification) -> String? { note.userInfo?["name"] as? String }
    static func requestValue(_ note: Notification) -> String? { note.userInfo?["value"] as? String }
    static func requestScope(_ note: Notification) -> String { note.userInfo?["scope"] as? String ?? "hub" }
    @discardableResult
    static func send(_ name: String, value: String? = nil, scope: String = "hub") -> String {
        let request = UUID().uuidString
        guard isActive else { return request }
        var fields: [String: Any] = ["name": name, "scope": scope, "request_id": request]
        if let value { fields["value"] = value }
        NotificationCenter.default.post(name: command, object: nil, userInfo: fields)
        return request
    }
    static func publish(scope: String, state: [String: String], requestID: String? = nil, supported: Bool = true) {
        guard isActive else { return }
        var bounded: [String: String] = [:]
        for key in state.keys.sorted().prefix(32) { bounded[String(key.prefix(80))] = String((state[key] ?? "").prefix(2048)) }
        if states[scope] == nil, states.count >= 32 { states.removeValue(forKey: states.keys.sorted().first!) }
        states[scope] = bounded
        if scope == "hub" { hubState = bounded }
        guard let requestID else { return }
        responses[requestID] = Response(scope: scope, state: bounded, supported: supported)
        responseOrder.append(requestID)
        while responseOrder.count > 128 { responses.removeValue(forKey: responseOrder.removeFirst()) }
    }
    static func record(_ note: Notification, scope: String, state: [String: String], supported: Bool = true) {
        guard requestScope(note) == scope else { return }
        publish(scope: scope, state: state, requestID: note.userInfo?["request_id"] as? String, supported: supported)
    }
    static func handleSafe(_ note: Notification, scope: String, state: () -> [String: String], exercise: () -> Bool) {
        guard isActive, requestScope(note) == scope else { return }
        let supported: Bool
        switch requestName(note) {
        case "exercise.safe": supported = exercise()
        case "report": supported = true
        default: supported = false
        }
        record(note, scope: scope, state: state(), supported: supported)
    }
    static func serviceFields(loading: Bool, ready: Bool, hasData: Bool, error: Bool = false, unsupported: Bool = false, itemCount: Int) -> [String: String] {
        ["transient.loading": String(loading), "transient.ready": String(ready && !loading && !error && !unsupported),
         "transient.hasData": String(hasData), "transient.error": String(error), "transient.unsupported": String(unsupported),
         "transient.itemCount": String(itemCount)]
    }
}

extension View {
    @MainActor @ViewBuilder func acceptanceProbe(_ name: String) -> some View {
        if AcceptanceProbe.isActive {
            onAppear { AcceptanceProbe.mounts[name, default: 0] += 1; PerfTrace.appeared(name) }
                .onDisappear { AcceptanceProbe.unmounts[name, default: 0] += 1 }
        } else { self }
    }
}
