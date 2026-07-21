import SwiftUI
import KeyboardShortcuts

extension Notification.Name {
    static let popChatOpenSettings = Notification.Name("PopChatOpenSettings")
    /// Posted by FloatingPanel when ⌘V carries files/an image to attach.
    static let popChatAttachPasteboard = Notification.Name("PopChatAttachPasteboard")
}

/// The "Glass" panel: translucent rounded shell, header chrome as overlay pills
/// the transcript scrolls under, and a floating capsule input at the bottom.
struct ChatView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: ChatStore
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var shortcutStore: ShortcutStore
    var onClose: () -> Void
    /// Reports the natural content height while the chat is empty, so the panel
    /// can shrink to just chrome + input.
    var onCompactHeightChange: (CGFloat) -> Void = { _ in }

    @State private var draft = ""
    @State private var completionIndex = 0
    @State private var pendingAttachments: [Attachment] = []
    @State private var attachNotice: String?
    @State private var dropTargeted = false
    @State private var historyShown = false
    @State private var modelPillHovered = false
    @State private var actionPillHovered = false
    @State private var transcriptWidth: CGFloat = 680
    /// Streaming follows the bottom only while the user is there; an upward
    /// scroll disengages so streaming never yanks the view.
    @State private var pinnedToBottom = true
    @State private var showNewMessagesPill = false
    @AppStorage("webSearchEnabled") private var webEnabled = true
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @FocusState private var inputFocused: Bool
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
        .frame(minWidth: 480, minHeight: store.messages.isEmpty ? nil : 320)
        .dropDestination(for: URL.self) { urls, _ in
            handleFiles(urls)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .onExitCommand { onClose() }
        .onAppear { inputFocused = true }
        .onChange(of: state.focusBump) { _, _ in inputFocused = true }
        .onChange(of: draft) { _, _ in completionIndex = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .popChatAttachPasteboard)) { _ in
            _ = handlePasteboard()
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if store.messages.isEmpty {
                pillsRow
                    .padding(12)
            } else {
                transcriptZone
            }
            bottomArea
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            if store.messages.isEmpty {
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
        ScrollViewReader { proxy in
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
                                showCaret: store.isStreaming && message.id == store.messages.last(where: { $0.role == .assistant })?.id,
                                bubbleMaxWidth: max(220, (transcriptWidth - 32) * 0.78)
                            )
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
                pillsRow.padding(12)
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
            // Text ticks arrive ~30×/s while streaming: the follow-scroll must NOT
            // be animated, or each tick restarts an animation and layout never
            // goes idle (this froze the app). Animate only on new rows.
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

    // MARK: - Slash-command completion

    private var completionCandidates: [PromptShortcut] {
        guard draft.hasPrefix("/"), !draft.contains(" ") else { return [] }
        let query = String(draft.dropFirst()).lowercased()
        return shortcutStore.shortcuts.filter {
            query.isEmpty || $0.name.lowercased().hasPrefix(query)
        }
    }

    private var slashCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(completionCandidates.enumerated()), id: \.element.id) { index, shortcut in
                HStack(spacing: 8) {
                    Text("/" + shortcut.name)
                        .fontWeight(.medium)
                    Text(shortcut.template.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    index == completionIndex ? accent.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture { complete(with: shortcut) }
            }
        }
        .padding(6)
        .glassCard(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func complete(with shortcut: PromptShortcut? = nil) {
        let candidates = completionCandidates
        guard let chosen = shortcut ?? (candidates.indices.contains(completionIndex) ? candidates[completionIndex] : candidates.first) else { return }
        draft = "/" + chosen.name + " "
    }

    // MARK: - Attachments

    private var attachCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pendingAttachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                }
            }
            if let notice = attachNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(scheme == .dark ? Theme.warningOrange : Theme.warningTextLight)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func attachmentChip(_ attachment: Attachment) -> some View {
        AttachmentChip(attachment: attachment) {
            pendingAttachments.removeAll { $0.id == attachment.id }
            if pendingAttachments.isEmpty { attachNotice = nil }
        }
    }

    private func handleFiles(_ urls: [URL]) {
        attachNotice = nil
        for url in urls {
            Task {
                let result = await AttachmentLoader.load(url: url)
                switch result {
                case .success(let attachment):
                    pendingAttachments.append(attachment)
                    if let note = attachment.note, attachment.noteKind == .warning {
                        attachNotice = "\(attachment.filename): \(note)"
                    }
                    updateSizeWarning()
                case .failure(let error):
                    attachNotice = error.message
                }
            }
        }
    }

    private func updateSizeWarning() {
        let totalChars = pendingAttachments.reduce(0) { total, attachment in
            if case .text(let text) = attachment.content { return total + text.count }
            return total
        }
        if totalChars > 50_000 {
            attachNotice = "Attachments total ~\(totalChars / 4 / 1000)k tokens — may exceed smaller models' context windows."
        }
    }

    private func attachViaPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            handleFiles(panel.urls)
        }
        state.focusBump += 1
    }

    /// ⌘V with a file or image on the pasteboard attaches it; plain text pastes normally.
    private func handlePasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            handleFiles(urls)
            return true
        }
        if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) {
            attachNotice = nil
            switch AttachmentLoader.load(image: image, suggestedName: "pasted-image.jpg") {
            case .success(let attachment):
                pendingAttachments.append(attachment)
                updateSizeWarning()
            case .failure(let error):
                attachNotice = error.message
            }
            return true
        }
        return false
    }

    // MARK: - Input area

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if !completionCandidates.isEmpty {
                slashCard
                    .transition(.opacity)
            }
            if !pendingAttachments.isEmpty || attachNotice != nil {
                attachCard
                    .transition(.opacity)
            }
            inputCapsule
            if store.messages.isEmpty {
                hintRow
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.12), value: completionCandidates.isEmpty)
        .animation(.easeOut(duration: 0.12), value: pendingAttachments.count)
        .animation(.easeOut(duration: 0.12), value: attachNotice)
    }

    private var inputCapsule: some View {
        HStack(spacing: 10) {
            Button(action: attachViaPicker) {
                Image(systemName: "paperclip")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach files (or drag & drop, or paste)")
            Button {
                webEnabled.toggle()
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 16))
                    .foregroundStyle(webEnabled ? accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(webEnabled ? "Web access on — model may search and read pages" : "Web access off")
            TextField("Message…  (“/” for shortcuts)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit(submit)
                .onKeyPress(phases: .down) { press in
                    // ⌘V is handled earlier: FloatingPanel.performKeyEquivalent
                    // (attachables) or the Edit menu (plain text).
                    // Shift+Return inserts a newline at the cursor (Return sends).
                    if press.modifiers.contains(.shift), press.key == .return {
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                            editor.insertNewlineIgnoringFieldEditor(nil)
                            return .handled
                        }
                        return .ignored
                    }
                    return .ignored
                }
                .onKeyPress(.upArrow) {
                    guard !completionCandidates.isEmpty else { return .ignored }
                    completionIndex = max(0, completionIndex - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !completionCandidates.isEmpty else { return .ignored }
                    completionIndex = min(completionCandidates.count - 1, completionIndex + 1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard !completionCandidates.isEmpty else { return .ignored }
                    complete()
                    return .handled
                }
                .onKeyPress(.return) {
                    guard !completionCandidates.isEmpty else { return .ignored }
                    complete()
                    return .handled
                }
            if store.isStreaming {
                Button(action: store.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.stopRed)
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? accent : Color.primary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCard(Capsule())
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty || !pendingAttachments.isEmpty
    }

    private var hintRow: some View {
        Text("\(hotkeyLabel) toggles · ⇧↩ newline · Tab completes")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
    }

    private var hotkeyLabel: String {
        KeyboardShortcuts.getShortcut(for: .togglePopChat).map(String.init(describing:)) ?? "⌥Space"
    }

    private func submit() {
        guard !store.isStreaming else { return }
        store.send(draft, attachments: pendingAttachments)
        draft = ""
        pendingAttachments = []
        attachNotice = nil
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

private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    @State private var showNote = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(attachment.filename)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: 160)
            if let note = attachment.note {
                Button {
                    showNote.toggle()
                } label: {
                    Image(systemName: attachment.noteKind == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(attachment.noteKind == .warning ? Theme.warningOrange : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(note)
                .popover(isPresented: $showNote, arrowEdge: .bottom) {
                    Text(note)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: 320)
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
            in: Capsule()
        )
    }

    private var icon: String {
        if case .image = attachment.content { return "photo" }
        return "doc.text"
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let showCaret: Bool
    let bubbleMaxWidth: CGFloat

    @AppStorage("bubbleStyle") private var bubbleStyleRaw = BubbleStyle.accentTint.rawValue
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme

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
            AssistantMessageView(text: message.text, showCaret: showCaret)
                .frame(maxWidth: .infinity, alignment: .leading)
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
