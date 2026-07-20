import Foundation

/// Which search backend the user picked in Settings.
enum SearchEngineChoice: String, CaseIterable, Identifiable {
    case duckduckgo
    case tavily
    case brave
    case providerNative

    var id: String { rawValue }

    var label: String {
        switch self {
        case .duckduckgo: "DuckDuckGo (no key)"
        case .tavily: "Tavily (API key)"
        case .brave: "Brave Search (API key)"
        case .providerNative: "Provider-native (OpenRouter)"
        }
    }

    /// Secrets-file account holding this engine's API key, if it needs one.
    var apiKeyAccount: String? {
        switch self {
        case .tavily: "search-tavily"
        case .brave: "search-brave"
        case .duckduckgo, .providerNative: nil
        }
    }
}

/// A resolved, ready-to-call local search backend.
enum SearchEngineConfig {
    case duckduckgo
    case tavily(key: String)
    case brave(key: String)
}

/// Executes the model's web tool calls. Results go back to the model as plain text;
/// failures are returned as "ERROR: …" tool results (so the model can adapt) and
/// surfaced to the user as activity rows by the caller.
struct WebToolExecutor {
    let engine: SearchEngineConfig

    static let maxFetchCharacters = 6000
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) PopChat/0.1"

    /// Short human-readable label shown in the transcript before executing.
    static func activityLabel(name: String, argumentsJSON: String) -> String {
        let args = decodeArguments(argumentsJSON)
        switch name {
        case "web_search": return "Searching: \(args["query"] ?? "?")"
        case "fetch_url": return "Reading: \(args["url"] ?? "?")"
        default: return "Tool: \(name)"
        }
    }

    func execute(name: String, argumentsJSON: String) async -> String {
        let args = Self.decodeArguments(argumentsJSON)
        do {
            switch name {
            case "web_search":
                guard let query = args["query"], !query.isEmpty else { return "ERROR: missing query" }
                return try await search(query: query)
            case "fetch_url":
                guard let url = args["url"], !url.isEmpty else { return "ERROR: missing url" }
                return try await fetch(urlString: url)
            default:
                return "ERROR: unknown tool \(name)"
            }
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    private static func decodeArguments(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    // MARK: - Search backends

    private struct SearchHit {
        let title: String
        let url: String
        let snippet: String
    }

    private func search(query: String) async throws -> String {
        let hits: [SearchHit]
        switch engine {
        case .duckduckgo: hits = try await searchDuckDuckGo(query: query)
        case .tavily(let key): hits = try await searchTavily(query: query, key: key)
        case .brave(let key): hits = try await searchBrave(query: query, key: key)
        }
        guard !hits.isEmpty else {
            return "ERROR: no results (the search backend may be rate-limiting; try again or rephrase)"
        }
        return hits.prefix(5).enumerated().map { index, hit in
            "\(index + 1). \(hit.title)\n   \(hit.url)\n   \(hit.snippet)"
        }.joined(separator: "\n")
    }

    private func searchDuckDuckGo(query: String) async throws -> [SearchHit] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let html = try await getString(url: components.url!, headers: [:])

        // Anchors look like: class="result__a" href="//duckduckgo.com/l/?uddg=<encoded>&rut=…">Title</a>
        let linkRegex = try NSRegularExpression(
            pattern: #"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        let snippetRegex = try NSRegularExpression(
            pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(html.startIndex..., in: html)
        let snippets = snippetRegex.matches(in: html, range: range).map {
            Self.stripHTML(String(html[Range($0.range(at: 1), in: html)!]))
        }
        return linkRegex.matches(in: html, range: range).enumerated().compactMap { index, match in
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { return nil }
            let href = String(html[hrefRange])
            // Unwrap the uddg redirect parameter to the real destination URL.
            var url = href
            if let components = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
               let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = uddg
            }
            return SearchHit(
                title: Self.stripHTML(String(html[titleRange])),
                url: url,
                snippet: index < snippets.count ? snippets[index] : ""
            )
        }
    }

    private func searchTavily(query: String, key: String) async throws -> [SearchHit] {
        struct Response: Decodable {
            struct Result: Decodable {
                let title: String
                let url: String
                let content: String
            }
            let results: [Result]
        }
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": key, "query": query, "max_results": 5,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
        return try JSONDecoder().decode(Response.self, from: data).results.map {
            SearchHit(title: $0.title, url: $0.url, snippet: $0.content)
        }
    }

    private func searchBrave(query: String, key: String) async throws -> [SearchHit] {
        struct Response: Decodable {
            struct Web: Decodable {
                struct Result: Decodable {
                    let title: String
                    let url: String
                    let description: String?
                }
                let results: [Result]
            }
            let web: Web?
        }
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "5")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
        return (try JSONDecoder().decode(Response.self, from: data).web?.results ?? []).map {
            SearchHit(title: $0.title, url: $0.url, snippet: $0.description ?? "")
        }
    }

    // MARK: - URL fetch

    private func fetch(urlString: String) async throws -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            return "ERROR: only http(s) URLs can be fetched"
        }
        let html = try await getString(url: url, headers: [:])
        var text = Self.stripHTML(html)
        if text.count > Self.maxFetchCharacters {
            text = String(text.prefix(Self.maxFetchCharacters)) + "\n[Content truncated at \(Self.maxFetchCharacters) characters]"
        }
        return text.isEmpty ? "ERROR: page contained no extractable text" : text
    }

    // MARK: - Helpers

    private func getString(url: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data: data)
        return String(decoding: data, as: UTF8.self)
    }

    private static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else {
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            throw NSError(domain: "PopChat.Web", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"
            ])
        }
    }

    /// Crude readability: drop script/style/head blocks, strip tags, decode common
    /// entities, collapse whitespace. Good enough for handing pages to a model.
    static func stripHTML(_ html: String) -> String {
        var text = html
        for block in ["script", "style", "head", "nav", "footer"] {
            text = text.replacingOccurrences(
                of: "<\(block)[^>]*>.*?</\(block)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
