import AppKit
import XCTest
import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

/// Hidden AppKit integration tests exercise the real entry points without
/// connecting providers, starting room work, or replacing the user's defaults.
final class WorkspaceNavigationTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (ActivityReportsController, BridgeViewModel, UserDefaults, String) {
        _ = NSApplication.shared
        let name = "BridgeWorkspaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let controller = ActivityReportsController(defaults: defaults, presentsWindows: false)
        let model = BridgeViewModel(automaticallyConnect: false, workspaceController: controller)
        return (controller, model, defaults, name)
    }

    @MainActor
    func testEverySidebarPageReusesOneNativeWindow() async throws {
        let (controller, model, defaults, name) = try fixture()
        defer { controller.close(); defaults.removePersistentDomain(forName: name) }
        var identity: ObjectIdentifier?
        for page in BridgePage.allCases {
            model.openPage(page)
            XCTAssertEqual(controller.page, page)
            if identity == nil { identity = controller.windowIdentity }
            XCTAssertEqual(controller.windowIdentity, identity, "\(page) must use the common frame")
            XCTAssertEqual(controller.windowCreationCount, 1)
            XCTAssertFalse(controller.isWindowVisible, "integration tests must not display windows")
        }
        XCTAssertNotNil(identity)
    }

    @MainActor
    func testMinimumContentSizeIncludesNativeTitlebarAndDoesNotUseUserFrameAutosave() async throws {
        let (controller, model, defaults, name) = try fixture()
        defer { controller.close(); defaults.removePersistentDomain(forName: name) }
        model.openPage(.settings)
        let window = try XCTUnwrap(NSApplication.shared.windows.first { ObjectIdentifier($0) == controller.windowIdentity })
        let minimum = BridgeWorkspaceLayout.minimumContentSize
        // The sidebar runs under the traffic lights, so pages lay out below
        // the titlebar band and the minimum must include it.
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        let titlebar = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titlebar, 0)
        XCTAssertEqual(window.contentMinSize.width, minimum.width)
        XCTAssertEqual(window.contentMinSize.height, minimum.height + titlebar, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, minimum.height)
        XCTAssertTrue(window.frameAutosaveName.isEmpty)
    }

    @MainActor
    func testToolbarAndLegacyControllerEntryPointsUseSharedNavigation() async throws {
        let (controller, model, defaults, name) = try fixture()
        defer { controller.close(); defaults.removePersistentDomain(forName: name) }
        model.openLogs(); XCTAssertEqual(controller.page, .logs)
        TeamRoomController.shared.show(); XCTAssertEqual(controller.page, .teamChat)
        GLMChatController.shared.show(); XCTAssertEqual(controller.page, .glmChat)
        LogViewerController.shared.show(); XCTAssertEqual(controller.page, .logs)
        model.openProviderProof(); XCTAssertEqual(controller.page, .providerProof)
        model.openPage(.settings); XCTAssertEqual(controller.page, .settings)
        model.openPage(.accounts); XCTAssertEqual(controller.page, .accounts)
        model.openActivityReports(); XCTAssertEqual(controller.page, .overview)
        XCTAssertEqual(controller.windowCreationCount, 1)
    }

    @MainActor
    func testSessionDeepLinkHistoryAndRestoredSelection() async throws {
        let (controller, model, defaults, name) = try fixture()
        defer { controller.close(); defaults.removePersistentDomain(forName: name) }
        model.openActivityReports(sessionID: "codex:fixture")
        XCTAssertEqual(controller.page, .goals)
        XCTAssertEqual(controller.selectedSessionID, "codex:fixture")
        model.openPage(.teamChat); model.openPage(.settings)
        controller.goBack(); XCTAssertEqual(controller.page, .teamChat)
        controller.goBack(); XCTAssertEqual(controller.page, .goals)
        XCTAssertEqual(controller.selectedSessionID, "codex:fixture")
        controller.goForward(); XCTAssertEqual(controller.page, .teamChat)
        XCTAssertEqual(ActivityReportsController(defaults: defaults, presentsWindows: false).page, .teamChat)
    }

    @MainActor
    func testCloseAndReopenPreserveRouteAndUseSameWindow() async throws {
        let (controller, model, defaults, name) = try fixture()
        defer { controller.close(); defaults.removePersistentDomain(forName: name) }
        model.openPage(.settings)
        let identity = controller.windowIdentity
        controller.close()
        controller.show(model: model)
        XCTAssertEqual(controller.page, .settings)
        XCTAssertEqual(controller.windowIdentity, identity)
        XCTAssertEqual(controller.windowCreationCount, 1)
    }

    @MainActor
    func testWindowLifecycleTracksVisiblePageWorkWithoutCreatingAnotherWindow() async throws {
        let (controller, model, defaults, name) = try fixture()
        defer { controller.close(); defaults.removePersistentDomain(forName: name) }
        model.openPage(.overview)
        let identity = controller.windowIdentity
        let notification = Notification(name: NSWindow.didDeminiaturizeNotification)
        controller.windowDidDeminiaturize(notification)
        XCTAssertTrue(controller.isWindowVisible)
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        XCTAssertFalse(controller.isWindowVisible)
        controller.windowDidDeminiaturize(notification)
        XCTAssertTrue(controller.isWindowVisible)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(controller.isWindowVisible)
        XCTAssertEqual(controller.windowIdentity, identity)
        XCTAssertEqual(controller.windowCreationCount, 1)
    }

    @MainActor
    func testFailedSettingsSaveRetainsPageAndCanBeDismissedWithoutWritingConfiguration() async throws {
        let (controller, model, defaults, name) = try fixture()
        defer { controller.close(); defaults.removePersistentDomain(forName: name) }
        model.openPage(.settings)
        model.persistProviderSettings() // No connected/configured runtime in this fixture.
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.settingsRestartRequired)
        XCTAssertEqual(controller.page, .settings)
        model.dismissError()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(controller.windowCreationCount, 1)
    }

    @MainActor
    func testLogReloadPreservesFiltersAndLastGoodSnapshotOnReadFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.jsonl")
        try Data("{\"level\":\"info\",\"message\":\"session ready\"}\n".utf8).write(to: file)
        let logs = LogViewerModel(fileURL: file)
        logs.query = "ready"
        await logs.reload()
        XCTAssertEqual(logs.snapshot.entries.count, 1)
        XCTAssertEqual(logs.filteredEntries.count, 1)
        let measuredAt = logs.lastReloadedAt
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await logs.reload()
        XCTAssertNotNil(logs.errorMessage)
        XCTAssertEqual(logs.snapshot.entries.count, 1)
        XCTAssertEqual(logs.query, "ready")
        XCTAssertEqual(logs.lastReloadedAt, measuredAt)
        XCTAssertFalse(logs.isLoading)
    }

    @MainActor
    func testCancelledLogReloadCannotPublishSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.jsonl")
        try Data("{\"message\":\"must not publish\"}\n".utf8).write(to: file)
        let logs = LogViewerModel(fileURL: file)
        let task = Task { await logs.reload() }
        task.cancel()
        await task.value
        XCTAssertNil(logs.lastReloadedAt)
        XCTAssertTrue(logs.snapshot.entries.isEmpty)
        XCTAssertFalse(logs.isLoading)
    }
}
