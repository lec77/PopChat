import Foundation

struct Conversation: Codable, Identifiable {
    var id: UUID
    var title: String
    var updatedAt: Date
    /// For a fork: only the messages AFTER the fork point — the shared prefix
    /// lives in the parent chain and is resolved on load.
    var messages: [ChatMessage]
    /// Conversation this one was forked from; nil for a root conversation.
    var parentID: UUID? = nil
    /// Last shared message (inclusive) in the parent's resolved transcript.
    var forkMessageID: UUID? = nil
}

struct ConversationMeta: Identifiable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    /// One-line preview for the history popover (last real message).
    let snippet: String
    let isFork: Bool

    static func snippet(for messages: [ChatMessage]) -> String {
        let last = messages.last { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty }
        let flattened = (last?.text ?? "").replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(120))
    }
}

/// One JSON file per conversation in Application Support. Forked conversations
/// form a tree: a fork's file stores a parent pointer plus only the messages
/// added after the fork, so shared history is never duplicated on disk. The
/// full transcript is resolved by walking the parent chain. Deleting or pruning
/// a parent first materializes its direct children (their files absorb the
/// shared prefix and become standalone), so forks are never silently orphaned.
/// Capped at `maxStored` conversations; oldest are pruned.
enum ConversationStore {
    static let maxStored = 50

    /// Test hook: smoke harnesses point this at a scratch directory so synthetic
    /// conversations never touch the user's real history.
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static var directory: URL {
        let dir = overrideDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PopChat/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static func save(_ conversation: Conversation) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(conversation) else { return }
        try? data.write(to: url(for: conversation.id), options: [.atomic])
    }

    static func load(id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Conversation.self, from: data)
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    // MARK: - Fork resolution

    /// Full transcript: the parent chain's shared prefix plus this
    /// conversation's own tail. `missingParent` is true when the chain is
    /// broken (parent file gone or fork point no longer present) — the caller
    /// should surface that instead of degrading silently.
    static func resolveMessages(_ conversation: Conversation) -> (messages: [ChatMessage], missingParent: Bool) {
        resolveMessages(conversation, lookup: { load(id: $0) }, visited: [conversation.id])
    }

    private static func resolveMessages(
        _ conversation: Conversation,
        lookup: (UUID) -> Conversation?,
        visited: Set<UUID>
    ) -> ([ChatMessage], Bool) {
        guard let parentID = conversation.parentID, let forkMessageID = conversation.forkMessageID else {
            return (conversation.messages, false)
        }
        guard !visited.contains(parentID), let parent = lookup(parentID) else {
            return (conversation.messages, true)
        }
        let (parentMessages, parentBroken) = resolveMessages(
            parent, lookup: lookup, visited: visited.union([parentID])
        )
        guard let cut = parentMessages.firstIndex(where: { $0.id == forkMessageID }) else {
            return (conversation.messages, true)
        }
        return (Array(parentMessages.prefix(through: cut)) + conversation.messages, parentBroken)
    }

    static func loadResolved(id: UUID) -> (conversation: Conversation, messages: [ChatMessage], missingParent: Bool)? {
        guard let conversation = load(id: id) else { return nil }
        let (messages, missingParent) = resolveMessages(conversation)
        return (conversation, messages, missingParent)
    }

    /// Delete with fork safety: direct children absorb the shared prefix and
    /// become standalone roots before the parent's file is removed.
    static func deleteMaterializingChildren(id: UUID) {
        let all = loadAll()
        for child in all.values where child.parentID == id {
            materialize(child, in: all)
        }
        delete(id: id)
    }

    private static func materialize(_ conversation: Conversation, in all: [UUID: Conversation]) {
        var standalone = conversation
        (standalone.messages, _) = resolveMessages(conversation, lookup: { all[$0] }, visited: [conversation.id])
        standalone.parentID = nil
        standalone.forkMessageID = nil
        save(standalone)
    }

    private static func loadAll() -> [UUID: Conversation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [UUID: Conversation] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conversation = try? decoder.decode(Conversation.self, from: data) else { continue }
            result[conversation.id] = conversation
        }
        return result
    }

    /// Newest first, snippets from the fully-resolved transcript. Also prunes
    /// storage beyond `maxStored` (materializing children of pruned parents).
    static func listRecent() -> [ConversationMeta] {
        let all = loadAll()
        var resolvedCache: [UUID: [ChatMessage]] = [:]
        func resolved(_ conversation: Conversation) -> [ChatMessage] {
            if let cached = resolvedCache[conversation.id] { return cached }
            let (messages, _) = resolveMessages(conversation, lookup: { all[$0] }, visited: [conversation.id])
            resolvedCache[conversation.id] = messages
            return messages
        }

        var metas = all.values.map { conversation in
            ConversationMeta(
                id: conversation.id,
                title: conversation.title,
                updatedAt: conversation.updatedAt,
                snippet: ConversationMeta.snippet(for: resolved(conversation)),
                isFork: conversation.parentID != nil
            )
        }
        metas.sort { $0.updatedAt > $1.updatedAt }
        for stale in metas.dropFirst(maxStored) {
            guard let conversation = all[stale.id] else { continue }
            for child in all.values where child.parentID == conversation.id {
                materialize(child, in: all)
            }
            delete(id: stale.id)
        }
        return Array(metas.prefix(maxStored))
    }
}
