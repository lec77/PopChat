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
    /// Latest `.status` lifecycle note from the active turn ("Starting Codex…"),
    /// rendered inside the waiting row while the reply is still empty. Cleared
    /// the moment visible text arrives and at the end of every turn — it must
    /// never outlive the wait it describes.
    @Published private(set) var pendingStatus: String?
    @Published private(set) var recent: [ConversationMeta] = []
    private(set) var conversationID = UUID()

    /// Bumped whenever a STORED conversation replaces the current one (history
    /// pick, launch resume) — as opposed to messages arriving by chat. Drives the
    /// restore choreography of delta 3 (5d): the panel's slower growth curve and
    /// the transcript's one-group reveal. Both need to fire before `messages`
    /// changes, so `adopt` sets them first.
    @Published private(set) var restoreTick = 0
    /// Whether that restore landed in an empty panel (which is about to grow) or
    /// replaced a conversation already on screen (crossfade in place).
    private(set) var restoredIntoEmptyPanel = false

    // Fork state: `messages` always holds the full resolved transcript, but a
    // forked conversation persists only its divergent tail — the first
    // `sharedPrefixCount` messages belong to the parent chain.
    private var forkParentID: UUID?
    private var forkMessageID: UUID?
    private var sharedPrefixCount = 0

    private let providerStore: ProviderStore
    private let shortcutStore: ShortcutStore
    private var streamTask: Task<Void, Never>?

    // Streaming reveal: partial snapshots land in `streamTarget`; a drain task
    // reveals them — per-character at a paced ~180 chars/s, per-sentence at
    // boundaries. The per-character pacing MUST be allowed to lag behind arrival
    // — see startDrain — or it is indistinguishable from mirroring the stream.
    // Stop flushes instantly.
    private var streamTarget = ""
    /// How much of the reply has ARRIVED, vs. how much of it the typewriter has
    /// revealed — `--smoke-input --live` compares the two to prove the composer is
    /// released mid-reveal rather than at the end of it.
    var streamTargetLength: Int { streamTarget.count }
    private var streamFinished = false
    private var streamingMessageID: UUID?
    private var drainTask: Task<Void, Never>?

    /// Delta 4: the trailing fade over text the drain has just committed, for the
    /// row currently revealing. Published so the streaming row repaints while the
    /// fade runs out even on ticks where no new characters landed — MessageRow is
    /// Equatable-gated on it, so no other row is touched.
    struct RevealState: Equatable {
        var messageID: UUID
        var fade: TextReveal
    }
    @Published private(set) var reveal: RevealState?

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
        // Announced BEFORE `messages` changes: @Published sends in willSet, so
        // everything observing the message list already sees the restore flags
        // when it reacts (PanelController's growth curve, ChatView's reveal).
        restoredIntoEmptyPanel = messages.isEmpty
        restoreTick += 1
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
    You are a helpful assistant in a small desktop chat panel. Be concise and direct.

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
        // A previous reply may still be typing itself out; complete it instantly
        // rather than letting the new turn's rows appear above a half-revealed one.
        flushTypewriter()

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
        switch config.kind {
        case .chatGPT:
            if !ChatGPTAuth.isSignedIn {
                messages.append(ChatMessage(
                    role: .error,
                    text: "Not signed in to ChatGPT. Right-click the menu bar icon → Settings… → Providers → Sign in with ChatGPT."
                ))
                persist()
                return
            }
        case .codexAppServer:
            // No pre-flight here on purpose. CodexAppServerClient resolves the
            // executable itself and reports a missing install / missing
            // `codex login` as an error EVENT, which lands in the transcript
            // through the same path this branch would use. Repeating the check
            // duplicates its message (they had already drifted) and puts its
            // filesystem probing on the main thread in the send path.
            break
        case .openAICompatible:
            let isLocal = config.baseURL.contains("localhost") || config.baseURL.contains("127.0.0.1")
            if config.apiKey.isEmpty && !isLocal {
                messages.append(ChatMessage(
                    role: .error,
                    text: "No API key for \(providerName). Add one in Settings → Providers (right-click the menu bar icon), or pick a configured provider from the model pill above."
                ))
                persist()
                return
            }
        }

        // Codex owns its own tool loop, so PopChat's client-side tools can't be
        // injected into it. Don't resolve the engine choice (which can append a
        // fallback warning) for a provider that cannot consume it — the globe
        // instead switches Codex's NATIVE web_search on at launch.
        let codexWebSearch = config.kind == .codexAppServer && Self.webSearchEnabled
        if codexWebSearch { noteCodexNativeSearch() }
        let webAccess = config.kind == .codexAppServer
            ? nil
            : resolveWebAccess(providerBaseURL: config.baseURL)

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
        pendingStatus = nil

        let typewriter = StreamingMode(rawValue: UserDefaults.standard.string(forKey: "streamingMode") ?? "")
            ?? .perCharacter
        streamTarget = ""
        streamFinished = false
        streamingMessageID = assistantMessage.id

        // Same event stream either way — only the wire protocol differs.
        let stream: AsyncStream<ChatStreamEvent>
        switch config.kind {
        case .chatGPT:
            stream = CodexResponsesClient.run(
                history: history, config: config, webAccess: webAccess,
                sessionID: conversationID.uuidString.lowercased()
            )
        case .codexAppServer:
            stream = CodexAppServerClient.run(history: history, config: config, webSearch: codexWebSearch)
        case .openAICompatible:
            stream = OpenAIChatClient.run(history: history, config: config, webAccess: webAccess)
        }

        streamTask = Task {
            // The streaming assistant row stays last; activity rows are inserted above it.
            var assistantIndex = messages.count - 1
            for await event in stream {
                switch event {
                case .partial(let text), .done(let text):
                    streamTarget = text
                    // The wait this described is over — real text is arriving.
                    if !text.isEmpty { pendingStatus = nil }
                    startDrain(messageID: assistantMessage.id, mode: typewriter)
                case .status(let text):
                    pendingStatus = text
                case .activity(let text):
                    messages.insert(ChatMessage(role: .activity, text: text), at: assistantIndex)
                    assistantIndex += 1
                case .error(let message):
                    messages.append(ChatMessage(role: .error, text: message))
                }
            }
            let finalText = streamTarget
            streamFinished = true
            // Hand the composer back the moment the NETWORK turn ends. The
            // typewriter can still be revealing seconds of tail (typewriterStep
            // deliberately lags), and holding isStreaming across it left the send
            // button stuck as Stop and Return doing nothing long after the reply
            // had actually arrived.
            isStreaming = false
            pendingStatus = nil
            await drainTask?.value
            // "Still ours": flushTypewriter() clears streamingMessageID when a new
            // turn takes over mid-reveal, so this must not clobber its bookkeeping.
            let stillOurs = streamingMessageID == assistantMessage.id
            // The drain has returned by now, so any fade it left is stale — it
            // exits without clearing when the row it was revealing is gone.
            if stillOurs { drainTask = nil; reveal = nil }
            // By id, not by index, and with the text captured above: the user can
            // now start another turn while this tail reveals, so neither the row
            // nor `streamTarget` is guaranteed to still be ours.
            if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                if finalText.isEmpty {
                    messages.remove(at: index)
                } else {
                    messages[index].text = finalText
                }
            }
            if stillOurs { streamingMessageID = nil }
            persist()
        }
    }

    /// Typewriter reveal speed. The per-tick step is this divided by the tick rate,
    /// so the granularity floor is a perf consequence (~6 chars at 33ms), not a
    /// choice: every tick re-lays out the growing message.
    nonisolated private static let typewriterCharsPerSecond = 180

    /// Tick period. Each tick re-renders and re-lays-out the growing message, and
    /// that cost scales with its length — so long texts tick less often (and take
    /// proportionally bigger steps to hold the same feel).
    nonisolated static func typewriterInterval(forLength count: Int) -> Int {
        count > 12_000 ? 100 : count > 4_000 ? 66 : 33
    }

    /// Characters to reveal on one tick.
    ///
    /// Pace at a FIXED rate while the answer is still arriving, and let the backlog
    /// grow. Any catch-up term proportional to the backlog settles at an equilibrium
    /// where the reveal rate EQUALS the arrival rate — which is why this mode used to
    /// look exactly like `.byChunk` on a fast model. Lag is the only lever that keeps
    /// the typewriter feel. It stays bounded two ways: the rate floors at "drain the
    /// backlog in 6s" (so a 20k-char answer isn't a two-minute wait), and it triples
    /// once the stream is done, so the tail types out instead of stranding the user.
    /// Extracted from the drain so `--smoke-typewriter` can assert all of that.
    nonisolated static func typewriterStep(backlog: Int, interval: Int, finished: Bool) -> Int {
        var rate = max(typewriterCharsPerSecond, backlog / 6)
        if finished { rate *= 3 }
        return min(backlog, max(1, rate * interval / 1000))
    }

    /// Generations of the current step that the per-character fade spans (6a).
    nonisolated static let revealGenerations = 6

    /// 6b pacing. A commit every ≥140 ms so a fast model can't dump the whole
    /// answer at once; 60 ms once the stream is done so the tail drains.
    nonisolated static let sentenceGapMs = 140
    nonisolated static let sentenceTailGapMs = 60
    /// How long one committed group takes to fade in (6b).
    nonisolated static let sentenceFadeMs = 350
    /// Past this much backlog, per-sentence commits whole paragraphs rather than
    /// accelerating — the entrance must never speed up (a faster fade reads as
    /// flicker, not as speed).
    nonisolated static let sentenceParagraphBacklog = 1_500

    private func startDrain(messageID: UUID, mode: StreamingMode) {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            // 6a state: characters currently under the ramp, and the step that
            // built it (which is also the rate the ramp runs out at).
            var head = 0
            var lastStep = 0
            // 6b state: in-flight sentence groups, newest first, with their age
            // in ms; plus time since the last commit.
            var groups: [(length: Int, age: Int)] = []
            var sinceCommit = Int.max

            while let self, !Task.isCancelled {
                guard let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                let displayed = self.messages[index].text
                let target = self.streamTarget
                let interval = Self.typewriterInterval(forLength: target.count)
                let finished = self.streamFinished

                if !target.hasPrefix(displayed) {
                    // Non-monotonic snapshot (new tool round) — jump to it, and
                    // drop any fade: the text it described no longer exists.
                    self.messages[index].text = target
                    head = 0
                    groups = []
                } else if displayed.count >= target.count {
                    // Nothing to commit: either the stream is done or we are
                    // waiting on the network. Either way the fade must keep
                    // running out, or the head would stay dimmed indefinitely.
                    head = max(0, head - max(lastStep, 1))
                    if head == 0, groups.isEmpty, finished {
                        self.reveal = nil
                        return
                    }
                } else if mode == .perCharacter {
                    let step = Self.typewriterStep(
                        backlog: target.count - displayed.count,
                        interval: interval,
                        finished: finished
                    )
                    self.messages[index].text = String(target.prefix(displayed.count + step))
                    lastStep = step
                    head = min(displayed.count + step, step * Self.revealGenerations)
                } else if sinceCommit >= (finished ? Self.sentenceTailGapMs : Self.sentenceGapMs) {
                    let commit = Self.sentenceCommitLength(
                        in: target, revealed: displayed.count, finished: finished
                    )
                    if commit > displayed.count {
                        self.messages[index].text = String(target.prefix(commit))
                        groups.insert((length: commit - displayed.count, age: 0), at: 0)
                        sinceCommit = 0
                    }
                }

                if mode == .perSentence {
                    for i in groups.indices { groups[i].age += interval }
                    groups.removeAll { $0.age >= Self.sentenceFadeMs }
                    sinceCommit = sinceCommit >= Int.max - interval ? Int.max : sinceCommit + interval
                    self.reveal = groups.isEmpty
                        ? nil
                        : RevealState(messageID: messageID, fade: .groups(groups, duration: Self.sentenceFadeMs))
                } else {
                    self.reveal = head > 0
                        ? RevealState(messageID: messageID, fade: .ramp(head: head))
                        : nil
                }
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    /// 6b. Character index the per-sentence reveal may commit up to — the end of
    /// a sentence, line, or paragraph — or `revealed` when the text has not
    /// reached a boundary yet, so a half-sentence never shows.
    ///
    /// Boundaries: `.` `!` `?` followed by whitespace, and any newline (which is
    /// what makes list items and closing code fences boundaries too). Positions
    /// inside an OPEN code fence are never boundaries — a half-written fence must
    /// not commit. Extracted from the drain so `--smoke-typewriter` can assert it.
    nonisolated static func sentenceCommitLength(in text: String, revealed: Int, finished: Bool) -> Int {
        let chars = Array(text)
        guard revealed < chars.count else { return revealed }

        var boundaries: [Int] = []
        var paragraphEnds: Set<Int> = []
        var insideFence = false
        var atLineStart = true
        var index = 0
        while index < chars.count {
            if atLineStart, chars[index...].starts(with: ["`", "`", "`"]) {
                insideFence.toggle()
            }
            atLineStart = false
            let char = chars[index]
            if char == "\n" {
                atLineStart = true
                // The newline ENDING a fence line is a boundary when that line
                // closed the fence (insideFence is already false by then).
                if !insideFence {
                    boundaries.append(index + 1)
                    if index + 1 < chars.count, chars[index + 1] == "\n" {
                        paragraphEnds.insert(index + 1)
                    } else if index + 1 == chars.count {
                        paragraphEnds.insert(index + 1)
                    }
                }
            } else if !insideFence, char == "." || char == "!" || char == "?" {
                let next = index + 1
                if next == chars.count {
                    if finished { boundaries.append(next) }
                } else if chars[next].isWhitespace {
                    boundaries.append(next)
                }
            }
            index += 1
        }
        // Once the stream is over, the end of the text is ALWAYS a boundary —
        // including inside a fence the reply never closed. "An unclosed fence
        // never half-commits" is a rule about mid-stream text, and applying it
        // here instead strands the drain: it would spin without ever committing,
        // and the streamTask tail awaits that drain.
        if finished, boundaries.last != chars.count {
            boundaries.append(chars.count)
            paragraphEnds.insert(chars.count)
        }

        let pending = boundaries.filter { $0 > revealed }
        guard let last = pending.last else { return revealed }

        // Long answers coalesce instead of accelerating: the same 6 s ceiling as
        // per-character, spent on MORE PER BEAT rather than a faster entrance.
        let backlog = chars.count - revealed
        if backlog > sentenceParagraphBacklog {
            return pending.last { paragraphEnds.contains($0) } ?? last
        }
        let beats = max(1, 6_000 / sentenceGapMs)
        let perBeat = max(1, Int((Double(pending.count) / Double(beats)).rounded(.up)))
        let candidate = pending[min(perBeat, pending.count) - 1]
        // Groups never span a paragraph break — units stay semantic.
        return pending.first { paragraphEnds.contains($0) && $0 < candidate } ?? candidate
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

    private static let codexNativeSearchNotice =
        "Codex runs its own web search — the Search engine setting doesn't apply to this provider."

    /// Codex's native `web_search` ignores the Settings engine choice and
    /// PopChat's round cap, which the policy says to state rather than degrade
    /// silently. Once per conversation, though: unlike the per-message
    /// fallbacks this is a standing property of the provider, not of the turn.
    private func noteCodexNativeSearch() {
        guard !messages.contains(where: { $0.text == Self.codexNativeSearchNotice }) else { return }
        messages.append(ChatMessage(role: .activity, text: Self.codexNativeSearchNotice))
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
        // Don't wait for the cancelled task's tail to clear it — the waiting row
        // must not keep pulsing "Reasoning…" after the user said stop.
        pendingStatus = nil
        flushTypewriter()
    }

    /// The complete text of a message: for the row a typewriter is still
    /// revealing, everything that has ARRIVED rather than the characters typed
    /// out so far. Copy would otherwise hand back a truncated reply while
    /// claiming to copy the whole response.
    func fullText(of messageID: UUID) -> String {
        if messageID == streamingMessageID, !streamTarget.isEmpty { return streamTarget }
        return messages.first { $0.id == messageID }?.text ?? ""
    }

    /// Ends any typewriter still revealing a reply, showing it in full. Called by
    /// stop() and at the head of send(): once the composer is usable again during
    /// the reveal (see the streamTask tail), a new turn can begin mid-tail, and it
    /// must not inherit the previous one's drain or `streamTarget`.
    private func flushTypewriter() {
        drainTask?.cancel()
        drainTask = nil
        // The fade describes a reveal that is over; leaving it would strand the
        // flushed tail translucent with nothing left to tick it back to opaque.
        reveal = nil
        if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = streamTarget
        }
        streamingMessageID = nil
    }

    /// Start a new conversation that shares history up to and including
    /// `messageID` — stored as a tree branch (parent pointer + divergent tail
    /// only), so the shared prefix is never duplicated on disk.
    func fork(at messageID: UUID) {
        guard !isStreaming else { return }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        // A reply can still be typing itself out here (isStreaming tracks the
        // network turn, not the reveal). Complete it FIRST: the persist() below
        // writes the parent, and everything after re-points the store at the
        // branch — so a partial row would be frozen into the parent's file and
        // never corrected, truncating the reply permanently.
        flushTypewriter()
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
