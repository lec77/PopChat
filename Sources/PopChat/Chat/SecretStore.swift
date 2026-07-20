import Foundation

/// Plain-file secret storage. Deliberately NOT the Apple Keychain: with an ad-hoc
/// signed app every rebuild changes the binary's identity, so the Keychain re-prompts
/// for the login-keychain password — unacceptable UX. Keys are stored unencrypted but
/// user-only readable (0600) at ~/Library/Application Support/PopChat/secrets.json —
/// the same trust model as the .env files these keys come from.
enum SecretStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }

    /// In-memory mirror of the file — reads happen on every UI render (e.g. the
    /// provider switcher filtering by configured keys), so don't hit disk each time.
    /// Only this app writes the file, and all access is main-thread, so this is safe.
    private static var cache: [String: String]?

    private static func load() -> [String: String] {
        if let cache { return cache }
        let secrets: [String: String]
        if let data = try? Data(contentsOf: fileURL) {
            secrets = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        } else {
            secrets = [:]
        }
        cache = secrets
        return secrets
    }

    private static func save(_ secrets: [String: String]) {
        cache = secrets
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    static func get(account: String) -> String? {
        load()[account]
    }

    static func set(_ value: String, account: String) {
        var secrets = load()
        if value.isEmpty {
            secrets.removeValue(forKey: account)
        } else {
            secrets[account] = value
        }
        save(secrets)
    }

    static func delete(account: String) {
        set("", account: account)
    }
}
