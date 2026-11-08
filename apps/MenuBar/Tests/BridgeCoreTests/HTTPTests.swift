@testable import BridgeCore
import Darwin
import Foundation
import XCTest

final class HTTPTests: XCTestCase {
    func testParserWaitsForCompleteBody() throws {
        let partial = Data(
            "POST /events HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nabc".utf8
        )
        XCTAssertNil(try HTTPParser.parse(partial, maximumBodyBytes: 100))
        var complete = partial
        complete.append(Data("de".utf8))
        let request = try XCTUnwrap(
            HTTPParser.parse(complete, maximumBodyBytes: 100)
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/events")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "abcde")
    }

    func testParserRejectsOversizedBodyBeforeReadingIt() {
        let request = Data(
            "POST /events HTTP/1.1\r\nContent-Length: 101\r\n\r\n".utf8
        )
        XCTAssertThrowsError(try HTTPParser.parse(request, maximumBodyBytes: 100)) {
            XCTAssertEqual($0 as? BridgeError, .payloadTooLarge)
        }
    }

    func testHealthIsPublicAndStatusRequiresToken() async throws {
        let configuration = try BridgeConfiguration.makeDefault()
        let orchestrator = Orchestrator(
            configuration: configuration,
            claudeRunner: CompletingRunner(agent: .claude),
            codexRunner: CompletingRunner(agent: .codex),
            configurationSaver: { _ in }
        )
        let router = BridgeRouter(configuration: configuration, orchestrator: orchestrator)
        let health = await router.handle(
            HTTPRequest(method: "GET", target: "/health", headers: [:], body: Data())
        )
        XCTAssertEqual(health.status, 200)
        let denied = await router.handle(
            HTTPRequest(method: "GET", target: "/status", headers: [:], body: Data())
        )
        XCTAssertEqual(denied.status, 401)

        let oversizedToken = await router.handle(
            HTTPRequest(
                method: "GET",
                target: "/status",
                headers: ["authorization": "Bearer " + String(repeating: "x", count: 2_000)],
                body: Data()
            )
        )
        XCTAssertEqual(oversizedToken.status, 401)

        let providerRetry = await router.handle(
            HTTPRequest(
                method: "POST",
                target: "/provider/retry",
                headers: ["authorization": "Bearer \(configuration.server.bearerToken)"],
                body: Data()
            )
        )
        XCTAssertEqual(providerRetry.status, 200)
        let status = try BridgeJSON.decoder.decode(BridgeStatus.self, from: providerRetry.body)
        XCTAssertEqual(status.provider.state, .ready)
        XCTAssertEqual(status.provider.provider, "rules")
    }

    func testServerStartReturnsOnlyAfterListenerIsReady() async throws {
        var configuration = ServerConfiguration(bearerToken: "test-token")
        configuration.port = try availableLoopbackPort()
        let server = LocalHTTPServer(configuration: configuration) { request in
            request.path == "/health"
                ? .json(["status": "ok"])
                : .error(status: 404, message: "Not found")
        }
        try await server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(configuration.port)/health")
        )
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: data) as? [String: String],
            ["status": "ok"]
        )
    }

    func testServerRefusesToListenBeyondLoopback() async throws {
        for host in ["0.0.0.0", "::", "192.168.1.20", "example.invalid"] {
            var configuration = ServerConfiguration(bearerToken: "test-token")
            configuration.host = host
            configuration.port = try availableLoopbackPort()
            let server = LocalHTTPServer(configuration: configuration) { _ in .empty() }
            do {
                try await server.start()
                server.stop()
                XCTFail("Listened on \(host)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("never listens on the network"), "\(host): \(error)")
            }
        }
        XCTAssertTrue(ServerConfiguration(bearerToken: "t").isLoopback)
    }

    private func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }
}

private struct CompletingRunner: AgentRunner {
    var agent: AgentName

    func run(
        project _: URL,
        prompt _: String,
        nativeSessionID _: String?,
        bridgeSessionID _: String
    ) async throws -> AgentResult {
        AgentResult(
            agent: agent,
            success: true,
            output: "Verified <bridge:complete>",
            sessionID: UUID().uuidString,
            rateLimited: false,
            resetAt: nil,
            error: nil,
            diagnostics: [:]
        )
    }
}
