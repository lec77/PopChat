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
    /// Per-provider, not global: delta 5 renders fetch errors next to the provider
    /// they belong to — inline in the switcher's model column and in the expanded
    /// Settings row — and two providers can be fetching at once (the switcher
    /// lazy-fetches whichever provider the rail is previewing).
    @Published var modelFetchErrors: [UUID: String] = [:]
    @Published var fetchingProviders: Set<UUID> = []
    /// Providers the switcher has already auto-fetched this launch, so landing on
    /// a provider whose server is down doesn't re-fire on every preview.
    private var autoFetched: Set<UUID> = []

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
            // Same reason for the fallback: the first preset IS the ChatGPT one now,
            // and it has no key field to recover a misfiled key from.
            let target = providers.first { !legacyBase.isEmpty && !$0.baseURL.isEmpty && legacyBase.hasPrefix($0.baseURL) }
                ?? providers.first { !$0.baseURL.isEmpty }
                ?? providers[0]
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
        // Retired presets: drop the untouched ones, keep anything set up (see
        // `retiredPresetNames`). Runs before the ChatGPT healing below so a list
        // that ends up empty still gets that preset inserted.
        let knownModels = Self.loadJSON([UUID: [String]].self, key: Keys.knownModels) ?? [:]
        migrated.removeAll { provider in
            guard provider.isPreset, Self.retiredPresetNames.contains(provider.name) else { return false }
            let configured = !(SecretStore.get(account: provider.id.uuidString) ?? "").isEmpty
                || !(knownModels[provider.id] ?? []).isEmpty
                || selectedModels[provider.id] != nil
            return !configured && provider.id != selectedID
        }
        // Provider lists saved before the ChatGPT preset existed: add it once.
        if !migrated.contains(where: { $0.kind == .chatGPT }) {
            if let index = migrated.firstIndex(where: { $0.isPreset && Self.chatGPTProviderNames.contains($0.name) }) {
                // A round-trip through an older build strips the `kind` field; heal
                // that entry in place instead of inserting a second, undeletable one.
                // Require isPreset so a user's custom provider that merely happens to
                // share the name isn't erased and switched to ChatGPT OAuth.
                migrated[index].kind = .chatGPT
                migrated[index].baseURL = ""
                migrated[index].defaultModel = ChatGPTAuth.defaultModel
            } else {
                migrated.insert(Self.chatGPTPreset(), at: min(1, migrated.count))
            }
        }
        // Renamed 2026-07-21: the preset says what it IS (your subscription), not
        // which app's OAuth flow it borrows. Rename in place so the stored id —
        // and with it the selection, model list and secrets — survives.
        for index in migrated.indices
        where migrated[index].isPreset && migrated[index].kind == .chatGPT
            && migrated[index].name == Self.legacyChatGPTProviderName {
            migrated[index].name = Self.chatGPTProviderName
        }

        self.providers = migrated
        self.selectedID = selectedID ?? migrated[0].id
        self.knownModels = knownModels
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

    static let chatGPTProviderName = "OpenAI (subscription)"
    /// Name shipped before 2026-07-21; still recognized when healing old lists.
    static let legacyChatGPTProviderName = "OpenAI (ChatGPT)"
    static var chatGPTProviderNames: [String] { [chatGPTProviderName, legacyChatGPTProviderName] }

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
            chatGPTPreset(),
            Provider(id: UUID(), name: "OpenAI", baseURL: "https://api.openai.com/v1", isPreset: true, defaultModel: "gpt-4o"),
            Provider(id: UUID(), name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", isPreset: true, defaultModel: "openrouter/auto"),
            Provider(id: UUID(), name: "Ollama (local)", baseURL: "http://localhost:11434/v1", isPreset: true, defaultModel: ""),
        ]
    }

    /// Presets dropped 2026-07-22. They stay in an existing list only while the
    /// user has actually set them up — a key, a fetched model list, a chosen
    /// model, or the live selection. Nothing can re-add them (they are gone from
    /// `presets()` and a hand-added one is `isPreset: false`), so this needs no
    /// one-shot flag; it just never finds anything to drop after the first launch.
    static let retiredPresetNames: Set<String> = ["DeepSeek", "LM Studio (local)"]

    // MARK: - Selection

    var selectedProvider: Provider? {
        providers.first { $0.id == selectedID }
    }

    /// Is this provider set up enough to talk to? It has an API key, a fetched
    /// model list, or an explicitly chosen model (which covers keyless local
    /// servers) — or, for the ChatGPT kind, a live sign-in.
    ///
    /// This is the single predicate behind BOTH the switcher's provider rail and
    /// the green dots in Settings › Providers (delta 5): a green row is exactly a
    /// row the switcher offers. Don't fork it.
    func isConfigured(_ provider: Provider) -> Bool {
        if provider.kind == .chatGPT { return ChatGPTAuth.isSignedIn }
        return !(SecretStore.get(account: provider.id.uuidString) ?? "").isEmpty
            || !(knownModels[provider.id] ?? []).isEmpty
            || selectedModels[provider.id] != nil
    }

    /// Providers worth offering in the quick switcher. The active provider is
    /// always included even if it stopped qualifying (key cleared, signed out) —
    /// the pill must never name a provider its own list omits. Settings shows all.
    var configuredProviders: [Provider] {
        providers.filter { isConfigured($0) || $0.id == selectedID }
    }

    var currentModel: String {
        guard let provider = selectedProvider else { return "" }
        return selectedModels[provider.id] ?? provider.defaultModel
    }

    /// The model a provider would come back with — its remembered choice, else
    /// its default. What the switcher commits when you click a provider row.
    func rememberedModel(_ id: UUID) -> String {
        selectedModels[id] ?? providers.first { $0.id == id }?.defaultModel ?? ""
    }

    func setModel(_ model: String) {
        selectedModels[selectedID] = model
    }

    func setModel(_ model: String, for id: UUID) {
        selectedModels[id] = model
    }

    /// Provider + model committed together — the switcher's unit of choice, and
    /// the only place selection is written now that Settings is a pure catalog.
    func select(_ id: UUID, model: String) {
        if !model.isEmpty { selectedModels[id] = model }
        selectedID = id
    }

    /// Seeds the fixed ChatGPT catalog onto the ChatGPT provider specifically —
    /// not `selectedProvider` — so a post-sign-in seed lands on the right provider
    /// even if the Settings picker moved during the browser flow.
    func applyChatGPTCatalog() {
        guard let provider = providers.first(where: { $0.kind == .chatGPT }) else { return }
        knownModels[provider.id] = ChatGPTAuth.modelCatalog
    }

    func currentKey() -> String {
        key(for: selectedID)
    }

    func key(for id: UUID) -> String {
        SecretStore.get(account: id.uuidString) ?? ""
    }

    func setKey(_ key: String, for id: UUID) {
        SecretStore.set(key, account: id.uuidString)
        // Keys aren't @Published (they live in the secrets file), but the green
        // dot / rail membership read them — republish so both refresh as typed.
        objectWillChange.send()
    }

    func currentConfig() -> ProviderConfig? {
        guard let provider = selectedProvider else { return nil }
        return ProviderConfig(baseURL: provider.baseURL, apiKey: currentKey(), model: currentModel, kind: provider.kind)
    }

    // MARK: - Custom providers

    @discardableResult
    func addCustom() -> UUID {
        // Distinct names: several blank "Custom" rows are indistinguishable in the
        // switcher and in Settings' list.
        var name = "Custom"
        var suffix = 2
        while providers.contains(where: { $0.name == name }) {
            name = "Custom \(suffix)"
            suffix += 1
        }
        let provider = Provider(id: UUID(), name: name, baseURL: "", isPreset: false, defaultModel: "")
        providers.append(provider)
        // Deliberately does NOT select it (delta 5): Settings manages the catalog,
        // the panel's pill owns what the next message actually uses. Adding a
        // half-configured provider must not redirect the live conversation.
        return provider.id
    }

    /// Deletes a custom provider (presets stay). Drops its key and cached model
    /// state too — the id is gone, so those entries could never be reached again.
    func remove(_ id: UUID) {
        guard providers.count > 1,
              let index = providers.firstIndex(where: { $0.id == id }),
              !providers[index].isPreset else { return }
        SecretStore.delete(account: id.uuidString)
        knownModels[id] = nil
        selectedModels[id] = nil
        modelFetchErrors[id] = nil
        autoFetched.remove(id)
        providers.remove(at: index)
        if selectedID == id {
            selectedID = providers[0].id
        }
    }

    // MARK: - Model list

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    func isFetching(_ id: UUID) -> Bool { fetchingProviders.contains(id) }

    /// Fires one `/models` fetch the first time the switcher lands on a provider
    /// that has nothing cached but plausibly could answer (a key, or a local
    /// server needing none). Once per provider per launch — a provider whose
    /// server is down must not re-fetch on every preview.
    func lazyFetchModels(for id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        guard (knownModels[id] ?? []).isEmpty, !autoFetched.contains(id), !isFetching(id) else { return }
        let hasKey = !key(for: id).isEmpty
        let isLocal = provider.baseURL.contains("localhost") || provider.baseURL.contains("127.0.0.1")
        guard provider.kind == .chatGPT || hasKey || isLocal else { return }
        autoFetched.insert(id)
        Task { await fetchModels(for: id) }
    }

    func fetchModels() async {
        await fetchModels(for: selectedID)
    }

    func fetchModels(for id: UUID) async {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        // The ChatGPT backend has no /models endpoint — the catalog is fixed.
        if provider.kind == .chatGPT {
            applyChatGPTCatalog()
            modelFetchErrors[id] = nil
            return
        }
        fetchingProviders.insert(id)
        modelFetchErrors[id] = nil
        defer { fetchingProviders.remove(id) }

        guard !provider.baseURL.isEmpty else {
            modelFetchErrors[id] = "Add a base URL for \(provider.name) first."
            return
        }
        guard var url = URL(string: provider.baseURL) else {
            modelFetchErrors[id] = "Invalid base URL: \(provider.baseURL)"
            return
        }
        url.append(path: "models")

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let apiKey = key(for: id)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                modelFetchErrors[id] = "HTTP \(code) fetching models: \(body)"
                return
            }
            let ids = try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
            guard !ids.isEmpty else {
                modelFetchErrors[id] = "\(provider.name) returned an empty model list."
                return
            }
            knownModels[id] = ids
            // Only seed a model for a provider that has no default of its own —
            // and never for one the user isn't on, which would silently make an
            // unconfigured provider "configured" behind their back.
            if selectedModels[id] == nil, provider.defaultModel.isEmpty, id == selectedID {
                selectedModels[id] = ids[0]
            }
        } catch {
            modelFetchErrors[id] = "Fetching models failed: \(error.localizedDescription)"
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
