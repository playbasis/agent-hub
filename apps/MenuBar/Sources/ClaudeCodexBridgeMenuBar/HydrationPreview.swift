import AppKit
import BridgeCore
import SwiftUI

/// Isolated visual QA, never a runtime/provider client. The installed app
/// ignores every option unless the existing diagnostic launch gate is set.
enum HydrationPreview {
    struct Configuration: Equatable {
        var surface: String
        var frozenTime: Double?
        var reduceMotion: Bool?
        var increasedContrast: Bool
        var light: Bool
        var width: Double
        static func read(_ environment: [String: String]) -> Self? {
            guard environment["BRIDGE_UI_PREVIEW"] == "1", let surface = environment["BRIDGE_HYDRATION_PREVIEW"],
                  ["overview", "now", "projects", "panel"].contains(surface) else { return nil }
            let time = environment["BRIDGE_HYDRATION_TIME"].flatMap(Double.init).flatMap { $0.isFinite && (0 ... 60).contains($0) ? $0 : nil }
            let width = environment["BRIDGE_HYDRATION_WIDTH"].flatMap(Double.init).flatMap { $0.isFinite && (320 ... 1600).contains($0) ? $0 : nil }
            let reduceMotion = environment["BRIDGE_HYDRATION_REDUCE_MOTION"].flatMap { ["0": false, "1": true][$0] }
            return Self(surface: surface, frozenTime: time, reduceMotion: reduceMotion,
                        increasedContrast: environment["BRIDGE_HYDRATION_CONTRAST"] == "1",
                        light: environment["BRIDGE_HYDRATION_LIGHT"] == "1", width: width ?? (surface == "panel" ? 350 : 1000))
        }
    }
    static let isRequested: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BRIDGE_UI_PREVIEW"] == "1" && env["BRIDGE_HYDRATION_PREVIEW"] != nil
    }()
    private static let configuration = Configuration.read(ProcessInfo.processInfo.environment)
    static let frozenTime = configuration?.frozenTime
    @MainActor private static var window: NSWindow?

    @MainActor static func show() {
        guard let config = configuration else { return }
        let view = PreviewContent(config: config)
            .environment(\.hydrationAccessibility, HydrationAccessibility(reduceMotion: config.reduceMotion,
                increasedContrast: config.increasedContrast ? true : nil))
            .environment(\.colorScheme, config.light ? .light : .dark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: config.width, height: config.surface == "panel" ? 260 : 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent Hub · Loading preview · \(config.surface)"
        window.appearance = NSAppearance(named: config.light ? .aqua : .darkAqua)
        window.contentMinSize = NSSize(width: config.surface == "panel" ? 320 : 420, height: 220)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.defaultAppStorage(AcceptanceProbe.defaults))
        window.center()
        window.orderFrontRegardless()
        self.window = window
    }

    private struct PreviewContent: View {
        var config: Configuration
        var body: some View {
            ScrollView {
                if config.surface == "panel" {
                    HydrationComponentPlaceholder(message: "Preparing saved activity…").padding(18)
                } else {
                    ActivityLoadingView(page: BridgePage.restored(config.surface), message: "Reading saved activity…").padding(22)
                }
            }
            .background(config.light ? Color(nsColor: .windowBackgroundColor) : BridgeTheme.ink)
        }
    }
}
