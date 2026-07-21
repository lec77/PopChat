import Foundation

/// Streaming client for the ChatGPT Codex backend — the Responses API endpoint that
/// bills to the user's ChatGPT subscription instead of an API key. Mirrors
/// OpenAIChatClient's agentic loop and emits the same ChatStreamEvent stream, so
/// ChatStore treats both identically.
///
/// Protocol differences from chat completions, all handled here:
/// - conversation goes in `input` as typed items (message / function_call /
///   function_call_output), not `messages`
/// - tools are flat objects (`{"type":"function","name":…}`), not nested
/// - SSE events are typed (`response.output_text.delta`, `response.output_item.done`,
///   `response.completed`/`failed`), not choice deltas
/// - auth is a Bearer access token + `chatgpt-account-id` header, refreshed via
///   ChatGPTAuth; a 401 retries once after a forced refresh
enum CodexResponsesClient {
    private static let endpoint = "https://chatgpt.com/backend-api/codex/responses"
    private static let maxToolRounds = 5

    /// The backend expects a Codex-style `instructions` preamble from clients of
    /// this flow. Kept minimal and honest: PopChat is a chat panel, not a coding
    /// agent harness.
    private static let baseInstructions = """
    You are a helpful assistant answering in a lightweight chat panel. \
    Prefer concise, well-formatted Markdown answers. Use the provided tools \
    when they genuinely help.
    """

    private struct ClientError: Error {
        let message: String
    }

    // MARK: - Entry

    static func run(
        history: [OpenAIChatClient.WireMessage],
        config: ProviderConfig,
        webAccess: OpenAIChatClient.WebAccess?,
        sessionID: String? = nil
    ) -> AsyncStream<ChatStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                await runLoop(history: history, config: config, webAccess: webAccess, sessionID: sessionID, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func runLoop(
        history: [OpenAIChatClient.WireMessage],
        config: ProviderConfig,
        webAccess: OpenAIChatClient.WebAccess?,
        sessionID: String?,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) async {
        // The Responses backend takes the system prompt as top-level `instructions`,
        // not as an input message with role "system" (opencode does the same on the
        // OAuth path). ChatStore prepends the configured system prompt as a system
        // WireMessage for the chat-completions client, so peel those out here and
        // fold them into instructions; the rest of the history becomes input items.
        let systemTexts = history.compactMap { message -> String? in
            guard message.role == "system", case .text(let text) = message.content else { return nil }
            return text
        }
        let instructions = systemTexts.isEmpty ? baseInstructions : systemTexts.joined(separator: "\n\n")
        var input = history.filter { $0.role != "system" }.map(inputItem(for:))
        var visible = ""
        var executor: WebToolExecutor?
        if case .localTools(let engine) = webAccess {
            executor = WebToolExecutor(engine: engine)
        }
        // Stable per-conversation id (falls back to per-turn) — the backend keys
        // routing/prompt caching off it.
        let sessionID = sessionID ?? UUID().uuidString.lowercased()

        var round = 0
        while true {
            let roundsExhausted = round >= maxToolRounds
            if roundsExhausted {
                continuation.yield(.activity("Tool-call limit reached (\(maxToolRounds) rounds) — finishing with what was gathered"))
            }

            let outcome: RoundOutcome
            do {
                outcome = try await streamOneRound(
                    input: input,
                    model: config.model,
                    instructions: instructions,
                    sessionID: sessionID,
                    toolsEnabled: executor != nil,
                    forceFinal: roundsExhausted,
                    visiblePrefix: visible,
                    continuation: continuation
                )
            } catch is CancellationError {
                return // user hit stop; store keeps the partial
            } catch let error as ClientError {
                continuation.yield(.error(error.message))
                return
            } catch let error as ChatGPTAuth.AuthError {
                continuation.yield(.error(error.message))
                return
            } catch {
                continuation.yield(.error(error.localizedDescription))
                return
            }

            visible = outcome.visibleText

            // A truncated response terminates the turn with a visible warning,
            // regardless of any partial tool calls it may have carried.
            if let reason = outcome.incompleteReason {
                continuation.yield(.error(truncationMessage(reason: reason)))
                continuation.yield(.done(visible))
                return
            }

            guard let executor, !outcome.toolCalls.isEmpty, !roundsExhausted else {
                continuation.yield(.done(visible))
                return
            }

            // Model requested tools: echo its output items back, then the results.
            input.append(contentsOf: outcome.roundItems)
            for call in outcome.toolCalls {
                continuation.yield(.activity(
                    WebToolExecutor.activityLabel(name: call.name, argumentsJSON: call.arguments)
                ))
                let result = await executor.execute(name: call.name, argumentsJSON: call.arguments)
                if result.hasPrefix("ERROR:") {
                    continuation.yield(.activity("⚠︎ \(call.name) failed: \(result.dropFirst(6).trimmingCharacters(in: .whitespaces))"))
                }
                input.append([
                    "type": "function_call_output",
                    "call_id": call.callID,
                    "output": result,
                ])
            }
            round += 1
        }
    }

    // MARK: - History → input items

    /// Maps PopChat's chat-completions-shaped history onto Responses input items.
    /// (Tool rounds never appear in persisted history — only user/assistant turns.)
    private static func inputItem(for message: OpenAIChatClient.WireMessage) -> [String: Any] {
        let isAssistant = message.role == "assistant"
        let textType = isAssistant ? "output_text" : "input_text"
        var parts: [[String: Any]] = []
        switch message.content {
        case .text(let text):
            parts.append(["type": textType, "text": text])
        case .parts(let wireParts):
            for part in wireParts {
                if let text = part.text {
                    parts.append(["type": textType, "text": text])
                } else if let image = part.imageURL {
                    parts.append(["type": "input_image", "image_url": image.url])
                }
            }
        case nil:
            break
        }
        return [
            "type": "message",
            "role": message.role,
            "content": parts,
        ]
    }

    // MARK: - Single request/stream

    private struct ToolCall {
        var callID: String
        var name: String
        var arguments: String
    }

    private struct RoundOutcome {
        var visibleText: String
        /// Raw output items to echo back as input on the next round (function
        /// calls and any reasoning items the backend requires to stay paired).
        var roundItems: [[String: Any]]
        var toolCalls: [ToolCall]
        /// Set when the backend ended the response with `response.incomplete`
        /// (output-token limit, content filter, …) — the answer is truncated.
        var incompleteReason: String? = nil
    }

    private static func streamOneRound(
        input: [[String: Any]],
        model: String,
        instructions: String,
        sessionID: String,
        toolsEnabled: Bool,
        forceFinal: Bool,
        visiblePrefix: String,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) async throws -> RoundOutcome {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
            "stream": true,
            // With store:false, reasoning items must round-trip through the tool
            // loop with their encrypted payloads, or the next request is rejected.
            "include": ["reasoning.encrypted_content"],
            "reasoning": ["effort": "medium", "summary": "auto"],
            "prompt_cache_key": sessionID,
        ]
        if toolsEnabled {
            // Keep tools DECLARED even on the forced final round — the input still
            // carries function_call items referencing them, and the Responses API
            // may 400 if they're undeclared. tool_choice "none" forces the answer
            // instead of omitting the tools entirely.
            body["tools"] = codexTools
            body["tool_choice"] = forceFinal ? "none" : "auto"
        }

        // First attempt uses the cached access token; a 401 forces one refresh.
        var forceRefresh = false
        while true {
            let (accessToken, accountID) = try await credentials(forceRefresh: forceRefresh)
            var request = URLRequest(url: URL(string: endpoint)!)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            // Header set mirrors opencode's known-working requests.
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(ChatGPTAuth.originator, forHTTPHeaderField: "originator")
            request.setValue(ChatGPTAuth.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(sessionID, forHTTPHeaderField: "session-id")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError(message: "Unexpected response type")
            }
            if http.statusCode == 401, !forceRefresh {
                forceRefresh = true
                continue
            }
            guard http.statusCode == 200 else {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line
                    if errorBody.count > 2000 { break }
                }
                throw ClientError(message: friendlyHTTPError(status: http.statusCode, body: errorBody))
            }

            return try await consumeStream(
                bytes: bytes,
                visiblePrefix: visiblePrefix,
                continuation: continuation
            )
        }
    }

    private static func credentials(forceRefresh: Bool) async throws -> (String, String) {
        if forceRefresh {
            return try await ChatGPTAuth.refreshedCredentials()
        }
        return try await ChatGPTAuth.validCredentials()
    }

    private static func consumeStream(
        bytes: URLSession.AsyncBytes,
        visiblePrefix: String,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) async throws -> RoundOutcome {
        var visible = visiblePrefix
        var roundText = ""
        var roundItems: [[String: Any]] = []
        var toolCalls: [ToolCall] = []

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue } // skip "event:" and keepalives
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            // Refusals stream as response.refusal.delta, not output_text — surface
            // them as visible text too, or a refused answer yields done("") and
            // ChatStore silently deletes the row (user sees nothing at all).
            case "response.output_text.delta", "response.refusal.delta":
                if let piece = event["delta"] as? String, !piece.isEmpty {
                    if roundText.isEmpty && !visible.isEmpty {
                        visible += "\n\n"
                    }
                    roundText += piece
                    visible += piece
                    continuation.yield(.partial(visible))
                }

            case "response.output_item.done":
                guard var item = event["item"] as? [String: Any],
                      let itemType = item["type"] as? String else { break }
                // Server-assigned item ids must not be replayed: with store:false
                // there is nothing for the backend to resolve them against.
                item.removeValue(forKey: "id")
                if itemType == "function_call",
                   let callID = item["call_id"] as? String,
                   let name = item["name"] as? String {
                    let arguments = item["arguments"] as? String ?? "{}"
                    toolCalls.append(ToolCall(callID: callID, name: name, arguments: arguments))
                    roundItems.append(item)
                } else if itemType == "reasoning" || itemType == "message" {
                    // The whole round's output must be echoed back on the next
                    // request, in order: reasoning items stay paired with their
                    // function calls (or the backend 400s), and message items
                    // keep any text the model produced alongside the calls.
                    roundItems.append(item)
                }

            case "response.completed", "response.done":
                return RoundOutcome(visibleText: visible, roundItems: roundItems, toolCalls: toolCalls)

            case "response.incomplete":
                // Truncated (output limit / content filter) — carry the reason out
                // so the loop can surface a visible warning instead of presenting a
                // cut-off answer as complete.
                let reason = ((event["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
                return RoundOutcome(visibleText: visible, roundItems: roundItems, toolCalls: toolCalls, incompleteReason: reason ?? "unknown")

            case "response.failed":
                let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                throw ClientError(message: errorText(code: error?["code"], message: error?["message"])
                    ?? "The ChatGPT backend reported a failure without details.")

            case "error":
                throw ClientError(message: errorText(code: event["code"], message: event["message"])
                    ?? "The ChatGPT backend sent an error event without details.")

            default:
                break
            }
        }
        // Stream ended without a terminal event — keep whatever arrived.
        return RoundOutcome(visibleText: visible, roundItems: roundItems, toolCalls: toolCalls)
    }

    private static func truncationMessage(reason: String?) -> String {
        switch reason {
        case "max_output_tokens":
            return "⚠︎ Response was cut off at the model's output limit — it may be incomplete."
        case "content_filter":
            return "⚠︎ Response was stopped by a content filter — it may be incomplete."
        default:
            return "⚠︎ Response ended early and may be incomplete\(reason.map { " (\($0))" } ?? "")."
        }
    }

    private static func errorText(code: Any?, message: Any?) -> String? {
        let message = message as? String
        let code = code as? String
        switch (code, message) {
        case (let code?, let message?): return "\(code): \(message)"
        case (nil, let message?): return message
        case (let code?, nil): return code
        default: return nil
        }
    }

    private static func friendlyHTTPError(status: Int, body: String) -> String {
        switch status {
        case 401:
            return "ChatGPT sign-in is no longer valid — sign in again in Settings → Providers."
        case 429:
            return "ChatGPT subscription rate limit reached (the plan's Codex quota). Try again later, or switch provider. Details: \(body.prefix(300))"
        default:
            return "HTTP \(status) from chatgpt.com: \(body.isEmpty ? "no body" : String(body.prefix(500)))"
        }
    }

    /// Same tools as OpenAIChatClient, in the Responses API's flat format.
    private static let codexTools: [[String: Any]] = [
        [
            "type": "function",
            "name": "web_search",
            "description": "Search the web. Use for current events, facts you are unsure about, or anything after your training data. Returns titles, URLs, and snippets.",
            "strict": false,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The search query"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "type": "function",
            "name": "fetch_url",
            "description": "Fetch a web page and return its readable text content. Use after web_search to read a promising result, or when the user gives a URL.",
            "strict": false,
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The http(s) URL to fetch"],
                ],
                "required": ["url"],
            ],
        ],
    ]
}
