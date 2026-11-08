import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var target: String
    public var headers: [String: String]
    public var body: Data

    public var path: String {
        target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    public func queryValue(_ name: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public init(
        status: Int,
        reason: String,
        headers: [String: String] = ["Content-Type": "application/json"],
        body: Data = Data()
    ) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(
        _ value: T,
        status: Int = 200,
        reason: String = "OK"
    ) -> HTTPResponse {
        do {
            return HTTPResponse(
                status: status,
                reason: reason,
                body: try BridgeJSON.compactEncoder.encode(value)
            )
        } catch {
            return .error(status: 500, message: "Response encoding failed")
        }
    }

    public static func empty(status: Int = 200, reason: String = "OK") -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, body: Data("{}".utf8))
    }

    public static func error(status: Int, message: String) -> HTTPResponse {
        .json(ErrorEnvelope(error: message), status: status, reason: reasonPhrase(status))
    }

    fileprivate var wireData: Data {
        var responseHeaders = headers
        responseHeaders["Content-Length"] = String(body.count)
        responseHeaders["Connection"] = "close"
        var lines = ["HTTP/1.1 \(status) \(reason)"]
        lines += responseHeaders.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
        lines += ["", ""]
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }
}

private struct ErrorEnvelope: Codable {
    var error: String
}

public typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

public final class LocalHTTPServer: @unchecked Sendable {
    private let configuration: ServerConfiguration
    private let handler: HTTPHandler
    private let queue = DispatchQueue(label: "dev.claudecodexbridge.http")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(configuration: ServerConfiguration, handler: @escaping HTTPHandler) {
        self.configuration = configuration
        self.handler = handler
    }

    public func start() async throws {
        guard !hasListener() else { return }
        guard configuration.isLoopback else {
            throw BridgeError.configuration("server.host must be 127.0.0.1, ::1 or localhost; Agent Hub never listens on the network.")
        }

        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            throw BridgeError.configuration("Invalid server port")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: port
        )
        let listener = try NWListener(using: parameters)
        let startGate = ListenerStartGate()
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                startGate.resolve(.success(()))
            case let .failed(error):
                if let listener {
                    self?.removeListener(listener)
                }
                startGate.resolve(.failure(error))
                Task {
                    await BridgeLogger.shared.log(
                        "ERROR",
                        "HTTP listener failed",
                        fields: ["error": .string(error.localizedDescription)]
                    )
                }
            case .cancelled:
                startGate.resolve(.failure(CancellationError()))
            default:
                break
            }
        }

        storeListener(listener)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startGate.install(continuation)
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
            startGate.resolve(.failure(CancellationError()))
        }
    }

    public func stop() {
        stateLock.lock()
        let currentListener = listener
        listener = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()

        currentListener?.cancel()
        for connection in activeConnections {
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        guard listener != nil else {
            stateLock.unlock()
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .cancelled = state {
                self?.removeConnection(connection)
            } else if case .failed = state {
                self?.removeConnection(connection)
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            do {
                if let request = try HTTPParser.parse(
                    accumulated,
                    maximumBodyBytes: configuration.maxEventBytes
                ) {
                    Task {
                        let response = await self.handler(request)
                        self.send(response, on: connection)
                    }
                    return
                }
            } catch BridgeError.payloadTooLarge {
                send(.error(status: 413, message: "Payload too large"), on: connection)
                return
            } catch {
                send(.error(status: 400, message: error.localizedDescription), on: connection)
                return
            }
            if let error {
                send(.error(status: 400, message: error.localizedDescription), on: connection)
            } else if isComplete {
                send(.error(status: 400, message: "Incomplete HTTP request"), on: connection)
            } else {
                receive(connection, buffer: accumulated)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.removeConnection(connection)
        })
    }

    private func removeListener(_ candidate: NWListener) {
        stateLock.lock()
        if listener === candidate {
            listener = nil
        }
        stateLock.unlock()
    }

    private func removeConnection(_ connection: NWConnection) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        stateLock.unlock()
    }

    private func hasListener() -> Bool {
        stateLock.lock()
        let result = listener != nil
        stateLock.unlock()
        return result
    }

    private func storeListener(_ listener: NWListener) {
        stateLock.lock()
        self.listener = listener
        stateLock.unlock()
    }
}

private final class ListenerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

public enum HTTPParser {
    public static func parse(
        _ data: Data,
        maximumBodyBytes: Int
    ) throws -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 32_768 { throw BridgeError.invalidRequest("HTTP headers too large") }
            return nil
        }
        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw BridgeError.invalidRequest("HTTP headers are not UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw BridgeError.invalidRequest("Missing HTTP request line")
        }
        let components = requestLine.split(separator: " ")
        guard components.count == 3, components[2].hasPrefix("HTTP/1.") else {
            throw BridgeError.invalidRequest("Malformed HTTP request line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw BridgeError.invalidRequest("Malformed HTTP header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard headers["transfer-encoding"]?.lowercased() != "chunked" else {
            throw BridgeError.invalidRequest("Chunked request bodies are not supported")
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0 else {
            throw BridgeError.invalidRequest("Invalid Content-Length")
        }
        guard contentLength <= maximumBodyBytes else {
            throw BridgeError.payloadTooLarge
        }
        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return HTTPRequest(
            method: String(components[0]),
            target: String(components[1]),
            headers: headers,
            body: data[bodyStart ..< bodyStart + contentLength]
        )
    }
}

private func reasonPhrase(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 201: "Created"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 409: "Conflict"
    case 413: "Payload Too Large"
    case 503: "Service Unavailable"
    default: "Internal Server Error"
    }
}
