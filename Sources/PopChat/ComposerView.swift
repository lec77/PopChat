import SwiftUI
import KeyboardShortcuts

/// Attachment state lives here so drops (handled at the panel root) and the
/// composer share it without the root view observing keystrokes.
@MainActor
final class ComposerModel: ObservableObject {
    @Published var pendingAttachments: [Attachment] = []
    @Published var attachNotice: String?

    func handleFiles(_ urls: [URL]) {
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

    /// ⌘V with a file or image on the pasteboard attaches it; plain text never
    /// reaches this (the Edit menu handles it).
    func handlePasteboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            handleFiles(urls)
            return
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
        }
    }

    func remove(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        if pendingAttachments.isEmpty { attachNotice = nil }
    }

    func clear() {
        pendingAttachments = []
        attachNotice = nil
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
}

/// The input area: capsule field, slash-command popup, attachment chips, hint
/// row. Owns all transient typing state so keystrokes invalidate only this
/// subtree — never the transcript above it.
struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    let shortcutStore: ShortcutStore
    let isStreaming: Bool
    let isEmptyChat: Bool
    let focusBump: Int
    let onSend: (String, [Attachment]) -> Void
    let onStop: () -> Void
    let onFocusRequest: () -> Void

    @State private var draft = ""
    @State private var completionIndex = 0
    @AppStorage("webSearchEnabled") private var webEnabled = true
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { Theme.color(accentHex) }

    var body: some View {
        VStack(spacing: 8) {
            if !completionCandidates.isEmpty {
                slashCard
                    .transition(.opacity)
            }
            if !model.pendingAttachments.isEmpty || model.attachNotice != nil {
                attachCard
                    .transition(.opacity)
            }
            inputCapsule
            if isEmptyChat {
                hintRow
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.12), value: completionCandidates.isEmpty)
        .animation(.easeOut(duration: 0.12), value: model.pendingAttachments.count)
        .animation(.easeOut(duration: 0.12), value: model.attachNotice)
        .onAppear { inputFocused = true }
        .onChange(of: focusBump) { _, _ in inputFocused = true }
        .onChange(of: draft) { _, _ in completionIndex = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .popChatAttachPasteboard)) { _ in
            model.handlePasteboard()
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
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.pendingAttachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                model.remove(attachment.id)
                            }
                        }
                    }
                }
            }
            if let notice = model.attachNotice {
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

    private func attachViaPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            model.handleFiles(panel.urls)
        }
        onFocusRequest()
    }

    // MARK: - Input capsule

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
            if isStreaming {
                Button(action: onStop) {
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
        !draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.pendingAttachments.isEmpty
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
        guard !isStreaming else { return }
        onSend(draft, model.pendingAttachments)
        draft = ""
        model.clear()
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
