import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let state = PanelState()
    private let providerStore: ProviderStore
    private let shortcutStore: ShortcutStore
    private let chatStore: ChatStore
    private var cancellables: Set<AnyCancellable> = []
    private var isHiding = false
    /// Last content height reported by the compact (no messages) layout.
    private var lastCompactHeight: CGFloat?

    private static let compactMinHeight: CGFloat = 90
    private static let expandedMinHeight: CGFloat = 320
    private static let defaultExpandedHeight: CGFloat = 440

    /// User's preferred height for the expanded (has messages) state.
    private var expandedHeight: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "panelExpandedHeight")
            return stored > 0 ? stored : Self.defaultExpandedHeight
        }
        set { UserDefaults.standard.set(newValue, forKey: "panelExpandedHeight") }
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
        panel.contentMinSize = NSSize(
            width: 480,
            height: chatStore.messages.isEmpty ? Self.compactMinHeight : Self.expandedMinHeight
        )
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(
            rootView: ChatView(
                state: state,
                store: chatStore,
                providerStore: providerStore,
                shortcutStore: shortcutStore,
                onClose: { [weak self] in self?.hide() },
                onCompactHeightChange: { [weak self] height in self?.compactHeightChanged(height) }
            )
        )
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

    func show() {
        isHiding = false
        if chatStore.messages.isEmpty {
            setContentHeight(lastCompactHeight ?? 110, animated: false)
        }
        position()
        let target = panel.frame
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: -10), display: false)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        state.focusBump += 1
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        NSAnimationContext.runAnimationGroup({ [weak self] context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self?.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiding else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.isHiding = false
            }
        })
    }

    /// Upper-center of the screen the cursor is on, keeping whatever size the user
    /// last resized the panel to.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.72 - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Dynamic height (compact ↔ expanded)

    private func emptinessChanged(_ empty: Bool) {
        panel.contentMinSize = NSSize(
            width: 480,
            height: empty ? Self.compactMinHeight : Self.expandedMinHeight
        )
        if !empty {
            setContentHeight(expandedHeight, animated: true)
        }
        // When emptied (new chat), ChatView reports the compact height on next layout.
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

    func windowDidEndLiveResize(_ notification: Notification) {
        if !chatStore.messages.isEmpty {
            expandedHeight = panel.contentRect(forFrameRect: panel.frame).height
        }
    }
}
