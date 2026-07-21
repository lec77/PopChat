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
    @State private var actionPillHovered = false
    @State private var transcriptWidth: CGFloat = 680
    /// Streaming follows the bottom only while the user is there; an upward
    /// scroll disengages so streaming never yanks the view.
    @State private var pinnedToBottom = true
    @State private var showNewMessagesPill = false
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.color(accentHex) }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            if store.messages.isEmpty {
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
        .frame(minWidth: 480, minHeight: store.messages.isEmpty && !draftEditorShown ? nil : 320)
        .dropDestination(for: URL.self) { urls, _ in
            composerModel.handleFiles(urls)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .onExitCommand { onClose() }
        .onChange(of: draftEditorShown) { _, shown in
            // The editor needs real height even when the chat is empty; the
            // compact preference resumes reporting when the editor closes.
            if store.messages.isEmpty, shown {
                onCompactHeightChange(440)
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if !draftEditorShown {
                if store.messages.isEmpty {
                    pillsRow
                        .padding(12)
                        .background(WindowDragStrip())
                } else {
                    transcriptZone
                }
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

    private var pillsRow: some View {
        HStack {
            modelPill
            Spacer()
            actionPill
        }
    }

    private var modelPill: some View {
        Menu {
            Section("Provider") {
                ForEach(providerStore.configuredProviders) { provider in
                    Button {
                        providerStore.selectedID = provider.id
                    } label: {
                        HStack {
                            Text(provider.name)
                            if provider.id == providerStore.selectedID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if providerStore.configuredProviders.count < providerStore.providers.count {
                    Button("Set up more providers…") {
                        NotificationCenter.default.post(name: .popChatOpenSettings, object: nil)
                    }
                }
            }
            Section("Model") {
                let models = providerStore.knownModels[providerStore.selectedID] ?? []
                ForEach(models, id: \.self) { model in
                    Button {
                        providerStore.setModel(model)
                    } label: {
                        HStack {
                            Text(model)
                            if model == providerStore.currentModel {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Button(models.isEmpty ? "Fetch models" : "Refresh models") {
                    Task { await providerStore.fetchModels() }
                }
                .disabled(providerStore.isFetchingModels)
            }
        } label: {
            HStack(spacing: 4) {
                Text(switcherLabel)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            // Whole pill is clickable — plain-style controls only hit-test
            // opaque pixels without an explicit content shape.
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .pillBackground(hovered: modelPillHovered)
        .onHover { modelPillHovered = $0 }
    }

    private var actionPill: some View {
        HStack(spacing: 14) {
            Button {
                historyShown.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .background(historyShown ? Color.primary.opacity(0.14) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Recent chats")
            .popover(isPresented: $historyShown, arrowEdge: .bottom) {
                HistoryPopover(store: store)
            }
            Button {
                store.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
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
                    .frame(width: 24, height: 24)
                    .background(state.pinned ? Color.primary.opacity(0.14) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(state.pinned ? "Unpin — hide when clicking away" : "Keep on top")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.pinned)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .pillBackground(hovered: actionPillHovered)
        .onHover { actionPillHovered = $0 }
    }

    private var switcherLabel: String {
        let provider = providerStore.selectedProvider?.name ?? "No provider"
        let model = providerStore.currentModel
        return "\(provider) · \(model.isEmpty ? "no model" : model)"
    }

    // MARK: - Transcript

    private var transcriptZone: some View {
        let streamingID = store.isStreaming ? store.messages.last(where: { $0.role == .assistant })?.id : nil
        let bubbleMaxWidth = max(220, (transcriptWidth - 32) * 0.78)
        return ScrollViewReader { proxy in
            trackingBottomPin(
                ScrollView {
                    // Plain VStack, deliberately: LazyVStack re-estimates row heights as
                    // items load during scrolling, and with variable-height text rows the
                    // fluctuating content height fights NSScrollView's position
                    // adjustments — an infinite re-layout loop that froze the app.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.messages) { message in
                            MessageRow(
                                message: message,
                                showCaret: message.id == streamingID,
                                bubbleMaxWidth: bubbleMaxWidth,
                                onFork: { store.fork(at: message.id) }
                            )
                            .equatable()
                            .transition(rowTransition(for: message.role))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.top, 56)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
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
                pillsRow
                    .padding(12)
                    .background(WindowDragStrip())
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
        }
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
        Button {
            showNewMessagesPill = false
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text("New messages")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.color("#f5f5f7"))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 13)
            .background(Theme.color("#2C2C30").opacity(0.95), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
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

/// Equatable so unchanged rows skip body re-evaluation entirely during
/// streaming ticks and keystrokes — no markdown segmentation, no
/// attributed-string rebuilds, no measurement.
private struct MessageRow: View, Equatable {
    let message: ChatMessage
    let showCaret: Bool
    let bubbleMaxWidth: CGFloat
    /// Ignored by ==: it captures only stable references (store + message id).
    var onFork: () -> Void = {}

    @AppStorage("bubbleStyle") private var bubbleStyleRaw = BubbleStyle.accentTint.rawValue
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.showCaret == rhs.showCaret
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
                                .foregroundStyle(style == .accentFill ? Color.white.opacity(0.75) : .secondary)
                        }
                    }
                    if !message.text.isEmpty {
                        SelectableText(attributed: MarkdownRenderer.plain(
                            message.text,
                            color: style == .accentFill ? .white : .labelColor
                        ))
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
            VStack(alignment: .leading, spacing: 4) {
                AssistantMessageView(text: message.text, showCaret: showCaret)
                // Always visible once the response is complete; occupies its
                // space during streaming (opacity only) so finishing never
                // reflows the transcript.
                if !message.text.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
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
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
                Button("Fork Here", action: onFork)
            }
        case .activity:
            Label(message.text, systemImage: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
