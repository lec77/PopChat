import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let providerStore = ProviderStore()
    private let shortcutStore = ShortcutStore()
    private lazy var panelController = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
    private var settingsWindow: NSWindow?

    /// Hooks for `--smoke-firstrun`, which drives the real launch path.
    var isPanelOnScreen: Bool { panelController.isPanelOnScreen }
    func hidePanel() { panelController.hide() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auto / Light / Dark (Settings › General): NSApp.appearance reaches every
        // window at once — panel, Settings, popovers; nil follows the system.
        AppearanceChoice.applyCurrent()
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "bubble.left.and.bubble.right.fill",
                accessibilityDescription: "PopChat"
            )
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        KeyboardShortcuts.onKeyUp(for: .togglePopChat) { [weak self] in
            self?.panelController.toggle()
        }

        // "Dismiss PopChat" means all of it: a floating Settings window left
        // hovering over the app the user returned to reads as stuck. Only
        // USER-initiated dismissals (hotkey, Esc, ⌘W, close button) fire this —
        // the focus-loss auto-hide must not yank Settings away while the user
        // is off copying an API key from another app.
        panelController.onUserDismiss = { [weak self] in
            self?.settingsWindow?.close()
        }

        NotificationCenter.default.addObserver(
            forName: .popChatOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        // Read while the launch Apple event is still the current one — by the
        // time the block below runs it is gone.
        let loginItem = launchedAsLoginItem

        // Build the panel + view hierarchy and load the resumed conversation off
        // the critical path, so the first hotkey press shows a warm panel.
        DispatchQueue.main.async { [weak self] in
            self?.panelController.prewarm()
            self?.presentLaunchUI(loginItem: loginItem)
        }
    }

    // MARK: - Being findable at all

    nonisolated static let hasLaunchedKey = "hasLaunchedBefore"

    /// Whether macOS started us at login rather than the user opening the app.
    /// MUST be read during `applicationDidFinishLaunching` — it inspects the
    /// launch Apple event, which is only the current event that early. A login
    /// launch is the one case where showing the panel is wrong: the user asked
    /// for PopChat to be *ready*, not to greet them at every boot.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// An LSUIElement app that opens nothing looks broken: the status item is
    /// one of a dozen menu bar glyphs, and nothing on screen names the hotkey.
    /// So the first launch ever opens the panel and points at the icon once.
    func presentLaunchUI(loginItem: Bool) {
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: Self.hasLaunchedKey)
        defaults.set(true, forKey: Self.hasLaunchedKey)
        guard firstLaunch, !loginItem else { return }

        // The panel is a non-activating panel, so it can show without stealing
        // focus — but on a first launch the user just double-clicked us and IS
        // expecting the foreground.
        NSApp.activate(ignoringOtherApps: true)
        panelController.show()
        // After the panel, never before: the hint is a `.transient` popover and
        // a window ordering in front of it would dismiss it on the spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let button = self?.statusItem.button else { return }
            FirstRunHint.show(from: button)
        }
    }

    /// Double-clicking an already-running LSUIElement app otherwise does
    /// NOTHING — macOS just reactivates it. That's the exact move someone makes
    /// when they think the app failed to start, so it has to show the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        FirstRunHint.dismiss()
        panelController.show()
        return true
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panelController.toggle()
        }
    }

    // Left click toggles the panel; the menu only appears on right/ctrl-click.
    // Assigning statusItem.menu permanently would hijack left click, so it's
    // attached just for the click and detached after.
    private func showMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Toggle PopChat", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit PopChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    /// ⌘A/⌘C/⌘V/⌘X/⌘Z are MENU key equivalents on macOS, not text-view built-ins.
    /// An LSUIElement app never shows a menu bar, but NSApp.mainMenu is still
    /// consulted for key equivalents — without this invisible Edit menu, none of
    /// the standard edit shortcuts work anywhere in the app.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        // ⌘W. No visible menu bar means no File/Window menu, so without this the
        // Settings window closes only via its traffic-light X — and the panel
        // ignores ⌘W entirely.
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(closeKeyWindow), keyEquivalent: "w")
        closeItem.target = self
        appMenu.addItem(closeItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// ⌘W: hide the panel (a user dismissal, so Settings goes with it) or close
    /// whatever other closable window is key. Popover windows aren't closable
    /// and fall through to a no-op.
    @objc private func closeKeyWindow() {
        guard let key = NSApp.keyWindow else { return }
        if key is FloatingPanel {
            panelController.dismiss()
        } else if key.styleMask.contains(.closable) {
            key.performClose(nil)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = DismissOnEscWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "PopChat Settings"
            window.contentView = NSHostingView(rootView: SettingsView(store: providerStore, shortcutStore: shortcutStore))
            window.isReleasedWhenClosed = false
            // The chat panel floats (.floating level); a normal-level Settings
            // window would always open BEHIND it. Same level + orderFront wins.
            window.level = .floating
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Settings window for an LSUIElement app: no Window menu exists, so Esc has to
/// be handled by the window itself (⌘W comes from the invisible main menu).
/// Intercepted in `sendEvent`, not `cancelOperation`: a focused text field's
/// editor consumes Esc first — NSTextView turns it into the completion popup —
/// so the responder chain never reaches the window. The one Esc that must keep
/// its normal meaning is an in-progress IME composition (the Commands tab takes
/// CJK input), hence the marked-text guard.
private final class DismissOnEscWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 53, // Esc
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           !((firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
            close()
            return
        }
        super.sendEvent(event)
    }
}
