import AppKit
import SwiftUI

// MARK: - Hydration loading

/// Preview-only overrides; production inherits the reactive system values.
struct HydrationAccessibility {
    var reduceMotion: Bool? = nil
    var increasedContrast: Bool? = nil
}
private struct HydrationAccessibilityKey: EnvironmentKey {
    static let defaultValue = HydrationAccessibility()
}
extension EnvironmentValues {
    var hydrationAccessibility: HydrationAccessibility {
        get { self[HydrationAccessibilityKey.self] }
        set { self[HydrationAccessibilityKey.self] = newValue }
    }
}

/// Timing for the loading cascade. One clock drives every tile, so tiles flip
/// in one after another and a single sweep runs down the page like a
/// waterfall, instead of each placeholder pulsing on its own. Reduce Motion
/// shows the settled tiles with no flip, sweep or twinkle.
enum Hydration {
    static let frameInterval: Double = 1 / 30
    /// Entrance delay between consecutive tiles, and flip duration.
    static let stagger: Double = 0.07
    static let entrance: Double = 0.55
    /// One sweep pass plus its rest; the band takes `sweepTravel` to cross a tile.
    static let sweepPeriod: Double = 2.8
    static let sweepTravel: Double = 1.1
    static let sweepLag: Double = 0.12
    static let dotSpacing: CGFloat = 11

    /// Seconds since `start`, or nil with Reduce Motion.
    static func elapsed(_ date: Date, since start: Date, animated: Bool) -> Double? {
        let seconds = date.timeIntervalSince(start)
        return animated && seconds.isFinite ? max(0, seconds) : nil
    }

    static func shouldAnimate(appeared: Bool, windowVisible: Bool, reduceMotion: Bool, snapshot: Bool) -> Bool {
        appeared && windowVisible && !reduceMotion && !snapshot
    }

    /// 0 (edge-on, hidden) to 1 (flat), eased out so the flip lands softly.
    static func entrance(order: Int, t: Double?) -> Double {
        guard let t, t.isFinite else { return 1 }
        let p = min(max((t - Double(max(0, order)) * stagger) / entrance, 0), 1)
        let q = 1 - p
        return 1 - q * q * q
    }

    /// The sweep band's progress across a tile, 0…1, or nil while it rests.
    static func sweep(order: Int, t: Double?, lag: Double) -> Double? {
        guard let t, t.isFinite, lag.isFinite, lag >= 0 else { return nil }
        let local = t - entrance - Double(max(0, order)) * lag
        guard local >= 0 else { return nil }
        let phase = local.truncatingRemainder(dividingBy: sweepPeriod)
        return phase < sweepTravel ? phase / sweepTravel : nil
    }

    static func glyphLevel(x: Int, y: Int, t: Double?) -> Double {
        guard let t, t.isFinite else { return 1 - Double(x + y) / 5 }
        let cycle = (t * 1.25 - Double(x + y) * 0.16).truncatingRemainder(dividingBy: 1)
        let phase = cycle < 0 ? cycle + 1 : cycle
        return phase < 0.4 ? sin(phase / 0.4 * .pi) : 0
    }

    /// Stable 0..<1 noise for a lattice cell, so twinkles and ghost bars
    /// don't reshuffle between frames.
    static func noise(_ x: Int, _ y: Int, _ salt: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663) ^ (salt &* 83_492_791))
        h ^= h >> 33; h &*= 0xff51_afd7_ed55_8ccd
        h ^= h >> 33; h &*= 0xc4ce_b9fe_1a85_ec53
        h ^= h >> 33
        return Double(h % 10_000) / 10_000
    }
}

/// One clock per placeholder, never one per tile or glyph. Environment values
/// react immediately when accessibility settings change. Window occlusion is
/// observed because an AppKit-owned window can stay mounted while invisible.
struct HydrationClock<Content: View>: View {
    var identity: String
    var enabled = true
    @ViewBuilder var content: (Double?) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hydrationAccessibility) private var accessibility
    @Environment(\.activityContentVisible) private var contentVisible
    @State private var start = Date()
    @State private var appeared = false
    @State private var windowVisible = false
    private var motionReduced: Bool { accessibility.reduceMotion ?? reduceMotion }
    private var staticCapture: Bool { SnapshotCapture.isActive && !HydrationPreview.isRequested }

    private var animated: Bool {
        enabled && contentVisible && Hydration.shouldAnimate(appeared: appeared, windowVisible: windowVisible, reduceMotion: motionReduced,
                                snapshot: staticCapture || HydrationPreview.frozenTime != nil)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: Hydration.frameInterval, paused: !animated)) { context in
            // A paused/attaching window does not mean Reduce Motion. Keep its
            // first frame at the entrance, rather than briefly painting every
            // settled tile and then hiding them when the window attaches.
            content(motionReduced || !enabled || !contentVisible || staticCapture ? nil : HydrationPreview.frozenTime ?? Hydration.elapsed(context.date, since: start, animated: true))
        }
        .background(HydrationWindowVisibility { windowVisible = $0 }.allowsHitTesting(false))
        .onAppear { start = Date(); appeared = true }
        .onDisappear { appeared = false; windowVisible = false }
        .onChange(of: identity) { _ in start = Date() }
    }
}

struct HydrationWindowVisibility: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.changed = changed; return view }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed; view.publish() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastVisible: Bool?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObservers()
            let center = NotificationCenter.default
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                        if note.name == NSWindow.willCloseNotification { self?.publish(false) }
                        else { self?.publish() }
                    })
                }
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.publish() })
            }
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.publish() })
            }
            publish()
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); publish() }
        func publish(_ explicit: Bool? = nil) {
            let visible = explicit ?? (window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden
                && !isHiddenOrHasHiddenAncestor && visibleRect.intersects(bounds) } ?? false)
            guard visible != lastVisible else { return }
            lastVisible = visible
            // Never mutate SwiftUI state during updateNSView/layout; coalesce
            // stale notifications and do not retain a removed placeholder.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastVisible == visible else { return }
                self.changed?(visible)
            }
        }
        func stop() { changed = nil; stopObservers() }
        private func stopObservers() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
        deinit { stopObservers() }
    }
}

enum HydrationTileStyle {
    /// A KPI or chart card: flips around its vertical axis.
    case card
    /// A wide summary strip: drops down from its top edge.
    case banner
    /// A table row: drops down like a split-flap board.
    case row
}

/// One placeholder tile: a faint dot lattice with ghost content shaped like
/// the card it stands in for, a brand-cyan sweep, and sparse twinkles.
struct HydrationTile: View {
    var style: HydrationTileStyle
    var order: Int
    var t: Double?
    var height: CGFloat
    var radius: CGFloat = BridgeTheme.radiusCard
    var lag: Double = Hydration.sweepLag
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.hydrationAccessibility) private var accessibility
    private var increasedContrast: Bool { accessibility.increasedContrast ?? (contrast == .increased) }

    var body: some View {
        let entered = Hydration.entrance(order: order, t: t)
        let sweep = Hydration.sweep(order: order, t: t, lag: lag)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Canvas { context, size in
            Self.draw(style, order: order, t: t, sweep: sweep, increasedContrast: increasedContrast, in: &context, size: size)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(shape.fill(BridgeTheme.hydrationSurface))
        .clipShape(shape)
        .overlay(shape.strokeBorder(BridgeTheme.hydrationBorder(increasedContrast: increasedContrast), lineWidth: 1))
        // A shallow tilt with mild perspective: steeper angles project the
        // tile far outside its frame and over its neighbours mid-flip.
        .rotation3DEffect(.degrees((1 - entered) * (style == .card ? 55 : -50)),
                          axis: style == .card ? (x: 0, y: 1, z: 0) : (x: 1, y: 0, z: 0),
                          anchor: style == .card ? .center : .top, perspective: 0.25)
        .scaleEffect(0.94 + 0.06 * entered)
        .opacity(entered)
        // Clip *after* projection as well, so no mid-flip raster can paint
        // outside the tile's allocated layout box into an adjacent tile.
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(_ style: HydrationTileStyle, order: Int, t: Double?, sweep: Double?, increasedContrast: Bool,
                             in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        guard w.isFinite, h.isFinite, w > 1, h > 1 else { return }

        // The band runs along f(x, y) = x + skew·y, a fixed diagonal whatever
        // the tile's proportions.
        let skew: CGFloat = 0.35
        let half = max(28, min(80, w * 0.25))
        let centre = sweep.map { -half + CGFloat($0) * (w + skew * h + 2 * half) }
        func lit(_ p: CGPoint) -> Double {
            guard let centre else { return 0 }
            let d = abs(p.x + skew * p.y - centre) / half
            return d >= 1 ? 0 : Double(1 - d * d)
        }

        // Lattice: one path for the resting dots, then the few lit ones.
        let s = Hydration.dotSpacing
        let cols = max(Int(min(w / s, 256)), 1), rows = max(Int(min(h / s, 64)), 1)
        let ox = (w - CGFloat(cols - 1) * s) / 2, oy = (h - CGFloat(rows - 1) * s) / 2
        var lattice = Path()
        var sparks: [(CGPoint, Double)] = []
        for j in 0 ..< rows {
            for i in 0 ..< cols {
                let p = CGPoint(x: ox + CGFloat(i) * s, y: oy + CGFloat(j) * s)
                lattice.addEllipse(in: CGRect(x: p.x - 0.6, y: p.y - 0.6, width: 1.2, height: 1.2))
                var glow = lit(p) * 0.5
                if let t, t.isFinite {
                    let n = Hydration.noise(i, j, order)
                    let wave = sin(t * (0.7 + n * 1.3) + n * 37)
                    if wave > 0.97 { glow += (wave - 0.97) / 0.03 * 0.45 }
                }
                if glow > 0.03 { sparks.append((p, min(glow, 0.8))) }
            }
        }
        context.fill(lattice, with: .color(BridgeTheme.hydrationDot(increasedContrast: increasedContrast)))
        for (p, glow) in sparks {
            context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)),
                         with: .color(BridgeTheme.brand.opacity(glow)))
        }

        // Ghost content, so the layout reads before the numbers arrive.
        let ghost = GraphicsContext.Shading.color(BridgeTheme.hydrationGhost(increasedContrast: increasedContrast))
        func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat? = nil) {
            let rect = CGRect(x: x, y: y, width: max(width, 0), height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: radius ?? height / 2), with: ghost)
        }
        let compact = h < 60
        let pad: CGFloat = compact ? 10 : 14
        switch style {
        case .card:
            bar(pad, pad, w * 0.36, compact ? 6 : 7)
            bar(pad, pad + (compact ? 13 : 16), w * 0.22, compact ? 11 : 16, radius: 4)
            if h >= 100 {
                let top = h * 0.55, base = h - pad
                let count = max(Int(min((w - 2 * pad) / 14, 256)), 1)
                let step = (w - 2 * pad) / CGFloat(count)
                for i in 0 ..< count {
                    let column = (base - top) * CGFloat(0.25 + 0.75 * Hydration.noise(i, 0, order + 11))
                    bar(pad + CGFloat(i) * step + 2, base - column, step - 4, column, radius: 2)
                }
            }
        case .banner:
            if h > 80 {
                bar(pad, pad, w * 0.3, 8)
                bar(pad, pad + 22, w * 0.62, 6)
                bar(pad, pad + 36, w * 0.5, 6)
                bar(w - pad - 64, pad, 64, 18)
            } else {
                bar(pad, h / 2 - 4, w * 0.42, 8)
                bar(w - pad - 64, h / 2 - 9, 64, 18)
            }
        case .row:
            context.fill(Path(ellipseIn: CGRect(x: 12, y: h / 2 - 11, width: 22, height: 22)), with: ghost)
            bar(44, h / 2 - 9, w * 0.3, 7)
            bar(44, h / 2 + 3, w * 0.18, 6)
            bar(w - 12 - 52, h / 2 - 3.5, 52, 7)
        }

        // The swipe: a soft brand band perpendicular to the lattice diagonal.
        if let centre {
            let norm = 1 + skew * skew
            let start = CGPoint(x: centre - half, y: 0)
            let end = CGPoint(x: start.x + 2 * half / norm, y: 2 * half * skew / norm)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: BridgeTheme.brand.opacity(0.08), location: 0.5),
                    .init(color: .clear, location: 1),
                ]),
                startPoint: start, endPoint: end))
        }
    }
}

/// A 3×3 cell grid whose cells light in a diagonal cascade. It stands in for
/// a spinner wherever saved activity is being read.
struct HydrationGlyph: View {
    var size: CGFloat = 14
    var tint: Color = BridgeTheme.brand
    var t: Double? = nil

    var body: some View {
        Canvas { g, box in
            let gap = box.width * 0.12
            let cell = (box.width - 2 * gap) / 3
            for j in 0 ..< 3 {
                for i in 0 ..< 3 {
                    let level = Hydration.glyphLevel(x: i, y: j, t: t)
                    let rect = CGRect(x: CGFloat(i) * (cell + gap), y: CGFloat(j) * (cell + gap), width: cell, height: cell)
                    g.fill(Path(roundedRect: rect, cornerRadius: cell * 0.28), with: .color(tint.opacity(0.18 + 0.82 * level)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Hydration for a single component, such as the menu-bar panel: a glyph and
/// label over a strip of small tiles shaped like the panel's cards. The sweep
/// crosses the strip as one continuous swipe rather than a page waterfall.
struct HydrationComponentPlaceholder: View {
    var message: String
    var isReading = true

    var body: some View {
        HydrationClock(identity: "component", enabled: isReading) { t in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HydrationGlyph(size: 12, t: t)
                    Text(message).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.hydrationLabel)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 6) {
                    ForEach(0 ..< 3, id: \.self) {
                        HydrationTile(style: .card, order: $0, t: t, height: 52, radius: BridgeTheme.radiusWell, lag: 0.35)
                    }
                }
                HydrationTile(style: .banner, order: 3, t: t, height: 30, radius: BridgeTheme.radiusWell, lag: 0.35)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bridge.loading.component")
        .allowsHitTesting(false)
    }
}
