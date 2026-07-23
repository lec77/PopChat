import AppKit
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
    @State private var tab: Tab
    @State private var searchKeyDraft = ""
    @State private var systemPromptDraft = ChatStore.systemPrompt
    @AppStorage("searchEngine") private var searchEngine = SearchEngineChoice.duckduckgo.rawValue
    @AppStorage("webSearchEnabled") private var webEnabled = true
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @AppStorage("customAccentColor") private var customAccentHex = ""
    @AppStorage("bubbleStyle") private var bubbleStyleRaw = BubbleStyle.accentTint.rawValue
    @AppStorage("streamingMode") private var streamingModeRaw = StreamingMode.perCharacter.rawValue
    @AppStorage("liquidGlass") private var liquidGlass = true
    @AppStorage("panelTint") private var panelTint = -1.0
    @AppStorage("appearance") private var appearanceRaw = AppearanceChoice.auto.rawValue
    @AppStorage(CodexAppServerClient.executablePathKey) private var codexExecutablePath = ""
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
    /// The one provider row disclosed for editing (delta 5, 7b). Nothing here
    /// touches `store.selectedID` — Settings is a catalog, the panel's pill owns
    /// what is live.
    @State private var editingID: UUID?
    /// Non-nil only from the design-QA harness, which needs a row already
    /// disclosed to render the editor band.
    private let initialEditingID: UUID?
    /// API-key draft, scoped to `editingID`. Reloaded on every expand; the old
    /// `apiKeyDraft` + `onChange(of: store.selectedID)` pair is exactly the
    /// coupling delta 5 removes.
    @State private var keyDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: ProviderStore, shortcutStore: ShortcutStore, tab: Tab = .general, editing: UUID? = nil) {
        self.store = store
        self.shortcutStore = shortcutStore
        _tab = State(initialValue: tab)
        initialEditingID = editing
    }

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
        .onAppear { searchKeyDraft = currentSearchKey() }
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
                Text("Applies to your messages in the panel. Custom opens a picker for any accent color; Accent fill flips its text between black and white for whichever reads better. Streaming text: Per-character fades in glyph by glyph, Per-sentence commits a sentence at a time. Defaults: Accent tint, Blue, Per-character streaming. Panel tint defaults to the system glass appearance; the slider overrides it for PopChat only. Reduce Transparency always wins.")
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

    /// Four presets, then the rainbow-ringed custom swatch (AccentPicker.swift)
    /// separated by a hairline so it reads as "or make your own" rather than as
    /// a fifth preset. The custom color lives in its own key, so selecting a
    /// preset and coming back doesn't lose it.
    private var accentRow: some View {
        HStack(spacing: 2) {
            Text("Accent color")
            Spacer()
            ForEach(Theme.accentOptions, id: \.self) { hex in
                accentSwatch(hex)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 7)
            CustomAccentSwatch(accentHex: $accentHex, customHex: $customAccentHex)
            Text("Custom")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
        }
    }

    private func accentSwatch(_ hex: String) -> some View {
        let selected = hex == accentHex
        return Button {
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
                .foregroundStyle(Theme.bubbleForeground(style: style, accentHex: accentHex))
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(
                    Theme.bubbleFill(style: style, accentHex: accentHex, dark: scheme == .dark),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }

    // MARK: - Providers

    /// Pure catalog (delta 5, 7b): every provider, no radio, no selection. A row
    /// discloses in place; the live provider+model is chosen from the panel's pill.
    /// The old design made "click the row you want to paste a key into" silently
    /// switch what the next message used.
    /// Hand-built rather than a `Form`: the grouped Form owns the layout of every
    /// row it contains — it re-reads a label/field HStack as its own label/value
    /// row and sizes the control itself, so the 230pt fields and the full-bleed
    /// editor band are simply not expressible inside it (same family as the
    /// vertical-axis-TextField trap in Commands, delta 2 §4e). The card below
    /// reproduces the grouped chrome by hand.
    private var providersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Providers")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                VStack(spacing: 0) {
                    ForEach(Array(store.providers.enumerated()), id: \.element.id) { offset, provider in
                        if offset > 0 {
                            Divider().padding(.leading, 32).opacity(0.7)
                        }
                        providerRow(provider)
                        if editingID == provider.id {
                            editorBand(provider)
                        }
                    }
                    Divider().padding(.leading, 10).opacity(0.7)
                    addProviderRow
                }
                .background(
                    formCardBackground,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: editingID)
                Text("The live provider and model are picked from the pill in the chat panel — this list only manages what shows up there. Keys are stored locally, never synced.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
                    .help("~/Library/Application Support/PopChat/secrets.json, user-only permissions.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .background(formPageBackground)
        .onExitCommand { collapseEditor() }
        .onAppear {
            if let id = initialEditingID { toggleEditor(id) }
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

    /// Matches the grouped `Form` on the neighbouring tabs: same page color, and a
    /// group box that is a relative overlay on it rather than an absolute gray —
    /// so the card tracks the page in both appearances instead of needing two
    /// hand-picked constants that drift with the system.
    private var formPageBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var formCardBackground: Color {
        Color.primary.opacity(scheme == .dark ? 0.040 : 0.038)
    }

    private func providerRow(_ provider: Provider) -> some View {
        let expanded = editingID == provider.id
        let ready = providerIsReady(provider)
        return HStack(spacing: 10) {
            Circle()
                .fill(ready ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if !provider.isPreset {
                        Text("Custom")
                            .font(.system(size: 9.5, weight: .semibold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(providerSubtitle(provider))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.6))
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(expanded ? Color.primary.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { toggleEditor(provider.id) }
        .contextMenu {
            if !provider.isPreset {
                Button("Remove Provider…", role: .destructive) {
                    providerPendingDeletion = provider.id
                }
            }
        }
    }

    private var addProviderRow: some View {
        HStack {
            Button("Add Provider…") {
                let id = store.addCustom()
                keyDraft = ""
                editingID = id
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Green-dot law (delta 5): identical predicate to `configuredProviders`, so a
    /// green row here is exactly a row the panel's switcher offers.
    private func providerIsReady(_ provider: Provider) -> Bool {
        _ = chatGPTAuthTick // re-read the dot when sign-in state changes
        return store.isConfigured(provider)
    }

    private func providerSubtitle(_ provider: Provider) -> String {
        if provider.kind == .chatGPT {
            _ = chatGPTAuthTick
            guard ChatGPTAuth.isSignedIn else { return "Not signed in · unofficial direct access" }
            return "Signed in · \(ChatGPTAuth.planLabel ?? "your ChatGPT plan") · unofficial"
        }
        if provider.kind == .codexAppServer {
            switch store.codexAppServerStatus {
            case .unknown: return "Not checked"
            case .checking: return "Checking installed Codex…"
            case .ready(let email, let plan):
                let detail = [email, plan].compactMap { $0 }.joined(separator: " · ")
                return detail.isEmpty ? "Installed Codex · signed in" : "Installed Codex · \(detail)"
            case .missing: return "Codex not found · install it yourself"
            case .notSignedIn: return "Codex installed · run codex login"
            case .failed: return "Codex app-server unavailable"
            }
        }
        let host = URL(string: provider.baseURL)?.host ?? provider.baseURL
        let isLocal = ["localhost", "127.0.0.1"].contains(host)
        guard store.isConfigured(provider) else {
            if provider.baseURL.isEmpty { return "Not set up" }
            // A local server needs no key, so "Needs API key" would send the user
            // looking for one that doesn't exist — it needs a model list instead.
            return isLocal ? "\(host) · no models fetched" : "Needs API key"
        }
        var parts = [host.isEmpty ? provider.baseURL : host]
        let count = store.knownModels[provider.id]?.count ?? 0
        if count > 0 {
            parts.append("\(count) model\(count == 1 ? "" : "s")")
        }
        if isLocal, store.key(for: provider.id).isEmpty {
            parts.append("no key needed")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Inline provider editor (7b)

    private func toggleEditor(_ id: UUID) {
        if editingID == id {
            collapseEditor()
        } else {
            // Drafts commit as they're typed (scoped to the expanded row), so
            // switching rows only has to reload the draft for the new one.
            keyDraft = store.key(for: id)
            editingID = id
            if store.providers.first(where: { $0.id == id })?.kind == .codexAppServer,
               store.codexAppServerStatus == .unknown {
                Task { await store.refreshCodexAppServer(includeModels: true) }
            }
        }
    }

    private func collapseEditor() {
        editingID = nil
        keyDraft = ""
    }

    /// The disclosed block under a row: a quaternary well band spanning the card,
    /// hairline top and bottom.
    @ViewBuilder
    private func editorBand(_ provider: Provider) -> some View {
        let index = store.providers.firstIndex { $0.id == provider.id }
        VStack(alignment: .leading, spacing: 8) {
            if provider.kind == .chatGPT {
                chatGPTAuthRows
            } else if provider.kind == .codexAppServer {
                codexAppServerRows
            } else if let index {
                if !provider.isPreset {
                    editorField("Name") {
                        TextField("", text: $store.providers[index].name)
                    }
                }
                editorField("Base URL") {
                    TextField("", text: $store.providers[index].baseURL)
                        .help("Include /v1 where the provider requires it; local servers (Ollama, LM Studio) need no key.")
                }
                editorField("API Key") {
                    SecureField("", text: $keyDraft)
                        .onChange(of: keyDraft) { _, newValue in
                            store.setKey(newValue, for: provider.id)
                        }
                }
            }
            modelRow(for: provider)
            Text("Used when this provider is picked for the first time; after that the pill remembers your last model per provider.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.modelFetchErrors[provider.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !provider.isPreset {
                Button("Remove Provider…", role: .destructive) {
                    providerPendingDeletion = provider.id
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) { Divider().opacity(0.7) }
        .overlay(alignment: .bottom) { Divider().opacity(0.7) }
    }

    /// Label left, 230pt field right — the Form's own label/value row can't be
    /// used here because the band sits inside a single full-bleed list row.
    private func editorField<Content: View>(_ label: String, @ViewBuilder _ field: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
            Spacer(minLength: 8)
            // The width has to be pinned on a CONTAINER, not the control: a
            // grouped Form lays a bare TextField out as its own label/value row
            // and sizes it from the text, ignoring `.frame` on the field itself.
            HStack(spacing: 0) {
                field()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            .frame(width: 230)
            .fixedSize()
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
        Label {
            Text("Risk warning: this direct subscription route is unofficial. It calls a ChatGPT/Codex backend that is not documented for third-party apps, so it may stop working and may carry account or terms risk. Prefer the separate Codex app-server provider when possible.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Local Codex bridge. Authentication and installation belong to Codex, not
    /// PopChat, so there is deliberately no install or sign-in button here.
    @ViewBuilder
    private var codexAppServerRows: some View {
        editorField("Codex path") {
            HStack(spacing: 6) {
                TextField("Auto-detect", text: $codexExecutablePath)
                    .help("Leave empty to auto-detect (PopChat checks common install locations, then asks your login shell), or enter the path `which codex` prints in Terminal.")
                    .onChange(of: codexExecutablePath) { _, _ in
                        // Not just a status reset: this also bumps the generation so a
                        // check already running against the OLD path cannot publish
                        // over this, and clears the once-per-launch auto-fetch flag so
                        // the switcher will actually re-probe the corrected path.
                        store.invalidateCodexAppServer()
                    }
                Button("Locate…") { locateCodexExecutable() }
                    .help("Choose the codex executable — the file `which codex` points at.")
            }
        }
        HStack(spacing: 8) {
            switch store.codexAppServerStatus {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Starting codex app-server and checking the account…")
                    .foregroundStyle(.secondary)
            case .ready(let email, let plan):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                let detail = [email, plan].compactMap { $0 }.joined(separator: " · ")
                Text(detail.isEmpty ? "Signed in with ChatGPT" : detail)
            case .missing:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                // The user's next question is always "then what path do I enter?"
                // — answer it here, where the field is.
                Text("Codex not found — run `which codex` in Terminal and paste the result above, or click Locate…")
                    .lineLimit(3)
            case .notSignedIn:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("Codex is not signed in with ChatGPT")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message).lineLimit(2)
            case .unknown:
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("Not checked yet").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Check Again") {
                Task { await store.refreshCodexAppServer(includeModels: true) }
            }
            .disabled(store.codexAppServerStatus == .checking)
        }
        .font(.caption)

        Label {
            Text("You must install and maintain Codex yourself, then run `codex login` in Terminal. PopChat does not install Codex or copy its credentials; it only starts your local `codex app-server` process. The app-server protocol is experimental, so a Codex update may occasionally be required.")
        } icon: {
            Image(systemName: "info.circle.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Text("Chat-only safety: PopChat requests ephemeral read-only threads with approval policy Never, and launches Codex with shell/exec, MCP, plugins/connectors, subagents, and other machine tools disabled. Managed Codex policy may override client settings, so app-server remains a local process you should trust and maintain.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text("Web search: Codex runs its own web search, switched by the globe in the chat input. The engine choice and round cap in Settings → Web Search don't apply to this provider.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// File-picker alternative to typing a path — for the user who has codex
    /// installed somewhere auto-detect missed and doesn't live in a terminal.
    private func locateCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // codex usually lives in a hidden directory (~/.nvm, ~/.local, /usr/local).
        panel.showsHiddenFiles = true
        panel.message = "Select the codex executable (the path `which codex` prints in Terminal)."
        let current = codexExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            // Assigning the binding runs the field's onChange, which invalidates
            // the cached status and re-arms the on-demand check.
            codexExecutablePath = url.path
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

    /// Default model for the EDITED provider — never the selected one. Settings
    /// no longer has a selection to piggyback on (delta 5).
    private func modelRow(for provider: Provider) -> some View {
        let id = provider.id
        let models = store.knownModels[id] ?? []
        return editorField("Default model") {
            HStack(spacing: 6) {
                TextField("", text: Binding(
                    get: { store.rememberedModel(id) },
                    set: { store.setModel($0, for: id) }
                ))
                Menu {
                    ForEach(models, id: \.self) { model in
                        Button(model) { store.setModel(model, for: id) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden) // the label IS the indicator
                .fixedSize()
                .disabled(models.isEmpty)
                .help(models.isEmpty ? "Fetch the model list first" : "Pick from fetched models")
                Button {
                    Task { await store.fetchModels(for: id) }
                } label: {
                    if store.isFetching(id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .fixedSize()
                .help("Fetch model list from the provider")
            }
        }
    }

    private func currentSearchKey() -> String {
        guard let account = SearchEngineChoice(rawValue: searchEngine)?.apiKeyAccount else { return "" }
        return SecretStore.get(account: account) ?? ""
    }
}
