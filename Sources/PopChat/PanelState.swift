import Foundation

/// Shared UI state between the panel controller (AppKit) and the chat view (SwiftUI).
final class PanelState: ObservableObject {
    /// Always-on-top. When false, the panel hides as soon as it loses key status
    /// (i.e. you click into another app).
    @Published var pinned = false

    /// Bumped every time the panel is shown or re-focused; the chat view observes
    /// this to move keyboard focus into the input field.
    @Published var focusBump = 0
}
