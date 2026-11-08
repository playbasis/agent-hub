import AppKit
import BridgeCore
import Foundation

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    static weak var model: BridgeViewModel?
    static let desktopActivationPolicy: NSApplication.ActivationPolicy = .regular
    private let showWorkspace: @MainActor () -> Void
    private var hasFinishedLaunching = false
    private var automaticallyRestoresWorkspace = true

    override convenience init() {
        self.init(showWorkspace: { Self.model?.reopenWorkspace() })
    }

    /// The presentation action is injectable so lifecycle routing can be
    /// verified without displaying a window or connecting a provider account.
    init(showWorkspace: @escaping @MainActor () -> Void, restoresWorkspace: Bool = true) {
        self.showWorkspace = showWorkspace
        self.automaticallyRestoresWorkspace = restoresWorkspace
        super.init()
    }

    // The Hub is a regular desktop application with a menu-bar shortcut, not an
    // accessory: it must remain discoverable in the Dock and Cmd-Tab switcher.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Snapshot renders stay out of the Dock and never take focus.
        NSApplication.shared.setActivationPolicy(SnapshotCapture.isActive ? .accessory : Self.desktopActivationPolicy)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    // Clicking the Launchpad icon while the app is already running does not
    // start a second process, so SingleInstanceGuard's activation notification
    // never fires. AppKit sends this instead; without it, the click would look
    // like nothing happened.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        // A visual-QA process must not open a second, empty Hub when macOS or
        // an accessibility observer reactivates its minimized preview window.
        guard automaticallyRestoresWorkspace else { return false }
        presentWorkspace()
        // We restored the one main frame ourselves. Do not ask AppKit to
        // restore any utility panels as a second, competing presentation.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the Hub window is not Quit: the status item, account refresh
        // and any ongoing work remain available until an explicit Quit.
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasFinishedLaunching, automaticallyRestoresWorkspace else { return }
        // A status-item click activates the application before ordering its
        // panel front. Check on the next run-loop turn so that quick access
        // never unexpectedly opens the large Hub window as well.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard Self.shouldRestoreWorkspaceOnActivation(
                // Status-item windows are also NSWindows. Only the shared
                // desktop frame determines whether there is a Hub to restore.
                hasVisibleWindow: ActivityReportsController.shared.isWindowVisible,
                hasVisibleMenuPanel: MenuBarController.shared.isPanelVisible,
                isShuttingDown: Self.model?.isQuitRequested == true
            ) else { return }
            self.presentWorkspace()
        }
    }

    static func shouldRestoreWorkspaceOnActivation(
        hasVisibleWindow: Bool,
        hasVisibleMenuPanel: Bool,
        isShuttingDown: Bool
    ) -> Bool {
        !hasVisibleWindow && !hasVisibleMenuPanel && !isShuttingDown
    }

    private func presentWorkspace() {
        guard Self.model?.isQuitRequested != true else { return }
        showWorkspace()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Renderers can coexist with the Hub, but they must neither answer its
        // activation handshake nor consume its production quit request.
        if SingleInstanceGuard.productionOwner != nil {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(activateFromSecondaryLaunch(_:)),
                name: SingleInstanceGuard.activationNotification,
                object: nil
            )
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(requestGracefulQuit),
                name: BridgeLifecycleNotifications.requestAppQuit,
                object: nil
            )
        }
        let environment = ProcessInfo.processInfo.environment
        // A renderer or acceptance run alongside the installed Hub must not
        // put a second Agent Hub icon in the menu bar.
        if let model = Self.model, !SingleInstanceGuard.isDiagnosticLaunch(environment) {
            MenuBarController.shared.install(model: model)
        }
        automaticallyRestoresWorkspace = !SingleInstanceGuard.isDiagnosticLaunch(environment)
        if automaticallyRestoresWorkspace {
            Task { await ActivityReportingService.shared.startConnectionMonitoring() }
        }
        hasFinishedLaunching = true
        if automaticallyRestoresWorkspace {
            presentWorkspace()
        }
        if let reportPath = ProcessInfo.processInfo.environment[
            "BRIDGE_UI_INTERACTION_REPORT"
        ], !reportPath.isEmpty {
            // Give the status item one run-loop turn to acquire its real
            // menu-bar window and screen coordinates before anchoring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MenuBarController.shared.openAnchored()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MenuBarController.shared.writeInteractionSmokeReport(to: reportPath)
                Self.model?.requestQuit()
            }
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let model = Self.model else {
            return .terminateNow
        }
        if model.hasCompletedShutdown {
            return .terminateNow
        }

        // Returning terminateLater enters NSModalPanelRunLoopMode, which does
        // not schedule MainActor tasks. Cancel this first termination request,
        // finish cleanup on the normal run loop, then request termination
        // again once the model reports that shutdown is complete.
        model.requestQuit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        Self.model?.prepareForImmediateTermination()
        Self.model = nil
    }

    @objc
    private func activateFromSecondaryLaunch(_ notification: Notification) {
        guard let response = SingleInstanceGuard.activationAcknowledgement(
            for: notification, owner: SingleInstanceGuard.productionOwner,
            isQuitRequested: Self.model?.isQuitRequested == true
        ) else { return }
        presentWorkspace()
        DistributedNotificationCenter.default().postNotificationName(
            BridgeLifecycleNotifications.activationAcknowledged,
            object: nil, userInfo: response, deliverImmediately: true
        )
    }

    @objc
    private func requestGracefulQuit() {
        Self.model?.requestQuit()
    }
}
