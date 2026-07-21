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

    // Fork state: `messages` always holds the full resolved transcript, but a
    // forked conversation persists only its divergent tail — the first
    // `sharedPrefixCount` messages belong to the parent chain.
    private var forkParentID: UUID?
    private var forkMessageID: UUID?
    private var sharedPrefixCount = 0

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
        if let latest = recent.first, let loaded = ConversationStore.loadResolved(id: latest.id) {
            adopt(loaded)
        }
    }

    private func adopt(_ loaded: (conversation: Conversation, messages: [ChatMessage], missingParent: Bool)) {
        conversationID = loaded.conversation.id
        messages = loaded.messages
        if loaded.missingParent {
            // Broken chain: continue as a standalone conversation, and say so.
            forkParentID = nil
            forkMessageID = nil
            sharedPrefixCount = 0
            let notice = "This fork's parent conversation is missing — showing only the messages added after the fork."
            if !messages.contains(where: { $0.role == .error && $0.text == notice }) {
                messages.append(ChatMessage(role: .error, text: notice))
            }
        } else {
            forkParentID = loaded.conversation.parentID
            forkMessageID = loaded.conversation.forkMessageID
            sharedPrefixCount = loaded.messages.count - loaded.conversation.messages.count
        }
    }

    static var webSearchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "webSearchEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "webSearchEnabled") }
    }

    /// Teaches the model the pasteable-block format the renderer recognizes.
    /// Editable in Settings → Commands; an explicitly empty value means "send
    /// no system prompt".
    nonisolated static let defaultSystemPrompt = """
    You are PopChat, a helpful assistant in a small desktop chat panel. Be concise and direct.

    When a reply includes content the user will copy and reuse verbatim — a prompt, template, \
    code snippet, configuration, or other reusable text — wrap exactly that content in a \
    pasteable block:

    <pasteable title="Short label">
    the exact reusable content
    </pasteable>

    Pasteable rules:
    - The tags go on their own lines, with a short descriptive title.
    - Inside the tags, put only the content to copy — no commentary.
    - Keep explanations outside the block, in normal prose.
    - Use pasteable blocks only for content meant to be copied; use normal markdown code \
    fences for illustrative code.
    """

    static var systemPrompt: String {
        UserDefaults.standard.string(forKey: "systemPrompt") ?? defaultSystemPrompt
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
        if config.kind == .chatGPT {
            if !ChatGPTAuth.isSignedIn {
                messages.append(ChatMessage(
                    role: .error,
                    text: "Not signed in to ChatGPT. Right-click the menu bar icon → Settings… → Providers → Sign in with ChatGPT."
                ))
                persist()
                return
            }
        } else {
            let isLocal = config.baseURL.contains("localhost") || config.baseURL.contains("127.0.0.1")
            if config.apiKey.isEmpty && !isLocal {
                messages.append(ChatMessage(
                    role: .error,
                    text: "No API key for \(providerName). Add one via right-click on the menu bar icon → Settings…"
                ))
                persist()
                return
            }
        }

        let webAccess = resolveWebAccess(providerBaseURL: config.baseURL)

        var history = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { OpenAIChatClient.WireMessage(role: $0.role.rawValue, content: Self.wireContent(for: $0)) }
        let systemPrompt = Self.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            history.insert(OpenAIChatClient.WireMessage(role: "system", content: .text(systemPrompt)), at: 0)
        }

        persist()
        let assistantMessage = ChatMessage(role: .assistant, text: "")
        messages.append(assistantMessage)
        isStreaming = true

        let typewriter = StreamingMode(rawValue: UserDefaults.standard.string(forKey: "streamingMode") ?? "")
            ?? .perCharacter
        streamTarget = ""
        streamFinished = false
        streamingMessageID = assistantMessage.id

        // Same event stream either way — only the wire protocol differs.
        let stream = config.kind == .chatGPT
            ? CodexResponsesClient.run(
                history: history, config: config, webAccess: webAccess,
                sessionID: conversationID.uuidString.lowercased()
            )
            : OpenAIChatClient.run(history: history, config: config, webAccess: webAccess)

        streamTask = Task {
            // The streaming assistant row stays last; activity rows are inserted above it.
            var assistantIndex = messages.count - 1
            for await event in stream {
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
                // Each tick re-renders and re-lays-out the growing message, and
                // that cost scales with its length — so the tick rate adapts:
                // fewer, larger steps for long texts, same ~180 chars/s feel.
                let interval = target.count > 12_000 ? 100 : target.count > 4_000 ? 66 : 33
                if displayed.count >= target.count {
                    if self.streamFinished { return }
                } else if target.hasPrefix(displayed) {
                    let backlog = target.count - displayed.count
                    let step = min(backlog, max(Int(Double(interval) * 0.18), backlog / 12))
                    self.messages[index].text = String(target.prefix(displayed.count + step))
                } else {
                    // Non-monotonic snapshot (new tool round) — jump to it.
                    self.messages[index].text = target
                }
                try? await Task.sleep(for: .milliseconds(interval))
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

    /// Start a new conversation that shares history up to and including
    /// `messageID` — stored as a tree branch (parent pointer + divergent tail
    /// only), so the shared prefix is never duplicated on disk.
    func fork(at messageID: UUID) {
        guard !isStreaming else { return }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        persist() // parent must be current on disk before the branch points into it
        forkParentID = conversationID
        forkMessageID = messageID
        conversationID = UUID()
        sharedPrefixCount = index + 1
        messages = Array(messages.prefix(index + 1))
        messages.append(ChatMessage(
            role: .activity,
            text: "Forked here — this branch diverges from the original conversation."
        ))
        persist()
    }

    func deleteConversation(_ id: UUID) {
        ConversationStore.deleteMaterializingChildren(id: id)
        recent = ConversationStore.listRecent()
        if id == conversationID {
            stop()
            conversationID = UUID()
            messages.removeAll()
            forkParentID = nil
            forkMessageID = nil
            sharedPrefixCount = 0
        } else if forkParentID == id {
            // Our file was just materialized as standalone; align memory with it.
            forkParentID = nil
            forkMessageID = nil
            sharedPrefixCount = 0
        }
    }

    func newChat() {
        stop()
        persist()
        conversationID = UUID()
        messages.removeAll()
        forkParentID = nil
        forkMessageID = nil
        sharedPrefixCount = 0
    }

    func loadConversation(_ id: UUID) {
        guard id != conversationID else { return }
        stop()
        persist()
        guard let loaded = ConversationStore.loadResolved(id: id) else {
            recent.removeAll { $0.id == id }
            messages.append(ChatMessage(role: .error, text: "Couldn't load that conversation — its file is missing or corrupt."))
            return
        }
        adopt(loaded)
    }

    /// Writes the current conversation to disk (a fork stores only its
    /// divergent tail) and refreshes its slot in the recent list. No-op for
    /// empty conversations (avoids junk files).
    private func persist() {
        guard !messages.isEmpty else { return }
        let title = Self.title(for: messages)
        let conversation = Conversation(
            id: conversationID,
            title: title,
            updatedAt: Date(),
            messages: Array(messages.dropFirst(sharedPrefixCount)),
            parentID: forkParentID,
            forkMessageID: forkMessageID
        )
        ConversationStore.save(conversation)
        recent.removeAll { $0.id == conversationID }
        recent.insert(ConversationMeta(
            id: conversationID,
            title: title,
            updatedAt: conversation.updatedAt,
            snippet: ConversationMeta.snippet(for: messages),
            isFork: forkParentID != nil
        ), at: 0)
    }

    private static func title(for messages: [ChatMessage]) -> String {
        let firstUserText = messages.first { $0.role == .user }?.text ?? "New chat"
        let flattened = firstUserText.replacingOccurrences(of: "\n", with: " ")
        return flattened.count > 40 ? String(flattened.prefix(40)) + "…" : flattened
    }
}
