import AppKit
import BridgeCore
import SwiftUI

@main
struct ClaudeCodexBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var lifecycleDelegate
    @StateObject private var model: BridgeViewModel

    init() {
        SingleInstanceGuard.acquireOrExit()
        let replayPreview = ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW"] == "1"
            && ProcessInfo.processInfo.environment["BRIDGE_GOAL_REPLAY_PREVIEW"] == "1"
        let model = BridgeViewModel(automaticallyConnect: !RefreshAcceptance.isReplayMode && !HydrationPreview.isRequested && !replayPreview)
        _model = StateObject(wrappedValue: model)
        AppLifecycleDelegate.model = model

        if RefreshAcceptance.isReplayMode || replayPreview {
            Task {
                let fixture = await RefreshAcceptance.loadReplayFixture()
                model.restoreSavedActivity(fixture)
            }
        }

        if ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW"] == "1" {
            if let raw = ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW_TAB"],
               let tab = PanelTab(rawValue: raw)
            {
                model.panelTab = tab
            }
            if let scenario = ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW_ACCOUNTS"] {
                // Re-apply after the real status read so the forced state wins.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    model.accounts.applyPreview(scenario)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if HydrationPreview.isRequested {
                    HydrationPreview.show()
                } else if ProcessInfo.processInfo.environment["BRIDGE_REPORTS_PREVIEW"] == "1" {
                    ActivityReportsController.shared.showPreview(model: model)
                    if RefreshAcceptance.reportPath != nil { Task { await RefreshAcceptance.run(model: model) } }
                } else if ProcessInfo.processInfo.environment["BRIDGE_ROOM_SNAPSHOT"] != nil {
                    Task { await TeamRoomController.shared.renderPreview() }
                } else {
                    GlassPreviewWindow.showIfRequested(model: model)
                }
            }
        }
        if !HydrationPreview.isRequested, ProcessInfo.processInfo.environment["BRIDGE_OPEN_TEAM_ROOM"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { TeamRoomController.shared.show() }
        }
        if !HydrationPreview.isRequested, ProcessInfo.processInfo.environment["BRIDGE_OPEN_REPORTS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.openActivityReports() }
        }
    }

    var body: some Scene {
        // No MenuBarExtra scene: MenuBarController owns a plain NSStatusItem
        // and NSPanel directly, since the dropdown needs to be draggable and
        // independently dismissable — capabilities MenuBarExtra's window
        // doesn't expose.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.openPage(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Open \(BridgeBrand.shortName)") { model.openActivityReports() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Team Chat") { model.openPage(.teamChat) }
            }
        }
    }
}
