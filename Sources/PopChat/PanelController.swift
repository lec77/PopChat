import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let state = PanelState()
    private let providerStore: ProviderStore
    private let shortcutStore: ShortcutStore
    let chatStore: ChatStore // internal for the sizing smoke harness
    private var cancellables: Set<AnyCancellable> = []
    private var isHiding = false
    /// Last content height reported by the compact (no messages) layout.
    private var lastCompactHeight: CGFloat?

    // Delta 2 (4a): 520pt min width keeps the header pills from colliding with
    // long model names; 120pt empty-min gives the input capsule breathing room.
    private static let minWidth: CGFloat = 520
    private static let compactMinHeight: CGFloat = 120
    private static let expandedMinHeight: CGFloat = 320
    private static let defaultExpandedHeight: CGFloat = 440

    /// User's preferred height for the expanded (has messages) state. Clamped on
    /// read: values below the minimum may persist from before minimums were
    /// enforced (see windowWillResize).
    private var expandedHeight: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "panelExpandedHeight")
            return stored > 0 ? max(stored, Self.expandedMinHeight) : Self.defaultExpandedHeight
        }
        set { UserDefaults.standard.set(newValue, forKey: "panelExpandedHeight") }
    }

    /// The live minimum content size — 520×320 with messages, 520×120 empty (4a).
    private var minContentSize: NSSize {
        NSSize(
            width: Self.minWidth,
            height: chatStore.messages.isEmpty ? Self.compactMinHeight : Self.expandedMinHeight
        )
    }

    init(providerStore: ProviderStore, shortcutStore: ShortcutStore) {
        self.providerStore = providerStore
        self.shortcutStore = shortcutStore
        self.chatStore = ChatStore(providerStore: providerStore, shortcutStore: shortcutStore)
        super.init()

        // Grow to the remembered height when the first message lands; the shrink
        // back to compact is driven by the ChatView height report.
        chatStore.$messages
            .map(\.isEmpty)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] empty in self?.emptinessChanged(empty) }
            .store(in: &cancellables)
    }

    private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: Self.defaultExpandedHeight))
        // Minimum size is enforced in windowWillResize, NOT via contentMinSize:
        // NSHostingView (even with sizingOptions = []) clears the window's
        // min/max constraints to zero during layout, so contentMinSize writes
        // are silently discarded once the content view is attached.
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onAttachablePaste = {
            NotificationCenter.default.post(name: .popChatAttachPasteboard, object: nil)
        }
        let hostingView = NSHostingView(
            rootView: ChatView(
                state: state,
                store: chatStore,
                providerStore: providerStore,
                shortcutStore: shortcutStore,
                onClose: { [weak self] in self?.hide() },
                onCompactHeightChange: { [weak self] height in self?.compactHeightChanged(height) }
            )
        )
        // CRITICAL for typing latency: with the default sizingOptions, every
        // intrinsic-size invalidation from the multiline input field made
        // AppKit re-ask the root for a fitting size, which re-measured the
        // ENTIRE transcript (~8,700 CoreText measurements per keystroke).
        // Window size is managed explicitly (setContentHeight/contentMinSize),
        // so the hosting view must not propagate SwiftUI sizes to the window.
        hostingView.sizingOptions = []
        // The hidden titlebar of the .titled/.fullSizeContentView panel produces
        // a ~32pt top safe-area inset. SwiftUI would lay content out below it —
        // pushing the pills down and (in the compact state, whose height report
        // can't see the inset) squeezing the input capsule out the bottom edge.
        // The panel draws its own chrome; content owns the full frame.
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true // presentation animates this layer
        return panel
    }()

    func toggle() {
        if !panel.isVisible {
            show()
        } else if panel.isKeyWindow {
            hide()
        } else {
            // Visible but unfocused (pinned mode): the hotkey pulls focus back first;
            // a second press then dismisses.
            panel.makeKeyAndOrderFront(nil)
            state.focusBump += 1
        }
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Builds the panel and lays it out once, without showing it — called shortly
    /// after launch so the first hotkey press skips all cold construction.
    func prewarm() {
        _ = panel
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    // Summon: fade + scale 0.97→1 + rise from 8pt below. Dismiss: quick fade with
    // a slight shrink. The scale/rise is a Core Animation transform on the content
    // layer — NEVER animate the real window frame: every frame of a window resize
    // re-runs full SwiftUI layout and backdrop compositing (this was a visible
    // hitch with long transcripts). Both collapse to opacity-only under Reduce
    // Motion.
    func show() {
        isHiding = false
        if chatStore.messages.isEmpty {
            setContentHeight(lastCompactHeight ?? Self.compactMinHeight, animated: false)
        }
        position()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        if !reduceMotion, let layer = panel.contentView?.layer {
            layer.add(
                Self.transformAnimation(
                    from: Self.scaledTransform(for: layer, scale: 0.97, rise: 8, flipped: panel.contentView?.isFlipped ?? true),
                    to: CATransform3DIdentity,
                    duration: 0.20,
                    timing: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                ),
                forKey: "present"
            )
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        state.focusBump += 1
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        if !reduceMotion, let layer = panel.contentView?.layer {
            let shrink = Self.transformAnimation(
                from: CATransform3DIdentity,
                to: Self.scaledTransform(for: layer, scale: 0.98, rise: 0, flipped: true),
                duration: 0.11,
                timing: CAMediaTimingFunction(name: .easeIn)
            )
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "dismiss")
        }
        NSAnimationContext.runAnimationGroup({ [weak self] context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self?.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiding else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.panel.contentView?.layer?.removeAllAnimations()
                self.isHiding = false
            }
        })
    }

    /// Scale about the layer's center plus a vertical offset ("rise" is toward
    /// the bottom of the screen), compensating for the (0,0) anchor point.
    private static func scaledTransform(for layer: CALayer, scale: CGFloat, rise: CGFloat, flipped: Bool) -> CATransform3D {
        let bounds = layer.bounds
        let dx = bounds.width * (1 - scale) / 2
        let dy = bounds.height * (1 - scale) / 2 + (flipped ? rise : -rise)
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return transform
    }

    private static func transformAnimation(
        from: CATransform3D,
        to: CATransform3D,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = duration
        animation.timingFunction = timing
        return animation
    }

    /// Where the user last dragged the panel (top-left, stable across the
    /// top-anchored height changes); nil until they move it.
    private var savedTopLeft: NSPoint? {
        get {
            let stored = UserDefaults.standard.string(forKey: "panelTopLeft")
            let parts = (stored ?? "").split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return NSPoint(x: x, y: y)
        }
        set {
            guard let point = newValue else { return }
            UserDefaults.standard.set("\(point.x),\(point.y)", forKey: "panelTopLeft")
        }
    }

    /// The user's last position when they've moved the panel (validated against
    /// the current screens); otherwise slightly below the center of the screen
    /// the cursor is on (user decision 2026-07-21 — overrides the design doc's
    /// upper-center placement).
    private func position() {
        let size = panel.frame.size
        if let topLeft = savedTopLeft {
            let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
            let onScreen = NSScreen.screens.contains { screen in
                let intersection = frame.intersection(screen.visibleFrame)
                return intersection.width >= 120 && intersection.height >= 80
            }
            if onScreen {
                panel.setFrameOrigin(frame.origin)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.45 - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Dynamic height (compact ↔ expanded)

    private func emptinessChanged(_ empty: Bool) {
        if !empty {
            setContentHeight(expandedHeight, animated: true)
        }
        // When emptied (new chat), ChatView reports the compact height on next layout.
        // The minimum switches implicitly — windowWillResize reads emptiness live.
    }

    private func compactHeightChanged(_ height: CGFloat) {
        guard chatStore.messages.isEmpty else { return }
        let clamped = max(height, Self.compactMinHeight)
        lastCompactHeight = clamped
        setContentHeight(clamped, animated: panel.isVisible)
    }

    /// Resizes keeping the top edge fixed, so the panel grows downward.
    private func setContentHeight(_ contentHeight: CGFloat, animated: Bool) {
        let currentContent = panel.contentRect(forFrameRect: panel.frame)
        guard abs(currentContent.height - contentHeight) > 1 else { return }
        var newContent = currentContent
        newContent.origin.y = currentContent.maxY - contentHeight
        newContent.size.height = contentHeight
        let newFrame = panel.frameRect(forContentRect: newContent)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: panel.isVisible)
        }
    }

    // MARK: - NSWindowDelegate

    /// Enforces the minimum panel size for user resizes. This is the delegate
    /// method, not contentMinSize, because the NSHostingView content view resets
    /// the window's min/max to zero during layout regardless of sizingOptions.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minFrame = sender.frameRect(forContentRect: NSRect(origin: .zero, size: minContentSize)).size
        return NSSize(
            width: max(frameSize.width, minFrame.width),
            height: max(frameSize.height, minFrame.height)
        )
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !state.pinned else { return }
        // Deferred one tick so the new key window is known: if key moved to another
        // PopChat window (file picker, settings), keep the panel; hide only when
        // focus left the app entirely (keyWindow becomes nil for an accessory app).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.state.pinned else { return }
            if NSApp.keyWindow == nil {
                self.hide()
            }
        }
    }

    // Fires for user drags (and for the top-anchored height changes, whose
    // top-left is invariant, so saving is harmless). Programmatic positioning
    // happens before the panel is visible and is excluded by the guard.
    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, !isHiding else { return }
        let frame = panel.frame
        savedTopLeft = NSPoint(x: frame.origin.x, y: frame.maxY)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if !chatStore.messages.isEmpty {
            expandedHeight = panel.contentRect(forFrameRect: panel.frame).height
        }
    }
}
