import AppKit
import SwiftUI

/// Single-line search field that routes ↑/↓/↩/⎋ back to its owner instead of
/// letting the field editor swallow them.
///
/// SwiftUI's `TextField` can't do this: a focused NSTextField handles
/// `moveUp:`/`moveDown:` itself (jump to start/end of the value), so an ancestor
/// `.onKeyPress` never sees the arrows. Same `doCommandBy` trick as
/// `ComposerTextView`, via NSTextFieldDelegate's control(_:textView:doCommandBy:).
///
/// Handlers return `true` when they consumed the key; `false` falls through to
/// the field editor's default behaviour.
struct KeyRoutingTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 11.5
    /// Bumped by the owner to (re)claim first responder — e.g. ⌘F while the
    /// field is already on screen.
    var focusBump: Int = 0
    var onMoveUp: () -> Bool = { false }
    var onMoveDown: () -> Bool = { false }
    /// (shift held) -> handled. Return sends "next", ⇧Return "previous".
    var onReturn: (Bool) -> Bool = { _ in false }
    var onEscape: () -> Bool = { false }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.stringValue = text
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
        // Both fields appear only on demand (find bar, history popover), so
        // claiming focus on creation is what the user asked for by opening them.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if context.coordinator.lastFocusBump != focusBump {
            context.coordinator.lastFocusBump = focusBump
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.count)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyRoutingTextField
        var lastFocusBump: Int

        init(_ parent: KeyRoutingTextField) {
            self.parent = parent
            lastFocusBump = parent.focusBump
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveUp()
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveDown()
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() { return false } // IME confirm
                return parent.onReturn(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                return false
            }
        }
    }
}

/// Zero-height carrier for a key equivalent that has no visible button.
/// `.hidden()` would drop the button out of the interaction tree; a 0-opacity
/// button in a background still registers its shortcut with the window.
extension View {
    func keyCommand(_ key: KeyEquivalent, modifiers: EventModifiers = .command, action: @escaping () -> Void) -> some View {
        background {
            Button("", action: action)
                .keyboardShortcut(key, modifiers: modifiers)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
