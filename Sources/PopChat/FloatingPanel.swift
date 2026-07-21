import AppKit

/// The popup window. `.nonactivatingPanel` is the load-bearing style: the panel can
/// take keyboard focus without activating PopChat, so the previously active app stays
/// active and regains typing focus the instant the panel closes.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onAttachablePaste: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // The SwiftUI content draws its own rounded glass shell; the window itself
        // is a clear canvas (the system shadow follows the drawn shape).
        isOpaque = false
        backgroundColor = .clear
        // The controller hand-animates show/hide (fade + rise); the system
        // animation would double up.
        animationBehavior = .none
        isReleasedWhenClosed = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// ⌘V with files or a raw image on the pasteboard becomes an attachment.
    /// Must run here, before the Edit menu's Paste equivalent fires — otherwise
    /// `paste:` would insert file paths as text into the field editor.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           let onAttachablePaste,
           Self.pasteboardHasAttachable(NSPasteboard.general) {
            onAttachablePaste()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func pasteboardHasAttachable(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return true
        }
        return pasteboard.string(forType: .string) == nil
            && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }
}
