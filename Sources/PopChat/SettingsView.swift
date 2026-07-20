import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: ProviderStore
    @ObservedObject var shortcutStore: ShortcutStore
    @State private var apiKeyDraft = ""
    @State private var searchKeyDraft = ""
    @AppStorage("searchEngine") private var searchEngine = SearchEngineChoice.duckduckgo.rawValue
    @AppStorage("webSearchEnabled") private var webEnabled = true

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            hotkeySection
            generalSection
            providerSection
            webSearchSection
            shortcutsSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .onAppear {
            apiKeyDraft = store.currentKey()
            searchKeyDraft = currentSearchKey()
        }
        .onChange(of: store.selectedID) { _, _ in apiKeyDraft = store.currentKey() }
        .onChange(of: searchEngine) { _, _ in searchKeyDraft = currentSearchKey() }
    }

    // MARK: - Sections

    private var hotkeySection: some View {
        Section("Hotkey") {
            KeyboardShortcuts.Recorder("Toggle PopChat:", name: .togglePopChat)
            Text("If ⌥Space is taken by another app (e.g. ChatGPT), unbind it there or record a different shortcut here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        Section("General") {
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
    }

    private var providerSection: some View {
        Section("Provider") {
            Picker("Provider", selection: $store.selectedID) {
                ForEach(store.providers) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }

            if let index = store.providers.firstIndex(where: { $0.id == store.selectedID }) {
                if !store.providers[index].isPreset {
                    TextField("Name", text: $store.providers[index].name)
                }
                TextField("Base URL", text: $store.providers[index].baseURL)
                SecureField("API Key", text: $apiKeyDraft)
                    .onChange(of: apiKeyDraft) { _, newValue in
                        store.setKey(newValue)
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
            Text("Keys are stored locally in ~/Library/Application Support/PopChat/secrets.json (user-only permissions, not synced). Include /v1 in custom base URLs where the provider requires it; local servers (Ollama, LM Studio) need no key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var webSearchSection: some View {
        Section("Web Search") {
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
            Text("The model decides when to search (web_search + fetch_url tools, max 5 rounds). Provider-native uses OpenRouter's server-side plugin and only applies when OpenRouter is the active provider; other choices fall back to DuckDuckGo with a visible notice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsSection: some View {
        Section("Slash Commands") {
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
            Text("Type “/name your text” in the chat field. The compact form is shown in the transcript; the expanded template is what the model receives.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
