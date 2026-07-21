import Foundation

struct Conversation: Codable, Identifiable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var messages: [ChatMessage]
}

struct ConversationMeta: Identifiable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    /// One-line preview for the history popover (last real message).
    let snippet: String

    static func snippet(for messages: [ChatMessage]) -> String {
        let last = messages.last { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty }
        let flattened = (last?.text ?? "").replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(120))
    }
}

/// One JSON file per conversation in Application Support. Attachments are persisted
/// in full (including image data), so a restored conversation continues with complete
/// context. Capped at `maxStored` conversations; oldest are pruned.
enum ConversationStore {
    static let maxStored = 50

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

    /// Newest first. Also prunes storage beyond `maxStored`.
    static func listRecent() -> [ConversationMeta] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var metas: [ConversationMeta] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conversation = try? decoder.decode(Conversation.self, from: data) else { continue }
            metas.append(ConversationMeta(
                id: conversation.id,
                title: conversation.title,
                updatedAt: conversation.updatedAt,
                snippet: ConversationMeta.snippet(for: conversation.messages)
            ))
        }
        metas.sort { $0.updatedAt > $1.updatedAt }
        for stale in metas.dropFirst(maxStored) {
            delete(id: stale.id)
        }
        return Array(metas.prefix(maxStored))
    }
}
