import AppKit
import XCTest
import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class DesktopLifecycleTests: XCTestCase {
    @MainActor
    func testHubRemainsInDockAndApplicationSwitcher() async {
        XCTAssertEqual(AppLifecycleDelegate.desktopActivationPolicy, .regular)
        let delegate = AppLifecycleDelegate(showWorkspace: {})
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @MainActor
    func testActivationRestoresClosedOrMinimizedHubWithoutCompetingWithToolbar() async {
        XCTAssertTrue(AppLifecycleDelegate.shouldRestoreWorkspaceOnActivation(
            hasVisibleWindow: false, hasVisibleMenuPanel: false, isShuttingDown: false))
        XCTAssertFalse(AppLifecycleDelegate.shouldRestoreWorkspaceOnActivation(
            hasVisibleWindow: true, hasVisibleMenuPanel: false, isShuttingDown: false))
        XCTAssertFalse(AppLifecycleDelegate.shouldRestoreWorkspaceOnActivation(
            hasVisibleWindow: false, hasVisibleMenuPanel: true, isShuttingDown: false))
        XCTAssertFalse(AppLifecycleDelegate.shouldRestoreWorkspaceOnActivation(
            hasVisibleWindow: false, hasVisibleMenuPanel: false, isShuttingDown: true))
    }

    @MainActor
    func testDockAndLaunchpadReopenAreHandledByOneWorkspacePresentation() async {
        var presentations = 0
        let delegate = AppLifecycleDelegate(showWorkspace: { presentations += 1 })
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(presentations, 2)
    }

    @MainActor
    func testDesktopReopenRetainsCurrentPageAndOneWindowAfterClose() async throws {
        _ = NSApplication.shared
        let suite = "HubDesktopLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = ActivityReportsController(defaults: defaults, presentsWindows: false)
        let model = BridgeViewModel(automaticallyConnect: false, workspaceController: controller)
        let delegate = AppLifecycleDelegate(showWorkspace: { model.reopenWorkspace() })
        defer { controller.close(); defaults.removePersistentDomain(forName: suite) }

        model.openPage(.settings)
        let identity = controller.windowIdentity
        controller.close()
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertEqual(controller.page, .settings)
        XCTAssertEqual(controller.windowIdentity, identity)
        XCTAssertEqual(controller.windowCreationCount, 1)

        model.openPage(.teamChat)
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        XCTAssertEqual(controller.page, .teamChat)
        XCTAssertEqual(controller.windowIdentity, identity)
        XCTAssertEqual(controller.windowCreationCount, 1)
    }

    @MainActor
    func testPackagedIdentityPreservesInstalledPathAndUsesNativePlaybasisIcon() async throws {
        let root = projectRoot
        let data = try Data(contentsOf: root.appendingPathComponent("packaging/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "dev.claudecodexbridge.app")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "ClaudeCodexBridgeMenuBar")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "ClaudeCodexBridge")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertNotEqual(info["LSUIElement"] as? Bool, true)

        let strings = try String(contentsOf: root.appendingPathComponent("packaging/en.lproj/InfoPlist.strings"))
        XCTAssertTrue(strings.contains("\"CFBundleDisplayName\" = \"\(BridgeBrand.productName)\";"))

        let sourceURL = root.appendingPathComponent("packaging/Brand/playbasis-mark-2048.png")
        let sourceData = try Data(contentsOf: sourceURL)
        let source = try XCTUnwrap(NSBitmapImageRep(data: sourceData))
        XCTAssertEqual(source.pixelsWide, 2048)
        XCTAssertEqual(source.pixelsHigh, 2048)
        XCTAssertTrue(source.hasAlpha)

        let iconData = try Data(contentsOf: root.appendingPathComponent("packaging/AppIcon.icns"))
        XCTAssertEqual(String(data: iconData.prefix(4), encoding: .ascii), "icns")
        XCTAssertNotNil(NSImage(data: iconData))
        // macOS may encode the two smallest sizes with legacy or PNG type
        // codes. Both describe the same native representations.
        let representations = try icnsRepresentations(iconData)
        XCTAssertTrue(representations.contains("ic04") || representations.contains("icp4"))
        XCTAssertTrue(representations.contains("ic05") || representations.contains("icp5"))
        XCTAssertTrue(Set(["ic07", "ic08", "ic09", "ic10", "ic11", "ic12", "ic13", "ic14"]).isSubset(of: representations))
    }

    private var projectRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { url.deleteLastPathComponent() }
        return url
    }

    /// Parse container boundaries as well as checking that AppKit can decode
    /// the largest image. An icon with only that one image is not sufficient
    /// for a crisp Dock, switcher and Finder presentation at every scale.
    private func icnsRepresentations(_ data: Data) throws -> Set<String> {
        let bytes = Array(data)
        func word(at offset: Int) -> Int {
            bytes[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard bytes.count >= 8, word(at: 4) == bytes.count else {
            throw NSError(domain: "HubIconTests", code: 1)
        }
        var types = Set<String>()
        var offset = 8
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw NSError(domain: "HubIconTests", code: 2) }
            let length = word(at: offset + 4)
            guard length >= 8, length <= bytes.count - offset else { throw NSError(domain: "HubIconTests", code: 3) }
            let type = String(bytes: bytes[offset ..< offset + 4], encoding: .ascii) ?? ""
            if type != "TOC " && type != "info" { types.insert(type) }
            offset += length
        }
        return types
    }
}
