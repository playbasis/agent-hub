import BridgeCore
import Darwin
import Foundation

@main
enum BridgeCLI {
    static func main() async {
        do {
            let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
            guard let command = arguments.first else {
                printUsage()
                return
            }
            let options = CLIOptions(Array(arguments.dropFirst()))
            switch command {
            case "room-mcp-server":
                let env = ProcessInfo.processInfo.environment
                guard let room = env["BRIDGE_TEAM_ROOM"].flatMap(UUID.init(uuidString:)),
                      let round = env["BRIDGE_TEAM_ROUND"].flatMap(UUID.init(uuidString:)),
                      let work = env["BRIDGE_TEAM_WORK"].flatMap(UUID.init(uuidString:)) else { throw BridgeError.invalidRequest("Room MCP requires active worker context.") }
                await RoomMCPServer.run(configuration: try ConfigurationStore.load(create: false), context: RoomExecutionContext(roomID: room, roundID: round, workID: work, helper: CommandLine.arguments[0]))
            case "room":
                try await room(options)
            case "validate-personas":
                // Build-time validation uses the compiled catalog, so removing
                // a source portrait cannot silently pass a source/copy count.
                let directory = URL(fileURLWithPath: try options.required("--directory"))
                let expected = Set(AgentPersonaCatalog.all.map { $0.slug + ".png" })
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                    .filter { $0.pathExtension.lowercased() == "png" }
                guard !expected.isEmpty, Set(files.map(\.lastPathComponent)) == expected else {
                    throw BridgeError.configuration("Persona assets do not match the compiled catalog")
                }
                for file in files {
                    let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 8, size <= 1_048_576 else {
                        throw BridgeError.configuration("Invalid persona asset: \(file.lastPathComponent)")
                    }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    guard try handle.read(upToCount: 8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
                        throw BridgeError.configuration("Persona asset is not a PNG: \(file.lastPathComponent)")
                    }
                }
                print("Validated \(expected.count) persona portraits")
            case "init":
                let configuration = try ConfigurationStore.load()
                print("Created or loaded \(BridgePaths.configuration.path)")
                printJSON(configuration.redacted())
            case "serve":
                let runtime = BridgeRuntime(configuration: try ConfigurationStore.load())
                try await runtime.start()
                let config = runtime.configuration
                print("ClaudeCodexBridge listening on \(config.server.host):\(config.server.port)")
                await SignalWaiter.wait()
                await runtime.stop()
            case "app-quit":
                DistributedNotificationCenter.default().postNotificationName(
                    BridgeLifecycleNotifications.requestAppQuit,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
            case "status":
                let client = BridgeAPIClient(configuration: try ConfigurationStore.load())
                printJSON(try await client.status())
            case "usage":
                let configuration = try ConfigurationStore.load()
                let reader = LivePlanUsageReader(configuration: configuration.agents)
                let values = await reader.readAll()
                printJSON(Dictionary(
                    uniqueKeysWithValues: values.map { ($0.agent.rawValue, $0) }
                ))
            case "credits":
                try await credits(options)
            case "activity":
                let action = options.positional.first ?? "view"
                let configuration = try ConfigurationStore.load()
                let service = ActivityReportingService.shared
                switch action {
                case "refresh": printJSON(try await service.refresh(configuration: configuration.agents, force: true))
                case "repositories": printJSON(try await service.inspectRepositories())
                case "pin": printJSON(try await service.pin(sessionID: options.value("--session")))
                case "journal": printJSON(try await service.journal())
                case "publish": printJSON(try await service.publishJournal())
                case "view": printJSON(try await service.overview())
                default: throw BridgeError.invalidRequest("Use activity view|refresh|repositories|pin|journal|publish")
                }
            case "metrics":
                let request = try ActivityAccountingCLIRequest(arguments: Array(arguments.dropFirst()))
                let overview = try await ActivityReportingService.shared.overview()
                let report = try request.query.report(overview: overview)
                if request.action == .export {
                    let url = URL(fileURLWithPath: request.output ?? "agent-hub-metrics.json").standardizedFileURL
                    try ActivityAccountingExport.write(report, to: url, overwrite: request.overwrite)
                    print("Exported local metrics to \(url.path)")
                } else { printJSON(report) }
            case "jev":
                switch options.positional.first {
                case "snapshots":
                    let path = try options.required("--output")
                    let overview = try await ActivityReportingService.shared.overview()
                    try JEVAssessmentEvidence.exportSnapshots(overview: overview, to: URL(fileURLWithPath: path))
                    print("Exported private local assessment identities to \(path)")
                case "import":
                    let path = try options.required("--input")
                    let store = JEVAssessmentStore(directory: BridgePaths.applicationSupport.appendingPathComponent("JEVAssessments", isDirectory: true))
                    let count = try await store.importJSONL(at: URL(fileURLWithPath: path))
                    print("Imported \(count) private JEV assessment receipts")
                case "import-tool":
                    let path = try options.required("--input")
                    let store = JEVToolPageAssessmentStore(directory: BridgePaths.applicationSupport.appendingPathComponent("JEVToolPageAssessments", isDirectory: true))
                    let count = try await store.importJSONL(at: URL(fileURLWithPath: path))
                    print("Imported \(count) private historical tool-page assessments")
                default: throw BridgeError.invalidRequest("Use jev snapshots --output <new-private-file> | jev import --input <private-file> | jev import-tool --input <private-file>")
                }
            case "economics":
                let request = try EconomicsCLIRequest(arguments: Array(arguments.dropFirst()))
                print(try await EconomicReportService().execute(request))
            case "start":
                let project = try options.required("--project")
                let goal = try options.required("--goal")
                let duration = Int(options.value("--duration") ?? "240") ?? 240
                let agent = AgentName(rawValue: options.value("--agent") ?? "claude") ?? .claude
                let client = BridgeAPIClient(configuration: try ConfigurationStore.load())
                printJSON(
                    try await client.start(
                        try SessionRequest(
                            projectPath: project,
                            goal: goal,
                            durationMinutes: duration,
                            startingAgent: agent
                        )
                    )
                )
            case "pause", "resume", "stop":
                let client = BridgeAPIClient(configuration: try ConfigurationStore.load())
                let status: BridgeStatus
                if command == "pause" {
                    status = try await client.pause()
                } else if command == "resume" {
                    status = try await client.resume()
                } else {
                    status = try await client.stop()
                }
                printJSON(status)
            case "handoff":
                let raw = try options.required("--agent")
                guard let agent = AgentName(rawValue: raw), agent != .none else {
                    throw BridgeError.invalidRequest("--agent must be claude or codex")
                }
                let reason = options.value("--reason") ?? "Manual CLI override"
                let client = BridgeAPIClient(configuration: try ConfigurationStore.load())
                printJSON(try await client.handoff(agent: agent, reason: reason))
            case "logs":
                let limit = Int(options.value("--limit") ?? "20") ?? 20
                let client = BridgeAPIClient(configuration: try ConfigurationStore.load())
                printJSON(try await client.logs(limit: limit))
            case "trace":
                try await trace(options)
            case "config":
                print("Path: \(BridgePaths.configuration.path)")
                printJSON(try ConfigurationStore.load().redacted())
            case "coordinator":
                try await configureCoordinator(options)
            case "prove-coordination":
                try await proveCoordination(options)
            case "audit-coordination":
                try await auditCoordination(options)
            case "install-hooks":
                let project = try options.required("--project")
                let result = try HookInstaller.install(
                    projectPath: project,
                    configuration: try ConfigurationStore.load(),
                    dryRun: options.has("--dry-run")
                )
                if options.has("--dry-run") {
                    print(result.renderedJSON)
                } else {
                    print("Installed Claude hooks at \(result.settingsURL.path)")
                    if let backup = result.backupURL {
                        print("Backup: \(backup.path)")
                    }
                }
            case "hook":
                guard options.positional.count >= 2, options.positional[0] == "claude" else {
                    throw BridgeError.invalidRequest("usage: bridge hook claude <EventName>")
                }
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let payload = try BridgeJSON.decoder.decode([String: JSONValue].self, from: data)
                let client = BridgeAPIClient(configuration: try ConfigurationStore.load())
                let status = try await client.status()
                let event = try EventNormalizer.normalizeClaudeHook(
                    name: options.positional[1],
                    payload: payload,
                    bridgeSessionID: status.session?.id
                )
                try await client.submit(event)
            case "mcp-server":
                await MCPServer.run(configuration: try ConfigurationStore.load())
            case "doctor":
                try await doctor()
            case "help", "--help", "-h":
                printUsage()
            default:
                throw BridgeError.invalidRequest("Unknown command: \(command)")
            }
        } catch {
            FileHandle.standardError.write(Data("bridge: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func credits(_ options: CLIOptions) async throws {
        let action = options.positional.first ?? "history"
        let client = BridgeAPIClient(configuration: try ConfigurationStore.load())
        let query = try CreditHistoryQuery(query: ["window": options.value("--window") ?? "24h"]
            .merging(options.value("--scope").map { ["scope": $0] } ?? [:], uniquingKeysWith: { _, new in new }))
        switch action {
        case "history", "verify":
            if options.has("--offline") {
                let report = try await CreditHistoryStore().report(now: Date(), from: query.from(at: Date()), to: Date())
                printJSON(report)
                return
            }
            let snapshot = try await client.creditHistory(query: query)
            if action == "verify" {
                printJSON(["integrity_verified": snapshot.history.completeness.integrityVerified ? "true" : "false",
                           "records": String(snapshot.history.completeness.retainedRecordCount)])
            } else { printJSON(snapshot) }
        case "refresh": printJSON(try await client.refreshCodexUsage())
        case "export":
            let value = try await client.creditHistory(query: query)
            let output = URL(fileURLWithPath: try options.required("--output")).standardizedFileURL
            let data = try BridgeJSON.encoder.encode(value)
            try CreditHistoryExport.write(data, to: output)
            print("Exported private credit observations to \(output.path)")
        case "capture":
            // Explicit operator capture: no automatic filesystem scans or
            // guessed historical backfill. Queries account metadata only.
            let status = try await client.refreshCodexUsage()
            guard let quota = status.quota["codex"] else { throw BridgeError.invalidRequest("Codex did not return usage.") }
            let store = CreditHistoryStore()
            let result = try await store.record(quota, anonymousEpochID: try options.required("--epoch"))
            print(result.disposition.rawValue)
        default: throw BridgeError.invalidRequest("Use credits history|refresh|verify|export|capture")
        }
    }

    private static func room(_ options: CLIOptions) async throws {
        let env = ProcessInfo.processInfo.environment
        func id(_ flag: String, _ key: String) throws -> UUID {
            guard let raw = options.value(flag) ?? env[key], let id = UUID(uuidString: raw) else { throw BridgeError.invalidRequest("Missing valid \(flag) or \(key)") }
            return id
        }
        guard let action = options.positional.first, ["read", "post", "ask"].contains(action) else {
            throw BridgeError.invalidRequest("usage: bridge room read|post|ask [--room UUID --round UUID --work UUID] [--kind update --to team --text message]")
        }
        let client = BridgeAPIClient(configuration: try ConfigurationStore.load(create: false))
        let roomID = try id("--room", "BRIDGE_TEAM_ROOM")
        if action == "read" { printJSON(try await client.teamContext(roomID: roomID)); return }
        let note = try RoomTeamNote(roomID: roomID, roundID: id("--round", "BRIDGE_TEAM_ROUND"), workID: id("--work", "BRIDGE_TEAM_WORK"), requestID: options.value("--request-id").flatMap(UUID.init(uuidString:)) ?? UUID(), kind: action == "ask" ? "question" : options.value("--kind") ?? "update", to: options.value("--to") ?? (action == "ask" ? "Lead" : "team"), text: options.required("--text"))
        let result = try await client.teamNote(note, ask: action == "ask")
        printJSON(result)
        if result.state == "failed" { throw BridgeError.processFailed("Team consultation failed; see the persisted reply.") }
    }

    private static func doctor() async throws {
        let configuration = try ConfigurationStore.load()
        var checks: [String: JSONValue] = [
            "config_path": .string(BridgePaths.configuration.path),
            "config_exists": .bool(FileManager.default.fileExists(
                atPath: BridgePaths.configuration.path
            )),
        ]
        for (name, command) in [
            ("claude", configuration.agents.claudeCommand),
            ("codex", configuration.agents.codexCommand),
        ] {
            do {
                let url = try ExecutableLocator.resolve(command)
                let output = try await ProcessRunner.run(
                    executable: url.path,
                    arguments: ["--version"],
                    currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    stdin: "",
                    timeoutSeconds: 10,
                    maximumOutputCharacters: 2_000
                )
                checks[name] = .object([
                    "path": .string(url.path),
                    "version": .string(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "ok": .bool(output.status == 0),
                ])
            } catch {
                checks[name] = .object([
                    "ok": .bool(false),
                    "error": .string(error.localizedDescription),
                ])
            }
        }
        let serverOK = (try? await BridgeAPIClient(configuration: configuration).health()) == true
        checks["server_reachable"] = .bool(serverOK)
        printJSON(JSONValue.object(checks))
    }

    private static func trace(_ options: CLIOptions) async throws {
        let action = options.positional.first ?? "view"
        let configuration = try ConfigurationStore.load()
        if action == "backfill" {
            let project = try options.required("--project")
            let store = try ProjectStore(projectPath: project)
            let imported = try store.backfillLegacyTrace(configuration: configuration)
            printJSON(JSONValue.object([
                "imported_records": .number(Double(imported)),
                "trace_verified": .bool(store.verifyTrace()),
            ]))
            return
        }
        let client = BridgeAPIClient(configuration: configuration)
        switch action {
        case "view":
            let limit = Int(options.value("--limit") ?? "100") ?? 100
            printJSON(try await client.trace(limit: limit))
        case "summary":
            printJSON(try await client.traceSummary())
        case "verify":
            let summary = try await client.traceSummary()
            printJSON(JSONValue.object([
                "verified": .bool(summary.traceVerified),
                "records": .number(Double(summary.records)),
            ]))
            if !summary.traceVerified { throw BridgeError.invalidRequest("trace verification failed") }
        case "export":
            let output = options.value("--output") ?? "bridge-trace.json"
            let url = URL(fileURLWithPath: output).standardizedFileURL
            try await client.traceExport().write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            print("Exported sanitized trace to \(url.path)")
        default:
            throw BridgeError.invalidRequest(
                "usage: bridge trace view|summary|verify|export|backfill "
                    + "[--limit N] [--output PATH] [--project PATH]"
            )
        }
    }

    private static func configureCoordinator(_ options: CLIOptions) async throws {
        guard let action = options.positional.first else {
            throw BridgeError.invalidRequest(
                "usage: bridge coordinator gemini|rules|status"
            )
        }
        let configuration = try ConfigurationStore.load()
        let client = BridgeAPIClient(configuration: configuration)
        switch action {
        case "gemini":
            guard options.has("--key-stdin") else {
                throw BridgeError.invalidRequest(
                    "Gemini setup requires --key-stdin so the key never appears "
                        + "in process arguments"
                )
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !key.isEmpty
            else {
                throw BridgeError.invalidRequest(
                    "--key-stdin requires a non-empty API key on standard input"
                )
            }
            let result = try await client.configureCoordinator(
                CoordinatorConfigurationRequest(
                    mode: .gemini,
                    apiKey: key,
                    model: options.value("--model"),
                    endpoint: options.value("--endpoint")
                )
            )
            printJSON(result)
            print("Restart ClaudeCodexBridge to activate the new coordinator.")
        case "rules":
            let result = try await client.configureCoordinator(
                CoordinatorConfigurationRequest(
                    mode: .rules,
                    forgetKey: options.has("--forget-key")
                )
            )
            printJSON(result)
            print("Restart ClaudeCodexBridge to activate the new coordinator.")
        case "status":
            printCoordinatorStatus(
                configuration,
                liveHealth: try? await client.status().provider
            )
        default:
            throw BridgeError.invalidRequest(
                "coordinator must be gemini, rules, or status"
            )
        }
    }

    private static func proveCoordination(_ options: CLIOptions) async throws {
        let projectPath = try options.required("--project")
        let project = URL(
            fileURLWithPath: projectPath,
            isDirectory: true
        ).standardizedFileURL
        let duration = Int(options.value("--duration") ?? "20") ?? 20
        let maximumTurns = Int(options.value("--maximum-turns") ?? "8") ?? 8
        guard (5 ... 1_440).contains(duration) else {
            throw BridgeError.invalidRequest(
                "--duration must be between 5 and 1440 minutes"
            )
        }
        guard (3 ... 80).contains(maximumTurns) else {
            throw BridgeError.invalidRequest(
                "--maximum-turns must be between 3 and 80 for a three-stage proof"
            )
        }
        let configuration = try ConfigurationStore.load()
        guard configuration.meta.coordinatorIdentifier == "gemini" else {
            throw BridgeError.configuration(
                "The live configuration must use Gemini before running this proof"
            )
        }

        let client = BridgeAPIClient(configuration: configuration)
        let preflight = try await client.status()
        guard [.idle, .complete, .stopped, .error].contains(preflight.state) else {
            throw BridgeError.sessionAlreadyActive
        }
        try await CoordinationAgentPreflight.requireReady(
            configuration: configuration.agents
        )
        // A proof explicitly spends one minimal generation request here. App
        // startup uses the non-generating model/auth check so relaunches do not
        // consume scarce Gemini request quota.
        let provider = try await client.retryProvider().provider
        guard provider.provider == "gemini",
              provider.state == .ready,
              !provider.fallbackActive
        else {
            throw BridgeError.configuration(
                "Gemini coordinator preflight failed: "
                    + (provider.message ?? "unknown provider error")
            )
        }
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(
            atPath: project.appendingPathComponent(".git").path
        ) {
            let git = try await ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: ["init", "--quiet", project.path],
                currentDirectory: project,
                stdin: "",
                timeoutSeconds: 15,
                maximumOutputCharacters: 4_000
            )
            guard git.status == 0 else {
                throw BridgeError.processFailed(
                    git.stderr.isEmpty ? "git init failed" : git.stderr
                )
            }
        }

        let goal = options.value("--goal") ?? canonicalCoordinationProofGoal
        _ = try await client.start(
            try SessionRequest(
                projectPath: project.path,
                goal: goal,
                durationMinutes: duration,
                startingAgent: .claude
            )
        )

        let proofDeadline = Date().addingTimeInterval(TimeInterval(duration * 60))
        var status = try await client.status()
        while ![SessionState.complete, .paused, .parked, .stopped, .error]
            .contains(status.state),
            Date() < proofDeadline
        {
            if status.session?.turnCount ?? 0 >= maximumTurns {
                status = try await client.pause()
                break
            }
            try await Task.sleep(for: .milliseconds(500))
            status = try await client.status()
        }
        if Date() >= proofDeadline,
           ![SessionState.complete, .paused, .parked, .stopped, .error]
            .contains(status.state)
        {
            status = try await client.pause()
        }

        let store = try ProjectStore(projectPath: project.path)
        let projectVerification = await CoordinationProjectVerifier.verify(
            project: project
        )
        let report = CoordinationProofAuditor.audit(
            status: status,
            store: store,
            projectVerification: projectVerification
        )
        let reportURL = store.context.appendingPathComponent(
            "coordination-proof.json"
        )
        try CoordinationProofAuditor.save(report, to: reportURL)
        printJSON(report)
        print("Proof artifact: \(reportURL.path)")
        guard report.passed else {
            throw BridgeError.configuration(
                "Coordination proof did not pass every requirement"
            )
        }
    }

    private static func auditCoordination(_ options: CLIOptions) async throws {
        let project = URL(
            fileURLWithPath: try options.required("--project"),
            isDirectory: true
        ).standardizedFileURL
        let store = try ProjectStore(projectPath: project.path)
        guard let session = try store.loadRuntime() else {
            throw BridgeError.configuration(
                "The project has no persisted bridge runtime to audit"
            )
        }
        let verification = await CoordinationProjectVerifier.verify(
            project: project
        )
        let report = CoordinationProofAuditor.audit(
            status: BridgeStatus(
                state: session.state,
                activeAgent: session.activeAgent,
                session: session,
                latestDecision: nil,
                quota: [:],
                provider: .rulesReady
            ),
            store: store,
            projectVerification: verification
        )
        let reportURL = store.context.appendingPathComponent(
            "coordination-proof.json"
        )
        try CoordinationProofAuditor.save(report, to: reportURL)
        printJSON(report)
        print("Proof artifact: \(reportURL.path)")
        guard report.passed else {
            throw BridgeError.configuration(
                "Coordination proof did not pass every requirement"
            )
        }
    }

    private static let canonicalCoordinationProofGoal = """
    Prove that Gemini can coordinate a real Claude Code ↔ Codex CLI workflow on \
    this isolated project. Follow these stages exactly:

    1. Claude acts first as architect. It must inspect BRIDGE.md, write DESIGN.md \
    for a tiny Swift package named WordMirror with a public reverseWords(_:) \
    function, state edge cases and acceptance tests, and then finish with \
    <bridge:continue>. Claude must not implement the package in this stage.
    2. Gemini must hand the implementation to Codex. Codex must read DESIGN.md, \
    initialize and implement the package directly in this project root (the \
    required Package.swift must be at ./Package.swift; do not create a nested \
    WordMirror directory), add focused XCTest cases, run swift test, record \
    the passing command in IMPLEMENTATION.md, and finish with <bridge:continue>. \
    Codex must not claim final completion because independent review remains.
    3. Gemini must hand independent verification back to Claude. Claude must \
    inspect the implementation, run swift test itself, write REVIEW.md containing \
    its findings and an explicit PASS only if correct, and finish with \
    <bridge:complete> only when every acceptance criterion passes.

    Do not skip or combine roles. Completion requires DESIGN.md, IMPLEMENTATION.md, \
    REVIEW.md, passing tests, successful turns from both agents, and Gemini routing \
    events from both agents without deterministic-rules fallback.
    """

    private static func printCoordinatorStatus(
        _ configuration: BridgeConfiguration,
        liveHealth: ProviderHealth?
    ) {
        var values: [String: JSONValue] = [
            "provider": .string(configuration.meta.coordinatorIdentifier),
            "model": .string(configuration.meta.model),
            "endpoint": .string(configuration.meta.endpoint),
            "credential_storage": .string(
                "environment or private Application Support file"
            ),
        ]
        if let liveHealth {
            values["live_provider"] = .string(liveHealth.provider)
            values["live_state"] = .string(liveHealth.state.rawValue)
            values["fallback_active"] = .bool(liveHealth.fallbackActive)
            if let message = liveHealth.message {
                values["live_message"] = .string(message)
            }
        }
        printJSON(JSONValue.object(values))
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        guard let data = try? BridgeJSON.encoder.encode(value) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func printUsage() {
        print("""
        ClaudeCodexBridge

          bridge init
          bridge serve
          bridge app-quit
          bridge status
          bridge usage
          bridge credits history|verify [--window 24h|7d|all] [--scope ID] [--offline]
          bridge credits refresh
          bridge credits export --output PATH [--window 24h|7d|all]
          bridge activity view|refresh|repositories|journal|publish
          bridge activity pin [--session PROVIDER:NATIVE_ID]
          bridge jev snapshots --output PRIVATE_NEW_FILE
          bridge jev import|import-tool --input PRIVATE_JSONL
          bridge metrics [view|export] [--window 24h|14d|all] [--from ISO8601] [--to ISO8601]
            [--provider claude|codex|grok] [--project PATH] [--session PROVIDER:NATIVE_ID]
            export [--output PATH] [--overwrite]
          bridge economics [view|briefing|candidates] [--period 24h|7d|30d|day|week|month|year|all] [--previous]
            [--from ISO8601] [--to ISO8601] [--provider claude|codex|grok] [--project PATH]
          bridge economics export --output FOLDER [--sanitized] [--receipts] [selectors]
          bridge economics accept|reject --candidate ID [--title T] [--standard prototype|internal_tool|production] [--hands-on 1.5-3]
          bridge economics accept --commits HASH,HASH --repository ID|PATH --title T [...]
          bridge economics revise --outcome ID [--title T] [--summary S] [--standard S] [--hands-on H]
          bridge economics withdraw --outcome ID --reason regression|reverted|duplicate|scope_change|other [--note N]
          bridge economics assess --outcome ID (--size xs|s|m|l|xl | --hours LOW,BASE,HIGH) [--baseline historical|contemporary|measured]
          bridge economics assess --file ASSESSMENTS.json
          bridge economics outcomes
          bridge economics assumptions [--rate ID] [--operator-rate ID|same] [--baseline B] [--hours-per-day 8] [--time-zone TZ]
            [--subscription "id|provider|label|monthly|USD"] [--remove-subscription ID] [--add-rate "id|label|hourly|USD|user_rate"] [--remove-rate ID]
          bridge start --project PATH --goal TEXT [--duration 240] [--agent claude|codex]
          bridge pause | resume | stop
          bridge handoff --agent claude|codex [--reason TEXT]
          bridge install-hooks --project PATH [--dry-run]
          bridge logs [--limit 20]
          bridge trace view|summary|verify|export [--limit 100] [--output PATH]
          bridge trace backfill --project PATH
          bridge doctor
          bridge config
          bridge room read [--room UUID]
          bridge room post --kind update --to team --text MESSAGE [--room UUID --round UUID --work UUID]
          bridge room ask --text QUESTION [--room UUID --round UUID --work UUID]
          bridge coordinator gemini --key-stdin [--model MODEL] [--endpoint URL]
          bridge coordinator rules [--forget-key]
          bridge coordinator status
          bridge prove-coordination --project PATH [--duration 20] [--maximum-turns 8]
          bridge audit-coordination --project PATH
          bridge mcp-server
        """)
    }
}

private struct CLIOptions {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    values[argument] = arguments[index + 1]
                    index += 2
                } else {
                    flags.insert(argument)
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    func value(_ name: String) -> String? { values[name] }
    func has(_ name: String) -> Bool { flags.contains(name) }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw BridgeError.invalidRequest("Missing \(name)")
        }
        return value
    }
}

private enum SignalWaiter {
    static func wait() async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let gate = SignalGate()
        await gate.wait()
    }
}

private final class SignalGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []
    private var completed = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    func start() {
        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.finish() }
            source.resume()
            sources.append(source)
        }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        sources.forEach { $0.cancel() }
        continuation?.resume()
        continuation = nil
    }
}
