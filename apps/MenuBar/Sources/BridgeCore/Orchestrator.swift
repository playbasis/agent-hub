import Foundation

public actor Orchestrator {
    private var configuration: BridgeConfiguration
    private var session: RuntimeSession?
    private var store: ProjectStore?
    private var quota: QuotaTracker
    private var latestDecision: Decision?
    private var providerHealth: ProviderHealth
    private var dispatchTask: Task<Void, Never>?
    private var dispatchGeneration: UUID?
    private var wakeTask: Task<Void, Never>?
    private var planUsageTask: Task<Void, Never>?
    private var codexUsageTask: Task<Void, Never>?
    private var codexUsageGeneration: UUID?
    private var dispatching = false
    private let decisionEngine: DecisionEngine
    private let claudeRunner: any AgentRunner
    private let codexRunner: any AgentRunner
    private let grokRunner: any AgentRunner
    private let nonCodexUsageReader: @Sendable () async -> [QuotaEstimate]
    private let codexUsageReader: @Sendable () async -> QuotaEstimate
    private let creditHistoryStore: CreditHistoryStore
    private let recordsCreditHistory: Bool
    private var anonymousCreditEpoch = UUID().uuidString
    private var currentCreditScope: CreditHistoryScope?
    private var creditRecordingWarning: String?
    private var creditReadFailureAt: Date?
    private let planUsageSaver: @Sendable ([String: QuotaEstimate]) throws -> Void
    private let configurationSaver: @Sendable (BridgeConfiguration) throws -> Void
    private let recoveryLoader: @Sendable () -> RuntimeSession?
    private let recoverySaver: @Sendable (RuntimeSession?) throws -> Void

    public init(
        configuration: BridgeConfiguration,
        claudeRunner: (any AgentRunner)? = nil,
        codexRunner: (any AgentRunner)? = nil,
        grokRunner: (any AgentRunner)? = nil,
        configurationSaver: @escaping @Sendable (BridgeConfiguration) throws -> Void = {
            try ConfigurationStore.save($0)
        },
        recoveryLoader: (@Sendable () -> RuntimeSession?)? = nil,
        recoverySaver: (@Sendable (RuntimeSession?) throws -> Void)? = nil,
        nonCodexUsageReader: (@Sendable () async -> [QuotaEstimate])? = nil,
        codexUsageReader: (@Sendable () async -> QuotaEstimate)? = nil,
        creditHistoryStore: CreditHistoryStore? = nil,
        planUsageLoader: @Sendable () -> [String: QuotaEstimate] = { PlanUsageStore.load() },
        planUsageSaver: @escaping @Sendable ([String: QuotaEstimate]) throws -> Void = { try PlanUsageStore.save($0) }
    ) {
        self.configuration = configuration
        quota = QuotaTracker(
            cooldownMinutes: configuration.session.rateLimitCooldownMinutes
        )
        quota.applyProviderUsage(planUsageLoader())
        providerHealth = configuration.meta.provider == .rules
            ? .rulesReady
            : ProviderHealth(
                provider: configuration.meta.coordinatorIdentifier,
                state: .checking,
                fallbackActive: true,
                message: "Checking provider; deterministic rules remain active."
            )
        decisionEngine = DecisionEngine(configuration: configuration)
        self.claudeRunner = claudeRunner ?? ClaudeRunner(configuration: configuration.agents)
        self.codexRunner = codexRunner ?? CodexRunner(configuration: configuration.agents)
        self.grokRunner = grokRunner ?? GrokRunner(configuration: configuration.agents)
        let usageReader = LivePlanUsageReader(configuration: configuration.agents)
        self.nonCodexUsageReader = nonCodexUsageReader ?? {
            async let claude = usageReader.readClaude()
            async let grok = usageReader.readGrok()
            return await [claude, grok]
        }
        self.codexUsageReader = codexUsageReader ?? { await usageReader.readCodex() }
        self.creditHistoryStore = creditHistoryStore ?? CreditHistoryStore()
        // Injected provider fixtures must never write synthetic balances to a
        // developer's real financial history. Tests opt in with a private store.
        self.recordsCreditHistory = creditHistoryStore != nil || codexUsageReader == nil
        self.planUsageSaver = planUsageSaver
        self.configurationSaver = configurationSaver
        if let recoveryLoader {
            self.recoveryLoader = recoveryLoader
        } else if claudeRunner == nil, codexRunner == nil, grokRunner == nil {
            self.recoveryLoader = { try? SessionRecoveryStore.load() }
        } else {
            // Injected runners indicate a test/simulation. Avoid mutating the
            // real user's Application Support recovery snapshot.
            self.recoveryLoader = { nil }
        }
        if let recoverySaver {
            self.recoverySaver = recoverySaver
        } else if claudeRunner == nil, codexRunner == nil, grokRunner == nil {
            self.recoverySaver = { try SessionRecoveryStore.save($0) }
        } else {
            self.recoverySaver = { _ in }
        }
    }

    @discardableResult
    public func recover() async -> RuntimeSession? {
        guard var candidate = recoveryLoader() else { return nil }
        guard !candidate.isExpired,
              ![SessionState.complete, .stopped, .error].contains(candidate.state)
        else {
            try? recoverySaver(nil)
            return nil
        }
        candidate.activeAgent = .none
        candidate.wakeAt = nil
        if candidate.state != .paused {
            candidate.state = .paused
            candidate.lastError = "Recovered after restart; resume manually."
        }
        session = candidate
        // Deliberately do not construct ProjectStore here. That would touch a
        // protected user folder during app launch and cause an unexpected TCC
        // permission dialog. Resume attaches the store after a user action.
        store = nil
        try? recoverySaver(candidate)
        await BridgeLogger.shared.log("INFO", "Restored paused session snapshot", fields: [
            "session_id": .string(candidate.id),
        ])
        return candidate
    }

    public func start(_ request: SessionRequest) async throws -> RuntimeSession {
        if let existing = session,
           ![SessionState.complete, .stopped, .error].contains(existing.state)
        {
            throw BridgeError.sessionAlreadyActive
        }
        let created = Date()
        var runtime = RuntimeSession(
            id: UUID().uuidString,
            projectPath: request.projectPath,
            goal: request.goal,
            createdAt: created,
            deadline: created.addingTimeInterval(TimeInterval(request.durationMinutes * 60)),
            state: .idle,
            activeAgent: .none,
            preferredStartingAgent: request.startingAgent,
            agentSessionIDs: [:],
            lastEventID: nil,
            lastError: nil,
            wakeAt: nil,
            turnCount: 0
        )
        let projectStore = try ProjectStore(projectPath: request.projectPath)
        try projectStore.initialize(session: runtime)
        session = runtime
        store = projectStore
        try recoverySaver(runtime)
        quota = QuotaTracker(
            cooldownMinutes: configuration.session.rateLimitCooldownMinutes
        )
        latestDecision = nil
        if !configuration.recentProjects.contains(request.projectPath) {
            configuration.recentProjects.insert(request.projectPath, at: 0)
            configuration.recentProjects = Array(configuration.recentProjects.prefix(12))
            try configurationSaver(configuration)
        }
        let event = BridgeEvent(
            source: .bridge,
            type: .userMessage,
            content: .string(request.goal),
            sessionID: runtime.id,
            projectPath: request.projectPath,
            metadata: ["bridge_managed": .bool(true)]
        )
        try await ingest(event)
        runtime = session ?? runtime
        await BridgeLogger.shared.log("INFO", "Started bridge session", fields: [
            "session_id": .string(runtime.id),
            "project": .string(runtime.projectPath),
        ])
        return runtime
    }

    public func ingest(_ incoming: BridgeEvent) async throws {
        guard var runtime = session, let projectStore = store else {
            throw BridgeError.noActiveSession
        }
        let incomingProject = URL(fileURLWithPath: incoming.projectPath).standardizedFileURL.path
        guard incomingProject == runtime.projectPath else {
            throw BridgeError.invalidEvent("event project does not match the active session")
        }
        var event = incoming
        event.sessionID = runtime.id
        guard try projectStore.append(event: event) else { return }
        runtime.lastEventID = event.id.uuidString
        quota.update(event: event)
        session = runtime
        try persist(runtime, decision: latestDecision)

        if event.type == .toolUse {
            return
        }
        let bridgeManaged = event.metadata["bridge_managed"]?.boolValue == true
        if event.metadata["_runner_generation"]?.stringValue
            == dispatchGeneration?.uuidString
        {
            dispatching = false
            dispatchGeneration = nil
            dispatchTask = nil
        }
        if dispatching, !bridgeManaged {
            await BridgeLogger.shared.log("DEBUG", "Recorded hook event during managed turn")
            return
        }
        if runtime.isExpired {
            runtime.state = .stopped
            runtime.lastError = "Session deadline reached."
            session = runtime
            try persist(runtime, decision: latestDecision)
            return
        }
        if runtime.turnCount >= configuration.session.maximumTurns {
            runtime.state = .paused
            runtime.lastError = "Maximum turn count reached."
            session = runtime
            try persist(runtime, decision: latestDecision)
            return
        }
        if runtime.state == .paused || runtime.state == .stopped || runtime.state == .complete {
            return
        }

        runtime.state = .thinking
        session = runtime
        try persist(runtime, decision: latestDecision)
        var routingQuota = quota
        let outcome = await decisionEngine.decide(
            event: event,
            session: runtime,
            store: projectStore,
            quota: &routingQuota
        )
        let decision = outcome.decision
        providerHealth = outcome.provider
        guard var current = session, current.id == runtime.id else { return }
        try projectStore.appendDecision(
            event: event,
            decision: decision,
            fromAgent: sourceAgent(event.source),
            coordinator: outcome.provider
        )
        var coordinatorBudgetViolation: String?
        if configuration.trace.enabled, outcome.provider.provider == "grok",
           !outcome.provider.fallbackActive
        {
            let telemetry = outcome.telemetry ?? AgentTelemetry(
                identity: ProviderIdentity(
                    requestedModel: configuration.meta.model,
                    resolvedModel: configuration.meta.model,
                    requestedEffort: configuration.meta.routineEffort,
                    modelProvider: "xai"
                ),
                warnings: ["Coordinator telemetry was unavailable."]
            )
            let remaining = remainingBudget(
                in: projectStore,
                including: telemetry.usage.total
            )
            _ = try? projectStore.appendTrace(TraceRecord(
                id: UUID().uuidString,
                sequence: 0,
                timestamp: Date(),
                bridgeSessionID: runtime.id,
                turnID: "decision-\(event.id.uuidString)",
                eventID: event.id.uuidString,
                provider: .grok,
                evidenceProviders: {
                    switch event.source {
                    case .claude: [.claude]
                    case .codex: [.codex]
                    case .grok: [.grok]
                    case .bridge: []
                    }
                }(),
                nativeSessionID: nil,
                nativeTurnID: telemetry.nativeTurnID,
                identity: telemetry.identity,
                usage: telemetry.usage,
                tools: telemetry.tools,
                durationMilliseconds: telemetry.durationMilliseconds,
                timeToFirstTokenMilliseconds: telemetry.timeToFirstTokenMilliseconds,
                outcome: "success",
                exitCode: nil,
                completeness: telemetry.completeness,
                warnings: telemetry.warnings,
                budgetReserved: nil,
                budgetRemaining: remaining,
                estimatedCostUSD: nil,
                costProvenance: .unavailable,
                adapterVersion: "grok-build-coordinator/1",
                previousHash: nil,
                recordHash: ""
            ))
            if configuration.trace.totalTokenCeiling != nil {
                if telemetry.usage.total == nil {
                    coordinatorBudgetViolation =
                        "Coordinator usage is missing; strict token budget paused."
                } else if let remaining, remaining < 0 {
                    coordinatorBudgetViolation =
                        "Token ceiling was crossed by the coordinator; the next turn is paused."
                }
            }
        }
        latestDecision = decision
        if let coordinatorBudgetViolation {
            current.state = .paused
            current.activeAgent = .none
            current.lastError = coordinatorBudgetViolation
            session = current
            try persist(current, decision: decision)
            return
        }

        switch decision.action {
        case .complete:
            let proof = projectStore.currentTraceSummary()
            if configuration.trace.requireThreeProvider,
               !proof.threeProviderVerified
            {
                current.state = .paused
                current.activeAgent = .none
                current.lastError = "Completion paused: three-provider proof is incomplete."
                session = current
                try persist(current, decision: decision)
                return
            }
            if !configuration.trace.requireThreeProvider,
               configuration.trace.requireDualProvider,
               !proof.dualProviderVerified
            {
                current.state = .paused
                current.activeAgent = .none
                current.lastError = "Completion paused: dual-provider proof is incomplete."
                session = current
                try persist(current, decision: decision)
                return
            }
            current.state = .complete
            current.activeAgent = .none
            current.wakeAt = nil
            session = current
            try persist(current, decision: decision)
        case .pause:
            let reset = quota.earliestReset()
            current.state = reset == nil ? .paused : .parked
            current.activeAgent = .none
            current.wakeAt = reset
            session = current
            try persist(current, decision: decision)
            if let reset { scheduleWake(sessionID: current.id, at: reset) }
        case .continue, .handoff:
            current.state = .thinking
            current.activeAgent = .none
            session = current
            try persist(current, decision: decision)
            scheduleDispatch(
                agent: decision.nextAgent,
                prompt: decision.refinedPrompt,
                sessionID: current.id
            )
        }
    }

    public func pause() throws {
        guard var runtime = session, store != nil else {
            throw BridgeError.noActiveSession
        }
        dispatchTask?.cancel()
        dispatchTask = nil
        dispatchGeneration = nil
        wakeTask?.cancel()
        wakeTask = nil
        dispatching = false
        runtime.state = .paused
        runtime.activeAgent = .none
        runtime.wakeAt = nil
        session = runtime
        try persist(runtime, decision: latestDecision)
    }

    public func resume() async throws {
        guard var runtime = session else {
            throw BridgeError.noActiveSession
        }
        _ = try attachProjectStore(to: runtime)
        guard !runtime.isExpired else {
            runtime.state = .stopped
            runtime.lastError = "Session deadline reached."
            session = runtime
            try persist(runtime, decision: latestDecision)
            return
        }
        runtime.state = .idle
        runtime.wakeAt = nil
        runtime.lastError = nil
        session = runtime
        try persist(runtime, decision: latestDecision)
        let event = BridgeEvent(
            source: .bridge,
            type: .userMessage,
            content: .string("Resume the shared goal from current project state."),
            sessionID: runtime.id,
            projectPath: runtime.projectPath,
            metadata: ["bridge_managed": .bool(true)]
        )
        try await ingest(event)
    }

    public func stop() throws {
        guard var runtime = session else {
            throw BridgeError.noActiveSession
        }
        dispatchTask?.cancel()
        dispatchTask = nil
        dispatchGeneration = nil
        wakeTask?.cancel()
        wakeTask = nil
        dispatching = false
        runtime.state = .stopped
        runtime.activeAgent = .none
        runtime.wakeAt = nil
        session = runtime
        if let projectStore = store {
            try projectStore.saveRuntime(runtime)
            try projectStore.updateBridge(session: runtime, decision: latestDecision)
        }
        try recoverySaver(nil)
    }

    /// Quiesces background work before the host process exits. An unfinished
    /// session is persisted as paused so a later launch never mistakes a
    /// terminated subprocess for live work.
    public func shutdown() async {
        let activeDispatch = dispatchTask
        let activePlanUsage = planUsageTask
        let activeCodexUsage = codexUsageTask
        dispatchGeneration = nil
        dispatchTask?.cancel()
        dispatchTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        planUsageTask?.cancel()
        planUsageTask = nil
        codexUsageGeneration = nil
        codexUsageTask?.cancel()
        codexUsageTask = nil
        dispatching = false

        if var runtime = session, let projectStore = store {
            if [.idle, .thinking, .running, .parked].contains(runtime.state) {
                runtime.state = .paused
                runtime.lastError = "Paused when the bridge app closed; resume manually."
            }
            runtime.activeAgent = .none
            runtime.wakeAt = nil
            session = runtime
            try? projectStore.saveRuntime(runtime)
            try? projectStore.updateBridge(session: runtime, decision: latestDecision)
            try? recoverySaver(runtime)
        } else if let runtime = session {
            try? recoverySaver(runtime)
        }

        await activeDispatch?.value
        await activePlanUsage?.value
        await activeCodexUsage?.value
    }

    public func forceHandoff(_ request: ForceHandoffRequest) throws {
        guard var runtime = session else {
            throw BridgeError.noActiveSession
        }
        let projectStore = try attachProjectStore(to: runtime)
        guard request.agent != .none else {
            throw BridgeError.invalidRequest("handoff agent cannot be none")
        }
        dispatchGeneration = nil
        dispatchTask?.cancel()
        dispatchTask = nil
        dispatching = false
        let event = BridgeEvent(
            source: .bridge,
            type: .userMessage,
            content: .string(request.reason),
            sessionID: runtime.id,
            projectPath: runtime.projectPath,
            metadata: ["bridge_managed": .bool(true), "manual_handoff": .bool(true)]
        )
        let decision = try Decision(
            label: .implementation,
            confidence: 1,
            nextAgent: request.agent,
            action: .handoff,
            refinedPrompt: """
            Manual bridge hand-off: \(request.reason)

            Read BRIDGE.md and CHANGES.log, inspect the current working tree,
            and continue the shared goal. Preserve unrelated user changes and
            verify your work before using the completion marker.
            """,
            summaryForLog: "User forced a hand-off to \(request.agent.rawValue).",
            reason: request.reason
        )
        try projectStore.append(event: event)
        try projectStore.appendDecision(
            event: event,
            decision: decision,
            fromAgent: .none,
            coordinator: ProviderHealth(
                provider: "manual",
                state: .ready,
                fallbackActive: false,
                message: "User forced this hand-off.",
                lastChecked: Date()
            )
        )
        latestDecision = decision
        runtime.state = .thinking
        runtime.activeAgent = .none
        session = runtime
        try persist(runtime, decision: decision)
        scheduleDispatch(agent: request.agent, prompt: decision.refinedPrompt, sessionID: runtime.id)
    }

    public func status() -> BridgeStatus {
        var tracker = quota
        return BridgeStatus(
            state: session?.state ?? .idle,
            activeAgent: session?.activeAgent ?? .none,
            session: session,
            latestDecision: latestDecision,
            quota: tracker.snapshot(),
            provider: providerHealth
        )
    }

    public func recentTrace(limit: Int) -> [TraceRecord] {
        store?.traceRecords(limit: min(max(limit, 1), 2_000)) ?? []
    }

    public func traceSummary() -> TraceSummary {
        store?.currentTraceSummary() ?? TraceSummary(
            bridgeSessionID: session?.id,
            records: 0,
            providers: [:],
            successfulProviders: [],
            totalTokens: nil,
            toolCalls: 0,
            budgetRemaining: configuration.trace.totalTokenCeiling,
            dualProviderVerified: false,
            traceVerified: true,
            completeness: .partial,
            updatedAt: Date()
        )
    }

    public func traceExport() throws -> Data {
        guard let store else { throw BridgeError.noActiveSession }
        return try store.sanitizedTraceExport()
    }

    @discardableResult
    public func hydrateProvider(
        requireGeneration: Bool = false
    ) async -> ProviderHealth {
        providerHealth = await decisionEngine.probeProvider(
            requireGeneration: requireGeneration
        )
        return providerHealth
    }

    public func hydratePlanUsage() async {
        if let planUsageTask {
            await planUsageTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshPlanUsage()
        }
        planUsageTask = task
        await task.value
    }

    /// Account metadata only: this never starts a model turn or another
    /// provider CLI. All-provider refreshes share this same single worker.
    public func hydrateCodexUsage() async {
        if let codexUsageTask {
            await codexUsageTask.value
            return
        }
        let generation = UUID()
        codexUsageGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshCodexUsage(generation: generation)
        }
        codexUsageTask = task
        await task.value
    }

    public func creditHistory(query: CreditHistoryQuery = .init(), now: Date = Date()) async throws -> CreditHistorySnapshot {
        let current = currentCreditScope ?? .anonymous(anonymousCreditEpoch)
        var report = try await creditHistoryStore.report(now: now, from: query.from(at: now), to: now, scope: current)
        if let id = query.scopeID, id != current.id {
            guard let requested = report.scopes.first(where: { $0.id == id })?.scope else {
                throw BridgeError.invalidRequest("This credit-history stream is not available.")
            }
            report = try await creditHistoryStore.report(now: now, from: query.from(at: now), to: now, scope: requested)
        }
        report.forecast = CreditForecastSafety.applying(to: report.forecast, now: now, isCurrentScope: report.selectedScope == current,
            integrityVerified: report.completeness.integrityVerified, providerReadFailed: creditReadFailureAt != nil,
            recordingFailed: creditRecordingWarning != nil)
        return CreditHistorySnapshot(history: report, currentScope: current, recordingWarning: creditRecordingWarning,
                                     providerRefreshFailedAt: creditReadFailureAt)
    }

    public func recentEvents(limit: Int) -> [BridgeEvent] {
        store?.recentEvents(limit: limit) ?? []
    }

    private func scheduleDispatch(agent: AgentName, prompt: String, sessionID: String) {
        guard !dispatching else { return }
        dispatchTask?.cancel()
        let generation = UUID()
        dispatchGeneration = generation
        dispatchTask = Task {
            await dispatch(
                agent: agent,
                prompt: prompt,
                sessionID: sessionID,
                generation: generation
            )
        }
    }

    private func refreshPlanUsage() async {
        guard !Task.isCancelled else { planUsageTask = nil; return }
        async let otherProviders = nonCodexUsageReader()
        await hydrateCodexUsage()
        let values = await otherProviders
        guard !Task.isCancelled else {
            planUsageTask = nil
            return
        }
        // Codex is applied only by its shared worker. A slow Claude refresh
        // cannot later restore an older Codex balance or failure snapshot.
        for value in values where value.agent != .codex {
            quota.applyProviderUsage(value)
        }
        planUsageTask = nil
        try? planUsageSaver(quota.snapshot())
    }

    private func refreshCodexUsage(generation: UUID) async {
        let value = await codexUsageReader()
        guard codexUsageGeneration == generation else { return }
        defer {
            codexUsageTask = nil
            codexUsageGeneration = nil
        }
        guard !Task.isCancelled, value.agent == .codex else { return }
        if value.source == .live {
            if let hash = value.accountIdentityHash, !hash.isEmpty { currentCreditScope = .account(hash) }
            else {
                if currentCreditScope?.kind == .account { anonymousCreditEpoch = UUID().uuidString }
                currentCreditScope = .anonymous(anonymousCreditEpoch)
            }
            creditReadFailureAt = nil
            creditRecordingWarning = value.credits == nil ? "Codex did not report credits; no new balance was recorded." : nil
        } else {
            creditReadFailureAt = Date()
            if let hash = value.accountIdentityHash, !hash.isEmpty { currentCreditScope = .account(hash) }
        }
        if recordsCreditHistory, value.source == .live, value.credits != nil {
            do {
                let result = try await creditHistoryStore.record(value, anonymousEpochID: anonymousCreditEpoch)
                guard codexUsageGeneration == generation, !Task.isCancelled else { return }
                creditRecordingWarning = result.disposition == .rejected ? result.reason : nil
            } catch {
                creditRecordingWarning = "Balance is available, but credit history could not be saved: \(error.localizedDescription)"
            }
        }
        quota.applyProviderUsage(value)
        try? planUsageSaver(quota.snapshot())
    }

    private func dispatch(
        agent: AgentName,
        prompt: String,
        sessionID: String,
        generation: UUID
    ) async {
        guard !dispatching,
              dispatchGeneration == generation,
              var runtime = session,
              runtime.id == sessionID,
              let projectStore = store
        else { return }
        if let ceiling = configuration.trace.totalTokenCeiling {
            guard let reservation = configuration.trace.perTurnTokenReservation,
                  reservation > 0
            else {
                runtime.state = .paused
                runtime.lastError = "Token ceiling requires a positive per-turn reservation."
                session = runtime
                try? persist(runtime, decision: latestDecision)
                return
            }
            let remaining = remainingBudget(in: projectStore) ?? ceiling
            guard remaining >= reservation else {
                runtime.state = .paused
                runtime.lastError = "Token budget cannot reserve another provider turn."
                session = runtime
                try? persist(runtime, decision: latestDecision)
                return
            }
        }
        if configuration.trace.estimatedCostCeilingUSD != nil {
            runtime.state = .paused
            runtime.lastError = """
            Estimated-cost enforcement is unavailable because no versioned price catalog \
            is installed for the configured models.
            """
            session = runtime
            try? persist(runtime, decision: latestDecision)
            return
        }
        dispatching = true
        runtime.state = .running
        runtime.activeAgent = agent
        session = runtime
        try? persist(runtime, decision: latestDecision)

        let runner: any AgentRunner
        switch agent {
        case .claude: runner = claudeRunner
        case .codex: runner = codexRunner
        case .grok: runner = grokRunner
        case .none:
            runtime.state = .paused
            runtime.lastError = "Cannot dispatch a turn without an agent."
            session = runtime
            try? persist(runtime, decision: latestDecision)
            return
        }
        let nativeSessionID = runtime.agentSessionIDs[agent.rawValue]
        let result: AgentResult
        do {
            result = try await runner.run(
                project: projectStore.project,
                prompt: prompt,
                nativeSessionID: nativeSessionID,
                bridgeSessionID: sessionID
            )
        } catch {
            result = AgentResult(
                agent: agent,
                success: false,
                output: "",
                sessionID: nativeSessionID,
                rateLimited: EventNormalizer.containsRateLimit(error.localizedDescription),
                resetAt: nil,
                error: error.localizedDescription,
                diagnostics: [:]
            )
        }
        guard !Task.isCancelled,
              dispatchGeneration == generation,
              var current = session,
              current.id == sessionID
        else {
            if dispatchGeneration == generation {
                dispatching = false
                dispatchGeneration = nil
            }
            if dispatchGeneration == nil, var cancelled = session {
                cancelled.activeAgent = .none
                session = cancelled
                try? persist(cancelled, decision: latestDecision)
            }
            return
        }
        current.activeAgent = .none
        current.turnCount += 1
        if let native = result.sessionID {
            current.agentSessionIDs[agent.rawValue] = native
        }
        if configuration.trace.enabled {
            let remaining = remainingBudget(
                in: projectStore,
                including: result.telemetry.usage.total
            )
            _ = try? projectStore.appendTrace(TraceRecord(
                id: UUID().uuidString,
                sequence: 0,
                timestamp: Date(),
                bridgeSessionID: current.id,
                turnID: generation.uuidString,
                eventID: nil,
                provider: traceProvider(agent),
                nativeSessionID: result.sessionID,
                nativeTurnID: result.telemetry.nativeTurnID,
                identity: result.telemetry.identity,
                usage: result.telemetry.usage,
                tools: result.telemetry.tools,
                durationMilliseconds: result.telemetry.durationMilliseconds,
                timeToFirstTokenMilliseconds: result.telemetry.timeToFirstTokenMilliseconds,
                outcome: result.success ? "success" : "failure",
                exitCode: result.diagnostics["returncode"]?.intValue,
                completeness: result.telemetry.completeness,
                warnings: result.telemetry.warnings,
                budgetReserved: configuration.trace.perTurnTokenReservation,
                budgetRemaining: remaining,
                estimatedCostUSD: nil,
                costProvenance: .unavailable,
                adapterVersion: adapterVersion(agent),
                previousHash: nil,
                recordHash: ""
            ))
            if configuration.trace.totalTokenCeiling != nil,
               result.telemetry.usage.total == nil
            {
                current.state = .paused
                current.lastError = "Authoritative token usage is missing; strict budget paused."
            } else if let remaining, remaining < 0 {
                current.state = .paused
                current.lastError = "Token ceiling was crossed in-flight; the next turn is paused."
            }
        }
        session = current
        try? persist(current, decision: latestDecision)

        let eventType: EventType =
            result.rateLimited ? .rateLimit : (result.success ? .turnComplete : .error)
        let content = result.output.isEmpty
            ? (result.error.map(JSONValue.string) ?? .string(""))
            : .string(result.output)
        var metadata = result.diagnostics
        metadata["bridge_managed"] = .bool(true)
        metadata["_runner_generation"] = .string(generation.uuidString)
        if let reset = result.resetAt {
            metadata["reset_at"] = .string(ISO8601.withFractional.string(from: reset))
        }
        let event = BridgeEvent(
            source: eventSource(agent),
            type: eventType,
            content: content,
            sessionID: current.id,
            projectPath: current.projectPath,
            metadata: metadata
        )
        do {
            try await ingest(event)
        } catch {
            if dispatchGeneration == generation {
                dispatching = false
                dispatchGeneration = nil
                dispatchTask = nil
            }
            current.state = .error
            current.lastError = error.localizedDescription
            session = current
            try? persist(current, decision: latestDecision)
        }
    }

    private func scheduleWake(sessionID: String, at date: Date) {
        wakeTask?.cancel()
        wakeTask = Task {
            let interval = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            try? await wake(sessionID: sessionID)
        }
    }

    private func wake(sessionID: String) async throws {
        guard var runtime = session,
              runtime.id == sessionID,
              runtime.state == .parked
        else { return }
        quota.refresh()
        runtime.state = .idle
        runtime.wakeAt = nil
        session = runtime
        try persist(runtime, decision: latestDecision)
        try await resume()
    }

    private func persist(_ runtime: RuntimeSession, decision: Decision?) throws {
        try recoverySaver(runtime)
        guard let store else { return }
        try store.saveRuntime(runtime)
        try store.updateBridge(session: runtime, decision: decision)
    }

    private func attachProjectStore(to runtime: RuntimeSession) throws -> ProjectStore {
        if let store { return store }
        let attached = try ProjectStore(projectPath: runtime.projectPath)
        store = attached
        return attached
    }

    private func sourceAgent(_ source: EventSource) -> AgentName {
        switch source {
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .bridge: .none
        }
    }

    private func traceProvider(_ agent: AgentName) -> TraceProvider {
        switch agent {
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .none: .rules
        }
    }

    private func eventSource(_ agent: AgentName) -> EventSource {
        switch agent {
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .none: .bridge
        }
    }

    private func adapterVersion(_ agent: AgentName) -> String {
        switch agent {
        case .claude: "claude-cli/1"
        case .codex: "codex-jsonl/1"
        case .grok: "grok-build-jsonl/1"
        case .none: "rules/1"
        }
    }

    private func remainingBudget(
        in projectStore: ProjectStore,
        including additional: Int? = nil
    ) -> Int? {
        guard let ceiling = configuration.trace.totalTokenCeiling else { return nil }
        let consumed = projectStore.currentTraceSummary().totalTokens ?? 0
        return ceiling - consumed - (additional ?? 0)
    }
}
