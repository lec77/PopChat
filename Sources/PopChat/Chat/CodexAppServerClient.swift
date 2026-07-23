import Foundation

/// Readiness of the user's own Codex installation. PopChat deliberately does not
/// install, update, or authenticate Codex; it only starts `codex app-server`.
enum CodexAppServerStatus: Equatable {
    case unknown
    case checking
    case ready(email: String?, plan: String?)
    case missing
    case notSignedIn
    case failed(String)
}

/// Local adapter for Codex's experimental JSONL app-server protocol.
///
/// Each PopChat request gets an ephemeral Codex thread with the resolved PopChat
/// history injected into it. The thread is read-only, its sandbox has no network
/// access, and it never asks for an approval: this provider is a chat transport,
/// not an authorization for Codex to operate on the user's machine. Codex's own
/// `web_search` is the one exception, since it acts on the backend rather than
/// the machine — it follows PopChat's globe toggle (see `Session.init`).
enum CodexAppServerClient {
    static let executablePathKey = "codexExecutablePath"

    struct Inspection: Sendable {
        var email: String?
        var plan: String?
        var models: [String]
        var defaultModel: String?
        var supportedEfforts: [String: [String]]
        var defaultEfforts: [String: String]
    }

    struct ClientError: LocalizedError, Sendable {
        /// Why this failed, as DATA. `ProviderStore` maps failures onto
        /// `CodexAppServerStatus` from this — never by substring-matching
        /// `message`, which is user-facing prose that is free to be reworded
        /// (and lives in a different file from the code doing the matching).
        enum Reason: Sendable {
            case missing
            case notSignedIn
            case protocolFailure
        }

        let message: String
        var reason: Reason = .protocolFailure
        var errorDescription: String? { message }
    }

    /// Finder-launched apps have a small PATH, so also check the common Codex
    /// install locations. An explicit path wins when the user supplies one.
    ///
    /// May block for seconds (the login-shell probe below), so it must only run
    /// on the dedicated check/turn queues — never the main thread or a Swift
    /// concurrency cooperative task.
    static func executableURL() -> URL? {
        let defaultsPath = UserDefaults.standard.string(forKey: executablePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentPath = ProcessInfo.processInfo.environment["POPCHAT_CODEX_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            defaultsPath,
            environmentPath,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.cargo/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.bun/bin/codex",
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        // Also honor PATH for terminal-launched builds.
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: "codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        return loginShellCodexURL()
    }

    /// Last resort: ask the user's own login shell for its PATH and search that
    /// ourselves. Version managers (nvm, asdf, fnm, custom prefixes) install
    /// codex wherever their init scripts decide, and the fixed candidates above
    /// can't chase every layout — but `$SHELL` sources those same scripts, so
    /// its PATH finds codex exactly where the user's terminal does. Details that
    /// are all load-bearing (each one is a review counterexample):
    /// - PATH + marker, not `command -v codex`: in an interactive shell an
    ///   alias shadows the lookup (`command -v` prints the alias DEFINITION
    ///   with exit 0, so a fallback after `||` never runs), and rc greetings
    ///   drown plain output — the marker line is unambiguous whatever the rc
    ///   files print.
    /// - Interactive (-i) as well as login (-l): nvm and friends initialize in
    ///   rc files a plain login shell never reads; stdin is /dev/null so
    ///   nothing can prompt. csh/tcsh REJECT -l combined with any other flag
    ///   ("Unknown option"), so they get plain -i -c — csh-family PATH setup
    ///   lives in .cshrc/.tcshrc anyway. fish needs its own script because its
    ///   $PATH is a LIST that echoes space-separated (and paths contain
    ///   spaces), so it colon-joins explicitly.
    /// - The pipe is read INCREMENTALLY and parsed even on timeout: an rc file
    ///   that spawns a background process (ssh agent, tmux hook) leaves the
    ///   write end open and holds off EOF forever, and waiting for EOF would
    ///   throw away a marker line that arrived within milliseconds.
    /// Cached on success only — and re-validated on read — so "Check Again"
    /// after installing codex (or nvm-switching it away) actually re-probes.
    private static func loginShellCodexURL() -> URL? {
        if let cached = shellProbeCache.get() { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let marker = "POPCHAT-CODEX-PATH:"
        let flags: [String]
        let script: String
        switch shellName {
        case "csh", "tcsh":
            flags = ["-i", "-c"]
            script = "echo \(marker)$PATH"
        case "fish":
            flags = ["-l", "-i", "-c"]
            script = "echo \(marker)(string join : $PATH)"
        default: // zsh, bash, dash, ksh, …
            flags = ["-l", "-i", "-c"]
            script = "echo \(marker)$PATH"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = flags + [script]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        do { try process.run() } catch { return nil }

        let buffer = ProbeBuffer(marker: marker)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        buffer.waitForMarkerLine(timeout: 10)
        stdout.fileHandleForReading.readabilityHandler = nil
        // Done either way — a shell still alive here is stuck in an rc file.
        // (No waitUntilExit: Process reaps the child on its own, and the whole
        // point of the incremental read is not to wait on stragglers.)
        if process.isRunning { process.terminate() }

        guard let path = buffer.markerPayload()?
            .split(separator: ":")
            .map({ $0.trimmingCharacters(in: .whitespaces) + "/codex" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let url = URL(fileURLWithPath: path)
        shellProbeCache.set(url)
        return url
    }

    private static let shellProbeCache = ShellProbeCache()

    private final class ShellProbeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var found: URL?
        /// Re-validated on every read: an nvm/npm version switch deletes the
        /// old bin directory, and "Check Again" must re-probe rather than
        /// resurrect a dead path until relaunch.
        func get() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = found, !FileManager.default.isExecutableFile(atPath: cached.path) {
                found = nil
            }
            return found
        }
        func set(_ url: URL) { lock.lock(); defer { lock.unlock() }; found = url }
    }

    /// Thread-safe accumulator for the shell probe's stdout: the readability
    /// handler appends from FileHandle's own queue, the probing queue blocks
    /// until a COMPLETE marker line is present (PATH can span chunks), the pipe
    /// closes, or the deadline passes — whichever comes first.
    private final class ProbeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private let marker: String
        private var data = Data()
        private var closed = false

        init(marker: String) { self.marker = marker }

        func append(_ chunk: Data) {
            lock.lock()
            if chunk.isEmpty { closed = true } else { data.append(chunk) }
            let done = closed || completedMarkerLine() != nil
            lock.unlock()
            if done { ready.signal() }
        }

        func waitForMarkerLine(timeout: TimeInterval) {
            _ = ready.wait(timeout: .now() + timeout)
        }

        /// The text after the marker, once its line is complete — or whatever
        /// of it arrived, when the pipe closed or the deadline hit.
        func markerPayload() -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let line = completedMarkerLine() { return line }
            // Deadline/EOF fallback: take the partial tail. A truncated PATH
            // still yields its complete leading entries after the colon split.
            let text = String(decoding: data, as: UTF8.self)
            guard let range = text.range(of: marker, options: .backwards) else { return nil }
            return String(text[range.upperBound...])
        }

        /// Caller must hold `lock`.
        private func completedMarkerLine() -> String? {
            let text = String(decoding: data, as: UTF8.self)
            guard let range = text.range(of: marker, options: .backwards) else { return nil }
            let tail = text[range.upperBound...]
            guard let newline = tail.firstIndex(of: "\n") else { return nil }
            return String(tail[..<newline])
        }
    }

    static func inspect(includeModels: Bool = true) async throws -> Inspection {
        let holder = SessionHolder()
        return try await withThrowingTaskGroup(of: Inspection.self) { group in
            group.addTask(priority: .userInitiated) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Inspection, Error>) in
                        // FileHandle.availableData is deliberately blocking. Keep it
                        // off Swift's cooperative executor so a slow Codex process
                        // cannot starve unrelated async work.
                        let queue = DispatchQueue(
                            label: "com.chenle.PopChat.codex-app-server.inspect.\(UUID().uuidString)",
                            qos: .userInitiated
                        )
                        queue.async {
                            continuation.resume(with: Result {
                                try inspectBlocking(
                                    includeModels: includeModels,
                                    holder: holder
                                )
                            })
                        }
                    }
                } onCancel: {
                    holder.stop()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                holder.stop()
                throw ClientError(message: "Codex app-server did not answer within 30 seconds. Update Codex and check its login, then try again.")
            }
            defer {
                group.cancelAll()
                holder.stop()
            }
            guard let first = try await group.next() else {
                throw ClientError(message: "Codex app-server check ended unexpectedly.")
            }
            return first
        }
    }

    private static func inspectBlocking(
        includeModels: Bool,
        holder: SessionHolder
    ) throws -> Inspection {
        // Resolved HERE, on the dedicated queue, not in async `inspect` — the
        // login-shell probe inside executableURL() can block for seconds and
        // must stay off the cooperative pool. The 30s race in `inspect` covers
        // the probe as well.
        guard let executable = executableURL() else {
            throw ClientError(message: missingMessage, reason: .missing)
        }
        let session = try Session(executable: executable)
        holder.set(session)
        defer { session.stop() }
        try holder.checkCancellation()
        try session.initialize()
        let account = try readChatGPTAccount(session)

        guard includeModels else {
            return Inspection(
                email: account.email, plan: account.plan,
                models: [], defaultModel: nil,
                supportedEfforts: [:], defaultEfforts: [:]
            )
        }
        let response = try session.request(method: "model/list", params: [
            "includeHidden": .bool(false),
            "limit": .integer(200),
        ])
        let result = try responseResult(response, method: "model/list")
        let entries = result["data"]?.arrayValue ?? []
        let models = entries.compactMap { $0.objectValue?["id"]?.stringValue }
        let defaultModel = entries.first {
            $0.objectValue?["isDefault"]?.boolValue == true
        }?.objectValue?["id"]?.stringValue
        var supportedEfforts: [String: [String]] = [:]
        var defaultEfforts: [String: String] = [:]
        for entry in entries {
            guard let object = entry.objectValue,
                  let id = object["id"]?.stringValue else { continue }
            let efforts = (object["supportedReasoningEfforts"]?.arrayValue ?? [])
                .compactMap { $0.objectValue?["reasoningEffort"]?.stringValue }
            if !efforts.isEmpty { supportedEfforts[id] = efforts }
            if let defaultEffort = object["defaultReasoningEffort"]?.stringValue {
                defaultEfforts[id] = defaultEffort
            }
        }
        guard !models.isEmpty else {
            throw ClientError(message: "Codex app-server returned no available models. Update Codex and try again.")
        }
        return Inspection(
            email: account.email,
            plan: account.plan,
            models: models,
            defaultModel: defaultModel,
            supportedEfforts: supportedEfforts,
            defaultEfforts: defaultEfforts
        )
    }

    static func run(
        history: [OpenAIChatClient.WireMessage],
        config: ProviderConfig,
        webSearch: Bool = false,
        executableOverride: URL? = nil,
        inactivityTimeout: TimeInterval = 300
    ) -> AsyncStream<ChatStreamEvent> {
        AsyncStream { continuation in
            let holder = SessionHolder()
            let effectiveTimeout = max(inactivityTimeout, 0.05)
            let watchdog = InactivityWatchdog(timeout: effectiveTimeout) {
                holder.stop()
            }
            // The entire JSONL transport is synchronous/blocking by design. Give
            // each live turn a dedicated GCD queue rather than occupying a Swift
            // concurrency cooperative-pool thread for the duration of the reply.
            let queue = DispatchQueue(
                label: "com.chenle.PopChat.codex-app-server.turn.\(UUID().uuidString)",
                qos: .userInitiated
            )
            queue.async {
                runTurn(
                    history: history,
                    config: config,
                    webSearch: webSearch,
                    executableOverride: executableOverride,
                    inactivityTimeout: effectiveTimeout,
                    holder: holder,
                    watchdog: watchdog,
                    continuation: continuation
                )
                watchdog.cancel()
                holder.stop()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                watchdog.cancel()
                holder.stop()
            }
        }
    }

    private static func runTurn(
        history: [OpenAIChatClient.WireMessage],
        config: ProviderConfig,
        webSearch: Bool,
        executableOverride: URL?,
        inactivityTimeout: TimeInterval,
        holder: SessionHolder,
        watchdog: InactivityWatchdog,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) {
        do {
            // A fresh child per turn means seconds of silence before the first
            // token — say what is happening or the app reads as frozen. These
            // are `.status` (transient, shown in the waiting row), not
            // `.activity` (permanent transcript rows).
            continuation.yield(.status("Starting Codex…"))
            guard let executable = executableOverride ?? executableURL() else {
                throw ClientError(message: missingMessage, reason: .missing)
            }
            try holder.checkCancellation()
            let session = try Session(
                executable: executable,
                webSearch: webSearch,
                onMessage: { watchdog.kick() }
            )
            holder.set(session)
            defer { session.stop() }
            // The watchdog's clock starts when it is CONSTRUCTED, which is before
            // this queue was even scheduled and before the child was spawned.
            // Resolving the executable and launching Codex (cold start, Gatekeeper
            // scan on first run) is not the process being unresponsive — start
            // measuring silence only now that it is actually up.
            watchdog.kick()
            try session.initialize()
            _ = try readChatGPTAccount(session)
            try holder.checkCancellation()

            let split = try splitHistory(history)
            let sandboxDirectory = try appServerWorkingDirectory()
            // Say nothing about network when web search is on: the old blanket
            // "no tool network access" line reads as an instruction not to
            // search, and the model would obey it over the tool being present.
            let boundary = webSearch
                ? """
                You are serving a normal chat inside PopChat. Do not inspect local files, run shell commands, modify files, call MCP tools, spawn agents, or otherwise act on the user's computer. Answer from the conversation, using web search when the question needs current or external information. PopChat has started this thread with a read-only filesystem and no local tool network access.
                """
                : """
                You are serving a normal chat inside PopChat. Do not inspect local files, run shell commands, modify files, call MCP tools, spawn agents, or otherwise act on the user's computer. Answer directly from the conversation. PopChat has started this thread with read-only filesystem and no tool network access.
                """
            let developerInstructions = [split.systemPrompt, boundary]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            let threadResponse = try session.request(method: "thread/start", params: [
                "approvalPolicy": .string("never"),
                "cwd": .string(sandboxDirectory.path),
                "developerInstructions": .string(developerInstructions),
                "ephemeral": .bool(true),
                "model": .string(config.model),
                "sandbox": .string("read-only"),
                "serviceName": .string("popchat"),
            ])
            let threadResult = try responseResult(threadResponse, method: "thread/start")
            guard let threadID = threadResult["thread"]?.objectValue?["id"]?.stringValue else {
                throw ClientError(message: "Codex app-server returned an invalid thread/start response.")
            }

            if !split.priorMessages.isEmpty {
                let items = split.priorMessages.map(responseItem)
                let injectResponse = try session.request(method: "thread/inject_items", params: [
                    "threadId": .string(threadID),
                    "items": .array(items),
                ])
                _ = try responseResult(injectResponse, method: "thread/inject_items")
            }

            var turnParams: JSONObject = [
                "approvalPolicy": .string("never"),
                "input": .array(turnInput(split.currentMessage)),
                "model": .string(config.model),
                "sandboxPolicy": .object([
                    "type": .string("readOnly"),
                    "networkAccess": .bool(false),
                ]),
                "threadId": .string(threadID),
            ]
            if let effort = config.reasoningEffort {
                turnParams["effort"] = .string(effort)
            }
            // A turn can start emitting notifications before app-server writes the
            // matching JSON-RPC response. Waiting through `request` would buffer
            // those deltas and make the whole answer appear at once.
            continuation.yield(.status("Waiting for \(config.model)…"))
            let turnRequestID = try session.beginRequest(method: "turn/start", params: turnParams)
            // A turn can produce SEVERAL agentMessage items (a preamble, then the
            // answer). Deltas belong to the item currently streaming, and
            // `item/completed` is authoritative for THAT item only — folding it
            // into one running string drops every item that completed before it.
            var completedItems: [String] = []
            var streamingItem = ""
            func snapshot() -> String {
                (completedItems + (streamingItem.isEmpty ? [] : [streamingItem]))
                    .joined(separator: "\n\n")
            }
            var finished = false
            while !finished, let message = try session.nextMessage() {
                try holder.checkCancellation()
                if message["id"]?.intValue == turnRequestID {
                    _ = try responseResult(message, method: "turn/start")
                    continue
                }
                guard let method = message["method"]?.stringValue,
                      let params = message["params"]?.objectValue else { continue }
                switch method {
                case "item/agentMessage/delta":
                    if let delta = params["delta"]?.stringValue {
                        streamingItem += delta
                        continuation.yield(.partial(snapshot()))
                    }
                case "item/started":
                    if let activity = activityLabel(item: params["item"]?.objectValue) {
                        continuation.yield(.activity(activity))
                    } else if params["item"]?.objectValue?["type"]?.stringValue == "reasoning" {
                        // Reasoning items stream no visible text but can run for
                        // a long time — the one signal that the model is alive.
                        continuation.yield(.status("Reasoning…"))
                    }
                case "item/completed":
                    if let item = params["item"]?.objectValue,
                       item["type"]?.stringValue == "agentMessage" {
                        // The completed item's own text wins over the deltas we
                        // reassembled for it; fall back to those if it carries none.
                        let text = item["text"]?.stringValue ?? ""
                        let settled = text.isEmpty ? streamingItem : text
                        streamingItem = ""
                        if !settled.isEmpty { completedItems.append(settled) }
                        continuation.yield(.partial(snapshot()))
                    }
                case "error":
                    let willRetry = params["willRetry"]?.boolValue ?? false
                    if !willRetry, let message = params["error"]?.objectValue?["message"]?.stringValue {
                        continuation.yield(.error(friendlyError(message)))
                    }
                case "turn/completed":
                    let turn = params["turn"]?.objectValue
                    let status = turn?["status"]?.stringValue ?? "failed"
                    if status == "completed" || status == "interrupted" {
                        continuation.yield(.done(snapshot()))
                    } else {
                        let message = turn?["error"]?.objectValue?["message"]?.stringValue
                            ?? "Codex app-server turn failed (status: \(status))."
                        continuation.yield(.error(friendlyError(message)))
                    }
                    finished = true
                default:
                    continue
                }
            }
            if !finished, watchdog.didTimeOut {
                continuation.yield(.error(timeoutMessage(inactivityTimeout)))
            } else if !finished, !holder.isStopped {
                continuation.yield(.error("Codex app-server exited before the response completed. Update Codex and try again."))
            }
        } catch is CancellationError {
            if watchdog.didTimeOut {
                continuation.yield(.error(timeoutMessage(inactivityTimeout)))
            }
            return
        } catch let error as ClientError {
            if watchdog.didTimeOut {
                continuation.yield(.error(timeoutMessage(inactivityTimeout)))
            } else if !holder.isStopped {
                continuation.yield(.error(error.message))
            }
        } catch {
            if watchdog.didTimeOut {
                continuation.yield(.error(timeoutMessage(inactivityTimeout)))
            } else if !holder.isStopped {
                continuation.yield(.error("Codex app-server failed: \(error.localizedDescription)"))
            }
        }
    }

    private static func timeoutMessage(_ seconds: TimeInterval) -> String {
        let duration: String
        if seconds >= 60 {
            duration = "\(Int((seconds / 60).rounded())) minutes"
        } else if seconds >= 1 {
            duration = "\(Int(seconds.rounded())) seconds"
        } else {
            duration = "\(Int((seconds * 1_000).rounded())) milliseconds"
        }
        return "Codex app-server stopped responding: no protocol event arrived for \(duration). Stop the turn or update Codex, then try again."
    }

    private static let missingMessage = "Codex is not installed or PopChat cannot find it. Install Codex yourself and run `codex login`. If it is already installed, run `which codex` in Terminal and paste the result into the Codex path field in Settings → Providers."

    private struct Account: Sendable {
        var email: String?
        var plan: String?
    }

    private static func readChatGPTAccount(_ session: Session) throws -> Account {
        let response = try session.request(method: "account/read", params: ["refreshToken": .bool(false)])
        let result = try responseResult(response, method: "account/read")
        guard let account = result["account"]?.objectValue else {
            throw ClientError(
                message: "Codex is installed but not signed in. Run `codex login` in Terminal, then check again.",
                reason: .notSignedIn
            )
        }
        guard account["type"]?.stringValue == "chatgpt" else {
            throw ClientError(
                message: "Codex is not using a ChatGPT subscription. Run `codex login` and choose ChatGPT sign-in, then check again.",
                reason: .notSignedIn
            )
        }
        return Account(email: account["email"]?.stringValue, plan: account["planType"]?.stringValue)
    }

    fileprivate static func responseResult(_ response: JSONObject, method: String) throws -> JSONObject {
        if let error = response["error"]?.objectValue {
            let detail = error["message"]?.stringValue ?? "unknown protocol error"
            throw ClientError(message: "Codex app-server rejected \(method): \(detail). Try updating Codex.")
        }
        guard let result = response["result"]?.objectValue else {
            throw ClientError(message: "Codex app-server returned an invalid \(method) response. Try updating Codex.")
        }
        return result
    }

    private struct HistorySplit {
        var systemPrompt: String?
        var priorMessages: [OpenAIChatClient.WireMessage]
        var currentMessage: OpenAIChatClient.WireMessage
    }

    private static func splitHistory(_ history: [OpenAIChatClient.WireMessage]) throws -> HistorySplit {
        let system = history.first { $0.role == "system" }.flatMap(textContent)
        let conversational = history.filter { $0.role == "user" || $0.role == "assistant" }
        guard let lastUser = conversational.lastIndex(where: { $0.role == "user" }) else {
            throw ClientError(message: "The Codex app-server request has no user message.")
        }
        return HistorySplit(
            systemPrompt: system,
            priorMessages: Array(conversational[..<lastUser]),
            currentMessage: conversational[lastUser]
        )
    }

    private static func textContent(_ message: OpenAIChatClient.WireMessage) -> String? {
        switch message.content {
        case .text(let text): return text
        case .parts(let parts): return parts.compactMap(\.text).joined(separator: "\n")
        case nil: return nil
        }
    }

    /// Raw Responses API item accepted by `thread/inject_items`.
    private static func responseItem(_ message: OpenAIChatClient.WireMessage) -> JSONValue {
        let assistant = message.role == "assistant"
        let textType = assistant ? "output_text" : "input_text"
        var content: [JSONValue] = []
        switch message.content {
        case .text(let text):
            content.append(.object(["type": .string(textType), "text": .string(text)]))
        case .parts(let parts):
            for part in parts {
                if let text = part.text {
                    content.append(.object(["type": .string(textType), "text": .string(text)]))
                } else if let image = part.imageURL {
                    content.append(.object(["type": .string("input_image"), "image_url": .string(image.url)]))
                }
            }
        case nil:
            break
        }
        return .object([
            "type": .string("message"),
            "role": .string(message.role),
            "content": .array(content),
        ])
    }

    private static func turnInput(_ message: OpenAIChatClient.WireMessage) -> [JSONValue] {
        var input: [JSONValue] = []
        switch message.content {
        case .text(let text):
            input.append(.object(["type": .string("text"), "text": .string(text)]))
        case .parts(let parts):
            for part in parts {
                if let text = part.text {
                    input.append(.object(["type": .string("text"), "text": .string(text)]))
                } else if let image = part.imageURL {
                    input.append(.object(["type": .string("image"), "url": .string(image.url)]))
                }
            }
        case nil:
            break
        }
        return input
    }

    private static func activityLabel(item: JSONObject?) -> String? {
        guard let item, let type = item["type"]?.stringValue else { return nil }
        switch type {
        case "webSearch":
            return "Codex app-server searched the web: \(item["query"]?.stringValue ?? "")"
        case "commandExecution":
            return "⚠︎ Codex app-server attempted a local command; PopChat's read-only, no-approval policy applies."
        case "fileChange":
            return "⚠︎ Codex app-server attempted a file change; PopChat's read-only policy applies."
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            return "⚠︎ Codex app-server attempted a tool call; PopChat did not grant additional permissions."
        default:
            return nil
        }
    }

    private static func friendlyError(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("quota") {
            return "Your ChatGPT plan's Codex usage limit was reached. \(message)"
        }
        return "Codex app-server: \(message)"
    }

    private static func appServerWorkingDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: "PopChat/codex-app-server-sandbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - JSONL process transport

private typealias JSONObject = [String: JSONValue]

/// Small Sendable JSON representation, avoiding `[String: Any]` across the
/// detached process task while keeping the protocol's schemaless extension room.
private enum JSONValue: Codable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case object(JSONObject)
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(JSONObject.self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var objectValue: JSONObject? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var intValue: Int64? {
        switch self {
        case .integer(let value): value
        // Never `Int64(value)`: NaN, ±Infinity or an out-of-range magnitude TRAPS,
        // and this is evaluated on every notification the process sends.
        case .double(let value): Int64(exactly: value)
        default: nil
        }
    }
}

private final class SessionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?
    private var stopped = false

    func set(_ session: Session) {
        lock.lock()
        if stopped {
            lock.unlock()
            session.stop()
        } else {
            self.session = session
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let active = session
        session = nil
        stopped = true
        lock.unlock()
        active?.stop()
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func checkCancellation() throws {
        if isStopped { throw CancellationError() }
    }
}

/// A turn may legitimately run for a long time, but it must not remain wedged
/// forever after app-server stops producing protocol traffic. This watchdog is
/// reset by every decoded JSONL message and terminates only after an inactivity
/// interval (not a total turn-duration limit).
private final class InactivityWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let onTimeout: @Sendable () -> Void
    private let timer: DispatchSourceTimer
    private var lastActivity = DispatchTime.now().uptimeNanoseconds
    private var stopped = false
    private var timedOut = false

    init(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        self.timeout = max(timeout, 0.05)
        self.onTimeout = onTimeout
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.chenle.PopChat.codex-app-server.watchdog")
        )
        self.timer = timer
        let interval = max(0.05, min(self.timeout / 4, 5))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func kick() {
        lock.lock()
        if !stopped { lastActivity = DispatchTime.now().uptimeNanoseconds }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        timer.cancel()
    }

    private func check() {
        let now = DispatchTime.now().uptimeNanoseconds
        var shouldStop = false
        lock.lock()
        if !stopped {
            let elapsed = Double(now - lastActivity) / 1_000_000_000
            if elapsed >= timeout {
                stopped = true
                timedOut = true
                shouldStop = true
            }
        }
        lock.unlock()
        if shouldStop {
            timer.cancel()
            onTimeout()
        }
    }
}

private final class Session: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let onMessage: @Sendable () -> Void
    private let stateLock = NSLock()
    private var stopped = false
    private var stderrData = Data()
    private var readBuffer = Data()
    private var bufferedMessages: [JSONObject] = []
    private var nextRequestID: Int64 = 1

    /// `stop()` terminates the child precisely when a write may be blocked on its
    /// stdin, so EPIPE is now an EXPECTED outcome rather than a freak one. Its
    /// default disposition (SIGPIPE) kills the whole app; ignoring it makes
    /// `write(contentsOf:)` throw instead, which `send`'s callers already handle.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    init(executable: URL, webSearch: Bool = false, onMessage: @escaping @Sendable () -> Void = {}) throws {
        _ = Session.ignoreSIGPIPE
        self.onMessage = onMessage
        process.executableURL = executable
        // The app-server is used only as a model transport. Disable Codex's
        // machine/connector tool surfaces at process startup as well as using a
        // read-only thread: developer instructions alone are not a security
        // boundary, and read-only would still permit shell-based file reads.
        //
        // `web_search` is deliberately NOT in that set. It grants no access to
        // the user's machine — it runs on the model backend, the sandbox stays
        // read-only and `networkAccess: false` — and Codex owns its own tool
        // loop, so this switch is the only web access this provider can have.
        // It therefore follows PopChat's globe toggle instead of being pinned
        // off; a fresh process per turn is what makes that a launch argument.
        // The key is an ENUM (`disabled`/`cached`/`indexed`/`live`) and Codex
        // refuses to start on an unknown variant, so this is not a Bool spelled
        // as a string: `live` is what `codex --search` sets, the native
        // Responses `web_search` tool. `--smoke-codex-app-server-search` is
        // what catches the variant list changing under us.
        process.arguments = [
            "--disable", "shell_tool",
            "--disable", "unified_exec",
            "--disable", "multi_agent",
            "--disable", "apps",
            "--disable", "plugins",
            "--disable", "remote_plugin",
            "--disable", "browser_use",
            "--disable", "computer_use",
            "--disable", "image_generation",
            "-c", "web_search=\"\(webSearch ? "live" : "disabled")\"",
            "-c", "mcp_servers={}",
            "-c", "tools_view_image=false",
            "app-server", "--listen", "stdio://",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executable.deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [executableDirectory, "/opt/homebrew/bin", "/usr/local/bin", existingPath]
            .joined(separator: ":")
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw CodexAppServerClient.ClientError(
                message: "Couldn't start Codex at \(executable.path): \(error.localizedDescription)"
            )
        }
        // Drain stderr so a verbose app-server cannot fill its pipe and deadlock,
        // while retaining a short tail for launch/protocol failure messages.
        let stderr = errorOutput.fileHandleForReading
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(data)
        }
    }

    func initialize() throws {
        let response = try request(method: "initialize", params: [
            "clientInfo": .object([
                "name": .string("popchat"),
                "title": .string("PopChat"),
                "version": .string("1.0.0"),
            ]),
        ])
        _ = try CodexAppServerClient.responseResult(response, method: "initialize")
        try notify(method: "initialized", params: [:])
    }

    func request(method: String, params: JSONObject) throws -> JSONObject {
        let id = try beginRequest(method: method, params: params)
        while let message = try readMessage() {
            if message["id"]?.intValue == id { return message }
            bufferedMessages.append(message)
        }
        throw CodexAppServerClient.ClientError(
            message: "Codex app-server exited while waiting for \(method). Make sure your Codex installation is current.\(stderrSuffix())"
        )
    }

    /// Starts a JSON-RPC request without consuming stdout. Long-running methods
    /// such as `turn/start` use this so their notifications can be handled while
    /// the matching response is still pending.
    func beginRequest(method: String, params: JSONObject) throws -> Int64 {
        let id = nextRequestID
        nextRequestID += 1
        try send(["id": .integer(id), "method": .string(method), "params": .object(params)])
        return id
    }

    func notify(method: String, params: JSONObject) throws {
        try send(["method": .string(method), "params": .object(params)])
    }

    func nextMessage() throws -> JSONObject? {
        if !bufferedMessages.isEmpty { return bufferedMessages.removeFirst() }
        return try readMessage()
    }

    func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        // Do not close stdin from this thread while the worker may be inside a
        // FileHandle write. Terminating the child closes its pipe endpoints and
        // wakes the blocking stdout read without risking fd-close/reuse races.
        if process.isRunning { process.terminate() }
        errorOutput.fileHandleForReading.readabilityHandler = nil
        stateLock.unlock()
    }

    private func send(_ object: JSONObject) throws {
        var data = try JSONEncoder().encode(object)
        data.append(0x0A)
        // The `stopped` READ is locked; the write deliberately is NOT.
        // `write(contentsOf:)` blocks as soon as the child's ~64 KB stdin buffer
        // fills — a `thread/inject_items` carrying one image attachment is ~1 MB
        // — and it can only unblock if the child drains. Holding stateLock across
        // it wedges the process permanently: stop() (the watchdog's AND the Stop
        // button's only exit) blocks on the lock, and so does appendStderr, so the
        // child's stderr fills and it stops reading stdin at all. onTermination
        // runs on the consuming task's actor, so that hang reaches the MainActor.
        // stop() deliberately does not close stdin, so this fd cannot be closed
        // and reused underneath an in-flight write.
        stateLock.lock()
        let alreadyStopped = stopped
        stateLock.unlock()
        guard !alreadyStopped else { throw CancellationError() }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage() throws -> JSONObject? {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                do {
                    let message = try JSONDecoder().decode(JSONObject.self, from: Data(line))
                    onMessage()
                    return message
                } catch {
                    throw CodexAppServerClient.ClientError(
                        message: "Codex app-server sent invalid JSON. Try updating Codex."
                    )
                }
            }
            // `read(upToCount:)` may wait for the FULL requested length on a pipe;
            // initialize responses are much smaller and would deadlock forever.
            // availableData blocks only until some bytes arrive, then returns the
            // currently available JSONL chunk.
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                return nil
            }
            readBuffer.append(chunk)
        }
    }

    private func appendStderr(_ data: Data) {
        stateLock.lock(); defer { stateLock.unlock() }
        stderrData.append(data)
        if stderrData.count > 8_192 {
            stderrData.removeFirst(stderrData.count - 8_192)
        }
    }

    private func stderrSuffix() -> String {
        stateLock.lock(); defer { stateLock.unlock() }
        let text = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : " Codex said: \(text)"
    }
}
