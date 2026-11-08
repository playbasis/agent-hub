import AppKit
import Combine
import SwiftUI

enum MenuBarPanelLayout {
    // BRIDGE_UI_PREVIEW_HEIGHT lets the snapshot renderer capture the whole
    // scroll content; the shipped panel always uses the default height.
    static let cardSize = NSSize(
        width: 396,
        height: ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW"] == "1"
            ? (ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW_HEIGHT"].flatMap(Double.init) ?? 660)
            : 660
    )
    // The host window must include the full blur footprint. SwiftUI shadows
    // are clipped to an NSWindow's backing surface, even when the window is
    // transparent. The anchored state deliberately has no top inset or drop
    // shadow: AppKit constrains status-bar panels below the menu bar, so a top
    // inset becomes a false visual gap. Side/bottom room is retained for the
    // detached panel's single 10pt shape shadow.
    static let horizontalInset: CGFloat = 22
    static let topInset: CGFloat = 0
    static let bottomInset: CGFloat = 24
    static let panelSize = NSSize(
        width: cardSize.width + horizontalInset * 2,
        height: cardSize.height + topInset + bottomInset
    )
    static let anchorGap: CGFloat = 6
}

/// Borderless windows default to `canBecomeKey == false`. This panel is an
/// interactive form, so it must explicitly accept key status for SwiftUI text
/// editors, pickers, keyboard shortcuts, and normal button focus.
@MainActor
final class InteractiveMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        MenuBarController.shared.close()
    }
}

/// Owns the status item and the dropdown panel directly (no MenuBarExtra),
/// so the panel can be dragged free of its anchor and snapped back — a
/// SwiftUI MenuBarExtra window is not repositionable or independently
/// dismissable, which is required for a detachable dropdown.
@MainActor
final class MenuBarController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MenuBarController()

    /// True once the user has dragged the panel away from its anchored
    /// position under the status item. While detached, outside clicks no
    /// longer auto-dismiss it.
    @Published private(set) var isDetached = false
    /// Published so heavy panel content can stop updating while the panel is
    /// hidden; its hosting view stays alive between openings.
    @Published private(set) var isOpen = false
    var isPanelVisible: Bool { panel?.isVisible == true }
    var isCreditSurfaceExposed: Bool {
        guard let panel, NSApp?.isHidden != true else { return false }
        return panel.isVisible && !panel.isMiniaturized && panel.occlusionState.contains(.visible)
    }

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var modelObservation: AnyCancellable?
    private weak var model: BridgeViewModel?

    private override init() { super.init() }

    func install(model: BridgeViewModel) {
        self.model = model
        guard statusItem == nil else {
            refreshIcon()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        refreshIcon()

        modelObservation = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value updates; defer one tick.
                DispatchQueue.main.async { self?.refreshIcon() }
            }

        let hosting = NSHostingView(rootView: MenuContentView(model: model))
        hosting.frame = NSRect(origin: .zero, size: MenuBarPanelLayout.panelSize)
        hosting.autoresizingMask = [.width, .height]

        let panel = InteractiveMenuPanel(
            contentRect: NSRect(origin: .zero, size: MenuBarPanelLayout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the card draws its own SwiftUI shadow
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.acceptsMouseMovedEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.delegate = self
        enforceShapeOwnedShadow(on: panel)
        self.panel = panel
    }

    private func refreshIcon() {
        guard let model, let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: model.iconName,
            accessibilityDescription: model.statusLabel
        )
    }

    @objc private func statusItemClicked() {
        guard let panel else { return }
        if panel.isVisible {
            close()
        } else {
            openAnchored()
        }
    }

    private func anchorOrigin() -> NSPoint? {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return nil }
        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel?.frame.size ?? MenuBarPanelLayout.panelSize
        var x = buttonFrameOnScreen.midX - size.width / 2
        // The window includes transparent room for the SwiftUI shadow. Align
        // the visible card—not that transparent frame—to the status item.
        var y = buttonFrameOnScreen.minY
            - MenuBarPanelLayout.anchorGap
            - size.height
            + MenuBarPanelLayout.topInset

        if let screenFrame = buttonWindow.screen?.visibleFrame {
            x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
            y = max(y, screenFrame.minY + 8)
        }
        return NSPoint(x: x, y: y)
    }

    func openAnchored() {
        guard let panel else { return }
        model?.panelDidOpen()
        enforceShapeOwnedShadow(on: panel)
        if let origin = anchorOrigin() {
            panel.setFrameOrigin(origin)
        }
        isDetached = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        isOpen = true
        model?.observeActivity("panel", visible: model?.panelTab == .activity)
        if !panel.isKeyWindow {
            panel.makeKey()
        }
        installOutsideClickMonitor()
    }

    func close() {
        model?.observeActivity("panel", visible: false)
        panel?.orderOut(nil)
        isOpen = false
        removeOutsideClickMonitor()
    }

    /// Called by the drag handle the instant a drag begins.
    func markDetached() {
        guard !isDetached else { return }
        if let panel {
            enforceShapeOwnedShadow(on: panel)
        }
        isDetached = true
        removeOutsideClickMonitor()
    }

    /// Animates the panel back under the status item and restores normal
    /// click-outside-to-dismiss behavior.
    func reattach() {
        guard let panel else { return }
        enforceShapeOwnedShadow(on: panel)
        let target = anchorOrigin() ?? panel.frame.origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true)
        }
        isDetached = false
        installOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                guard let self, !self.isDetached else { return }
                self.close()
            }
        }
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self,
                      !self.isDetached,
                      self.panel?.isVisible == true
                else { return event }
                let statusItemWindow = self.statusItem?.button?.window
                if event.window !== self.panel, event.window !== statusItemWindow {
                    self.close()
                }
                return event
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalClickMonitor = nil
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        localClickMonitor = nil
    }

    func windowWillClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        enforceShapeOwnedShadow(on: panel)
    }

    /// AppKit may rebuild a borderless panel's window-server surface as it
    /// changes key/anchored state. Reassert that the rounded SwiftUI card owns
    /// elevation so a native rectangular NSWindow shadow can never stack with
    /// it. `invalidateShadow` clears any previously cached window-server mask.
    private func enforceShapeOwnedShadow(on panel: NSPanel) {
        panel.hasShadow = false
        panel.invalidateShadow()
    }

    /// Deterministic in-process interaction diagnostics used by the release
    /// smoke test. This avoids relying on screen coordinates while still
    /// checking AppKit key status, hit-test routing, and anchor geometry.
    func writeInteractionSmokeReport(to path: String) {
        // Startup hydration can delay the status item's attachment to its
        // menu-bar window. Re-resolve the anchor at measurement time so both
        // the test and a slow launch exercise the final, real geometry.
        openAnchored()
        guard let panel, let contentView = panel.contentView else { return }
        let descendants = allDescendants(of: contentView)
        let textView = descendants
            .compactMap { $0 as? NSTextView }
            .first(where: \.isEditable)

        var textEditorHitTestReachesEditor = false
        var textEditorAcceptsFocus = false
        var textEditorHitClass = "none"
        var textEditorHitAncestors: [String] = []
        var textEditorViewAncestors: [String] = []
        var textEditorPointInContent = NSPoint.zero
        var textEditorClickFocuses = false
        var textEditorKeyEventUpdatesModel = false
        var textEditorKeyEventUpdatesView = false
        if let textView {
            let targetRect = textView.visibleRect.isEmpty ? textView.bounds : textView.visibleRect
            let center = NSPoint(x: targetRect.midX, y: targetRect.midY)
            let pointInContent = contentView.convert(center, from: textView)
            textEditorPointInContent = pointInContent
            let hitView = contentView.hitTest(pointInContent)
            textEditorHitClass = hitView.map { String(describing: type(of: $0)) } ?? "none"
            var ancestor = hitView
            while let view = ancestor {
                textEditorHitAncestors.append(String(describing: type(of: view)))
                ancestor = view.superview
            }
            var textAncestor: NSView? = textView
            while let view = textAncestor {
                textEditorViewAncestors.append(String(describing: type(of: view)))
                textAncestor = view.superview
            }
            textEditorHitTestReachesEditor = isDescendant(
                hitView,
                of: textView
            )

            let pointInWindow = contentView.convert(pointInContent, to: nil)
            let eventTime = ProcessInfo.processInfo.systemUptime
            if let mouseDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: pointInWindow,
                modifierFlags: [],
                timestamp: eventTime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ), let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: pointInWindow,
                modifierFlags: [],
                timestamp: eventTime + 0.01,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            ) {
                // NSTextView's mouseDown enters an event-tracking loop. Queue
                // the matching mouseUp first so this deterministic smoke test
                // follows the same path as a real click without stalling.
                NSApp.postEvent(mouseUp, atStart: true)
                panel.sendEvent(mouseDown)
                textEditorClickFocuses = isResponder(panel.firstResponder, within: textView)
            }

            let originalGoal = model?.goal
            let originalText = textView.string
            if textEditorClickFocuses,
               let keyDown = NSEvent.keyEvent(
                   with: .keyDown,
                   location: pointInWindow,
                   modifierFlags: [],
                   timestamp: eventTime + 0.02,
                   windowNumber: panel.windowNumber,
                   context: nil,
                   characters: "z",
                   charactersIgnoringModifiers: "z",
                   isARepeat: false,
                   keyCode: 6
               ), let keyUp = NSEvent.keyEvent(
                   with: .keyUp,
                   location: pointInWindow,
                   modifierFlags: [],
                   timestamp: eventTime + 0.03,
                   windowNumber: panel.windowNumber,
                   context: nil,
                   characters: "z",
                   charactersIgnoringModifiers: "z",
                   isARepeat: false,
                   keyCode: 6
               )
            {
                panel.sendEvent(keyDown)
                panel.sendEvent(keyUp)
                textEditorKeyEventUpdatesView = textView.string != originalText
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                textEditorKeyEventUpdatesModel = model?.goal == (originalGoal ?? "") + "z"
                if let originalGoal {
                    model?.goal = originalGoal
                }
            }
            textEditorAcceptsFocus = panel.makeFirstResponder(textView)
        }

        let passthroughViews = descendants.filter {
            String(describing: type(of: $0)).contains("HitTestPassthrough")
        }
        let blockingDecorationCount = passthroughViews.filter {
            $0.hitTest(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY)) != nil
        }.count

        var measuredAnchorGap: CGFloat?
        var buttonFrame = NSRect.zero
        if let button = statusItem?.button, let buttonWindow = button.window {
            buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let visibleCardTop = panel.frame.maxY - MenuBarPanelLayout.topInset
            measuredAnchorGap = buttonFrame.minY - visibleCardTop
        }

        let panelWasKeyWindow = panel.isKeyWindow
        let panelWasVisible = panel.isVisible
        model?.openLogs()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let logViewerVisible = LogViewerController.shared.isVisible
        let logViewerEntryCount = LogViewerController.shared.entryCount
        let logViewerFile = LogViewerController.shared.displayedFileURL.path
        let logsUseSharedFrame = ActivityReportsController.shared.page == .logs
            && ActivityReportsController.shared.windowIdentity != nil
        LogViewerController.shared.close()

        let report: [String: Any] = [
            "anchor_gap": measuredAnchorGap.map { Double($0) } ?? NSNull(),
            "anchor_gap_matches": measuredAnchorGap.map {
                // Menu-bar frames can land on half-points on Retina displays.
                abs($0 - MenuBarPanelLayout.anchorGap) <= 0.75
            } ?? false,
            "button_frame": NSStringFromRect(buttonFrame),
            "blocking_decoration_count": blockingDecorationCount,
            "can_become_key": panel.canBecomeKey,
            "content_height": Double(contentView.frame.height),
            "content_width": Double(contentView.frame.width),
            "is_key_window": panelWasKeyWindow,
            "is_visible": panelWasVisible,
            "logs_use_shared_frame": logsUseSharedFrame,
            "log_viewer_entry_count": logViewerEntryCount,
            "log_viewer_file": logViewerFile,
            "log_viewer_visible": logViewerVisible,
            "panel_height": Double(panel.frame.height),
            "panel_frame": NSStringFromRect(panel.frame),
            "panel_width": Double(panel.frame.width),
            "native_window_shadow_enabled": panel.hasShadow,
            "shadow_mode": isDetached ? "floating" : "anchored",
            "passthrough_view_count": passthroughViews.count,
            "text_editor_accepts_focus": textEditorAcceptsFocus,
            "text_editor_click_focuses": textEditorClickFocuses,
            "text_editor_hit_ancestors": textEditorHitAncestors,
            "text_editor_hit_class": textEditorHitClass,
            "text_editor_hit_test_reaches_editor": textEditorHitTestReachesEditor,
            "text_editor_key_event_updates_model": textEditorKeyEventUpdatesModel,
            "text_editor_key_event_updates_view": textEditorKeyEventUpdatesView,
            "text_editor_point_in_content": NSStringFromPoint(textEditorPointInContent),
            "text_editor_present": textView != nil,
            "text_editor_view_ancestors": textEditorViewAncestors,
        ]
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(
                  withJSONObject: report,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allDescendants(of: $0) }
    }

    private func isDescendant(_ candidate: NSView?, of ancestor: NSView) -> Bool {
        var current = candidate
        while let view = current {
            if view === ancestor { return true }
            current = view.superview
        }
        return false
    }

    private func isResponder(_ responder: NSResponder?, within view: NSView) -> Bool {
        guard let responderView = responder as? NSView else { return false }
        return responderView === view || isDescendant(responderView, of: view)
    }
}

/// A deliberately small, dedicated drag surface. It never sits behind form
/// controls, and it waits for real pointer movement before detaching.
struct DragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        private var initialMouseLocation: NSPoint?
        private var initialWindowOrigin: NSPoint?
        private var hasCrossedDragThreshold = false

        override var acceptsFirstResponder: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            initialMouseLocation = NSEvent.mouseLocation
            initialWindowOrigin = window?.frame.origin
            hasCrossedDragThreshold = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window,
                  let initialMouseLocation,
                  let initialWindowOrigin
            else { return }
            let current = NSEvent.mouseLocation
            let deltaX = current.x - initialMouseLocation.x
            let deltaY = current.y - initialMouseLocation.y
            if !hasCrossedDragThreshold, hypot(deltaX, deltaY) >= 3 {
                hasCrossedDragThreshold = true
                MenuBarController.shared.markDetached()
            }
            guard hasCrossedDragThreshold else { return }
            window.setFrameOrigin(
                NSPoint(
                    x: initialWindowOrigin.x + deltaX,
                    y: initialWindowOrigin.y + deltaY
                )
            )
        }

        override func mouseUp(with event: NSEvent) {
            initialMouseLocation = nil
            initialWindowOrigin = nil
            hasCrossedDragThreshold = false
        }
    }

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ nsView: HandleView, context: Context) {}
}
