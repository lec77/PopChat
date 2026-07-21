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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    // ChatGPT sign-in state. Auth itself lives in ChatGPTAuth (SecretStore-backed);
    // `chatGPTAuthTick` just forces re-render after sign-in/out completes.
    @State private var chatGPTSignInTask: Task<Void, Never>?
    @State private var chatGPTAuthError: String?
    @State private var chatGPTAuthTick = false

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
                Text("Applies to your messages in the panel. Defaults: Accent tint, Blue, Per-character streaming. Panel tint defaults to the system glass appearance; the slider overrides it for PopChat only. Reduce Transparency always wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                Picker("Provider", selection: $store.selectedID) {
                    ForEach(store.providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }

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

                HStack {
                    Button("Add Custom Provider") { store.addCustom() }
                    if store.selectedProvider?.isPreset == false {
                        Button("Remove", role: .destructive) { store.removeSelected() }
                    }
                }
            } footer: {
                Text("Keys are stored locally in Application Support, never synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("~/Library/Application Support/PopChat/secrets.json, user-only permissions.")
            }
        }
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
                    chatGPTSignInTask = Task {
                        do {
                            try await ChatGPTAuth.signIn()
                        } catch is CancellationError {
                            // user cancelled — no error row
                        } catch {
                            chatGPTAuthError = error.localizedDescription
                        }
                        chatGPTSignInTask = nil
                        chatGPTAuthTick.toggle()
                        await store.fetchModels()
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

    private var commandsTab: some View {
        Form {
            Section {
                TextField(
                    "System prompt sent at the start of every conversation",
                    text: $systemPromptDraft,
                    axis: .vertical
                )
                .lineLimit(4...12)
                .font(.callout)
                .onChange(of: systemPromptDraft) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "systemPrompt")
                }
                Button("Reset to Default") {
                    systemPromptDraft = ChatStore.defaultSystemPrompt
                }
                .disabled(systemPromptDraft == ChatStore.defaultSystemPrompt)
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("/").foregroundStyle(.secondary)
                            TextField("name", text: $shortcut.name)
                                .frame(width: 140)
                            Spacer()
                            Button(role: .destructive) {
                                shortcutStore.remove(id: shortcut.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("Prompt template — {input} marks where your text goes", text: $shortcut.template, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.callout)
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Shortcut") { shortcutStore.add() }
            } footer: {
                Text("Type “/name your text” in the chat field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The compact form is shown in the transcript; the expanded template is what the model receives.")
            }
        }
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
