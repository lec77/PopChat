import AppKit
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let state = PanelState()
    private let providerStore: ProviderStore
    private let shortcutStore: ShortcutStore
    private let chatStore: ChatStore

    init(providerStore: ProviderStore, shortcutStore: ShortcutStore) {
        self.providerStore = providerStore
        self.shortcutStore = shortcutStore
        self.chatStore = ChatStore(providerStore: providerStore, shortcutStore: shortcutStore)
        super.init()
    }

    private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440))
        panel.contentMinSize = NSSize(width: 480, height: 320)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(
            rootView: ChatView(
                state: state,
                store: chatStore,
                providerStore: providerStore,
                shortcutStore: shortcutStore,
                onClose: { [weak self] in self?.hide() }
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
        position()
        panel.makeKeyAndOrderFront(nil)
        state.focusBump += 1
    }

    func hide() {
        panel.orderOut(nil)
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
}
