import AppKit
import SwiftUI
import KeyboardShortcuts

/// One-time orientation for a brand-new install.
///
/// PopChat is `LSUIElement`: launching it puts a status item in the menu bar and
/// shows nothing else, so a first-time user sees their double-click do
/// *nothing*. The panel now opens on first launch, but that alone doesn't teach
/// the two facts they need to find it again — the hotkey, and that the app lives
/// in the menu bar rather than the Dock.
///
/// It is an `NSPopover` anchored to the status item precisely because the arrow
/// does the pointing: prose saying "look in your menu bar" is worse than a
/// popover physically hanging off the icon. Shown once ever, keyed by
/// `AppDelegate.hasLaunchedKey`; never on a login-item launch.
enum FirstRunHint {
    @MainActor
    private static var popover: NSPopover?

    /// The recorded shortcut, not a hardcoded "⌥Space" — Settings can rebind it,
    /// and a hint that names the wrong keys is worse than no hint.
    static var shortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .togglePopChat).map(String.init(describing:)) ?? ""
    }

    @MainActor
    static func show(from button: NSStatusBarButton) {
        dismiss()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 268, height: 132)
        popover.contentViewController = NSHostingController(
            rootView: HintCard(shortcut: shortcutDescription, dismiss: dismiss)
        )
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @MainActor
    static var isShowing: Bool { popover?.isShown ?? false }

    @MainActor
    static func dismiss() {
        popover?.performClose(nil)
        popover = nil
    }
}

private struct HintCard: View {
    let shortcut: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PopChat lives up here")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 5) {
                if !shortcut.isEmpty {
                    HStack(spacing: 5) {
                        Text(shortcut)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                            )
                        Text("shows and hides the panel.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("There's no Dock icon — click this menu bar icon any time, or right-click it for Settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Got it", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 268)
    }
}
