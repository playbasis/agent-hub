import BridgeCore
import XCTest
@testable import ClaudeCodexBridgeMenuBar

final class RuntimeReadinessTests: XCTestCase {
    @MainActor
    func testRestoredJournalWaitsForConfirmedServiceBeforeLoading() async throws {
        let model = BridgeViewModel(automaticallyConnect: false)
        XCTAssertNil(model.runtimeClient)
        XCTAssertNil(model.runtimeClientID)
        XCTAssertFalse(model.dailyBrief.isConnected)
        await model.loadActivityJournal()
        XCTAssertNil(model.dailyBrief.errorMessage, "A cold start must show connecting, not an avoidable network failure")
        XCTAssertFalse(model.dailyBrief.hasLoaded)

        let client = BridgeAPIClient(configuration: try BridgeConfiguration.makeDefault())
        model.bindReadyRuntimeClient(client)
        XCTAssertTrue(model.isReady)
        XCTAssertNotNil(model.runtimeClient)
        XCTAssertNotNil(model.runtimeClientID)
        XCTAssertTrue(model.dailyBrief.isConnected)
        XCTAssertNil(model.dailyBrief.errorMessage)
    }

    @MainActor
    func testStatusPollsKeepIdentityButReconnectionRestartsVisiblePageLoads() async throws {
        let model = BridgeViewModel(automaticallyConnect: false)
        let client = BridgeAPIClient(configuration: try BridgeConfiguration.makeDefault())
        model.bindReadyRuntimeClient(client)
        let initial = try XCTUnwrap(model.runtimeClientID)
        model.bindReadyRuntimeClient(client)
        XCTAssertEqual(model.runtimeClientID, initial, "Normal status polls must not reload pages or invalidate saves")

        // No configuration was loaded, so retryConnection's guarded task cannot
        // start a runtime, contact providers or make network requests.
        model.retryConnection()
        XCTAssertFalse(model.isReady)
        XCTAssertNil(model.runtimeClient)
        model.bindReadyRuntimeClient(client)
        XCTAssertNotEqual(model.runtimeClientID, initial)
        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.dailyBrief.isConnected)
    }
}
