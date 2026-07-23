import AppKit
import CryptoKit
import Foundation
import Network

extension Notification.Name {
    /// Posted when ChatGPT sign-in state changes (sign in / out / forced sign-out
    /// on a failed refresh) so stores holding non-observable auth state can republish.
    static let popChatChatGPTAuthChanged = Notification.Name("popChatChatGPTAuthChanged")
}

/// "Sign in with ChatGPT" — the OAuth 2.1 PKCE flow used by OpenAI's Codex CLI,
/// letting a ChatGPT Plus/Pro subscription pay for model usage instead of an API
/// key. The browser handles login; a one-shot localhost listener catches the
/// redirect. Tokens persist in the SecretStore file alongside API keys.
///
/// Personal use of the user's own subscription only — same terms as Codex CLI.
enum ChatGPTAuth {
    // Constants from OpenAI's Codex CLI (the officially sanctioned client of this
    // flow). The redirect port is fixed by the client registration — not ours to
    // choose.
    private static let issuer = "https://auth.openai.com"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let redirectPort: UInt16 = 1455
    private static let redirectPath = "/auth/callback"
    private static let scope = "openid profile email offline_access"
    static let originator = "popchat"
    static let userAgent = "PopChat/1.0 (macOS)"

    static let defaultModel = "gpt-5.5"
    /// The Codex backend serves a fixed catalog — no /models endpoint. Mirrors
    /// opencode's allowlist (gpt-5.6 and the -pro variants are rejected by the
    /// backend for subscription auth).
    static let modelCatalog = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex-spark",
    ]

    /// The direct subscription backend has no model-capabilities endpoint, so this
    /// is a hand-maintained table — one entry per model, not a rule derived from
    /// catalog membership. An effort the backend rejects turns EVERY turn on that
    /// model into a 400 (`reasoning.effort` goes on the wire verbatim), so a value
    /// only belongs here once it has been seen to work. `medium` is what the client
    /// hardcoded before the Effort column existed, which is why it is the default
    /// everywhere except the codex-spark model. "xhigh" is confirmed working
    /// against this backend (user testing, 2026-07-22).
    private static let reasoningEfforts: [String: (supported: [String], fallback: String)] = [
        "gpt-5.5": (["low", "medium", "high", "xhigh"], "medium"),
        "gpt-5.4": (["low", "medium", "high", "xhigh"], "medium"),
        "gpt-5.4-mini": (["low", "medium", "high", "xhigh"], "medium"),
        "gpt-5.3-codex-spark": (["low", "medium", "high", "xhigh"], "high"),
    ]

    static func supportedReasoningEfforts(for model: String) -> [String] {
        reasoningEfforts[model]?.supported ?? []
    }

    static func defaultReasoningEffort(for model: String) -> String? {
        reasoningEfforts[model]?.fallback
    }

    struct AuthError: LocalizedError {
        let message: String
        /// HTTP status when this came from the token endpoint — lets refresh
        /// distinguish a revoked/expired grant (4xx) from a transient network error.
        var statusCode: Int?
        var errorDescription: String? { message }

        init(message: String, statusCode: Int? = nil) {
            self.message = message
            self.statusCode = statusCode
        }
    }

    // MARK: - Stored tokens

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var idToken: String
        var accountID: String
        var expiresAt: Date
        var email: String?
        var plan: String?
    }

    private static let secretsAccount = "chatgpt-oauth"

    /// Decode cache: `isSignedIn` sits on render paths (the header pill asks it
    /// per ChatView body evaluation — ~30×/s during a streaming reveal), and a
    /// JSONDecoder round-trip per call is exactly the hot-path waste the perf
    /// rules police. Keyed on the raw JSON so every writer — save, signOut, a
    /// refresh — invalidates it naturally; the key compare is O(1) in practice
    /// because SecretStore hands back the same cached string instance.
    /// Main-thread only, like SecretStore itself (the async refresh flows
    /// already hop to MainActor to call this).
    private static var tokensCache: (json: String, tokens: Tokens?)?

    private static func loadTokens() -> Tokens? {
        guard let json = SecretStore.get(account: secretsAccount) else { return nil }
        if let cached = tokensCache, cached.json == json { return cached.tokens }
        let tokens = json.data(using: .utf8).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
        tokensCache = (json, tokens)
        return tokens
    }

    private static func save(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens),
              let json = String(data: data, encoding: .utf8) else { return }
        SecretStore.set(json, account: secretsAccount)
        NotificationCenter.default.post(name: .popChatChatGPTAuthChanged, object: nil)
    }

    static var isSignedIn: Bool { loadTokens() != nil }
    static var accountEmail: String? { loadTokens()?.email }
    static var planLabel: String? {
        guard let plan = loadTokens()?.plan, !plan.isEmpty else { return nil }
        return "ChatGPT \(plan.capitalized)"
    }

    static func signOut() {
        SecretStore.delete(account: secretsAccount)
        NotificationCenter.default.post(name: .popChatChatGPTAuthChanged, object: nil)
    }

    // MARK: - Interactive sign-in

    /// Runs the full browser flow. Cancellation (user hits Cancel in Settings)
    /// tears down the listener and surfaces as CancellationError.
    @MainActor
    static func signIn() async throws {
        let verifier = try randomURLSafe(bytes: 64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = try randomURLSafe(bytes: 32)

        var components = URLComponents(string: issuer + "/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            // Self-identify (as opencode does) rather than impersonating Codex CLI.
            URLQueryItem(name: "originator", value: originator),
        ]

        let authorizeURL = components.url!
        let code = try await withCallbackServer(expectedState: state) {
            NSWorkspace.shared.open(authorizeURL)
        }
        let tokens = try await exchangeCode(code, verifier: verifier)
        save(tokens)
    }

    private static var redirectURI: String {
        "http://localhost:\(redirectPort)\(redirectPath)"
    }

    // MARK: - Localhost callback listener

    /// One-shot HTTP server: waits for the browser redirect, replies with a tiny
    /// confirmation page, and hands back the authorization code.
    private static func withCallbackServer(
        expectedState: String,
        onReady: @escaping @Sendable () -> Void
    ) async throws -> String {
        // Bind loopback ONLY — the redirect must never be reachable from the LAN
        // (Codex CLI binds 127.0.0.1 for exactly this reason). A default NWListener
        // binds all interfaces, exposing the callback to the local network.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: redirectPort)!
        )
        let listener = try NWListener(using: parameters)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The continuation must resume exactly once; connections can race.
                let resumed = ResumeGate()

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        onReady()
                    case .failed(let error):
                        if resumed.claim() {
                            continuation.resume(throwing: AuthError(
                                message: "Couldn't listen on localhost:\(redirectPort) for the sign-in redirect (\(error.localizedDescription)). Is another app (or Codex CLI login) using that port?"
                            ))
                        }
                    case .cancelled:
                        if resumed.claim() {
                            continuation.resume(throwing: CancellationError())
                        }
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { connection in
                    connection.start(queue: .main)
                    receiveRequestLine(connection) { requestLine in
                        guard let requestLine,
                              let result = parseCallback(requestLine: requestLine, expectedState: expectedState) else {
                            // Favicon fetches etc. — answer politely, keep waiting.
                            respond(connection, status: "404 Not Found", body: "PopChat: nothing here.")
                            return
                        }
                        switch result {
                        case .success(let code):
                            respond(
                                connection,
                                status: "200 OK",
                                body: "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:80px\"><h2>Signed in</h2><p>You can close this tab and return to PopChat.</p></body></html>"
                            )
                            if resumed.claim() {
                                listener.stateUpdateHandler = nil
                                listener.cancel()
                                continuation.resume(returning: code)
                            }
                        case .failure(let error):
                            respond(
                                connection,
                                status: "200 OK",
                                body: "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:80px\"><h2>Sign-in failed</h2><p>\(htmlEscape(error.message))</p></body></html>"
                            )
                            if resumed.claim() {
                                listener.stateUpdateHandler = nil
                                listener.cancel()
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }

                listener.start(queue: .main)
            }
        } onCancel: {
            listener.cancel()
        }
    }

    /// Serializes "resume exactly once" across listener callbacks (all on .main,
    /// but belt and braces — a class flag keeps it obvious).
    private final class ResumeGate: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// Accumulates bytes until the CRLF that terminates the HTTP request line —
    /// a single receive() can return a partial line if the request is split across
    /// TCP segments, which would otherwise mis-parse the genuine redirect as a 404.
    private static func receiveRequestLine(
        _ connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (String?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let terminator = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<terminator.lowerBound)
                completion(String(data: lineData, encoding: .utf8))
                return
            }
            // No full line yet: stop on error/EOF/oversize, otherwise keep reading.
            if error != nil || isComplete || buffer.count > 16 * 1024 {
                completion(nil)
                return
            }
            receiveRequestLine(connection, accumulated: buffer, completion: completion)
        }
    }

    private static func parseCallback(
        requestLine: String,
        expectedState: String
    ) -> Result<String, AuthError>? {
        // "GET /auth/callback?code=…&state=… HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == redirectPath else { return nil }

        let query = { (name: String) in
            components.queryItems?.first { $0.name == name }?.value
        }
        // Ignore anything not carrying our state nonce (nil = keep waiting, don't
        // abort). Checking state FIRST means a stray or forged request — including
        // one with an `error` param — can't tear down a legitimate pending sign-in.
        guard query("state") == expectedState else { return nil }
        if let error = query("error") {
            let description = query("error_description") ?? "no details"
            return .failure(AuthError(message: "OpenAI refused the sign-in: \(error) (\(description))"))
        }
        guard let code = query("code") else {
            return .failure(AuthError(message: "Redirect arrived without an authorization code."))
        }
        return .success(code)
    }

    private static func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Token exchange & refresh

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresIn = "expires_in"
        }
    }

    private static func exchangeCode(_ code: String, verifier: String) async throws -> Tokens {
        let response = try await tokenRequest(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        return try buildTokens(from: response, previous: nil)
    }

    /// Returns a fresh access token + ChatGPT account id, refreshing if the stored
    /// one expires within a minute. Safe to call from any actor — SecretStore
    /// access hops to the main actor (its documented invariant).
    static func validCredentials() async throws -> (accessToken: String, accountID: String) {
        guard let tokens = await MainActor.run(body: { loadTokens() }) else {
            throw AuthError(message: "Not signed in to ChatGPT — open Settings → Providers and sign in.")
        }
        if tokens.expiresAt > Date().addingTimeInterval(60) {
            return (tokens.accessToken, tokens.accountID)
        }
        let refreshed = try await refresh(tokens)
        return (refreshed.accessToken, refreshed.accountID)
    }

    /// Forces a refresh regardless of stored expiry — used after the backend
    /// rejects a token with 401 (revoked, or clock skew).
    static func refreshedCredentials() async throws -> (accessToken: String, accountID: String) {
        guard let tokens = await MainActor.run(body: { loadTokens() }) else {
            throw AuthError(message: "Not signed in to ChatGPT — open Settings → Providers and sign in.")
        }
        let refreshed = try await refresh(tokens)
        return (refreshed.accessToken, refreshed.accountID)
    }

    private static func refresh(_ tokens: Tokens) async throws -> Tokens {
        let response: TokenResponse
        do {
            response = try await tokenRequest(form: [
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "client_id": clientID,
            ])
        } catch let error as AuthError {
            // Only clear the session when the refresh grant itself is invalid:
            // the OAuth token endpoint signals that with 400 (invalid_grant) or
            // 401. Transient failures — 429 rate limits, 5xx, network errors —
            // keep the tokens so a later retry can succeed rather than forcing a
            // full browser re-sign-in.
            if let code = error.statusCode, code == 400 || code == 401 {
                await MainActor.run { signOut() }
            }
            throw AuthError(message: "ChatGPT session expired and refresh failed (\(error.message)). Sign in again in Settings → Providers.")
        }
        let updated = try buildTokens(from: response, previous: tokens)
        await MainActor.run { save(updated) }
        return updated
    }

    private static func tokenRequest(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: issuer + "/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = form
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "Unexpected response from the token endpoint.")
        }
        guard http.statusCode == 200 else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw AuthError(message: "Token endpoint returned HTTP \(http.statusCode): \(body)", statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func buildTokens(from response: TokenResponse, previous: Tokens?) throws -> Tokens {
        guard let refreshToken = response.refreshToken ?? previous?.refreshToken else {
            throw AuthError(message: "OpenAI returned no refresh token — sign in again.")
        }
        let idToken = response.idToken ?? previous?.idToken ?? ""
        let idClaims = decodeJWTClaims(idToken)
        let accessClaims = decodeJWTClaims(response.accessToken)

        // Same extraction order as opencode: id token first, then access token;
        // top-level claim, then the proprietary auth claim, then first org.
        guard let accountID = accountID(in: idClaims) ?? accountID(in: accessClaims) else {
            throw AuthError(message: "Sign-in succeeded but no ChatGPT account id was found in the token. Is this a ChatGPT (not API-platform) account?")
        }

        let authClaim = (accessClaims?["https://api.openai.com/auth"] ?? idClaims?["https://api.openai.com/auth"]) as? [String: Any]
        return Tokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            expiresAt: Date().addingTimeInterval(response.expiresIn ?? 3600),
            email: idClaims?["email"] as? String ?? previous?.email,
            plan: authClaim?["chatgpt_plan_type"] as? String ?? previous?.plan
        )
    }

    private static func accountID(in claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        if let id = claims["chatgpt_account_id"] as? String { return id }
        let authClaim = claims["https://api.openai.com/auth"] as? [String: Any]
        if let id = authClaim?["chatgpt_account_id"] as? String { return id }
        let organizations = claims["organizations"] as? [[String: Any]]
        return organizations?.first?["id"] as? String
    }

    // MARK: - Small codecs

    private static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func randomURLSafe(bytes count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            // Never derive PKCE/state from the zero buffer — that would void both.
            throw AuthError(message: "Couldn't generate secure random data for sign-in. Try again.")
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
