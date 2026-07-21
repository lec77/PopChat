import Foundation

/// How PopChat talks to a provider. Almost everything is OpenAI-compatible chat
/// completions with an API key; the ChatGPT kind instead uses OAuth tokens from
/// "Sign in with ChatGPT" against the Codex Responses backend.
enum ProviderKind: String, Codable {
    case openAICompatible
    case chatGPT
}

/// A provider is an identity — base URL + display name. API keys live in the local
/// secrets file keyed by provider id. The wire protocol is OpenAI-compatible chat
/// completions for every `kind` except `.chatGPT`, which uses the Codex Responses
/// backend via `CodexResponsesClient` (see `kind`).
struct Provider: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var baseURL: String
    var isPreset: Bool
    var defaultModel: String
    var kind: ProviderKind

    init(id: UUID, name: String, baseURL: String, isPreset: Bool, defaultModel: String, kind: ProviderKind = .openAICompatible) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.isPreset = isPreset
        self.defaultModel = defaultModel
        self.kind = kind
    }

    // Provider lists persisted before the ChatGPT kind existed have no `kind` field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        isPreset = try container.decode(Bool.self, forKey: .isPreset)
        defaultModel = try container.decode(String.self, forKey: .defaultModel)
        // Decode via the raw string and map unknown values to .openAICompatible
        // rather than decoding the enum directly, which would THROW on an
        // unrecognized case and fail the whole [Provider] decode — silently
        // resetting every provider (and orphaning their per-UUID secrets/models)
        // the first time a newer build's provider kind is seen by this build.
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(ProviderKind.init(rawValue:)) ?? .openAICompatible
    }
}

@MainActor
final class ProviderStore: ObservableObject {
    @Published var providers: [Provider] { didSet { persistJSON(providers, key: Keys.providers) } }
    @Published var selectedID: UUID { didSet { defaults.set(selectedID.uuidString, forKey: Keys.selected) } }
    /// Last-fetched `/models` list per provider — persisted so the switcher works offline.
    @Published var knownModels: [UUID: [String]] { didSet { persistJSON(knownModels, key: Keys.knownModels) } }
    @Published var selectedModels: [UUID: String] { didSet { persistJSON(selectedModels, key: Keys.selectedModels) } }
    @Published var modelFetchError: String?
    @Published var isFetchingModels = false

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let providers = "providersJSON"
        static let selected = "selectedProviderID"
        static let knownModels = "knownModelsJSON"
        static let selectedModels = "selectedModelsJSON"
    }

    init() {
        let stored = Self.loadJSON([Provider].self, key: Keys.providers)
        let providers = stored ?? Self.presets()
        var selectedModels = Self.loadJSON([UUID: String].self, key: Keys.selectedModels) ?? [:]
        var selectedID = UserDefaults.standard.string(forKey: Keys.selected).flatMap(UUID.init(uuidString:))

        // One-time migration from the milestone-2 flat UserDefaults config
        // (key moves into the secrets file).
        let d = UserDefaults.standard
        if stored == nil, let legacyKey = d.string(forKey: "providerAPIKey"), !legacyKey.isEmpty {
            let legacyBase = d.string(forKey: "providerBaseURL") ?? ""
            // Skip empty baseURLs: the ChatGPT preset's "" would `hasPrefix`-match
            // every legacy base URL and swallow the migrated key under a provider
            // that has no key field to recover it from.
            let target = providers.first { !legacyBase.isEmpty && !$0.baseURL.isEmpty && legacyBase.hasPrefix($0.baseURL) } ?? providers[0]
            SecretStore.set(legacyKey, account: target.id.uuidString)
            if let legacyModel = d.string(forKey: "providerModel") {
                selectedModels[target.id] = legacyModel
            }
            selectedID = target.id
        }
        for key in ["providerAPIKey", "providerBaseURL", "providerModel"] {
            d.removeObject(forKey: key)
        }

        var migrated = providers
        // Provider lists saved before the ChatGPT preset existed: add it once.
        if !migrated.contains(where: { $0.kind == .chatGPT }) {
            if let index = migrated.firstIndex(where: { $0.name == Self.chatGPTProviderName }) {
                // A round-trip through an older build strips the `kind` field; heal
                // that entry in place instead of inserting a second, undeletable one.
                migrated[index].kind = .chatGPT
                migrated[index].baseURL = ""
                migrated[index].defaultModel = ChatGPTAuth.defaultModel
            } else {
                migrated.insert(Self.chatGPTPreset(), at: min(1, migrated.count))
            }
        }

        self.providers = migrated
        self.selectedID = selectedID ?? migrated[0].id
        self.knownModels = Self.loadJSON([UUID: [String]].self, key: Keys.knownModels) ?? [:]
        self.selectedModels = selectedModels
        // didSet does not fire during init — persist the seeded/migrated state explicitly.
        persistJSON(self.providers, key: Keys.providers)
        persistJSON(self.selectedModels, key: Keys.selectedModels)

        // ChatGPT sign-in state is global (not @Published), so republish when it
        // changes or the switcher's configuredProviders would go stale after
        // sign-out. Observer lives for the app's lifetime alongside the store.
        NotificationCenter.default.addObserver(
            forName: .popChatChatGPTAuthChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    static let chatGPTProviderName = "OpenAI (ChatGPT)"

    static func chatGPTPreset() -> Provider {
        Provider(
            id: UUID(),
            name: chatGPTProviderName,
            baseURL: "",
            isPreset: true,
            defaultModel: ChatGPTAuth.defaultModel,
            kind: .chatGPT
        )
    }

    static func presets() -> [Provider] {
        [
            Provider(id: UUID(), name: "DeepSeek", baseURL: "https://api.deepseek.com", isPreset: true, defaultModel: "deepseek-chat"),
            chatGPTPreset(),
            Provider(id: UUID(), name: "OpenAI", baseURL: "https://api.openai.com/v1", isPreset: true, defaultModel: "gpt-4o"),
            Provider(id: UUID(), name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", isPreset: true, defaultModel: "openrouter/auto"),
            Provider(id: UUID(), name: "Ollama (local)", baseURL: "http://localhost:11434/v1", isPreset: true, defaultModel: ""),
            Provider(id: UUID(), name: "LM Studio (local)", baseURL: "http://localhost:1234/v1", isPreset: true, defaultModel: ""),
        ]
    }

    // MARK: - Selection

    var selectedProvider: Provider? {
        providers.first { $0.id == selectedID }
    }

    /// Providers worth offering in the quick switcher: they have an API key, a
    /// fetched model list, or an explicitly chosen model (covers keyless local
    /// servers). The active provider is always included. Settings shows all.
    var configuredProviders: [Provider] {
        providers.filter { provider in
            if provider.kind == .chatGPT {
                return provider.id == selectedID || ChatGPTAuth.isSignedIn
            }
            return provider.id == selectedID
                || !(SecretStore.get(account: provider.id.uuidString) ?? "").isEmpty
                || !(knownModels[provider.id] ?? []).isEmpty
                || selectedModels[provider.id] != nil
        }
    }

    var currentModel: String {
        guard let provider = selectedProvider else { return "" }
        return selectedModels[provider.id] ?? provider.defaultModel
    }

    func setModel(_ model: String) {
        selectedModels[selectedID] = model
    }

    /// Seeds the fixed ChatGPT catalog onto the ChatGPT provider specifically —
    /// not `selectedProvider` — so a post-sign-in seed lands on the right provider
    /// even if the Settings picker moved during the browser flow.
    func applyChatGPTCatalog() {
        guard let provider = providers.first(where: { $0.kind == .chatGPT }) else { return }
        knownModels[provider.id] = ChatGPTAuth.modelCatalog
    }

    func currentKey() -> String {
        SecretStore.get(account: selectedID.uuidString) ?? ""
    }

    func setKey(_ key: String) {
        SecretStore.set(key, account: selectedID.uuidString)
    }

    func currentConfig() -> ProviderConfig? {
        guard let provider = selectedProvider else { return nil }
        return ProviderConfig(baseURL: provider.baseURL, apiKey: currentKey(), model: currentModel, kind: provider.kind)
    }

    // MARK: - Custom providers

    func addCustom() {
        let provider = Provider(id: UUID(), name: "Custom", baseURL: "", isPreset: false, defaultModel: "")
        providers.append(provider)
        selectedID = provider.id
    }

    func removeSelected() {
        guard providers.count > 1,
              let index = providers.firstIndex(where: { $0.id == selectedID }),
              !providers[index].isPreset else { return }
        SecretStore.delete(account: selectedID.uuidString)
        providers.remove(at: index)
        selectedID = providers[0].id
    }

    // MARK: - Model list

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    func fetchModels() async {
        guard let provider = selectedProvider else { return }
        // The ChatGPT backend has no /models endpoint — the catalog is fixed.
        if provider.kind == .chatGPT {
            applyChatGPTCatalog()
            modelFetchError = nil
            return
        }
        isFetchingModels = true
        modelFetchError = nil
        defer { isFetchingModels = false }

        guard var url = URL(string: provider.baseURL) else {
            modelFetchError = "Invalid base URL: \(provider.baseURL)"
            return
        }
        url.append(path: "models")

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let key = SecretStore.get(account: provider.id.uuidString) ?? ""
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                modelFetchError = "HTTP \(code) fetching models: \(body)"
                return
            }
            let ids = try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
            guard !ids.isEmpty else {
                modelFetchError = "\(provider.name) returned an empty model list."
                return
            }
            knownModels[provider.id] = ids
            if selectedModels[provider.id] == nil, provider.defaultModel.isEmpty {
                selectedModels[provider.id] = ids[0]
            }
        } catch {
            modelFetchError = "Fetching models failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    private func persistJSON<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
