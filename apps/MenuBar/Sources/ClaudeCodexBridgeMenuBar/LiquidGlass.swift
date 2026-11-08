import AppKit
import SwiftUI

// MARK: - Behind-window blur backdrop

/// The glass slab: real behind-window blur and saturation from the window
/// server, masked to the panel's continuous-corner shape. This is the same
/// mechanism system materials use, so content behind the panel (desktop,
/// windows) shows through softened and color-bled.
struct GlassBackdrop: NSViewRepresentable {
    static let identifierValue = "LiquidGlassBackdrop"
    var cornerRadius: CGFloat = 14

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = HitTestPassthroughVisualEffectView()
        view.identifier = NSUserInterfaceItemIdentifier(Self.identifierValue)
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        view.maskImage = .roundedRectMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.maskImage = .roundedRectMask(radius: cornerRadius)
    }
}

@MainActor
private final class HitTestPassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSImage {
    static func roundedRectMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(
            size: NSSize(width: edge, height: edge),
            flipped: false
        ) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Transparent hosting panel

/// Belt-and-suspenders transparency for whatever window ends up hosting the
/// card (the controller-owned panel already sets these, but the debug
/// preview window benefits too). No shadow here — `hasShadow` stays false
/// on every host window. Depth comes from the one shape-aware SwiftUI shadow
/// on `liquidGlassCard`, avoiding a rectangular system shadow or stacked
/// silhouettes.
@MainActor
struct PanelClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = HitTestPassthroughView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.configure(view.window) }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
    }
}

@MainActor
private final class HitTestPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - The material

extension View {
    /// Liquid Glass card: behind-window blur, specular rim that catches
    /// light along the top-leading edge, continuous 26pt corners.
    func liquidGlassCard(
        cornerRadius: CGFloat = 14,
        elevation: GlassElevation = .floating
    ) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, elevation: elevation))
    }
}

enum GlassElevation {
    /// A compact contact shadow for a panel visually attached to the menu bar.
    case anchored
    /// A deeper shadow for the user-detached, freely positioned panel.
    case floating

    var color: Color {
        switch self {
        case .anchored: .clear
        case .floating: .black.opacity(0.33)
        }
    }

    var radius: CGFloat {
        switch self {
        case .anchored: 0
        case .floating: 10
        }
    }

    var yOffset: CGFloat {
        switch self {
        case .anchored: 0
        case .floating: 6
        }
    }
}

private struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat
    var elevation: GlassElevation

    func body(content: Content) -> some View {
        // Plain circular corners throughout — they must match the AppKit
        // mask's NSBezierPath geometry exactly or the material peeks out
        // past the clip at the corners.
        content
            .background(
                GlassBackdrop(cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
            )
            .background(
                // faint tint so the slab reads as material, not a hole
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255).opacity(0.55))
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.18), location: 0),
                                .init(color: .white.opacity(0.08), location: 0.3),
                                .init(color: .white.opacity(0.06), location: 0.7),
                                .init(color: .white.opacity(0.12), location: 1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            // One state-appropriate elevation shadow only. A status-bar
            // anchored panel needs a much tighter contact shadow than the
            // detached floating panel; using the latter for both caused the
            // menu-bar compositor to expose the host window's clipped edge.
            .shadow(
                color: elevation.color,
                radius: elevation.radius,
                x: 0,
                y: elevation.yOffset
            )
    }
}

/// Hairline separator that stays subordinate to the glass.
struct GlassHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

extension Color {
    /// Translucent fill for cards and wells sitting on the glass —
    /// fills and vibrancy instead of stacking a second glass layer.
    static let glassFill = Color.primary.opacity(0.055)
    static let glassStroke = Color.primary.opacity(0.085)
}

// MARK: - Prominent capsule button

struct GlassProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .padding(.horizontal, 16)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.96),
                                Color.accentColor.opacity(0.72),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.45), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Debug preview window (BRIDGE_UI_PREVIEW=1)

/// Shows the dropdown in a floating borderless window at a known position
/// so the rendered glass can be captured without opening the menu bar item.
@MainActor
enum GlassPreviewWindow {
    private static var window: NSWindow?
    static var hostView: NSView? { window?.contentView }

    static func showIfRequested(model: BridgeViewModel) {
        guard ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW"] == "1" else { return }
        let host = NSHostingView(rootView: MenuContentView(model: model).defaultAppStorage(AcceptanceProbe.defaults))
        let panel = InteractiveMenuPanel(
            contentRect: NSRect(origin: .zero, size: MenuBarPanelLayout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        host.frame = NSRect(origin: .zero, size: MenuBarPanelLayout.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        if let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: 80, y: screen.frame.maxY - 60))
        }
        if SnapshotCapture.isActive {
            panel.orderFrontRegardless()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        window = panel

        // In-process render for verification without screen-recording
        // permission. The behind-window blur region rasters dark (it is
        // composited by the window server), but geometry, fills, rim and
        // typography are all exact.
        if let path = ProcessInfo.processInfo.environment["BRIDGE_UI_SNAPSHOT"], !path.isEmpty {
            let delay = ProcessInfo.processInfo.environment["BRIDGE_UI_SNAPSHOT_DELAY"]
                .flatMap(Double.init) ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                writeSnapshot(of: host, to: path)
                NSApp.terminate(nil)
            }
        }
    }

    private static func writeSnapshot(of view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// In-process snapshot renders (preview only). They order windows front
/// without activating the app so keystrokes stay with the person's own work.
enum SnapshotCapture {
    static var isActive: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BRIDGE_UI_PREVIEW"] == "1" else { return false }
        if HydrationPreview.isRequested { return true }
        if environment["BRIDGE_GOAL_REPLAY_PREVIEW"] == "1" { return true }
        if AcceptanceProbe.isActive { return true }
        return ["BRIDGE_UI_SNAPSHOT", "BRIDGE_REPORTS_SNAPSHOT", "BRIDGE_ROOM_SNAPSHOT"].contains { environment[$0]?.isEmpty == false }
    }
}
