import SwiftUI
import KeyboardShortcuts
import ServiceManagement

/// System Settings-style window: toolbar tabs over a grouped form per tab.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, providers, webSearch, commands, hotkey

        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: "General"
            case .providers: "Providers"
            case .webSearch: "Web Search"
            case .commands: "Commands"
            case .hotkey: "Hotkey"
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .providers: "key"
            case .webSearch: "globe"
            case .commands: "slash.circle"
            case .hotkey: "keyboard"
            }
        }
    }

    @ObservedObject var store: ProviderStore
    @ObservedObject var shortcutStore: ShortcutStore
    @State private var tab: Tab = .general
    @State private var apiKeyDraft = ""
    @State private var searchKeyDraft = ""
    @State private var systemPromptDraft = ChatStore.systemPrompt
    @AppStorage("searchEngine") private var searchEngine = SearchEngineChoice.duckduckgo.rawValue
    @AppStorage("webSearchEnabled") private var webEnabled = true
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @AppStorage("bubbleStyle") private var bubbleStyleRaw = BubbleStyle.accentTint.rawValue
    @AppStorage("streamingMode") private var streamingModeRaw = StreamingMode.perCharacter.rawValue
    @AppStorage("liquidGlass") private var liquidGlass = true
    @AppStorage("panelTint") private var panelTint = -1.0
    @AppStorage("appearance") private var appearanceRaw = AppearanceChoice.auto.rawValue
    @FocusState private var focusedCommandName: UUID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    // ChatGPT sign-in state. Auth itself lives in ChatGPTAuth (SecretStore-backed);
    // `chatGPTAuthTick` just forces re-render after sign-in/out completes.
    @State private var chatGPTSignInTask: Task<Void, Never>?
    @State private var chatGPTAuthError: String?
    @State private var chatGPTAuthTick = false
    // Bumped on every sign-in/cancel so a stale attempt can't clobber the shared
    // UI state of a newer one (cancel-then-reclick race).
    @State private var chatGPTSignInGeneration = 0
    /// Custom provider awaiting delete confirmation (removal drops its API key).
    @State private var providerPendingDeletion: UUID?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .general: generalTab
                case .providers: providersTab
                case .webSearch: webSearchTab
                case .commands: commandsTab
                case .hotkey: hotkeyTab
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: 620)
        .onAppear {
            apiKeyDraft = store.currentKey()
            searchKeyDraft = currentSearchKey()
        }
        .onChange(of: store.selectedID) { _, _ in apiKeyDraft = store.currentKey() }
        .onChange(of: searchEngine) { _, _ in searchKeyDraft = currentSearchKey() }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 19))
                        Text(item.label)
                            .font(.system(size: 10.5))
                    }
                    .frame(width: 76, height: 52)
                    .background(
                        tab == item ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch PopChat at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = "Couldn't update login item: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let error = loginItemError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                appearanceRow
                accentRow
                Picker("Your message style", selection: $bubbleStyleRaw) {
                    ForEach(BubbleStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                liquidGlassRow
                panelTintRow
                Picker("Streaming text", selection: $streamingModeRaw) {
                    ForEach(StreamingMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                previewRow
            } header: {
                Text("Chat Style")
            } footer: {
                Text("Applies to your messages in the panel. Streaming text: Per-character fades in glyph by glyph, Per-sentence commits a sentence at a time. Defaults: Accent tint, Blue, Per-character streaming. Panel tint defaults to the system glass appearance; the slider overrides it for PopChat only. Reduce Transparency always wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Auto / Light / Dark (4f). Applied through NSApp.appearance so every
    /// window flips together; Auto (nil) tracks the system live.
    private var appearanceRow: some View {
        Picker("Appearance", selection: $appearanceRaw) {
            ForEach(AppearanceChoice.allCases) { choice in
                Text(choice.label).tag(choice.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: appearanceRaw) { _, _ in
            AppearanceChoice.applyCurrent()
        }
    }

    private var accentRow: some View {
        HStack {
            Text("Accent color")
            Spacer()
            ForEach(Theme.accentOptions, id: \.self) { hex in
                let selected = hex == accentHex
                Button {
                    accentHex = hex
                } label: {
                    Circle()
                        .fill(Theme.color(hex))
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .overlay(
                            Circle()
                                .strokeBorder(Theme.color(hex), lineWidth: 2)
                                .opacity(selected ? 1 : 0)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(hex)
            }
        }
    }

    private var liquidGlassRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Liquid glass", isOn: reduceTransparency ? .constant(false) : $liquidGlass)
                .disabled(reduceTransparency)
            Text(reduceTransparency
                ? "Off because Reduce Transparency is enabled in System Settings."
                : "Turn off for a solid panel and lower GPU use")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // labelsHidden is load-bearing: a bare Slider reserves an EMPTY label slot
    // inside its frame, which squeezed the track and stranded "Clear" mid-row.
    private var panelTintRow: some View {
        let disabled = !liquidGlass || reduceTransparency
        return HStack(spacing: 8) {
            Text("Panel tint")
            Spacer()
            Text("Clear")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Slider(
                value: Binding(
                    get: { panelTint < 0 ? 0.5 : panelTint },
                    set: { panelTint = $0 }
                ),
                in: 0...1
            )
            .labelsHidden()
            .frame(width: 180)
            Text("Tinted")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private var previewRow: some View {
        let style = BubbleStyle(rawValue: bubbleStyleRaw) ?? .accentTint
        return HStack {
            Text("Preview")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Looks good — ship it")
                .font(.system(size: 13))
                .foregroundStyle(Theme.bubbleForeground(style: style))
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(
                    Theme.bubbleFill(style: style, accentHex: accentHex, dark: scheme == .dark),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }

    // MARK: - Providers

    private var providersTab: some View {
        Form {
            Section {
                providerList
                HStack {
                    Button {
                        store.addCustom()
                    } label: {
                        Label("Add Custom Provider", systemImage: "plus")
                    }
                    Spacer()
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Presets stay; providers you add can be renamed and removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let index = store.providers.firstIndex(where: { $0.id == store.selectedID }) {
                    if store.providers[index].kind == .chatGPT {
                        chatGPTAuthRows
                    } else {
                        if !store.providers[index].isPreset {
                            TextField("Name", text: $store.providers[index].name)
                        }
                        TextField("Base URL", text: $store.providers[index].baseURL)
                            .help("Include /v1 where the provider requires it; local servers (Ollama, LM Studio) need no key.")
                        SecureField("API Key", text: $apiKeyDraft)
                            .onChange(of: apiKeyDraft) { _, newValue in
                                store.setKey(newValue)
                            }
                    }
                    modelRow
                    if let error = store.modelFetchError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text(store.selectedProvider?.name ?? "Provider")
            } footer: {
                Text("Keys are stored locally in Application Support, never synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("~/Library/Application Support/PopChat/secrets.json, user-only permissions.")
            }
        }
        .confirmationDialog(
            "Remove “\(store.providers.first { $0.id == providerPendingDeletion }?.name ?? "")”?",
            isPresented: Binding(get: { providerPendingDeletion != nil }, set: { if !$0 { providerPendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Provider", role: .destructive) {
                if let id = providerPendingDeletion { store.remove(id) }
                providerPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { providerPendingDeletion = nil }
        } message: {
            Text("Its API key and fetched model list are deleted too.")
        }
    }

    /// Every provider, preset and added, in one list — the switcher only shows the
    /// configured ones, so this is the single place an added provider is visible
    /// (and the only place it can be deleted).
    private var providerList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.providers.enumerated()), id: \.element.id) { offset, provider in
                if offset > 0 {
                    Divider().opacity(0.5)
                }
                providerRow(provider)
            }
        }
        .padding(.vertical, -2)
    }

    private func providerRow(_ provider: Provider) -> some View {
        let selected = provider.id == store.selectedID
        return HStack(spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                Text(providerSubtitle(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !provider.isPreset {
                Button {
                    providerPendingDeletion = provider.id
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove this provider")
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedID = provider.id }
    }

    private func providerSubtitle(_ provider: Provider) -> String {
        if provider.kind == .chatGPT {
            _ = chatGPTAuthTick // re-read the row when sign-in state changes
            return ChatGPTAuth.isSignedIn ? "Signed in · your ChatGPT plan" : "Not signed in"
        }
        if provider.baseURL.isEmpty { return "No base URL yet" }
        return provider.baseURL
    }

    /// Sign-in UI for the ChatGPT provider — replaces the Base URL/API key fields.
    /// Uses your ChatGPT Plus/Pro subscription via the same OAuth flow as Codex CLI.
    @ViewBuilder
    private var chatGPTAuthRows: some View {
        let _ = chatGPTAuthTick // re-evaluate when sign-in state changes
        if ChatGPTAuth.isSignedIn {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Signed in with ChatGPT")
                        let detail = [ChatGPTAuth.accountEmail, ChatGPTAuth.planLabel]
                            .compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Sign Out", role: .destructive) {
                    ChatGPTAuth.signOut()
                    chatGPTAuthTick.toggle()
                }
            }
        } else if chatGPTSignInTask != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the browser sign-in…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    chatGPTSignInGeneration += 1
                    chatGPTSignInTask?.cancel()
                    chatGPTSignInTask = nil
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use your ChatGPT subscription")
                    Text("Opens chatgpt.com to authorize. Works with Plus/Pro; usage counts against your plan's limits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign in with ChatGPT") {
                    chatGPTAuthError = nil
                    chatGPTSignInGeneration += 1
                    let generation = chatGPTSignInGeneration
                    chatGPTSignInTask = Task {
                        do {
                            try await ChatGPTAuth.signIn()
                        } catch is CancellationError {
                            // user cancelled — no error row
                        } catch let error as URLError where error.code == .cancelled {
                            // cancelled during the token-exchange request (URLSession
                            // throws URLError, not CancellationError) — also silent
                        } catch {
                            if generation == chatGPTSignInGeneration {
                                chatGPTAuthError = error.localizedDescription
                            }
                        }
                        // Only the latest attempt owns the shared UI state.
                        guard generation == chatGPTSignInGeneration else { return }
                        chatGPTSignInTask = nil
                        chatGPTAuthTick.toggle()
                        if ChatGPTAuth.isSignedIn {
                            store.applyChatGPTCatalog()
                        }
                    }
                }
            }
        }
        if let error = chatGPTAuthError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Web Search

    private var webSearchTab: some View {
        Form {
            Section {
                Toggle("Web access available to the model", isOn: $webEnabled)
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngineChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                if let account = SearchEngineChoice(rawValue: searchEngine)?.apiKeyAccount {
                    SecureField("Search API Key", text: $searchKeyDraft)
                        .onChange(of: searchKeyDraft) { _, newValue in
                            SecretStore.set(newValue, account: account)
                        }
                }
            } footer: {
                Text("The model decides when to search (max 5 tool rounds).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("web_search + fetch_url tools. Provider-native uses OpenRouter's server-side plugin and only applies when OpenRouter is the active provider; other choices fall back to DuckDuckGo with a visible notice.")
            }
        }
    }

    // MARK: - Commands

    // Real editors (4e): prompts leave the Form's label/value pattern — a
    // vertical-axis TextField rendered the template as a right-aligned trailing
    // "value" that grew with content. Fixed-height TextEditors in quaternary
    // wells scroll their own text; the Form scrolls the page.
    private var commandsTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    editorWell {
                        TextEditor(text: $systemPromptDraft)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .frame(height: 148)
                    }
                    Button("Reset to Default") {
                        systemPromptDraft = ChatStore.defaultSystemPrompt
                    }
                    .disabled(systemPromptDraft == ChatStore.defaultSystemPrompt)
                }
                .onChange(of: systemPromptDraft) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "systemPrompt")
                }
            } header: {
                Text("System Prompt")
            } footer: {
                Text("Sent with every conversation. The default teaches the model PopChat's pasteable-block format; clear it to send no system prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Content the model wraps in <pasteable title=\"…\"> … </pasteable> tags is rendered as a copyable card in the transcript.")
            }
            Section {
                ForEach($shortcutStore.shortcuts) { $shortcut in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 2) {
                            Text("/")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                            TextField("name", text: $shortcut.name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .focused($focusedCommandName, equals: shortcut.id)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                                )
                                .frame(width: 140)
                            Spacer()
                            Button(role: .destructive) {
                                shortcutStore.remove(id: shortcut.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Delete command")
                        }
                        editorWell {
                            TextEditor(text: $shortcut.template)
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .frame(height: 56)
                                .overlay(alignment: .topLeading) {
                                    if shortcut.template.isEmpty {
                                        Text("Prompt template — {input} marks where your text goes")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.tertiary)
                                            .padding(.leading, 5)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Command…") {
                    shortcutStore.add()
                    // Focus lands after the new row exists in the hierarchy.
                    let newID = shortcutStore.shortcuts.last?.id
                    DispatchQueue.main.async { focusedCommandName = newID }
                }
            } footer: {
                Text("Type “/name your text” in the chat field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The compact form is shown in the transcript; the expanded template is what the model receives.")
            }
        }
    }

    /// Quaternary well the fixed-height prompt editors sit in.
    private func editorWell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }

    // MARK: - Hotkey

    private var hotkeyTab: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle PopChat:", name: .togglePopChat)
            } footer: {
                Text("If ⌥Space is taken by another app, unbind it there or record a different shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var modelRow: some View {
        HStack(spacing: 6) {
            TextField("Model", text: Binding(
                get: { store.currentModel },
                set: { store.setModel($0) }
            ))
            let models = store.knownModels[store.selectedID] ?? []
            Menu {
                ForEach(models, id: \.self) { model in
                    Button(model) { store.setModel(model) }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(models.isEmpty)
            .help(models.isEmpty ? "Fetch the model list first" : "Pick from fetched models")
            Button {
                Task { await store.fetchModels() }
            } label: {
                if store.isFetchingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .fixedSize()
            .help("Fetch model list from the provider")
        }
    }

    private func currentSearchKey() -> String {
        guard let account = SearchEngineChoice(rawValue: searchEngine)?.apiKeyAccount else { return "" }
        return SecretStore.get(account: account) ?? ""
    }
}
