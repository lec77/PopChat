import Foundation

/// How PopChat talks to a provider. Almost everything is OpenAI-compatible chat
/// completions with an API key. The two subscription paths are intentionally
/// distinct: `.chatGPT` is PopChat's unofficial direct OAuth/backend adapter;
/// `.codexAppServer` delegates to the user's locally installed Codex.
enum ProviderKind: String, Codable {
    case openAICompatible
    case chatGPT
    case codexAppServer
}

/// A provider is an identity — base URL + display name. API keys live in the local
/// secrets file keyed by provider id. The wire protocol is OpenAI-compatible chat
/// completions for `.openAICompatible`; the subscription kinds use either the
/// direct Codex Responses adapter or the user's local Codex app-server.
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

/// The two attachment content kinds whose provider support varies by model.
enum ContentCapability: String, Codable {
    case images
    case files
}

/// Authoritative per-model capability metadata — only ever written from a source
/// that actually states it (OpenRouter `input_modalities`, Ollama `/api/show`).
/// A nil field means the source didn't say, never a guess.
struct ModelCapabilities: Codable, Equatable {
    var images: Bool?
    var files: Bool?
}

/// A per-model deviation from the resolved default — learned from a provider
/// rejection or set by the user. Settings lists exactly these, O(exceptions),
/// never the full catalog.
struct CapabilityException: Codable, Equatable {
    enum Source: String, Codable {
        case learned
        case manual
    }
    var images: Bool?
    var files: Bool?
    var source: Source
}

/// What the send path acts on for one provider+model. nil = unknown: send
/// optimistically and let a rejection surface (and be learned) explicitly.
struct AttachmentCapabilities: Equatable {
    var images: Bool?
    var files: Bool?
}

@MainActor
final class ProviderStore: ObservableObject {
    @Published var providers: [Provider] { didSet { persistJSON(providers, key: Keys.providers) } }
    @Published var selectedID: UUID { didSet { defaults.set(selectedID.uuidString, forKey: Keys.selected) } }
    /// Last-fetched `/models` list per provider — persisted so the switcher works offline.
    @Published var knownModels: [UUID: [String]] { didSet { persistJSON(knownModels, key: Keys.knownModels) } }
    @Published var selectedModels: [UUID: String] { didSet { persistJSON(selectedModels, key: Keys.selectedModels) } }
    /// Capability metadata is provider + model scoped. Only providers with an
    /// authoritative source populate it, so generic compatible endpoints never
    /// acquire a misleading Effort column from model-name guessing.
    @Published var knownModelEfforts: [UUID: [String: [String]]] {
        didSet { persistJSON(knownModelEfforts, key: Keys.knownModelEfforts) }
    }
    @Published var defaultModelEfforts: [UUID: [String: String]] {
        didSet { persistJSON(defaultModelEfforts, key: Keys.defaultModelEfforts) }
    }
    /// User choice is remembered independently for every provider/model pair.
    @Published var selectedModelEfforts: [UUID: [String: String]] {
        didSet { persistJSON(selectedModelEfforts, key: Keys.selectedModelEfforts) }
    }
    /// Attachment capabilities, per provider + model (same law as efforts:
    /// authoritative sources only, never model-name guessing).
    @Published var modelCapabilities: [UUID: [String: ModelCapabilities]] {
        didSet { persistJSON(modelCapabilities, key: Keys.modelCapabilities) }
    }
    /// Learned/manual deviations — the only per-model capability state a user
    /// ever sees or edits (Settings renders exactly this dictionary).
    @Published var capabilityExceptions: [UUID: [String: CapabilityException]] {
        didSet { persistJSON(capabilityExceptions, key: Keys.capabilityExceptions) }
    }
    /// Custom endpoints only: send PDFs as native `file` content parts. This is
    /// endpoint-level on purpose — whether a proxy forwards an unknown part type
    /// is a property of the endpoint, not of any model behind it.
    @Published var pdfPassThrough: [UUID: Bool] {
        didSet { persistJSON(pdfPassThrough, key: Keys.pdfPassThrough) }
    }
    /// Per-provider, not global: delta 5 renders fetch errors next to the provider
    /// they belong to — inline in the switcher's model column and in the expanded
    /// Settings row — and two providers can be fetching at once (the switcher
    /// lazy-fetches whichever provider the rail is previewing).
    @Published var modelFetchErrors: [UUID: String] = [:]
    @Published var fetchingProviders: Set<UUID> = []
    @Published var codexAppServerStatus: CodexAppServerStatus = .unknown
    /// Providers the switcher has already auto-fetched this launch, so landing on
    /// a provider whose server is down doesn't re-fire on every preview.
    private var autoFetched: Set<UUID> = []
    /// Coalesces Settings, switcher and send-path checks onto one app-server
    /// process. A request that additionally needs models follows a concurrent
    /// account-only check instead of racing it and publishing stale state.
    private struct CodexRefresh {
        var includesModels: Bool
        /// Completes only AFTER the result has been published to the store and
        /// this entry cleared, so a coalesced caller can just `await` it. The task
        /// owning its own publish+cleanup is what removes the need for a waiter to
        /// poll shared state — and `codexRefresh` is only ever assigned while it
        /// is nil, so the task clearing it unconditionally cannot drop a newer one.
        var task: Task<Void, Never>
    }
    private var codexRefresh: CodexRefresh?
    /// Bumped whenever the configured Codex executable changes. A check that
    /// started under an older generation describes a DIFFERENT binary, so its
    /// answer must be dropped rather than published over the reset state.
    private var codexGeneration = 0

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let providers = "providersJSON"
        static let selected = "selectedProviderID"
        static let knownModels = "knownModelsJSON"
        static let selectedModels = "selectedModelsJSON"
        static let knownModelEfforts = "knownModelEffortsJSON"
        static let defaultModelEfforts = "defaultModelEffortsJSON"
        static let selectedModelEfforts = "selectedModelEffortsJSON"
        static let modelCapabilities = "modelCapabilitiesJSON"
        static let capabilityExceptions = "capabilityExceptionsJSON"
        static let pdfPassThrough = "pdfPassThroughJSON"
    }

    init() {
        let stored = Self.loadJSON([Provider].self, key: Keys.providers)
        let providers = stored ?? Self.presets()
        var selectedModels = Self.loadJSON([UUID: String].self, key: Keys.selectedModels) ?? [:]
        let knownModelEfforts = Self.loadJSON([UUID: [String: [String]]].self, key: Keys.knownModelEfforts) ?? [:]
        let defaultModelEfforts = Self.loadJSON([UUID: [String: String]].self, key: Keys.defaultModelEfforts) ?? [:]
        let selectedModelEfforts = Self.loadJSON([UUID: [String: String]].self, key: Keys.selectedModelEfforts) ?? [:]
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
        // Add the supported local bridge separately from the existing direct
        // subscription route. It owns no token: the user's Codex installation
        // and `codex login` state remain the source of truth.
        if !migrated.contains(where: { $0.kind == .codexAppServer }) {
            if let index = migrated.firstIndex(where: {
                $0.isPreset && $0.name == Self.codexAppServerProviderName
            }) {
                // Same round-trip hazard as the ChatGPT preset above: an older
                // build doesn't know this `kind`, decodes it as .openAICompatible
                // and re-persists it that way. Heal that entry in place — inserting
                // a second one would leave an undeletable (isPreset), unusable
                // preset with an empty base URL sitting in the list forever.
                migrated[index].kind = .codexAppServer
                migrated[index].baseURL = ""
            } else {
                migrated.insert(Self.codexAppServerPreset(), at: min(1, migrated.count))
            }
        }
        // Keep the direct route's risk label current without replacing its id —
        // and with it the selection, model list and secrets.
        for index in migrated.indices
        where migrated[index].isPreset && migrated[index].kind == .chatGPT
            && migrated[index].name != Self.chatGPTProviderName {
            migrated[index].name = Self.chatGPTProviderName
        }

        self.providers = migrated
        self.selectedID = selectedID ?? migrated[0].id
        self.knownModels = knownModels
        self.selectedModels = selectedModels
        self.knownModelEfforts = knownModelEfforts
        self.defaultModelEfforts = defaultModelEfforts
        self.selectedModelEfforts = selectedModelEfforts
        self.modelCapabilities = Self.loadJSON([UUID: [String: ModelCapabilities]].self, key: Keys.modelCapabilities) ?? [:]
        self.capabilityExceptions = Self.loadJSON([UUID: [String: CapabilityException]].self, key: Keys.capabilityExceptions) ?? [:]
        self.pdfPassThrough = Self.loadJSON([UUID: Bool].self, key: Keys.pdfPassThrough) ?? [:]
        // Fresh install (no stored selection): don't pretend the first preset is
        // usable — `migrated[0]` is the ChatGPT-subscription preset, which nobody
        // has signed into yet, and the pill would confidently name a provider
        // that cannot send. Prefer whatever IS configured (a reinstall's secrets
        // file, a persisted Codex catalog, a local server with a chosen model).
        // The positional fallback above stays only so `selectedID` remains
        // non-optional; ChatView renders that state as "Set up a provider".
        if selectedID == nil, let configured = migrated.first(where: { isConfigured($0) }) {
            self.selectedID = configured.id
        }
        // didSet does not fire during init — persist the seeded/migrated state explicitly.
        persistJSON(self.providers, key: Keys.providers)
        persistJSON(self.selectedModels, key: Keys.selectedModels)
        persistJSON(self.knownModelEfforts, key: Keys.knownModelEfforts)
        persistJSON(self.defaultModelEfforts, key: Keys.defaultModelEfforts)
        persistJSON(self.selectedModelEfforts, key: Keys.selectedModelEfforts)

        // Fixed direct-subscription capabilities are authoritative even before
        // the first post-upgrade sign-in/model refresh.
        applyChatGPTCatalog()

        // ChatGPT sign-in state is global (not @Published), so republish when it
        // changes or the switcher's configuredProviders would go stale after
        // sign-out. Observer lives for the app's lifetime alongside the store.
        NotificationCenter.default.addObserver(
            forName: .popChatChatGPTAuthChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }

        // Do not probe app-server here. ProviderStore is constructed by launch,
        // screenshots and headless harnesses; starting Codex before the user shows
        // interest both slows those paths and lets a late result mutate restored
        // UserDefaults. Settings and the switcher check it on demand.
    }

    static let chatGPTProviderName = "OpenAI subscription (unofficial)"
    /// Name shipped before 2026-07-21; still recognized when healing old lists.
    static let legacyChatGPTProviderName = "OpenAI (ChatGPT)"
    static let previousChatGPTProviderName = "OpenAI (subscription)"
    static var chatGPTProviderNames: [String] {
        [chatGPTProviderName, previousChatGPTProviderName, legacyChatGPTProviderName]
    }
    static let codexAppServerProviderName = "OpenAI (Codex app-server)"

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

    static func codexAppServerPreset() -> Provider {
        Provider(
            id: UUID(),
            name: codexAppServerProviderName,
            baseURL: "",
            isPreset: true,
            defaultModel: "",
            kind: .codexAppServer
        )
    }

    static func presets() -> [Provider] {
        [
            chatGPTPreset(),
            codexAppServerPreset(),
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
        if provider.kind == .codexAppServer {
            switch codexAppServerStatus {
            case .ready:
                return true
            case .unknown, .checking:
                // The status is per-PROCESS and the check is on demand, so every
                // launch starts at .unknown. Requiring .ready here made the
                // provider vanish from the rail on each launch — and since the
                // switcher only lazy-probes providers it already shows, the
                // on-demand check became unreachable and it could never come back
                // (unless it happened to be the live provider). A persisted
                // catalog is evidence the last check succeeded; keep it visible
                // and let previewing it re-verify. `.checking` reuses the same
                // answer so the row doesn't blink out during a re-check.
                return !(knownModels[provider.id] ?? []).isEmpty
            case .missing, .notSignedIn, .failed:
                return false
            }
        }
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

    /// The header pill's question — "was this ever set up?" — as opposed to
    /// `isConfigured`'s "is it usable right now?". The difference is the Codex
    /// app-server's live status: a transient check failure (30s inspect cap,
    /// codex mid-update) flips `isConfigured` false, and the pill renaming a
    /// selected, catalog-bearing provider to "Set up a provider…" mid-
    /// conversation tells a fully-configured user a lie. Setup evidence is the
    /// same persisted trio the base predicate uses — key, fetched catalog,
    /// chosen model — plus the live sign-in for the ChatGPT kind (signing out
    /// erases the evidence, which is exactly right for the pill too).
    func hasSetupEvidence(_ provider: Provider) -> Bool {
        if provider.kind == .chatGPT { return ChatGPTAuth.isSignedIn }
        return !(SecretStore.get(account: provider.id.uuidString) ?? "").isEmpty
            || !(knownModels[provider.id] ?? []).isEmpty
            || selectedModels[provider.id] != nil
    }

    var currentModel: String {
        guard let provider = selectedProvider else { return "" }
        return selectedModels[provider.id] ?? provider.defaultModel
    }

    var currentReasoningEffort: String? {
        rememberedEffort(selectedID, model: currentModel)
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

    func supportedEfforts(_ id: UUID, model: String) -> [String] {
        knownModelEfforts[id]?[model] ?? []
    }

    func rememberedEffort(_ id: UUID, model: String) -> String? {
        let supported = supportedEfforts(id, model: model)
        guard !supported.isEmpty else { return nil }
        if let selected = selectedModelEfforts[id]?[model], supported.contains(selected) {
            return selected
        }
        if let modelDefault = defaultModelEfforts[id]?[model], supported.contains(modelDefault) {
            return modelDefault
        }
        return supported.first
    }

    /// The effort the user actually PICKED for this pair, if any — as opposed to
    /// `rememberedEffort`, which falls back to the model's advertised default.
    /// Committing a provider or a model must pass THIS: routing the fallback back
    /// through `select` would persist a derived default as an explicit choice, and
    /// the user would stay pinned to it after the provider's own default moved on.
    func chosenEffort(_ id: UUID, model: String) -> String? {
        selectedModelEfforts[id]?[model]
    }

    func setEffort(_ effort: String, for id: UUID, model: String) {
        guard supportedEfforts(id, model: model).contains(effort) else { return }
        var choices = selectedModelEfforts[id] ?? [:]
        choices[model] = effort
        selectedModelEfforts[id] = choices
    }

    func hasEffortModels(_ id: UUID) -> Bool {
        knownModelEfforts[id]?.values.contains(where: { !$0.isEmpty }) == true
    }

    // MARK: - Attachment capabilities

    /// The one answer the send path, the composer warning and the switcher
    /// glyphs all read. Priority: manual/learned exception > authoritative
    /// metadata > kind default — resolved per FIELD, so an exception recording
    /// "no images" doesn't erase what metadata says about files.
    func attachmentCapabilities(for id: UUID, model: String) -> AttachmentCapabilities {
        guard let provider = providers.first(where: { $0.id == id }) else {
            return AttachmentCapabilities()
        }
        return Self.resolveCapabilities(
            exception: capabilityExceptions[id]?[model],
            metadata: modelCapabilities[id]?[model],
            kindDefault: Self.kindDefaultCapabilities(for: provider, pdfPassThrough: pdfPassThrough[id] == true)
        )
    }

    func currentAttachmentCapabilities() -> AttachmentCapabilities {
        attachmentCapabilities(for: selectedID, model: currentModel)
    }

    nonisolated static func resolveCapabilities(
        exception: CapabilityException?,
        metadata: ModelCapabilities?,
        kindDefault: AttachmentCapabilities
    ) -> AttachmentCapabilities {
        AttachmentCapabilities(
            images: exception?.images ?? metadata?.images ?? kindDefault.images,
            files: exception?.files ?? metadata?.files ?? kindDefault.files
        )
    }

    /// What a provider kind promises when nothing model-specific is known.
    /// The OpenAI preset defaults to fully capable — its API exposes no
    /// capability metadata at all, so the alternative is a rotting allowlist;
    /// a model that disagrees rejects explicitly and gets learned. Everything
    /// else OpenAI-compatible stays unknown for images (send optimistically)
    /// and off for direct PDFs unless the endpoint's toggle says otherwise.
    nonisolated static func kindDefaultCapabilities(for provider: Provider, pdfPassThrough: Bool) -> AttachmentCapabilities {
        switch provider.kind {
        case .chatGPT, .codexAppServer:
            // Fixed catalogs, all gpt-5 family: vision yes; neither path has a
            // file-upload channel, so PDFs stay locally extracted.
            return AttachmentCapabilities(images: true, files: false)
        case .openAICompatible:
            if provider.isPreset, provider.baseURL.contains("api.openai.com") {
                return AttachmentCapabilities(images: true, files: true)
            }
            return AttachmentCapabilities(images: nil, files: !provider.isPreset && pdfPassThrough)
        }
    }

    /// Records that this provider+model refused a content kind. `learned` comes
    /// from a structurally attributed rejection; `manual` from an explicit user
    /// action — and manual never downgrades back to learned.
    func recordCapabilityException(
        _ capability: ContentCapability,
        supported: Bool,
        source: CapabilityException.Source,
        providerID: UUID,
        model: String
    ) {
        var forProvider = capabilityExceptions[providerID] ?? [:]
        forProvider[model] = Self.mergedException(
            forProvider[model], capability: capability, supported: supported, source: source
        )
        capabilityExceptions[providerID] = forProvider
    }

    nonisolated static func mergedException(
        _ existing: CapabilityException?,
        capability: ContentCapability,
        supported: Bool,
        source: CapabilityException.Source
    ) -> CapabilityException {
        var entry = existing ?? CapabilityException(source: source)
        switch capability {
        case .images: entry.images = supported
        case .files: entry.files = supported
        }
        entry.source = existing?.source == .manual ? .manual : source
        return entry
    }

    /// The ✕ in Settings: clear back to the default and simply try again on the
    /// next send — no confirmation, because that retry is the whole cost.
    func clearCapabilityException(providerID: UUID, model: String) {
        var forProvider = capabilityExceptions[providerID] ?? [:]
        forProvider[model] = nil
        capabilityExceptions[providerID] = forProvider.isEmpty ? nil : forProvider
    }

    /// Provider + model committed together — the switcher's unit of choice, and
    /// the only place selection is written now that Settings is a pure catalog.
    func select(_ id: UUID, model: String, effort: String? = nil) {
        if !model.isEmpty { selectedModels[id] = model }
        if let effort { setEffort(effort, for: id, model: model) }
        selectedID = id
    }

    /// Seeds the fixed ChatGPT catalog onto the ChatGPT provider specifically —
    /// not `selectedProvider` — so a post-sign-in seed lands on the right provider
    /// even if the Settings picker moved during the browser flow.
    func applyChatGPTCatalog() {
        guard let provider = providers.first(where: { $0.kind == .chatGPT }) else { return }
        knownModels[provider.id] = ChatGPTAuth.modelCatalog
        knownModelEfforts[provider.id] = Dictionary(uniqueKeysWithValues: ChatGPTAuth.modelCatalog.map {
            ($0, ChatGPTAuth.supportedReasoningEfforts(for: $0))
        })
        defaultModelEfforts[provider.id] = Dictionary(uniqueKeysWithValues: ChatGPTAuth.modelCatalog.compactMap {
            guard let value = ChatGPTAuth.defaultReasoningEffort(for: $0) else { return nil }
            return ($0, value)
        })
    }

    /// Ask the installed Codex process for both account state and its live model
    /// catalog. PopChat never installs or signs in Codex on the user's behalf.
    func refreshCodexAppServer(
        includeModels: Bool = true,
        inspection: @escaping @Sendable (Bool) async throws -> CodexAppServerClient.Inspection = {
            try await CodexAppServerClient.inspect(includeModels: $0)
        }
    ) async {
        guard providers.contains(where: { $0.kind == .codexAppServer }) else { return }
        if let inFlight = codexRefresh {
            let needsModelFollowUp = includeModels && !inFlight.includesModels
            // Awaiting the task is enough: it publishes and clears `codexRefresh`
            // before completing. The previous shape awaited only the inspection
            // and then spun `while codexRefresh?.id == … { await Task.yield() }`,
            // which pegged the MainActor with continuation hops for as long as the
            // owner took to publish — up to the 30s inspect cap, on the one thread
            // the whole UI runs on.
            await inFlight.task.value
            if needsModelFollowUp {
                await refreshCodexAppServer(includeModels: true, inspection: inspection)
            }
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.performCodexRefresh(includeModels: includeModels, inspection: inspection)
            self?.codexRefresh = nil
        }
        // Assigned with no await in between, so the task body cannot observe a nil
        // entry — and a waiter resuming from `task.value` cannot observe a stale one.
        codexRefresh = CodexRefresh(includesModels: includeModels, task: task)
        await task.value
    }

    /// Invalidates everything learned about the installed Codex. Called when the
    /// configured path changes: the previous answer described another executable.
    func invalidateCodexAppServer() {
        codexGeneration += 1
        codexAppServerStatus = .unknown
        guard let provider = providers.first(where: { $0.kind == .codexAppServer }) else { return }
        // Without this the switcher would never re-probe for the rest of the
        // launch (`lazyFetchModels` fires once per provider per launch), so fixing
        // a wrong path in Settings would leave the pill's rail permanently stale.
        autoFetched.remove(provider.id)
        fetchingProviders.remove(provider.id)
        modelFetchErrors[provider.id] = nil
    }

    private func performCodexRefresh(
        includeModels: Bool,
        inspection: @escaping @Sendable (Bool) async throws -> CodexAppServerClient.Inspection
    ) async {
        guard let provider = providers.first(where: { $0.kind == .codexAppServer }) else { return }
        let generation = codexGeneration
        codexAppServerStatus = .checking
        if includeModels { fetchingProviders.insert(provider.id) }

        let result: Result<CodexAppServerClient.Inspection, CodexAppServerClient.ClientError>
        do {
            result = .success(try await inspection(includeModels))
        } catch let error as CodexAppServerClient.ClientError {
            result = .failure(error)
        } catch {
            result = .failure(CodexAppServerClient.ClientError(
                message: "Checking Codex app-server failed: \(error.localizedDescription)"
            ))
        }

        fetchingProviders.remove(provider.id)
        // The path was edited while this ran — this answer is about the old binary.
        guard generation == codexGeneration else { return }

        switch result {
        case .success(let inspection):
            modelFetchErrors[provider.id] = nil
            if includeModels {
                knownModels[provider.id] = inspection.models.sorted()
                knownModelEfforts[provider.id] = inspection.supportedEfforts
                defaultModelEfforts[provider.id] = inspection.defaultEfforts
                // The discovered default belongs on the PROVIDER, not in
                // selectedModels: `fetchModels(for:)` documents that a background
                // refresh must never write a selection for a provider the user
                // isn't on. `defaultModel` feeds rememberedModel/currentModel, so
                // the provider is still usable the moment it's picked — without
                // this refresh having touched the user's choices at all.
                if let index = providers.firstIndex(where: { $0.id == provider.id }),
                   let discovered = inspection.defaultModel ?? inspection.models.first,
                   providers[index].defaultModel != discovered {
                    providers[index].defaultModel = discovered
                }
            }
            // Publish readiness only after the model capability maps land, so
            // the first switcher frame has its final effort lane and width.
            codexAppServerStatus = .ready(email: inspection.email, plan: inspection.plan)
        case .failure(let error):
            // Mapped from the typed reason, never from the message text: the
            // strings are user-facing prose defined in CodexAppServerClient, and
            // substring-matching them silently degraded every reworded message to
            // a generic `.failed`.
            switch error.reason {
            case .missing: codexAppServerStatus = .missing
            case .notSignedIn: codexAppServerStatus = .notSignedIn
            case .protocolFailure: codexAppServerStatus = .failed(error.message)
            }
            modelFetchErrors[provider.id] = error.message
        }
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
        return ProviderConfig(
            baseURL: provider.baseURL,
            apiKey: currentKey(),
            model: currentModel,
            reasoningEffort: currentReasoningEffort,
            kind: provider.kind
        )
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
        knownModelEfforts[id] = nil
        defaultModelEfforts[id] = nil
        selectedModelEfforts[id] = nil
        modelCapabilities[id] = nil
        capabilityExceptions[id] = nil
        pdfPassThrough[id] = nil
        modelFetchErrors[id] = nil
        autoFetched.remove(id)
        providers.remove(at: index)
        if selectedID == id {
            selectedID = providers[0].id
        }
    }

    // MARK: - Model list

    private struct ModelList: Decodable {
        /// OpenRouter enriches the standard shape with per-model modalities —
        /// the one OpenAI-compatible endpoint that states capabilities outright.
        struct Architecture: Decodable {
            let inputModalities: [String]?
            enum CodingKeys: String, CodingKey {
                case inputModalities = "input_modalities"
            }
        }
        struct Entry: Decodable {
            let id: String
            let architecture: Architecture?
        }
        let data: [Entry]
    }

    /// Split out (and non-private) so the attach-caps harness can feed it fixture
    /// JSON: ids as before, plus capabilities for exactly the entries that state
    /// their modalities — absence stays absence, never a guess.
    nonisolated static func decodeModelList(_ data: Data) throws -> (ids: [String], capabilities: [String: ModelCapabilities]) {
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        var capabilities: [String: ModelCapabilities] = [:]
        for entry in list.data {
            guard let modalities = entry.architecture?.inputModalities else { continue }
            capabilities[entry.id] = ModelCapabilities(
                images: modalities.contains("image"),
                files: modalities.contains("file")
            )
        }
        return (list.data.map(\.id).sorted(), capabilities)
    }

    func isFetching(_ id: UUID) -> Bool { fetchingProviders.contains(id) }

    /// Fires one `/models` fetch the first time the switcher lands on a provider
    /// that has nothing cached but plausibly could answer (a key, or a local
    /// server needing none). Once per provider per launch — a provider whose
    /// server is down must not re-fetch on every preview.
    func lazyFetchModels(for id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        if provider.kind == .codexAppServer {
            // An active app-server provider is always kept in the rail, even
            // before this launch has verified its cached state. Check it when the
            // user actually opens/previews it, not in ProviderStore.init.
            guard !autoFetched.contains(id), codexAppServerStatus != .checking else { return }
            autoFetched.insert(id)
            Task { await refreshCodexAppServer(includeModels: true) }
            return
        }
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
        if provider.kind == .codexAppServer {
            await refreshCodexAppServer(includeModels: true)
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
            let (ids, listCapabilities) = try Self.decodeModelList(data)
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
            // Capability metadata rides the same fetch. The Ollama probe answers
            // for endpoints whose /v1 list said nothing (one tiny /api/version
            // request decides whether the native API is even there).
            var capabilities = listCapabilities
            let native = await Self.probeOllamaCapabilities(baseURL: provider.baseURL, models: ids)
            capabilities.merge(native) { _, probed in probed }
            modelCapabilities[id] = capabilities.isEmpty ? nil : capabilities
        } catch {
            modelFetchErrors[id] = "Fetching models failed: \(error.localizedDescription)"
        }
    }

    /// Ollama's OpenAI-compatible surface exposes no capabilities, but its native
    /// API does: `/api/show` lists them per model ("vision" is the image answer;
    /// there is no file input at all). Detection is by probing `/api/version` at
    /// the same host rather than by preset name, so a custom provider pointed at
    /// an Ollama gets the same authoritative answer.
    nonisolated private static func probeOllamaCapabilities(
        baseURL: String, models: [String]
    ) async -> [String: ModelCapabilities] {
        var root = baseURL
        while root.hasSuffix("/") { root.removeLast() }
        guard root.hasSuffix("/v1"), let rootURL = URL(string: String(root.dropLast(3))) else { return [:] }

        struct Version: Decodable { let version: String }
        var versionRequest = URLRequest(url: rootURL.appending(path: "api/version"))
        versionRequest.timeoutInterval = 4
        guard let (versionData, versionResponse) = try? await URLSession.shared.data(for: versionRequest),
              (versionResponse as? HTTPURLResponse)?.statusCode == 200,
              (try? JSONDecoder().decode(Version.self, from: versionData)) != nil else { return [:] }

        struct Show: Decodable { let capabilities: [String]? }
        let showURL = rootURL.appending(path: "api/show")
        return await withTaskGroup(of: (String, ModelCapabilities)?.self) { group in
            // A local server answers these in milliseconds; the cap is a backstop
            // against someone proxying a huge catalog through an Ollama-shaped URL.
            for model in models.prefix(100) {
                group.addTask {
                    var request = URLRequest(url: showURL)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 10
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let show = try? JSONDecoder().decode(Show.self, from: data),
                          let capabilities = show.capabilities else { return nil }
                    return (model, ModelCapabilities(images: capabilities.contains("vision"), files: false))
                }
            }
            var result: [String: ModelCapabilities] = [:]
            for await entry in group {
                if let (model, capabilities) = entry { result[model] = capabilities }
            }
            return result
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
