import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
    /// UI-only row for explicit errors/warnings — never sent to the API.
    case error
    /// UI-only row documenting tool use ("Searching: …") — never sent to the API.
    case activity
}

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let role: ChatRole
    var text: String
    /// What actually goes over the wire when it differs from the display text
    /// (slash-command expansion). Nil means `text` is the wire text.
    var wireText: String?
    var attachments: [Attachment] = []
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var recent: [ConversationMeta] = []
    private(set) var conversationID = UUID()

    private let providerStore: ProviderStore
    private let shortcutStore: ShortcutStore
    private var streamTask: Task<Void, Never>?

    // Per-character streaming: partial snapshots land in `streamTarget`; a drain
    // task reveals them at ~180 chars/s (accelerating when it falls behind, so the
    // display never lags the stream noticeably). Stop flushes instantly.
    private var streamTarget = ""
    private var streamFinished = false
    private var streamingMessageID: UUID?
    private var drainTask: Task<Void, Never>?

    init(providerStore: ProviderStore, shortcutStore: ShortcutStore) {
        self.providerStore = providerStore
        self.shortcutStore = shortcutStore
        // Resume the most recent conversation across app restarts.
        recent = ConversationStore.listRecent()
        if let latest = recent.first, let conversation = ConversationStore.load(id: latest.id) {
            conversationID = conversation.id
            messages = conversation.messages
        }
    }

    static var webSearchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "webSearchEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "webSearchEnabled") }
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming else { return }

        // Slash-command expansion: display stays compact, the template goes on the wire.
        var wireText: String?
        if text.hasPrefix("/") {
            let body = text.dropFirst()
            let name = String(body.prefix { !$0.isWhitespace })
            let input = String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            guard let shortcut = shortcutStore.match(name: name) else {
                messages.append(ChatMessage(role: .user, text: text))
                messages.append(ChatMessage(
                    role: .error,
                    text: "Unknown shortcut “/\(name)”. Define it in Settings → Slash Commands, or escape the leading slash."
                ))
                persist()
                return
            }
            wireText = shortcut.expand(input: input)
        }

        messages.append(ChatMessage(role: .user, text: text, wireText: wireText, attachments: attachments))

        // Explicit-warning policy: catch misconfiguration up front, with a pointer to
        // the fix, rather than surfacing an opaque HTTP failure.
        guard let config = providerStore.currentConfig() else {
            messages.append(ChatMessage(role: .error, text: "No provider selected — open Settings…"))
            persist()
            return
        }
        let providerName = providerStore.selectedProvider?.name ?? "provider"
        if config.model.isEmpty {
            messages.append(ChatMessage(
                role: .error,
                text: "No model set for \(providerName). Pick one from the model menu (fetch the list first) or Settings."
            ))
            persist()
            return
        }
        let isLocal = config.baseURL.contains("localhost") || config.baseURL.contains("127.0.0.1")
        if config.apiKey.isEmpty && !isLocal {
            messages.append(ChatMessage(
                role: .error,
                text: "No API key for \(providerName). Add one via right-click on the menu bar icon → Settings…"
            ))
            persist()
            return
        }

        let webAccess = resolveWebAccess(providerBaseURL: config.baseURL)

        let history = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { OpenAIChatClient.WireMessage(role: $0.role.rawValue, content: Self.wireContent(for: $0)) }

        persist()
        let assistantMessage = ChatMessage(role: .assistant, text: "")
        messages.append(assistantMessage)
        isStreaming = true

        let typewriter = StreamingMode(rawValue: UserDefaults.standard.string(forKey: "streamingMode") ?? "")
            ?? .perCharacter
        streamTarget = ""
        streamFinished = false
        streamingMessageID = assistantMessage.id

        streamTask = Task {
            // The streaming assistant row stays last; activity rows are inserted above it.
            var assistantIndex = messages.count - 1
            for await event in OpenAIChatClient.run(history: history, config: config, webAccess: webAccess) {
                switch event {
                case .partial(let text), .done(let text):
                    streamTarget = text
                    if typewriter == .perCharacter {
                        startDrain(messageID: assistantMessage.id)
                    } else {
                        messages[assistantIndex].text = text
                    }
                case .activity(let text):
                    messages.insert(ChatMessage(role: .activity, text: text), at: assistantIndex)
                    assistantIndex += 1
                case .error(let message):
                    messages.append(ChatMessage(role: .error, text: message))
                }
            }
            streamFinished = true
            await drainTask?.value
            drainTask = nil
            if messages.indices.contains(assistantIndex), messages[assistantIndex].role == .assistant {
                if streamTarget.isEmpty {
                    messages.remove(at: assistantIndex)
                } else {
                    messages[assistantIndex].text = streamTarget
                }
            }
            streamingMessageID = nil
            isStreaming = false
            persist()
        }
    }

    private func startDrain(messageID: UUID) {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                let displayed = self.messages[index].text
                let target = self.streamTarget
                if displayed.count >= target.count {
                    if self.streamFinished { return }
                } else if target.hasPrefix(displayed) {
                    let backlog = target.count - displayed.count
                    let step = min(backlog, max(6, backlog / 12))
                    self.messages[index].text = String(target.prefix(displayed.count + step))
                } else {
                    // Non-monotonic snapshot (new tool round) — jump to it.
                    self.messages[index].text = target
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// Inlines text attachments ahead of the typed text; images become content parts.
    /// Stays a bare string when there are no images, for maximum provider compatibility.
    private static func wireContent(for message: ChatMessage) -> OpenAIChatClient.WireContent {
        let base = message.wireText ?? message.text
        var textBlocks: [String] = []
        var imageParts: [OpenAIChatClient.WirePart] = []
        for attachment in message.attachments {
            switch attachment.content {
            case .text(let text):
                // Only real warnings travel to the model (it should know data is partial);
                // routine processing notes are user-facing only.
                let suffix = (attachment.noteKind == .warning ? attachment.note : nil).map { " — \($0)" } ?? ""
                textBlocks.append("[File: \(attachment.filename)\(suffix)]\n\(text)")
            case .image(let dataURL):
                imageParts.append(.imageDataURL(dataURL))
            }
        }
        let combined = (textBlocks + [base]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if imageParts.isEmpty {
            return .text(combined)
        }
        return .parts(imageParts + [.text(combined.isEmpty ? "See attached image(s)." : combined)])
    }

    /// Resolves the Settings search-engine choice against the active provider,
    /// falling back with an explicit warning row when the choice can't apply.
    private func resolveWebAccess(providerBaseURL: String) -> OpenAIChatClient.WebAccess? {
        guard Self.webSearchEnabled else { return nil }

        let choice = SearchEngineChoice(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "")
            ?? .duckduckgo

        func keyedEngine(_ choice: SearchEngineChoice, make: (String) -> SearchEngineConfig) -> OpenAIChatClient.WebAccess {
            guard let account = choice.apiKeyAccount,
                  let key = SecretStore.get(account: account), !key.isEmpty else {
                messages.append(ChatMessage(
                    role: .error,
                    text: "\(choice.label) needs an API key (Settings → Web Search) — using DuckDuckGo for this message."
                ))
                return .localTools(.duckduckgo)
            }
            return .localTools(make(key))
        }

        switch choice {
        case .duckduckgo:
            return .localTools(.duckduckgo)
        case .tavily:
            return keyedEngine(.tavily) { .tavily(key: $0) }
        case .brave:
            return keyedEngine(.brave) { .brave(key: $0) }
        case .providerNative:
            if providerBaseURL.contains("openrouter") {
                return .openRouterPlugin
            }
            messages.append(ChatMessage(
                role: .error,
                text: "Provider-native search only works on OpenRouter — using DuckDuckGo for this message."
            ))
            return .localTools(.duckduckgo)
        }
    }

    func stop() {
        streamTask?.cancel()
        drainTask?.cancel()
        drainTask = nil
        // Flush the typewriter buffer so everything received is visible at once.
        if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = streamTarget
        }
    }

    func deleteConversation(_ id: UUID) {
        ConversationStore.delete(id: id)
        recent.removeAll { $0.id == id }
        if id == conversationID {
            stop()
            conversationID = UUID()
            messages.removeAll()
        }
    }

    func newChat() {
        stop()
        persist()
        conversationID = UUID()
        messages.removeAll()
    }

    func loadConversation(_ id: UUID) {
        guard id != conversationID else { return }
        stop()
        persist()
        guard let conversation = ConversationStore.load(id: id) else {
            recent.removeAll { $0.id == id }
            messages.append(ChatMessage(role: .error, text: "Couldn't load that conversation — its file is missing or corrupt."))
            return
        }
        conversationID = conversation.id
        messages = conversation.messages
    }

    /// Writes the current conversation to disk and refreshes its slot in the
    /// recent list. No-op for empty conversations (avoids junk files).
    private func persist() {
        guard !messages.isEmpty else { return }
        let title = Self.title(for: messages)
        let conversation = Conversation(
            id: conversationID,
            title: title,
            updatedAt: Date(),
            messages: messages
        )
        ConversationStore.save(conversation)
        recent.removeAll { $0.id == conversationID }
        recent.insert(ConversationMeta(
            id: conversationID,
            title: title,
            updatedAt: conversation.updatedAt,
            snippet: ConversationMeta.snippet(for: messages)
        ), at: 0)
    }

    private static func title(for messages: [ChatMessage]) -> String {
        let firstUserText = messages.first { $0.role == .user }?.text ?? "New chat"
        let flattened = firstUserText.replacingOccurrences(of: "\n", with: " ")
        return flattened.count > 40 ? String(flattened.prefix(40)) + "…" : flattened
    }
}
