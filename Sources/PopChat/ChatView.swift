import SwiftUI

extension Notification.Name {
    static let popChatOpenSettings = Notification.Name("PopChatOpenSettings")
    /// Posted by FloatingPanel when ⌘V carries files/an image to attach.
    static let popChatAttachPasteboard = Notification.Name("PopChatAttachPasteboard")
}

/// The "Glass" panel: translucent rounded shell, header chrome as overlay pills
/// the transcript scrolls under, and a floating capsule input at the bottom.
///
/// Performance shape (do not regress): typing state lives entirely inside
/// ComposerView, so keystrokes never invalidate the transcript; transcript rows
/// are Equatable-gated so streaming ticks re-render only the active row.
struct ChatView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: ChatStore
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var shortcutStore: ShortcutStore
    var onClose: () -> Void
    /// Reports the natural content height while the chat is empty, so the panel
    /// can shrink to just chrome + input.
    var onCompactHeightChange: (CGFloat) -> Void = { _ in }

    @State private var composerModel = ComposerModel()
    @State private var draftEditorShown = false
    @State private var dropTargeted = false
    @State private var historyShown = false
    @State private var modelPillHovered = false
    /// 7c switcher popover — the pill shows a pressed state while it's open.
    @State private var switcherShown = false
    @State private var actionPillHovered = false
    @State private var transcriptWidth: CGFloat = 680
    /// Width of the header pills row — the model pill caps at 46% of it (4a).
    @State private var headerWidth: CGFloat = 680
    /// Streaming follows the bottom only while the user is there; an upward
    /// scroll disengages so streaming never yanks the view.
    @State private var pinnedToBottom = true
    @State private var showNewMessagesPill = false
    // ⌘F find-in-chat. Hits are counted over DISPLAYED text and painted in
    // place (Find.swift); the transcript scrolls to the matched characters, not
    // to the message. Only rows that contain a hit get a MessageFind, so every
    // other row stays Equatable-gated while the query is typed, and highlights
    // add only .backgroundColor — never a re-measure (see SelectableText).
    @State private var findShown = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findFocusBump = 0
    /// 5d: a restored conversation arrives as ONE group once the panel has begun
    /// growing — no per-row stagger, this is a restore, not new content. False
    /// only for the frame or two between the restore and its reveal.
    @State private var transcriptRevealed = true
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.color(accentHex) }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            if store.messages.isEmpty, !draftEditorShown {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PanelGlassBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.panelBorder(dark: scheme == .dark), lineWidth: 0.5)
        )
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(accent, lineWidth: 3)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        // No SwiftUI min frame here: the window enforces minimums (PanelController
        // windowWillResize). A root larger than the window would render CENTERED
        // in it, clipping the pills and composer off the top/bottom edges.
        .dropDestination(for: URL.self) { urls, _ in
            composerModel.handleFiles(urls)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .onExitCommand { onClose() }
        // While the history popover is key, ITS ⌘F wins (popovers get their own
        // window), which is what "⌘F in history searches the histories" means.
        .keyCommand("f") { toggleFind() }
        .onChange(of: draftEditorShown) { _, shown in
            // The editor needs real height even when the chat is empty; the
            // compact preference resumes reporting when the editor closes.
            if store.messages.isEmpty, shown {
                onCompactHeightChange(440)
            }
        }
        // Lives on the root, not in transcriptZone: restoring into an EMPTY panel
        // builds that subtree fresh, and .onChange never fires on first appearance.
        .onChange(of: store.restoreTick) { _, _ in revealRestoredTranscript() }
    }

    /// Hide, let one layout pass land (that's where the transcript pre-scrolls to
    /// the bottom), then bring it in as a group ~60ms into the panel's growth so
    /// text never pops in mid-resize.
    private func revealRestoredTranscript() {
        let intoEmptyPanel = store.restoredIntoEmptyPanel
        transcriptRevealed = false
        let delay = reduceMotion || !intoEmptyPanel ? 0.016 : 0.06
        let reveal = reduceMotion || !intoEmptyPanel ? 0.15 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeOut(duration: reveal)) { transcriptRevealed = true }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // The ⌘E editor keeps the header pills visible (4d); only the
            // transcript hides while it's open.
            if store.messages.isEmpty || draftEditorShown {
                pillsRow
                    .padding(12)
                    .background(WindowDragStrip())
            } else {
                transcriptZone
            }
            ComposerView(
                model: composerModel,
                shortcutStore: shortcutStore,
                isStreaming: store.isStreaming,
                focusBump: state.focusBump,
                editorMode: $draftEditorShown,
                onSend: { text, attachments in store.send(text, attachments: attachments) },
                onStop: { store.stop() },
                onFocusRequest: { state.focusBump += 1 },
                onClose: onClose
            )
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            if store.messages.isEmpty, !draftEditorShown {
                onCompactHeightChange(height)
            }
        }
    }

    // MARK: - Header pills

    // Model pill caps at 46% of the row and truncates the id; the action
    // cluster is fixedSize — it never compresses (4a).
    private var pillsRow: some View {
        HStack(spacing: 10) {
            modelPill
            Spacer(minLength: 0)
            actionPill
                .fixedSize()
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: HeaderWidthKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(HeaderWidthKey.self) { headerWidth = $0 }
    }

    // Delta 5 (7c): a cascading provider→model→effort popover, not a Menu.
    // Effort appears only for models with explicit capability metadata; browsing
    // any lane must not switch what the next message uses until a row commits.
    private var modelPill: some View {
        Button {
            switcherShown.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(switcherLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .layoutPriority(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            // Whole pill is clickable — plain-style controls only hit-test
            // opaque pixels without an explicit content shape.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .pillBackground(hovered: modelPillHovered, pressed: switcherShown)
        .onHover { modelPillHovered = $0 }
        .popover(isPresented: $switcherShown, arrowEdge: .bottom) {
            ProviderSwitcher(store: providerStore)
        }
        // Invisible cap: the visible pill hugs its content, but never exceeds
        // 46% of the header row (the label truncates instead).
        .frame(maxWidth: max(headerWidth * 0.46, 140), alignment: .leading)
    }

    // Icon grid (4b): 14pt symbols in fixed 20×20 slots, 8pt gap, 4×8 padding
    // ≙ 28pt capsule height; active states are plain circular fills over the
    // slot — no negative margins.
    private var actionPill: some View {
        HStack(spacing: 8) {
            Button {
                historyShown.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
                    .background(historyShown ? Color.primary.opacity(0.14) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("y", modifiers: .command)
            .help("Recent chats (⌘Y)")
            .popover(isPresented: $historyShown, arrowEdge: .bottom) {
                HistoryPopover(store: store)
            }
            Button {
                store.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("New chat (⌘N)")
            Button {
                state.pinned.toggle()
            } label: {
                Image(systemName: state.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 14))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20, height: 20)
                    .background(state.pinned ? Color.primary.opacity(0.14) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: .command)
            .help(state.pinned ? "Unpin — hide when clicking away (⌘P)" : "Keep on top (⌘P)")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.pinned)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .pillBackground(hovered: actionPillHovered)
        .onHover { actionPillHovered = $0 }
    }

    private var switcherLabel: String {
        // A fresh install has a selection (selectedID is non-optional) but no
        // configured provider — naming one here reads as "ready to chat" and the
        // user only learns otherwise from an error after typing. Say what the
        // next step actually is; the click lands in the switcher, whose footer
        // opens Settings › Providers. hasSetupEvidence, NOT isConfigured: a
        // transient failed Codex check must not rename a set-up provider mid-
        // conversation. (Cheap per render: secrets and tokens are memory-cached,
        // the rest are dictionary lookups.)
        guard let provider = providerStore.selectedProvider,
              providerStore.hasSetupEvidence(provider) else { return "Set up a provider…" }
        let model = providerStore.currentModel
        let effort = providerStore.currentReasoningEffort.map { " · \($0)" } ?? ""
        return "\(provider.name) · \(model.isEmpty ? "no model" : model)\(effort)"
    }

    // MARK: - Transcript

    private var transcriptZone: some View {
        let streamingID = store.isStreaming ? store.messages.last(where: { $0.role == .assistant })?.id : nil
        let revealingID: UUID? = store.reveal?.messageID
        let revealFade: TextReveal? = store.reveal?.fade
        let bubbleMaxWidth = max(220, (transcriptWidth - 32) * 0.78)
        let hits = findShown ? findHits : []
        let activeHit = hits.indices.contains(findIndex) ? hits[findIndex] : nil
        let matchedIDs = Set(hits.map(\.messageID))
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollViewReader { proxy in
            trackingBottomPin(
                ScrollView {
                    // Plain VStack, deliberately: LazyVStack re-estimates row heights as
                    // items load during scrolling, and with variable-height text rows the
                    // fluctuating content height fights NSScrollView's position
                    // adjustments — an infinite re-layout loop that froze the app.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.messages) { message in
                            // Hoisted out of the initializer: inline ternaries here
                            // tipped the type-checker over its time limit.
                            let id: UUID = message.id
                            let revealing: Bool = id == revealingID
                            // Nil for messages with no hit, so every other row
                            // stays Equatable-gated while typing.
                            let rowFind: MessageFind? = matchedIDs.contains(id)
                                ? MessageFind(
                                    query: query,
                                    activeOccurrence: activeHit?.messageID == id ? activeHit?.occurrence : nil
                                )
                                : nil
                            // Nil for every row but the still-empty streaming one
                            // (same gating trick as `find`), so status updates
                            // repaint exactly one row.
                            let waiting: String? = id == streamingID && message.text.isEmpty
                                ? (store.pendingStatus ?? "Thinking…")
                                : nil
                            MessageRow(
                                message: message,
                                // The caret rides the fade head (Delta 4), so it
                                // outlives the NETWORK turn that streamingID
                                // tracks — the reveal can still be typing.
                                showCaret: id == streamingID || revealing,
                                bubbleMaxWidth: bubbleMaxWidth,
                                find: rowFind,
                                reveal: revealing ? revealFade : nil,
                                waitingStatus: waiting,
                                onFork: { store.fork(at: id) },
                                fullText: { store.fullText(of: id) }
                            )
                            .equatable()
                            .transition(rowTransition(for: message.role))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.top, 56)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    // 5d: the restore reveal. Opacity/offset on the group only —
                    // it cannot change any row's metrics, so nothing re-measures.
                    .opacity(transcriptRevealed ? 1 : 0)
                    .offset(y: transcriptRevealed || reduceMotion ? 0 : 8)
                }
            )
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: TranscriptWidthKey.self, value: geometry.size.width)
                }
            )
            .onPreferenceChange(TranscriptWidthKey.self) { transcriptWidth = $0 }
            .mask(topFade)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    pillsRow
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        // The bar tucks up under the pills (5a): the row's bottom
                        // inset drops to 4 while it's open.
                        .padding(.bottom, findShown ? 4 : 12)
                        .background(WindowDragStrip())
                    if findShown {
                        findBar(matchCount: hits.count)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                            .transition(.opacity)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: findShown)
            // Recompute from state rather than closing over `currentMatch`: the
            // captured value belongs to the body evaluation that installed the
            // closure, which is not guaranteed to be the post-change one.
            .onChange(of: findIndex) { _, index in
                let hits = findHits
                scrollToMatch(hits.indices.contains(index) ? hits[index] : nil, proxy)
            }
            .onChange(of: findQuery) { _, _ in
                findIndex = 0
                scrollToMatch(findHits.first, proxy)
            }
            .overlay(alignment: .bottom) {
                if showNewMessagesPill {
                    newMessagesPill(proxy)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showNewMessagesPill)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18), value: store.messages.count)
            // Text ticks arrive many times per second while streaming: the
            // follow-scroll must NOT be animated, or each tick restarts an
            // animation and layout never goes idle (this froze the app).
            // Animate only on new rows.
            .onChange(of: store.messages.last?.text) { _, _ in
                if pinnedToBottom {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } else {
                    showNewMessagesPill = true
                }
            }
            .onChange(of: store.messages.count) { _, _ in
                if pinnedToBottom {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                } else {
                    showNewMessagesPill = true
                }
            }
            .onChange(of: pinnedToBottom) { _, pinned in
                if pinned { showNewMessagesPill = false }
            }
            // Pre-scroll a restored transcript to the bottom while it is still
            // invisible, so the reveal shows the end of the conversation with no
            // visible scroll jump (5d). onAppear covers the empty→loaded case
            // (this subtree is new); onChange covers replacing an open chat.
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.restoreTick) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Find in chat (⌘F)

    /// Every occurrence in the transcript, in reading order. Counted over
    /// DISPLAYED text (markdown syntax stripped, code/table content as rendered)
    /// so hit N is exactly the range the transcript paints as active.
    private var findHits: [FindHit] {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var hits: [FindHit] = []
        for message in store.messages {
            let count = MarkdownRenderer.searchableStrings(for: message)
                .reduce(0) { $0 + FindHighlight.count(in: $1, query: query) }
            for occurrence in 0..<count {
                hits.append(FindHit(messageID: message.id, occurrence: occurrence))
            }
        }
        return hits
    }

    private func toggleFind() {
        if findShown {
            closeFind()
        } else {
            guard !store.messages.isEmpty else { return } // nothing to search
            findShown = true
            findIndex = 0
            findFocusBump += 1
        }
    }

    private func closeFind() {
        findShown = false
        findQuery = ""
        findIndex = 0
        state.focusBump += 1 // hand the caret back to the composer
    }

    private func stepMatch(_ delta: Int) {
        let count = findHits.count
        guard count > 0 else { return }
        findIndex = ((findIndex + delta) % count + count) % count // wraps both ways
    }

    /// Coarse fallback only. Rows that render real text views scroll themselves
    /// to the matched characters (`SelectableText.reveal`) — scrolling to the
    /// message here as well would fight that with a second, less precise jump.
    private func scrollToMatch(_ hit: FindHit?, _ proxy: ScrollViewProxy) {
        guard let hit,
              let message = store.messages.first(where: { $0.id == hit.messageID }),
              message.role == .activity || message.role == .error else { return }
        proxy.scrollTo(hit.messageID, anchor: .center)
    }

    private func findBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            KeyRoutingTextField(
                text: $findQuery,
                placeholder: "Find in chat",
                focusBump: findFocusBump,
                onMoveUp: {
                    stepMatch(-1)
                    return true
                },
                onMoveDown: {
                    stepMatch(1)
                    return true
                },
                onReturn: { shift in
                    stepMatch(shift ? -1 : 1)
                    return true
                },
                onEscape: {
                    closeFind()
                    return true
                }
            )
            .frame(height: 16)
            Text(matchLabel(matchCount))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            findStepButton("chevron.up", modifiers: [.command, .shift], enabled: matchCount > 0) { stepMatch(-1) }
            findStepButton("chevron.down", modifiers: .command, enabled: matchCount > 0) { stepMatch(1) }
            Button(action: closeFind) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Dimmer than the steppers (5a): stepping is the bar's job, ✕ isn't.
            .foregroundStyle(.secondary.opacity(0.78))
            .help("Close find (⎋)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .pillBackground()
    }

    private func matchLabel(_ count: Int) -> String {
        if findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard count > 0 else { return "No matches" }
        return "\(min(findIndex + 1, count)) of \(count)"
    }

    private func findStepButton(
        _ symbol: String,
        modifiers: EventModifiers,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .keyboardShortcut("g", modifiers: modifiers)
        .help(symbol == "chevron.up" ? "Previous match (⇧⌘G)" : "Next match (⌘G)")
    }

    /// Transcript scrolls under the pills; the top 44pt fades out beneath them.
    private var topFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
            Color.black
        }
    }

    private func rowTransition(for role: ChatRole) -> AnyTransition {
        guard !reduceMotion, role == .user else { return .opacity }
        return .opacity.combined(with: .move(edge: .bottom))
    }

    /// Disengage following only on an actual upward scroll (offset decrease) —
    /// content growth also increases the bottom distance, and reacting to that
    /// would break following on every big streamed chunk. Re-engage within 40pt
    /// of the bottom. State writes happen only on transitions.
    @ViewBuilder
    private func trackingBottomPin(_ content: some View) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: ScrollPin.self, of: { geometry in
                ScrollPin(
                    offset: geometry.contentOffset.y.rounded(),
                    bottomDistance: (geometry.contentSize.height - geometry.containerSize.height - geometry.contentOffset.y).rounded()
                )
            }, action: { old, new in
                if new.bottomDistance <= 40 {
                    if !pinnedToBottom { pinnedToBottom = true }
                } else if new.offset < old.offset - 4 {
                    if pinnedToBottom { pinnedToBottom = false }
                }
            })
        } else {
            content // macOS 14: always follow (previous behavior)
        }
    }

    private func newMessagesPill(_ proxy: ScrollViewProxy) -> some View {
        let dark = scheme == .dark
        return Button {
            showNewMessagesPill = false
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text("New messages")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(dark ? Theme.color("#f5f5f7") : Theme.color("#1d1d1f"))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 13)
            .background(
                dark ? Theme.color("#2C2C30").opacity(0.95) : Theme.color("#FCFCFE").opacity(0.97),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(
                dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10),
                lineWidth: 0.5
            ))
            .shadow(
                color: dark ? .black.opacity(0.4) : Theme.color("#282850").opacity(0.18),
                radius: 12, y: 8
            )
        }
        .buttonStyle(.plain)
    }

    private struct ScrollPin: Equatable {
        var offset: CGFloat
        var bottomDistance: CGFloat
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TranscriptWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 680
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HeaderWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 680
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Equatable so unchanged rows skip body re-evaluation entirely during
/// streaming ticks and keystrokes — no markdown segmentation, no
/// attributed-string rebuilds, no measurement.
private struct MessageRow: View, Equatable {
    let message: ChatMessage
    let showCaret: Bool
    let bubbleMaxWidth: CGFloat
    /// Nil unless this message contains a ⌘F hit. Part of ==, so a row repaints
    /// when its own highlights change and stays gated otherwise.
    var find: MessageFind?
    /// Delta 4 streaming fade. Also part of ==: the fade advances on ticks where
    /// `message.text` does NOT change (running out after the last commit), and
    /// without this the row would stay gated and the head would never settle.
    var reveal: TextReveal?
    /// Non-nil only for the streaming row while it has NO text yet: the label the
    /// waiting indicator pulses ("Thinking…", or the provider's latest `.status`).
    /// Part of == so a status change repaints exactly this row.
    var waitingStatus: String?
    /// Ignored by ==: it captures only stable references (store + message id).
    var onFork: () -> Void = {}
    /// Likewise ignored by ==. Resolves at click time to the text that has
    /// ARRIVED, which differs from `message.text` while the typewriter is still
    /// revealing this row — Copy promises the whole response.
    var fullText: () -> String = { "" }

    @AppStorage("bubbleStyle") private var bubbleStyleRaw = BubbleStyle.accentTint.rawValue
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    /// Single-text-view rows (user bubble, activity, error) render one string,
    /// so the message's occurrence numbering IS the view's.
    private var textFind: TextFind? {
        find.map { TextFind(query: $0.query, active: $0.activeOccurrence) }
    }

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.showCaret == rhs.showCaret
            && lhs.find == rhs.find
            && lhs.reveal == rhs.reveal
            && lhs.waitingStatus == rhs.waitingStatus
            && abs(lhs.bubbleMaxWidth - rhs.bubbleMaxWidth) < 0.5
    }

    var body: some View {
        switch message.role {
        case .user:
            let style = BubbleStyle(rawValue: bubbleStyleRaw) ?? .accentTint
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if !message.attachments.isEmpty {
                        ForEach(message.attachments) { attachment in
                            Label(attachment.filename, systemImage: "paperclip")
                                .font(.system(size: 11))
                                .foregroundStyle(style == .accentFill
                                    ? Theme.contrastingForeground(on: accentHex).opacity(0.75)
                                    : Color.secondary)
                        }
                    }
                    if !message.text.isEmpty {
                        SelectableText(
                            attributed: MarkdownRenderer.plain(
                                message.text,
                                color: Theme.bubbleForegroundNSColor(style: style, accentHex: accentHex)
                            ),
                            find: textFind
                        )
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(
                    Theme.bubbleFill(style: style, accentHex: accentHex, dark: scheme == .dark),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            // Before the first token the row has nothing but a caret to show, and
            // a Codex cold start plus silent reasoning can hold that state for
            // tens of seconds — which reads as a frozen app. Pulse a status
            // instead until real text arrives.
            if let waitingStatus, message.text.isEmpty {
                WaitingIndicator(status: waitingStatus)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    AssistantMessageView(
                        text: message.text, showCaret: showCaret, find: find, reveal: reveal
                    )
                    // Always visible once the response is complete; occupies its
                    // space during streaming (opacity only) so finishing never
                    // reflows the transcript.
                    if !message.text.isEmpty {
                        HStack(spacing: 12) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fullText(), forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .help("Copy the whole response")
                            Button(action: onFork) {
                                Label("Fork", systemImage: "arrow.triangle.branch")
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .help("Start a new conversation from this point")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .opacity(showCaret ? 0 : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fullText(), forType: .string)
                    }
                    Button("Fork Here", action: onFork)
                }
            }
        case .activity:
            Label { Text(FindHighlight.paint(message.text, find: textFind)) } icon: {
                Image(systemName: "sparkles")
            }
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label { Text(FindHighlight.paint(message.text, find: textFind)) } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What an empty streaming row shows while the network turn has produced no text
/// yet: a pulsing status plus, once the wait is long enough to read as a hang,
/// an elapsed counter. The pulse is a repeatForever opacity animation — CA-driven
/// per the caret rule, so no tick ever re-evaluates SwiftUI. Replaced by the
/// normal caret/text rendering the moment the first characters commit.
private struct WaitingIndicator: View {
    let status: String
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @State private var pulsing = false
    @State private var startedAt = Date()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.color(accentHex))
                .frame(width: 7, height: 7)
                .opacity(pulsing ? 0.25 : 1)
            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .opacity(pulsing ? 0.55 : 1)
            ElapsedLabel(since: startedAt)
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

/// "24s" beside the waiting status — appears only after 8 s, when slow starts
/// needing reassurance separate from ordinary latency. A 1 Hz TimelineView on
/// its own leaf view: seeded from a stable @State date, never `.now` (which
/// would re-create the schedule on every evaluation — the trap the caret rule
/// exists for), so a tick re-evaluates nothing but this label.
private struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(since))
            if seconds >= 8 {
                Text("\(seconds)s")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
