import SwiftUI
import MarkdownUI

extension Notification.Name {
    static let popChatOpenSettings = Notification.Name("PopChatOpenSettings")
}

struct ChatView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: ChatStore
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var shortcutStore: ShortcutStore
    var onClose: () -> Void

    @State private var draft = ""
    @State private var completionIndex = 0
    @State private var pendingAttachments: [Attachment] = []
    @State private var attachNotice: String?
    @State private var dropTargeted = false
    @AppStorage("webSearchEnabled") private var webEnabled = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            if !pendingAttachments.isEmpty || attachNotice != nil {
                attachmentBar
                Divider()
            }
            if !completionCandidates.isEmpty {
                shortcutPopup
                Divider()
            }
            inputBar
        }
        .frame(minWidth: 480, minHeight: 320)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("PopChat")
                .font(.headline)
            modelSwitcher
            Spacer()
            historyMenu
            Button {
                store.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("New chat (⌘N)")
            Button {
                state.pinned.toggle()
            } label: {
                Image(systemName: state.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .help(state.pinned ? "Unpin — hide when clicking away" : "Keep on top")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var modelSwitcher: some View {
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
            HStack(spacing: 3) {
                Text(switcherLabel)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var historyMenu: some View {
        Menu {
            if store.recent.isEmpty {
                Text("No saved chats")
            }
            ForEach(store.recent) { meta in
                Button {
                    store.loadConversation(meta.id)
                } label: {
                    HStack {
                        Text(meta.title)
                        if meta.id == store.conversationID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Recent chats")
    }

    private var switcherLabel: String {
        let provider = providerStore.selectedProvider?.name ?? "No provider"
        let model = providerStore.currentModel
        return "\(provider) · \(model.isEmpty ? "no model" : model)"
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.messages.isEmpty {
                        Text("Ask anything — “/” for shortcuts, globe toggles web access.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    ForEach(store.messages) { message in
                        MessageRow(message: message, isStreaming: store.isStreaming)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: store.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Slash-command completion

    private var completionCandidates: [PromptShortcut] {
        guard draft.hasPrefix("/"), !draft.contains(" ") else { return [] }
        let query = String(draft.dropFirst()).lowercased()
        return shortcutStore.shortcuts.filter {
            query.isEmpty || $0.name.lowercased().hasPrefix(query)
        }
    }

    private var shortcutPopup: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(completionCandidates.enumerated()), id: \.element.id) { index, shortcut in
                HStack(spacing: 8) {
                    Text("/" + shortcut.name)
                        .fontWeight(.medium)
                    Text(shortcut.template.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    index == completionIndex ? Color.accentColor.opacity(0.2) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .onTapGesture { complete(with: shortcut) }
            }
        }
        .padding(8)
    }

    private func complete(with shortcut: PromptShortcut? = nil) {
        let candidates = completionCandidates
        guard let chosen = shortcut ?? (candidates.indices.contains(completionIndex) ? candidates[completionIndex] : candidates.first) else { return }
        draft = "/" + chosen.name + " "
    }

    // MARK: - Attachments

    private var attachmentBar: some View {
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
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button(action: attachViaPicker) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .help("Attach files (or drag & drop, or paste)")
            Button {
                webEnabled.toggle()
            } label: {
                Image(systemName: "globe")
                    .foregroundStyle(webEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(webEnabled ? "Web access on — model may search and read pages" : "Web access off")
            TextField("Message…  (“/” for shortcuts)", text: $draft)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(submit)
                .onKeyPress(phases: .down) { press in
                    guard press.modifiers.contains(.command), press.key == KeyEquivalent("v") else {
                        return .ignored
                    }
                    return handlePasteboard() ? .handled : .ignored
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
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func submit() {
        guard !store.isStreaming else { return }
        store.send(draft, attachments: pendingAttachments)
        draft = ""
        pendingAttachments = []
        attachNotice = nil
    }
}

private struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration.content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(.vertical, 2)
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    @State private var showNote = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
            Text(attachment.filename)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 160)
            if let note = attachment.note {
                Button {
                    showNote.toggle()
                } label: {
                    Image(systemName: attachment.noteKind == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption2)
                        .foregroundStyle(attachment.noteKind == .warning ? Color.orange : Color.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var icon: String {
        if case .image = attachment.content { return "photo" }
        return "doc.text"
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { attachment in
                        Label(attachment.filename, systemImage: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Group {
                if message.text.isEmpty && isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                } else {
                    Markdown(message.text)
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            CodeBlockView(configuration: configuration)
                        }
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .activity:
            Label(message.text, systemImage: "wand.and.rays")
                .font(.caption)
                .foregroundStyle(.secondary)
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
