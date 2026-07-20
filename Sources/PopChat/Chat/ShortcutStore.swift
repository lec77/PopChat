import Foundation

/// A user-defined prompt shortcut, invoked as "/name input" in the chat field.
/// `{input}` in the template marks where the typed remainder goes; without a
/// placeholder the input is appended on a new line.
struct PromptShortcut: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var template: String

    func expand(input: String) -> String {
        if template.contains("{input}") {
            return template.replacingOccurrences(of: "{input}", with: input)
        }
        return input.isEmpty ? template : template + "\n\n" + input
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    @Published var shortcuts: [PromptShortcut] {
        didSet { persist() }
    }

    private static let defaultsKey = "shortcutsJSON"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([PromptShortcut].self, from: data) {
            shortcuts = stored
        } else {
            shortcuts = [
                PromptShortcut(
                    id: UUID(),
                    name: "translate",
                    template: "Translate the following into natural, idiomatic English. Reply with the translation only:\n\n{input}"
                ),
                PromptShortcut(
                    id: UUID(),
                    name: "explain",
                    template: "Explain the following clearly and concisely, assuming a technical reader:\n\n{input}"
                ),
            ]
            persist()
        }
    }

    func match(name: String) -> PromptShortcut? {
        shortcuts.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    func add() {
        shortcuts.append(PromptShortcut(id: UUID(), name: "new-shortcut", template: "…{input}"))
    }

    func remove(id: UUID) {
        shortcuts.removeAll { $0.id == id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
