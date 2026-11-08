import Foundation

public struct BridgeAPIClient: Sendable {
    public let configuration: BridgeConfiguration

    public init(configuration: BridgeConfiguration) {
        self.configuration = configuration
    }

    public func health() async throws -> Bool {
        let request = try makeRequest(path: "/health", authenticated: false)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    public func rooms() async throws -> [TeamRoom] {
        try await send(path: "/rooms", method: "GET", body: Optional<Data>.none)
    }

    public func roomRoles() async throws -> [RoomRoleCard] {
        try await send(path: "/rooms/roles", method: "GET", body: Optional<Data>.none)
    }

    public func teamContext(roomID: UUID) async throws -> TeamRoom {
        try await send(path: "/rooms/context?room=\(roomID.uuidString)", method: "GET", body: Optional<Data>.none)
    }

    public func teamNote(_ note: RoomTeamNote, ask: Bool = false) async throws -> RoomMessage {
        try await send(path: ask ? "/rooms/ask" : "/rooms/post", method: "POST", encodable: note)
    }

    public func roomCommand(_ action: String, command: RoomCommand) async throws -> TeamRoom {
        try await send(path: action.isEmpty ? "/rooms" : "/rooms/\(action)", method: "POST", encodable: command)
    }

    public func status() async throws -> BridgeStatus {
        try await send(path: "/status", method: "GET", body: Optional<Data>.none)
    }

    public func start(_ request: SessionRequest) async throws -> RuntimeSession {
        try await send(path: "/sessions", method: "POST", encodable: request)
    }

    public func pause() async throws -> BridgeStatus {
        try await send(path: "/sessions/pause", method: "POST", body: Data())
    }

    public func resume() async throws -> BridgeStatus {
        try await send(path: "/sessions/resume", method: "POST", body: Data())
    }

    public func stop() async throws -> BridgeStatus {
        try await send(path: "/sessions/stop", method: "POST", body: Data())
    }

    public func handoff(agent: AgentName, reason: String) async throws -> BridgeStatus {
        try await send(
            path: "/handoff",
            method: "POST",
            encodable: ForceHandoffRequest(agent: agent, reason: reason)
        )
    }

    public func retryProvider() async throws -> BridgeStatus {
        try await send(path: "/provider/retry", method: "POST", body: Data())
    }

    public func refreshPlanUsage() async throws -> BridgeStatus {
        try await send(path: "/usage/refresh", method: "POST", body: Data())
    }

    public func refreshCodexUsage() async throws -> BridgeStatus {
        try await send(path: "/usage/codex/refresh", method: "POST", body: Data())
    }

    public func creditHistory(query: CreditHistoryQuery = .init()) async throws -> CreditHistorySnapshot {
        try await send(path: query.path(), method: "GET", body: Optional<Data>.none)
    }

    public func tokenSeries() async throws -> TokenSeriesSnapshot {
        try await send(path: "/usage/series", method: "GET", body: Data())
    }

    public func refreshTokenSeries() async throws -> TokenSeriesSnapshot {
        try await send(path: "/usage/series/refresh", method: "POST", body: Data())
    }

    public func activity() async throws -> ActivityOverview {
        try await send(path: "/activity", method: "GET", body: Optional<Data>.none)
    }
    public func accounting(query: ActivityAccountingQuery = .init()) async throws -> ActivityAccounting.Report {
        try await send(path: query.path(), method: "GET", body: Optional<Data>.none)
    }
    public func refreshActivity() async throws -> ActivityOverview {
        try await send(path: "/activity/refresh", method: "POST", body: Data())
    }
    public func pinActivity(sessionID: String?) async throws -> ActivityOverview {
        try await send(path: "/activity/pin", method: "POST", encodable: ActivityPinRequest(sessionID: sessionID))
    }
    public func activityRepositories() async throws -> ActivityOverview {
        try await send(path: "/activity/repositories", method: "POST", body: Data())
    }
    public func activityJournal() async throws -> [ActivityJournalEntry] {
        try await send(path: "/activity/journal", method: "GET", body: Optional<Data>.none)
    }
    public func publishActivityJournal() async throws -> ActivityJournalEntry {
        try await send(path: "/activity/journal", method: "POST", body: Data())
    }

    public func configureCoordinator(
        _ request: CoordinatorConfigurationRequest
    ) async throws -> CoordinatorConfigurationStatus {
        try await send(
            path: "/coordinator/configure",
            method: "POST",
            encodable: request
        )
    }

    public func events(limit: Int) async throws -> [BridgeEvent] {
        try await send(
            path: "/events?limit=\(min(max(limit, 1), 500))",
            method: "GET",
            body: Optional<Data>.none
        )
    }

    public func logs(limit: Int) async throws -> [JSONValue] {
        try await send(
            path: "/logs?limit=\(min(max(limit, 1), 500))",
            method: "GET",
            body: Optional<Data>.none
        )
    }

    public func trace(limit: Int = 500) async throws -> [TraceRecord] {
        try await send(
            path: "/trace?limit=\(min(max(limit, 1), 2_000))",
            method: "GET",
            body: Optional<Data>.none
        )
    }

    public func traceSummary() async throws -> TraceSummary {
        try await send(path: "/trace/summary", method: "GET", body: Optional<Data>.none)
    }

    public func traceExport() async throws -> Data {
        var request = try makeRequest(path: "/trace/export")
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            throw BridgeError.network("Trace export failed")
        }
        return data
    }

    public func submit(_ event: BridgeEvent) async throws {
        let _: EmptyResponse = try await send(
            path: "/events",
            method: "POST",
            encodable: event
        )
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        encodable: Body
    ) async throws -> Response {
        try await send(
            path: path,
            method: method,
            body: BridgeJSON.compactEncoder.encode(encodable)
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Response {
        var request = try makeRequest(path: path)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.network("Missing HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let envelope = try? BridgeJSON.decoder.decode(ErrorResponse.self, from: data)
            throw BridgeError.network(envelope?.error ?? "HTTP \(http.statusCode)")
        }
        return try BridgeJSON.decoder.decode(Response.self, from: data)
    }

    func makeRequest(
        path: String,
        authenticated: Bool = true
    ) throws -> URLRequest {
        guard let url = URL(
            string: "http://\(configuration.server.host):\(configuration.server.port)\(path)"
        ) else {
            throw BridgeError.configuration("Invalid bridge server URL")
        }
        var request = URLRequest(url: url)
        // Session start and explicit provider retry can include a real remote
        // coordinator decision. Keep local transport headroom above the
        // provider's own 30-second timeout.
        request.timeoutInterval = 60
        if authenticated {
            request.setValue(
                "Bearer \(configuration.server.bearerToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }
}

private struct ErrorResponse: Decodable {
    var error: String
}

private struct EmptyResponse: Decodable {}
