import Foundation

/// Runtime config for one OpenAI-compatible endpoint. The base URL is used as-is with
/// "chat/completions" appended — include a "/v1" suffix where the provider requires it
/// (OpenAI: https://api.openai.com/v1, DeepSeek: https://api.deepseek.com works bare).
struct ProviderConfig {
    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModel = "deepseek-chat"

    var baseURL: String
    var apiKey: String
    var model: String
}

/// Streaming events, pi-ai style: every `partial` carries the full accumulated text so
/// far, so the UI just renders the latest snapshot. Errors are delivered in-stream —
/// the stream itself never throws. `activity` reports tool use for the transcript.
enum ChatStreamEvent {
    case partial(String)
    case activity(String)
    case done(String)
    case error(String)
}

enum OpenAIChatClient {
    /// How this turn may reach the web, if at all.
    enum WebAccess {
        /// Local agentic loop: web_search + fetch_url via standard function calling.
        case localTools(SearchEngineConfig)
        /// OpenRouter's server-side web plugin — no local loop.
        case openRouterPlugin
    }

    private static let maxToolRounds = 5

    /// Message content: a bare string for plain text (maximum provider compatibility)
    /// or an array of typed parts when images are involved.
    enum WireContent: Codable, Equatable {
        case text(String)
        case parts([WirePart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let string): try container.encode(string)
            case .parts(let parts): try container.encode(parts)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .text(string)
            } else {
                self = .parts(try container.decode([WirePart].self))
            }
        }
    }

    struct WirePart: Codable, Equatable {
        struct ImageURL: Codable, Equatable {
            var url: String
        }
        var type: String
        var text: String?
        var imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        static func text(_ string: String) -> WirePart {
            WirePart(type: "text", text: string, imageURL: nil)
        }

        static func imageDataURL(_ url: String) -> WirePart {
            WirePart(type: "image_url", text: nil, imageURL: ImageURL(url: url))
        }
    }

    struct WireMessage: Codable {
        var role: String
        var content: WireContent?
        var toolCalls: [WireToolCall]?
        var toolCallID: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }

        init(role: String, content: WireContent?, toolCalls: [WireToolCall]? = nil, toolCallID: String? = nil) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
        }
    }

    struct WireToolCall: Codable {
        struct Function: Codable {
            var name: String
            var arguments: String
        }
        var id: String
        var type = "function"
        var function: Function
    }

    private static let toolsJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "web_search",
          "description": "Search the web. Use for current events, facts you are unsure about, or anything after your training data. Returns titles, URLs, and snippets.",
          "parameters": {
            "type": "object",
            "properties": {
              "query": { "type": "string", "description": "The search query" }
            },
            "required": ["query"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "fetch_url",
          "description": "Fetch a web page and return its readable text content. Use after web_search to read a promising result, or when the user gives a URL.",
          "parameters": {
            "type": "object",
            "properties": {
              "url": { "type": "string", "description": "The http(s) URL to fetch" }
            },
            "required": ["url"]
          }
        }
      }
    ]
    """

    // MARK: - Streaming turn (optionally agentic)

    static func run(
        history: [WireMessage],
        config: ProviderConfig,
        webAccess: WebAccess?
    ) -> AsyncStream<ChatStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                await runLoop(history: history, config: config, webAccess: webAccess, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func runLoop(
        history: [WireMessage],
        config: ProviderConfig,
        webAccess: WebAccess?,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) async {
        var messages = history
        var visible = ""
        var executor: WebToolExecutor?
        if case .localTools(let engine) = webAccess {
            executor = WebToolExecutor(engine: engine)
        }

        var round = 0
        while true {
            // After maxToolRounds, one final request with tools disabled forces an answer.
            let roundsExhausted = round >= maxToolRounds
            if roundsExhausted {
                continuation.yield(.activity("Tool-call limit reached (\(maxToolRounds) rounds) — finishing with what was gathered"))
            }

            let outcome: RoundOutcome
            do {
                outcome = try await streamOneRound(
                    messages: messages,
                    config: config,
                    webAccess: webAccess,
                    toolsDisabled: roundsExhausted,
                    visiblePrefix: visible,
                    continuation: continuation
                )
            } catch is CancellationError {
                return // user hit stop; store keeps the partial
            } catch let error as ClientError {
                continuation.yield(.error(error.message))
                return
            } catch {
                continuation.yield(.error(error.localizedDescription))
                return
            }

            visible = outcome.visibleText

            guard let executor, !outcome.toolCalls.isEmpty, !roundsExhausted else {
                continuation.yield(.done(visible))
                return
            }

            // Model requested tools: record its turn, execute each call, loop again.
            messages.append(WireMessage(
                role: "assistant",
                content: outcome.roundText.isEmpty ? nil : .text(outcome.roundText),
                toolCalls: outcome.toolCalls
            ))
            for call in outcome.toolCalls {
                continuation.yield(.activity(
                    WebToolExecutor.activityLabel(name: call.function.name, argumentsJSON: call.function.arguments)
                ))
                let result = await executor.execute(name: call.function.name, argumentsJSON: call.function.arguments)
                if result.hasPrefix("ERROR:") {
                    continuation.yield(.activity("⚠︎ \(call.function.name) failed: \(result.dropFirst(6).trimmingCharacters(in: .whitespaces))"))
                }
                messages.append(WireMessage(role: "tool", content: .text(result), toolCallID: call.id))
            }
            round += 1
        }
    }

    // MARK: - Single request/stream

    private struct RoundOutcome {
        var visibleText: String
        var roundText: String
        var toolCalls: [WireToolCall]
    }

    private struct ClientError: Error {
        let message: String
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCallDelta: Decodable {
                    struct FunctionDelta: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int
                    let id: String?
                    let function: FunctionDelta?
                }
                let content: String?
                let toolCalls: [ToolCallDelta]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case toolCalls = "tool_calls"
                }
            }
            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]?
    }

    private static func streamOneRound(
        messages: [WireMessage],
        config: ProviderConfig,
        webAccess: WebAccess?,
        toolsDisabled: Bool,
        visiblePrefix: String,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) async throws -> RoundOutcome {
        guard var url = URL(string: config.baseURL) else {
            throw ClientError(message: "Invalid base URL: \(config.baseURL)")
        }
        url.append(path: "chat/completions")

        // The body mixes typed messages with schema JSON, so it's assembled as a
        // JSON object rather than one big Encodable.
        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)),
        ]
        switch webAccess {
        case .localTools where !toolsDisabled:
            body["tools"] = try JSONSerialization.jsonObject(with: Data(toolsJSON.utf8))
        case .openRouterPlugin:
            body["plugins"] = [["id": "web"]]
        default:
            break
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError(message: "Unexpected response type")
        }
        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 2000 { break }
            }
            throw ClientError(message: "HTTP \(http.statusCode) from \(url.host() ?? "?"): \(errorBody.isEmpty ? "no body" : errorBody)")
        }

        var visible = visiblePrefix
        var roundText = ""
        var pendingCalls: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let choice = chunk.choices?.first else { continue }

            if let piece = choice.delta?.content, !piece.isEmpty {
                if roundText.isEmpty && !visible.isEmpty {
                    visible += "\n\n"
                }
                roundText += piece
                visible += piece
                continuation.yield(.partial(visible))
            }
            for delta in choice.delta?.toolCalls ?? [] {
                var call = pendingCalls[delta.index] ?? (id: "", name: "", arguments: "")
                if let id = delta.id { call.id = id }
                if let name = delta.function?.name { call.name += name }
                if let fragment = delta.function?.arguments { call.arguments += fragment }
                pendingCalls[delta.index] = call
            }
        }

        let toolCalls = pendingCalls.sorted { $0.key < $1.key }.map { _, call in
            WireToolCall(id: call.id, function: .init(name: call.name, arguments: call.arguments))
        }
        return RoundOutcome(visibleText: visible, roundText: roundText, toolCalls: toolCalls)
    }
}
