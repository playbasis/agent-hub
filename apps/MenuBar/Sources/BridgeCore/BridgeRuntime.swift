import Foundation

public final class BridgeRuntime: @unchecked Sendable {
    public let configuration: BridgeConfiguration
    public let orchestrator: Orchestrator
    public let teamRooms: TeamRoomService
    private var server: LocalHTTPServer?
    private var providerTask: Task<Void, Never>?

    public init(configuration: BridgeConfiguration) {
        self.configuration = configuration
        orchestrator = Orchestrator(configuration: configuration)
        teamRooms = TeamRoomService(provider: LiveRoomProvider(configuration: configuration))
    }

    public func start() async throws {
        _ = await orchestrator.recover()
        let router = BridgeRouter(
            configuration: configuration,
            orchestrator: orchestrator,
            teamRooms: teamRooms
        )
        let server = LocalHTTPServer(configuration: configuration.server) {
            request in await router.handle(request)
        }
        try await server.start()
        self.server = server
        providerTask = Task { [orchestrator] in
            // Plan usage is intentionally refreshed only from the explicit UI
            // action. Launching provider CLIs in the background can make macOS
            // attribute their folder probes to this menu-bar app and show
            // surprise Desktop/Documents/Downloads permission dialogs.
            _ = await orchestrator.hydrateProvider()
        }
        await BridgeLogger.shared.log("INFO", "Bridge runtime started", fields: [
            "host": .string(configuration.server.host),
            "port": .number(Double(configuration.server.port)),
        ])
    }

    public func stop() async {
        let wasRunning = server != nil
        providerTask?.cancel()
        providerTask = nil
        server?.stop()
        server = nil
        await orchestrator.shutdown()
        await teamRooms.shutdown()
        if wasRunning {
            await BridgeLogger.shared.log("INFO", "Bridge runtime stopped gracefully")
        }
    }

    public func stopImmediately() {
        providerTask?.cancel()
        providerTask = nil
        server?.stop()
        server = nil
    }
}

public struct BridgeRouter: Sendable {
    private let configuration: BridgeConfiguration
    private let orchestrator: Orchestrator
    private let teamRooms: TeamRoomService?
    private let activityService: ActivityReportingService

    public init(configuration: BridgeConfiguration, orchestrator: Orchestrator, teamRooms: TeamRoomService? = nil, activityService: ActivityReportingService = .shared) {
        self.configuration = configuration
        self.orchestrator = orchestrator
        self.teamRooms = teamRooms
        self.activityService = activityService
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            if request.method == "GET", request.path == "/health" {
                return .json(["status": "ok", "version": "0.1.0"])
            }
            guard authorized(request) else { throw BridgeError.unauthorized }

            switch (request.method, request.path) {
            case ("GET", "/activity"):
                return .json(try await activityService.overview())
            case ("GET", "/activity/accounting"):
                let overview = try await activityService.overview()
                guard ActivityAccountingQuery.hasSnapshot(overview) else {
                    return .error(status: 503, message: "No local history has been collected; refresh activity first.")
                }
                return .json(try ActivityAccountingQuery.parse(target: request.target).report(overview: overview))
            case ("GET", "/economics/report"), ("GET", "/economics/briefing"), ("GET", "/economics/candidates"):
                let service = EconomicReportService(overview: { [activityService] in try await activityService.overview() })
                let output = try await service.output(EconomicReportQuery.parse(target: request.target))
                switch request.path {
                case "/economics/briefing":
                    return HTTPResponse(status: 200, reason: "OK", headers: ["Content-Type": "text/markdown; charset=utf-8"],
                                        body: Data(FeedbackBriefingBuilder.markdown(output.report).utf8))
                case "/economics/candidates": return .json(output.candidates)
                default: return .json(output.report)
                }
            case ("POST", "/activity/refresh"):
                return .json(try await activityService.refresh(configuration: configuration.agents, force: true))
            case ("POST", "/activity/pin"):
                let pin = try BridgeJSON.decoder.decode(ActivityPinRequest.self, from: request.body)
                return .json(try await activityService.pin(sessionID: pin.sessionID))
            case ("POST", "/activity/repositories"):
                return .json(try await activityService.inspectRepositories())
            case ("GET", "/activity/journal"):
                return .json(try await activityService.journal())
            case ("GET", "/activity/journal/evidence"):
                guard let id = request.queryValue("id"), let evidence = try await activityService.reportEvidence(id: id) else { return .error(status: 404, message: "Report evidence is unavailable.") }
                return .json(evidence)
            case ("POST", "/activity/journal"):
                return .json(try await activityService.publishJournal())
            case ("GET", "/rooms/context"):
                guard let teamRooms, let raw = request.queryValue("room"), let id = UUID(uuidString: raw) else { return .error(status: 400, message: "A room UUID is required.") }
                return .json(try await teamRooms.context(roomID: id))
            case ("POST", "/rooms/post"), ("POST", "/rooms/ask"):
                guard let teamRooms else { return .error(status: 503, message: "Team rooms unavailable.") }
                let note = try BridgeJSON.decoder.decode(RoomTeamNote.self, from: request.body)
                if request.path == "/rooms/ask" { return .json(try await teamRooms.ask(note)) }
                return .json(try await teamRooms.post(note))
            case ("GET", "/rooms/roles"):
                return .json(try RoomPrompts.cards(configuration: configuration))
            case ("GET", "/rooms"):
                guard let teamRooms else { return .error(status: 503, message: "Team rooms unavailable. Restart Agent Hub.") }
                return .json(try await teamRooms.list())
            case ("POST", "/rooms"), ("POST", "/rooms/activate"), ("POST", "/rooms/messages"), ("POST", "/rooms/stop"), ("POST", "/rooms/configure"):
                guard let teamRooms else { return .error(status: 503, message: "Team rooms unavailable.") }
                let command = try BridgeJSON.decoder.decode(RoomCommand.self, from: request.body)
                switch request.path {
                case "/rooms/configure": return .json(try await teamRooms.configure(command))
                case "/rooms": return .json(try await teamRooms.create(command))
                case "/rooms/activate": return .json(try await teamRooms.activate(command))
                case "/rooms/messages": return .json(try await teamRooms.send(command))
                default: return .json(try await teamRooms.stop(command))
                }
            case ("GET", "/status"):
                return .json(await orchestrator.status())
            case ("GET", "/events"):
                let limit = boundedLimit(request.queryValue("limit"))
                return .json(await orchestrator.recentEvents(limit: limit))
            case ("GET", "/logs"):
                let limit = boundedLimit(request.queryValue("limit"))
                return .json(await BridgeLogger.shared.recent(limit: limit))
            case ("GET", "/trace"):
                let limit = boundedLimit(request.queryValue("limit"))
                return .json(await orchestrator.recentTrace(limit: limit))
            case ("GET", "/trace/summary"):
                return .json(await orchestrator.traceSummary())
            case ("GET", "/trace/export"):
                return HTTPResponse(
                    status: 200,
                    reason: "OK",
                    headers: [
                        "Content-Type": "application/json",
                        "Content-Disposition": "attachment; filename=\"bridge-trace.json\"",
                    ],
                    body: try await orchestrator.traceExport()
                )
            case ("POST", "/events"):
                var event = try BridgeJSON.decoder.decode(BridgeEvent.self, from: request.body)
                event.metadata["bridge_managed"] = .bool(false)
                event.metadata.removeValue(forKey: "_runner_generation")
                try validate(event)
                try await orchestrator.ingest(event)
                return .empty(status: 201, reason: "Created")
            case ("POST", "/sessions"):
                let sessionRequest = try BridgeJSON.decoder.decode(
                    SessionRequest.self,
                    from: request.body
                )
                let runtime = try await orchestrator.start(
                    try SessionRequest(
                        projectPath: sessionRequest.projectPath,
                        goal: sessionRequest.goal,
                        durationMinutes: sessionRequest.durationMinutes,
                        startingAgent: sessionRequest.startingAgent
                    )
                )
                return .json(runtime, status: 201, reason: "Created")
            case ("POST", "/sessions/pause"):
                try await orchestrator.pause()
                return .json(await orchestrator.status())
            case ("POST", "/sessions/resume"):
                try await orchestrator.resume()
                return .json(await orchestrator.status())
            case ("POST", "/sessions/stop"):
                try await orchestrator.stop()
                return .json(await orchestrator.status())
            case ("POST", "/handoff"):
                let handoff = try BridgeJSON.decoder.decode(
                    ForceHandoffRequest.self,
                    from: request.body
                )
                try await orchestrator.forceHandoff(handoff)
                return .json(await orchestrator.status())
            case ("POST", "/provider/retry"):
                await orchestrator.hydrateProvider(requireGeneration: true)
                return .json(await orchestrator.status())
            case ("POST", "/usage/refresh"):
                await orchestrator.hydratePlanUsage()
                return .json(await orchestrator.status())
            case ("POST", "/usage/codex/refresh"):
                await orchestrator.hydrateCodexUsage()
                return .json(await orchestrator.status())
            case ("GET", "/credits/history"), ("GET", "/credits/export"):
                let values = ["window", "scope"].reduce(into: [String: String]()) { values, key in values[key] = request.queryValue(key) }
                return .json(try await orchestrator.creditHistory(query: CreditHistoryQuery(query: values)))
            case ("GET", "/usage/series"):
                return .json(TokenAccountingSeriesAdapter.build(overview: try await activityService.overview()))
            case ("POST", "/usage/series/refresh"):
                let overview = try await activityService.refresh(configuration: configuration.agents, force: true)
                return .json(TokenAccountingSeriesAdapter.build(overview: overview))
            case ("POST", "/coordinator/configure"):
                let request = try BridgeJSON.decoder.decode(
                    CoordinatorConfigurationRequest.self,
                    from: request.body
                )
                return .json(try configureCoordinator(request))
            default:
                if request.method == "POST",
                   request.path.hasPrefix("/hooks/claude/")
                {
                    let hookName = String(request.path.dropFirst("/hooks/claude/".count))
                    let payload = try BridgeJSON.decoder.decode(
                        [String: JSONValue].self,
                        from: request.body
                    )
                    let status = await orchestrator.status()
                    let event = try EventNormalizer.normalizeClaudeHook(
                        name: hookName,
                        payload: payload,
                        bridgeSessionID: status.session?.id
                    )
                    try await orchestrator.ingest(event)
                    return .empty()
                }
                return .error(status: 404, message: "Route not found")
            }
        } catch BridgeError.unauthorized {
            return .error(status: 401, message: "Unauthorized")
        } catch BridgeError.sessionAlreadyActive {
            return .error(status: 409, message: BridgeError.sessionAlreadyActive.localizedDescription)
        } catch BridgeError.noActiveSession {
            return .error(status: 409, message: BridgeError.noActiveSession.localizedDescription)
        } catch {
            return .error(status: 400, message: error.localizedDescription)
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let value = request.headers["authorization"],
              value.hasPrefix("Bearer ")
        else { return false }
        let supplied = String(value.dropFirst("Bearer ".count))
        return constantTimeEqual(supplied, configuration.server.bearerToken)
    }

    private func validate(_ event: BridgeEvent) throws {
        guard event.schemaVersion == "1.0",
              !event.sessionID.isEmpty,
              event.projectPath.hasPrefix("/"),
              event.content.text.count <= configuration.server.maxEventBytes
        else {
            throw BridgeError.invalidEvent("Event does not satisfy the v1 contract")
        }
    }

    private func configureCoordinator(
        _ request: CoordinatorConfigurationRequest
    ) throws -> CoordinatorConfigurationStatus {
        var updated = configuration
        switch request.mode {
        case .grok:
            let model = request.model?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? MetaConfiguration.grokModel
            guard !model.isEmpty else {
                throw BridgeError.invalidRequest(
                    "Grok configuration requires a model."
                )
            }
            if let key = request.apiKey?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !key.isEmpty
            {
                try CoordinatorSecretStore.save(
                    key,
                    account: "XAI_API_KEY"
                )
            }
            updated.meta.provider = .grokCLI
            updated.meta.model = model
            updated.meta.endpoint = MetaConfiguration.grokEndpoint
            updated.meta.apiKeyEnvironmentVariable = "XAI_API_KEY"
            updated.meta.confidenceThreshold = max(
                updated.meta.confidenceThreshold, 0.75
            )
        case .gemini:
            throw BridgeError.invalidRequest(
                "Gemini configuration is historical only. Configure Grok instead."
            )
        case .rules:
            updated.meta.provider = .rules
            if request.forgetKey {
                try CoordinatorSecretStore.remove(
                    account: updated.meta.apiKeyEnvironmentVariable
                )
            }
        }
        try ConfigurationStore.save(updated)
        return CoordinatorConfigurationStatus(
            provider: updated.meta.coordinatorIdentifier,
            model: updated.meta.model,
            endpoint: updated.meta.endpoint,
            credentialStored: CoordinatorSecretStore.resolve(
                environmentVariable: updated.meta.apiKeyEnvironmentVariable
            ) != nil,
            restartRequired: true
        )
    }

    private func boundedLimit(_ raw: String?) -> Int {
        min(max(Int(raw ?? "50") ?? 50, 1), 500)
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        var difference = UInt(a.count ^ b.count)
        let count = max(a.count, b.count)
        for index in 0 ..< count {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= UInt(x ^ y)
        }
        return difference == 0
    }
}
