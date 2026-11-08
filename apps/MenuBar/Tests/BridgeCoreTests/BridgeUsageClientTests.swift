@testable import BridgeCore
import Foundation
import XCTest

final class BridgeUsageClientTests: XCTestCase {
    func testNarrowUsageRequestKeepsAuthenticatedLocalTransportHeadroom() throws {
        let configuration = try BridgeConfiguration.makeDefault()
        let client = BridgeAPIClient(configuration: configuration)
        let request = try client.makeRequest(path: "/usage/codex/refresh")
        XCTAssertEqual(request.url?.path, "/usage/codex/refresh")
        XCTAssertEqual(request.url?.host, configuration.server.host)
        XCTAssertEqual(request.url?.port, configuration.server.port)
        XCTAssertEqual(request.timeoutInterval, 60)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(configuration.server.bearerToken)")
        XCTAssertGreaterThan(request.timeoutInterval, 20, "Account and rate-limit metadata reads each have a provider-owned ten-second bound")
    }
}
