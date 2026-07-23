import AppKit
import SwiftUI

// Headless streaming checks (no UI):
//   POPCHAT_API_KEY=… .build/debug/PopChat --smoke          plain streaming
//   POPCHAT_API_KEY=… .build/debug/PopChat --smoke-search   agentic loop w/ DuckDuckGo
let smokePlain = CommandLine.arguments.contains("--smoke")
let smokeSearch = CommandLine.arguments.contains("--smoke-search")
// Verifies the default system prompt actually elicits <pasteable> blocks.
let smokePasteable = CommandLine.arguments.contains("--smoke-pasteable")
if smokePlain || smokeSearch || smokePasteable {
    Task {
        let env = ProcessInfo.processInfo.environment
        let config = ProviderConfig(
            baseURL: env["POPCHAT_BASE_URL"] ?? ProviderConfig.defaultBaseURL,
            apiKey: env["POPCHAT_API_KEY"] ?? "",
            model: env["POPCHAT_MODEL"] ?? ProviderConfig.defaultModel
        )
        let prompt = smokeSearch
            ? "What is the latest stable release version of the Zed editor? Use web_search to check — do not answer from memory. Reply with just the version number and the source URL."
            : smokePasteable
                ? "Give me a reusable conventional-commit message template for bug fixes, ready to copy."
                : "Reply with exactly: PopChat streaming OK"
        print("smoke: \(config.baseURL) model=\(config.model) search=\(smokeSearch) pasteable=\(smokePasteable)")
        var chunks = 0
        var history = [OpenAIChatClient.WireMessage(role: "user", content: .text(prompt))]
        if smokePasteable {
            history.insert(
                OpenAIChatClient.WireMessage(role: "system", content: .text(ChatStore.defaultSystemPrompt)),
                at: 0
            )
        }
        for await event in OpenAIChatClient.run(
            history: history,
            config: config,
            webAccess: smokeSearch ? .localTools(.duckduckgo) : nil
        ) {
            switch event {
            case .partial:
                chunks += 1
            case .activity(let text):
                print("[activity] \(text)")
            case .status(let text):
                print("[status] \(text)")
            case .done(let text):
                print("chunks=\(chunks)\nfinal=\(text)")
                if smokePasteable {
                    let blocks = MarkdownRenderer.segments(text).compactMap { segment -> String? in
                        if case .pasteable(let title, let content) = segment {
                            return "title=\(title ?? "-") chars=\(content.count)"
                        }
                        return nil
                    }
                    print("pasteableBlocks=\(blocks.count) \(blocks.joined(separator: " | "))")
                    exit(blocks.isEmpty ? 1 : 0)
                }
                exit(text.isEmpty ? 1 : 0)
            case .error(let message):
                print("ERROR: \(message)")
                exit(1)
            }
        }
        exit(1)
    }
    RunLoop.main.run()
}

// Typewriter pacing (no network, no UI): replays the drain's step law against a
// synthetic fast provider. Guards the invariant that regressed once — while the
// answer is still arriving the reveal must run at a fixed rate and FALL BEHIND;
// a backlog-proportional step settles at reveal-rate == arrival-rate, which made
// "Per-character" render identically to "By chunk".
if CommandLine.arguments.contains("--smoke-typewriter") {
    // (total chars, provider chars/sec, max seconds the reveal may trail arrival)
    let cases: [(total: Int, arrival: Double, slack: Double)] = [
        (600, 900, 8), (3_000, 900, 10), (20_000, 1_500, 12),
    ]
    var failures: [String] = []
    for probe in cases {
        let arrivalMs = Int(Double(probe.total) / probe.arrival * 1000)
        var revealed = 0, elapsed = 0, revealedAtArrival = -1
        while revealed < probe.total, elapsed < 300_000 {
            if revealedAtArrival < 0, elapsed >= arrivalMs { revealedAtArrival = revealed }
            let arrived = min(probe.total, Int(probe.arrival * Double(elapsed) / 1000))
            let backlog = arrived - revealed
            if backlog > 0 {
                revealed += ChatStore.typewriterStep(
                    backlog: backlog,
                    interval: ChatStore.typewriterInterval(forLength: arrived),
                    finished: elapsed >= arrivalMs
                )
            }
            elapsed += ChatStore.typewriterInterval(forLength: arrived)
        }
        if revealedAtArrival < 0 { revealedAtArrival = revealed }
        let trail = Double(elapsed - arrivalMs) / 1000
        // THE assertion: how fast text appeared while the model was still producing.
        // Not the tail — the old backlog/12 catch-up also kept typing ~1s past the
        // end, yet during the answer it ran at the provider's rate, which is exactly
        // what made it look like .byChunk. Anything near the arrival rate is a mirror,
        // not a typewriter. (A short answer can pass this trivially: it ends before
        // the lag has room to build. The 3k/20k probes are the ones that discriminate.)
        let displayRate = Double(revealedAtArrival) / (Double(arrivalMs) / 1000)
        let paced = displayRate <= probe.arrival * 0.75
        let bounded = revealed == probe.total && trail <= probe.slack
        print(String(format: "%6d chars @%.0f/s → arrival %.1fs, reveal %.1fs (trail %.1fs), shown while streaming %.0f chars/s %@",
                     probe.total, probe.arrival, Double(arrivalMs) / 1000, Double(elapsed) / 1000,
                     trail, displayRate, paced && bounded ? "ok" : "BAD"))
        if !paced {
            failures.append(String(format: "%d: reveal mirrors arrival (%.0f of %.0f chars/s)",
                                   probe.total, displayRate, probe.arrival))
        }
        if !bounded { failures.append("\(probe.total): reveal trails \(trail)s / revealed \(revealed)") }
    }
    // Delta 4 / 6b: the per-sentence commit law. Replays the same synthetic
    // provider through ChatStore.sentenceCommitLength and checks the three things
    // the mode promises — commits land on sentence boundaries, never inside an
    // open code fence, and are paced (≥140 ms apart while arriving, ≥60 ms after)
    // without blowing the 6 s drain ceiling on a long answer.
    let unit = """
    Margins held through Q2, but two suppliers now carry most of the risk. Acme and \
    Delta both feed final assembly, so a stall at either blocks shipments.

    Here is the check:

    ```swift
    let ratio = 1.5 // note. a period mid-fence, and no boundary may land here
    print(ratio)
    ```

    I'd dual-source the top parts before Q3. That is the whole recommendation!

    """

    /// Independent of the implementation: is `index` a legal commit point?
    func isBoundary(_ chars: [Character], _ index: Int) -> Bool {
        if index == chars.count { return true }
        guard index > 0 else { return false }
        let prev = chars[index - 1]
        if prev == "\n" { return true }
        if prev == "." || prev == "!" || prev == "?" { return chars[index].isWhitespace }
        return false
    }

    /// Number of ``` fence lines before `index` — odd means the fence is open.
    func fencesBefore(_ chars: [Character], _ index: Int) -> Int {
        var count = 0, i = 0, atLineStart = true
        while i < index {
            if atLineStart, chars[i...].starts(with: ["`", "`", "`"]) { count += 1 }
            atLineStart = chars[i] == "\n"
            i += 1
        }
        return count
    }

    // The third probe ends INSIDE a fence the model never closed: no boundary is
    // legal there, so the drain must still finish rather than spin — and the
    // streamTask tail awaits that drain, so spinning would hang the turn.
    for probe in [(copies: 1, arrival: 900.0, truncated: false),
                  (copies: 24, arrival: 1_500.0, truncated: false),
                  (copies: 1, arrival: 900.0, truncated: true)] {
        var reply = String(repeating: unit, count: probe.copies)
        if probe.truncated { reply += "```swift\nlet unfinished = " }
        let chars = Array(reply)
        let arrivalMs = Int(Double(chars.count) / probe.arrival * 1000)
        var revealed = 0, elapsed = 0, sinceCommit = Int.max
        var commits: [(at: Int, gap: Int, finished: Bool)] = []
        while revealed < chars.count, elapsed < 300_000 {
            let arrived = min(chars.count, Int(probe.arrival * Double(elapsed) / 1000))
            let finished = elapsed >= arrivalMs
            let gap = finished ? ChatStore.sentenceTailGapMs : ChatStore.sentenceGapMs
            if revealed < arrived, sinceCommit >= gap {
                let commit = ChatStore.sentenceCommitLength(
                    in: String(chars.prefix(arrived)), revealed: revealed, finished: finished
                )
                if commit > revealed {
                    commits.append((at: commit, gap: sinceCommit, finished: finished))
                    revealed = commit
                    sinceCommit = 0
                }
            }
            let interval = ChatStore.typewriterInterval(forLength: max(arrived, 1))
            sinceCommit = sinceCommit >= Int.max - interval ? Int.max : sinceCommit + interval
            elapsed += interval
        }

        let offBoundary = commits.filter { !isBoundary(chars, $0.at) }
        // End-of-text is exempt: a finished reply must commit even if the model
        // left a fence open.
        let inFence = commits.filter { $0.at < chars.count && fencesBefore(chars, $0.at) % 2 == 1 }
        // The SPEC's numbers, deliberately literal: the loop above is driven by
        // ChatStore's constants, so asserting against those same constants would
        // be tautological — retuning them has to fail here.
        let tooEager = commits.dropFirst().filter { $0.gap < ($0.finished ? 60 : 140) }
        let trail = Double(elapsed - arrivalMs) / 1000
        let ok = offBoundary.isEmpty && inFence.isEmpty && tooEager.isEmpty
            && revealed == chars.count && trail <= 7
        print(String(format: "%6d chars @%.0f/s → %d commits, arrival %.1fs, reveal %.1fs (trail %.1fs) %@",
                     chars.count, probe.arrival, commits.count, Double(arrivalMs) / 1000,
                     Double(elapsed) / 1000, trail, ok ? "ok" : "BAD"))
        if let bad = offBoundary.first {
            let around = String(chars[max(0, bad.at - 12)..<min(chars.count, bad.at + 4)])
            failures.append("sentence: commit at \(bad.at) is mid-sentence (…\(around.debugDescription))")
        }
        if let bad = inFence.first { failures.append("sentence: commit at \(bad.at) is inside an open code fence") }
        if let bad = tooEager.first { failures.append("sentence: commit only \(bad.gap)ms after the previous one") }
        if revealed != chars.count { failures.append("sentence: revealed \(revealed)/\(chars.count)") }
        if trail > 7 { failures.append(String(format: "sentence: reveal trails arrival by %.1fs", trail)) }
    }

    // Delta 4 / 6a: the fade ramp is a spatial function of the drain's step, so
    // it must cover the head, stay monotonic towards opaque, and never extend
    // past what has actually been revealed.
    let ramp = TextReveal.ramp(head: 48)
    let covered = ramp.stops.reduce(0) { $0 + $1.length }
    let monotonic = zip(ramp.stops, ramp.stops.dropFirst()).allSatisfy { $0.alpha < $1.alpha }
    print("fade ramp: \(ramp.stops.count) bands over \(covered) chars, "
          + String(format: "alpha %.2f→%.2f %@", ramp.stops.first?.alpha ?? -1,
                   ramp.stops.last?.alpha ?? -1, covered == 48 && monotonic ? "ok" : "BAD"))
    if covered != 48 { failures.append("fade ramp covers \(covered) of 48 chars") }
    if !monotonic { failures.append("fade ramp alphas are not monotonic toward opaque") }
    if TextReveal.ramp(head: 0).stops.isEmpty == false { failures.append("fade ramp with no head is not empty") }

    // And that the ramp lands on the right characters when painted: the tail
    // fades, the settled text keeps its ORIGINAL attributes (so it can't drift
    // off the dynamic system colors), and the caret glyph stays solid.
    let sample = NSMutableAttributedString(
        string: String(repeating: "x", count: 60) + "▍",
        attributes: [.foregroundColor: NSColor.labelColor]
    )
    let painted = RevealFade.paint(sample, reveal: TextReveal(stops: ramp.stops, trailingSkip: 1))
    func alpha(at index: Int) -> CGFloat {
        (painted.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.alphaComponent ?? -1
    }
    let settled = painted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let caretColor = painted.attribute(.foregroundColor, at: 60, effectiveRange: nil) as? NSColor
    // Note labelColor is itself 85% opaque — the fade MULTIPLIES into whatever
    // alpha a run already had, so everything here is relative to that base.
    let base = NSColor.labelColor.alphaComponent
    let paintOK = settled === NSColor.labelColor       // untouched, not a copy
        && caretColor === NSColor.labelColor           // caret rides the head, never fades
        && alpha(at: 59) < base * 0.3                  // newest text is nearly invisible
        && alpha(at: 30) > alpha(at: 55)               // ramps toward opaque
    print(String(format: "fade paint: settled %@, caret %@, head %.2f, mid %.2f (base %.2f) %@",
                 settled === NSColor.labelColor ? "original" : "REWRITTEN",
                 caretColor === NSColor.labelColor ? "original" : "FADED",
                 alpha(at: 59), alpha(at: 30), base, paintOK ? "ok" : "BAD"))
    if !paintOK { failures.append("fade paint landed on the wrong characters") }

    print(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: "; "))
    exit(failures.isEmpty ? 0 : 1)
}

// User-installed Codex app-server check (no UI, no model turn/quota use):
//   .build/debug/PopChat --check-codex-app-server
if CommandLine.arguments.contains("--check-codex-app-server") {
    Task {
        do {
            let inspection = try await CodexAppServerClient.inspect(includeModels: true)
            print("codex=ready account=\(inspection.email ?? "?") plan=\(inspection.plan ?? "?")")
            print("models=\(inspection.models.joined(separator: ",")) default=\(inspection.defaultModel ?? "?")")
            let effortModels = inspection.models.compactMap { model -> String? in
                guard let efforts = inspection.supportedEfforts[model], !efforts.isEmpty else { return nil }
                return "\(model):\(efforts.joined(separator: "/"))"
            }
            print("efforts=\(effortModels.joined(separator: ","))")
            exit(0)
        } catch {
            print("CODEX-APP-SERVER-ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// LIVE check that the globe toggle actually reaches Codex's own web_search —
// needs the user's real Codex, signed in. `web_search` is a config ENUM and
// Codex REFUSES TO START on an unknown variant, so a wrong value here breaks
// every turn rather than just search; probe A therefore fails loudly if the
// variant PopChat sends stops being accepted. Probe B is the gate itself.
//   .build/debug/PopChat --smoke-codex-app-server-search
if CommandLine.arguments.contains("--smoke-codex-app-server-search") {
    Task {
        func turn(webSearch: Bool, model: String) async -> (text: String, searched: Bool, emptyQuery: Bool, error: String?) {
            let config = ProviderConfig(baseURL: "", apiKey: "", model: model, kind: .codexAppServer)
            let history = [OpenAIChatClient.WireMessage(
                role: "user",
                content: .text("Search the web: what is the current stable version of Swift? Answer in one line.")
            )]
            var text = ""
            var searched = false
            var emptyQuery = false
            var failure: String?
            for await event in CodexAppServerClient.run(
                history: history, config: config, webSearch: webSearch, inactivityTimeout: 120
            ) {
                switch event {
                case .partial(let value), .done(let value): text = value
                case .activity(let value):
                    if value.contains("searched the web") {
                        searched = true
                        // A row ending in a bare colon is the started-time
                        // labeling bug: the begin event has no query.
                        if value.trimmingCharacters(in: .whitespaces).hasSuffix(":") { emptyQuery = true }
                    }
                case .status: break
                case .error(let value): failure = value
                }
            }
            return (text, searched, emptyQuery, failure)
        }

        let model: String
        do {
            let inspection = try await CodexAppServerClient.inspect(includeModels: true)
            model = inspection.defaultModel ?? inspection.models.first ?? "gpt-5.1-codex"
        } catch {
            print("CODEX-APP-SERVER-ERROR: \(error.localizedDescription)")
            exit(1)
        }

        let on = await turn(webSearch: true, model: model)
        print("globe=on searched=\(on.searched) emptyQuery=\(on.emptyQuery) error=\(on.error ?? "none") text=\(on.text.prefix(120))")
        let off = await turn(webSearch: false, model: model)
        print("globe=off searched=\(off.searched) error=\(off.error ?? "none") text=\(off.text.prefix(120))")

        // Search FIRING is model-discretionary, so the pass condition is the
        // config being accepted (no error, an answer arrives) plus the gate
        // holding: with the globe off the tool must not exist to be called.
        // Any search row that DID fire must name its query.
        let passed = on.error == nil && !on.text.isEmpty && !on.emptyQuery
            && off.error == nil && !off.text.isEmpty
            && !off.searched
        print(passed ? "PASS" : "FAIL")
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// Deterministic transport regression harness. Pass a fake app-server executable
// (Tools/fake-codex-stream) that sends a delta before acknowledging turn/start,
// REPLAYS an item/completed, and fails mid-item with a willRetry error before
// re-delivering under a new item id. Laws, in order: the first partial must not
// wait for the turn/start acknowledgement; both completed items must survive;
// the replayed completion must not duplicate its item; the retryable error must
// drop the aborted in-flight partial (never glue the re-stream onto it) and
// surface a transient retry status instead of silence:
//   .build/debug/PopChat --smoke-codex-app-server-streaming /path/to/fake-codex
if let flag = CommandLine.arguments.firstIndex(of: "--smoke-codex-app-server-streaming"),
   CommandLine.arguments.count > flag + 1 {
    let executable = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Task {
        let started = Date()
        var firstPartialDelay: TimeInterval?
        var final = ""
        var failure: String?
        var sawAborted = false
        var sawGlued = false
        var sawRetryStatus = false
        let config = ProviderConfig(
            baseURL: "", apiKey: "", model: "fake-model",
            kind: .codexAppServer
        )
        let history = [OpenAIChatClient.WireMessage(role: "user", content: .text("stream"))]
        for await event in CodexAppServerClient.run(
            history: history,
            config: config,
            executableOverride: executable
        ) {
            switch event {
            case .partial(let text):
                if firstPartialDelay == nil { firstPartialDelay = Date().timeIntervalSince(started) }
                if text.contains("half-answer") { sawAborted = true }
                if text.contains("replacesC") { sawGlued = true }
                final = text
            case .done(let text):
                final = text
            case .status(let text):
                if text.localizedCaseInsensitiveContains("retrying") { sawRetryStatus = true }
            case .activity:
                break
            case .error(let message):
                failure = message
            }
        }
        let delay = firstPartialDelay ?? .infinity
        let lead = Date().timeIntervalSince(started) - delay
        // final == exactly the three items: the replayed completion of B would
        // make it four, and the aborted "half-answer…" partial must have been
        // streamed (sawAborted) but dropped rather than glued to C (sawGlued).
        let passed = failure == nil && final == "A\n\nB\n\nC" && lead > 1.0
            && sawAborted && !sawGlued && sawRetryStatus
        print(String(
            format: "first-partial=%.3fs lead=%.3fs aborted=%@ glued=%@ retry-status=%@ final=%@ %@",
            delay, lead,
            sawAborted ? "yes" : "no", sawGlued ? "yes" : "no", sawRetryStatus ? "yes" : "no",
            final.replacingOccurrences(of: "\n", with: "\\n"),
            passed ? "PASS" : "FAIL"
        ))
        if let failure { print("ERROR: \(failure)") }
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// A fake executable for this harness acknowledges setup, then stays silent after
// turn/start. The adapter must terminate it and surface the inactivity error:
//   .build/debug/PopChat --smoke-codex-app-server-timeout /path/to/fake-codex
if let flag = CommandLine.arguments.firstIndex(of: "--smoke-codex-app-server-timeout"),
   CommandLine.arguments.count > flag + 1 {
    let executable = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Task {
        let started = Date()
        var failure: String?
        let config = ProviderConfig(
            baseURL: "", apiKey: "", model: "fake-model",
            kind: .codexAppServer
        )
        let history = [OpenAIChatClient.WireMessage(role: "user", content: .text("stall"))]
        for await event in CodexAppServerClient.run(
            history: history,
            config: config,
            executableOverride: executable,
            inactivityTimeout: 0.25
        ) {
            if case .error(let message) = event { failure = message }
        }
        let elapsed = Date().timeIntervalSince(started)
        let passed = failure?.contains("stopped responding") == true && elapsed < 2
        print(String(format: "timeout=%.3fs %@ %@", elapsed, failure ?? "no error", passed ? "PASS" : "FAIL"))
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// Back-pressure regression. A fake executable that ACKNOWLEDGES setup and then
// stops draining its stdin must not be able to wedge PopChat: the adapter blocks
// inside a large `thread/inject_items` write, and stop() — the watchdog's and the
// Stop button's only exit — must still be able to terminate the child. Holding a
// lock across that write made stop() block on the lock the blocked write owned,
// and this harness never returned:
//   .build/debug/PopChat --smoke-codex-app-server-backpressure /path/to/fake-codex
if let flag = CommandLine.arguments.firstIndex(of: "--smoke-codex-app-server-backpressure"),
   CommandLine.arguments.count > flag + 1 {
    let executable = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Task {
        let started = Date()
        var failure: String?
        let config = ProviderConfig(
            baseURL: "", apiKey: "", model: "fake-model",
            kind: .codexAppServer
        )
        // Well past a ~64 KB pipe buffer: one downscaled image attachment is
        // about this big, so any real conversation carrying one reaches here.
        let filler = String(repeating: "x", count: 20_000)
        var history: [OpenAIChatClient.WireMessage] = (0..<40).map { index in
            OpenAIChatClient.WireMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: .text(filler)
            )
        }
        history.append(OpenAIChatClient.WireMessage(role: "user", content: .text("go")))
        for await event in CodexAppServerClient.run(
            history: history,
            config: config,
            executableOverride: executable,
            inactivityTimeout: 0.5
        ) {
            if case .error(let message) = event { failure = message }
        }
        // The assertion is that the stream ENDS AT ALL, with the inactivity error
        // rather than a hang — and that the EPIPE from terminating the child mid
        // write is thrown, not delivered as a fatal SIGPIPE.
        let elapsed = Date().timeIntervalSince(started)
        let passed = failure?.contains("stopped responding") == true && elapsed < 10
        print(String(
            format: "backpressure=%.3fs %@ %@",
            elapsed, failure ?? "no error", passed ? "PASS" : "FAIL"
        ))
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// ChatGPT-subscription auth + streaming checks (no UI):
//   .build/debug/PopChat --chatgpt-login    interactive: opens the browser OAuth flow
//   .build/debug/PopChat --smoke-chatgpt    requires a prior login; one streaming turn
if CommandLine.arguments.contains("--chatgpt-login") {
    Task { @MainActor in
        do {
            try await ChatGPTAuth.signIn()
            print("signed in: \(ChatGPTAuth.accountEmail ?? "?") plan=\(ChatGPTAuth.planLabel ?? "?")")
            exit(0)
        } catch {
            print("LOGIN-ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--smoke-chatgpt") {
    Task {
        guard ChatGPTAuth.isSignedIn else {
            print("SKIP: not signed in — run --chatgpt-login first")
            exit(1)
        }
        let model = ProcessInfo.processInfo.environment["POPCHAT_MODEL"] ?? ChatGPTAuth.defaultModel
        let config = ProviderConfig(baseURL: "", apiKey: "", model: model, kind: .chatGPT)
        let useSearch = CommandLine.arguments.contains("--with-search")
        print("smoke-chatgpt: model=\(model) account=\(ChatGPTAuth.accountEmail ?? "?") search=\(useSearch)")
        let prompt = useSearch
            ? "What is the latest stable release version of the Zed editor? Use web_search to check — do not answer from memory. Reply with just the version number and the source URL."
            : "Reply with exactly: PopChat ChatGPT OK"
        var chunks = 0
        let history = [OpenAIChatClient.WireMessage(role: "user", content: .text(prompt))]
        for await event in CodexResponsesClient.run(
            history: history,
            config: config,
            webAccess: useSearch ? .localTools(.duckduckgo) : nil
        ) {
            switch event {
            case .partial:
                chunks += 1
            case .activity(let text):
                print("[activity] \(text)")
            case .status(let text):
                print("[status] \(text)")
            case .done(let text):
                print("chunks=\(chunks)\nfinal=\(text)")
                exit(text.isEmpty ? 1 : 0)
            case .error(let message):
                print("ERROR: \(message)")
                exit(1)
            }
        }
        exit(1)
    }
    RunLoop.main.run()
}

// Conversation persistence round-trip check (no network, no UI).
if CommandLine.arguments.contains("--smoke-persist") {
    let conversation = Conversation(
        id: UUID(),
        title: "Persistence test",
        updatedAt: Date(),
        messages: [
            ChatMessage(role: .user, text: "hello"),
            ChatMessage(role: .assistant, text: "world"),
        ]
    )
    ConversationStore.save(conversation)
    let list = ConversationStore.listRecent()
    let loaded = ConversationStore.load(id: conversation.id)
    print("listCount=\(list.count) firstTitle=\(list.first?.title ?? "-") loadedMessages=\(loaded?.messages.count ?? -1) roundTripText=\(loaded?.messages.last?.text ?? "-")")
    ConversationStore.delete(id: conversation.id)
    print("afterDelete=\(ConversationStore.listRecent().filter { $0.id == conversation.id }.count)")

    // Fork tree round-trip: tail-only storage, chain resolution, and
    // materialization of children when the parent is deleted.
    let sharedTip = ChatMessage(role: .assistant, text: "shared tip")
    let parent = Conversation(
        id: UUID(), title: "Fork parent", updatedAt: Date(),
        messages: [ChatMessage(role: .user, text: "root q"), sharedTip,
                   ChatMessage(role: .user, text: "parent-only followup")]
    )
    let child = Conversation(
        id: UUID(), title: "Fork child", updatedAt: Date(),
        messages: [ChatMessage(role: .user, text: "diverged")],
        parentID: parent.id, forkMessageID: sharedTip.id
    )
    ConversationStore.save(parent)
    ConversationStore.save(child)
    let resolved = ConversationStore.loadResolved(id: child.id)
    print("forkResolved=\(resolved?.messages.count ?? -1) missingParent=\(resolved?.missingParent ?? true) tailOnDisk=\(ConversationStore.load(id: child.id)?.messages.count ?? -1)")
    ConversationStore.deleteMaterializingChildren(id: parent.id)
    let materialized = ConversationStore.load(id: child.id)
    print("afterParentDelete standalone=\(materialized?.parentID == nil) messages=\(materialized?.messages.count ?? -1)")
    ConversationStore.delete(id: child.id)
    exit(0)
}

// Attachment-loader check (no network): .build/debug/PopChat --smoke-file <path>
if let flagIndex = CommandLine.arguments.firstIndex(of: "--smoke-file"),
   CommandLine.arguments.count > flagIndex + 1 {
    let path = CommandLine.arguments[flagIndex + 1]
    Task {
        let result = await AttachmentLoader.load(url: URL(fileURLWithPath: path))
        switch result {
        case .success(let attachment):
            switch attachment.content {
            case .text(let text):
                print("OK text chars=\(text.count) note=\(attachment.note ?? "-")")
                print("preview: \(text.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))")
            case .image(let dataURL):
                print("OK image dataURLBytes=\(dataURL.count) note=\(attachment.note ?? "-")")
            }
        case .failure(let error):
            print("ATTACH-ERROR: \(error.message)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

/// Synthetic long-form conversation (prose/code/table/list/math) written into a
/// scratch store, so UI harnesses are deterministic and never touch real history.
func installBenchmarkConversation(minLength: Int) -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("popchat-bench-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    ConversationStore.overrideDirectory = scratch
    let block = """
    ## Section heading

    Some **bold** prose with `inline code`, a [link](https://example.com) and \
    inline math $e^{i\\pi} + 1 = 0$ to exercise every render path.

    ```swift
    func fib(_ n: Int) -> Int { n < 2 ? n : fib(n - 1) + fib(n - 2) }
    ```

    | Column A | Column B |
    |----------|----------|
    | one      | two      |

    - first item
    - second item

    $$\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}$$

    """
    var long = ""
    while long.count < minLength { long += block }
    ConversationStore.save(Conversation(
        id: UUID(),
        title: "ui benchmark",
        updatedAt: Date(),
        messages: [
            ChatMessage(role: .user, text: "benchmark"),
            ChatMessage(role: .assistant, text: long),
        ]
    ))
    return scratch
}

/// Conversation for the ⌘F harness: long enough to scroll, with the needle in
/// three widely separated messages so stepping matches must move the scroller.
func installFindConversation() -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("popchat-find-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    ConversationStore.overrideDirectory = scratch
    let filler = String(repeating: "Filler prose that exists purely to make the transcript tall. ", count: 30)
    var messages: [ChatMessage] = []
    for index in 0..<9 {
        let marker = index % 3 == 1 ? "needle\(index) " : "" // messages 1, 4, 7
        // Message 4 is pages long with its needle at the very END: centering the
        // MESSAGE would leave that hit far off screen, so it is what proves the
        // transcript scrolls to the matched characters.
        let body = index == 4 ? String(repeating: filler, count: 12) + " tailneedle end." : filler
        messages.append(ChatMessage(
            role: index % 2 == 0 ? .user : .assistant,
            text: "\(marker)message \(index). \(body)"
        ))
    }
    ConversationStore.save(Conversation(
        id: UUID(),
        title: "find harness",
        updatedAt: Date(),
        messages: messages
    ))
    return scratch
}

/// The transcript scroller is the vertically-scrollable NSScrollView with the
/// tallest document — a plain "first match" walk can land on a code block's
/// horizontal scroller or an attachment strip.
@MainActor
func transcriptScrollView(in root: NSView?) -> NSScrollView? {
    var best: NSScrollView?
    func walk(_ view: NSView) {
        if let scroll = view as? NSScrollView,
           let doc = scroll.documentView,
           doc.frame.height > (best?.documentView?.frame.height ?? 0) {
            best = scroll
        }
        for sub in view.subviews { walk(sub) }
    }
    if let root { walk(root) }
    return best
}

// Panel sizing invariants: real controller + synthetic conversation, replaying
// empty↔non-empty transitions. With messages the content height and min must
// never sit below the expanded minimum (320).
if CommandLine.arguments.contains("--smoke-minsize") {
    MainActor.assumeIsolated {
        let scratch = installBenchmarkConversation(minLength: 2_000)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Geometry persisted on a display that is now gone: the panel must come
        // back FITTING the current screen. Nothing else shrinks it (position()
        // is satisfied by a 120x80 intersection), so an oversized restore would
        // put every resize edge off-screen with no way to recover. Stored in the
        // real defaults domain, so the previous values go back on the way out.
        let defaults = UserDefaults.standard
        let priorWidth = defaults.double(forKey: "panelWidth")
        let priorHeight = defaults.double(forKey: "panelExpandedHeight")
        defaults.set(9_000, forKey: "panelWidth")
        defaults.set(9_000, forKey: "panelExpandedHeight")
        @MainActor func restoreGeometryDefaults() {
            if priorWidth > 0 { defaults.set(priorWidth, forKey: "panelWidth") }
            else { defaults.removeObject(forKey: "panelWidth") }
            if priorHeight > 0 { defaults.set(priorHeight, forKey: "panelExpandedHeight") }
            else { defaults.removeObject(forKey: "panelExpandedHeight") }
        }
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()
        restoreGeometryDefaults() // the panel exists now; don't leave 9000 lying around
        let originalID = controller.chatStore.conversationID

        // The enforced minimum lives in the windowWillResize delegate (the
        // NSHostingView zeroes contentMinSize) — probe it like a user drag.
        @MainActor func clamp(_ panel: NSWindow, _ size: NSSize) -> NSSize {
            controller.windowWillResize(panel, to: size)
        }

        @MainActor func findFieldScroll(_ view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
            for sub in view.subviews { if let found = findFieldScroll(sub) { return found } }
            return nil
        }

        @MainActor func findDragStrip(_ view: NSView?) -> WindowDragView? {
            guard let view else { return nil }
            if let strip = view as? WindowDragView { return strip }
            for sub in view.subviews { if let found = findDragStrip(sub) { return found } }
            return nil
        }

        @MainActor func report(_ label: String) {
            guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else {
                restoreGeometryDefaults()
                print("FAIL: no panel"); exit(1)
            }
            let content = panel.contentRect(forFrameRect: panel.frame)
            let clamped = clamp(panel, NSSize(width: 400, height: 197))
            // Where does the composer field actually sit? Its bottom edge plus the
            // capsule + composer paddings (5+6+12) must stay inside the window.
            var fieldNote = "field=?"
            if let scroll = findFieldScroll(panel.contentView), let root = panel.contentView {
                let frame = scroll.convert(scroll.bounds, to: root)
                let bottomGap = root.isFlipped ? root.bounds.height - frame.maxY : frame.minY
                fieldNote = "fieldY=\(Int(root.isFlipped ? frame.minY : root.bounds.height - frame.maxY))"
                    + " fieldH=\(Int(frame.height)) gapBelowField=\(Int(bottomGap))"
            }
            if let strip = findDragStrip(panel.contentView), let root = panel.contentView {
                let frame = strip.convert(strip.bounds, to: root)
                fieldNote += " pillsY=\(Int(root.isFlipped ? frame.minY : root.bounds.height - frame.maxY))"
                    + " pillsH=\(Int(frame.height)) rootH=\(Int(root.bounds.height))"
            }
            print("\(label): contentH=\(Int(content.height)) w=\(Int(content.width)) \(fieldNote) " +
                  "dragTo400x197→\(Int(clamped.width))x\(Int(clamped.height)) " +
                  "empty=\(controller.chatStore.messages.isEmpty)")
        }

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            MainActor.assumeIsolated {
                step += 1
                switch step {
                case 1:
                    report("launch non-empty")
                    controller.chatStore.newChat()
                case 2:
                    report("after newChat  ")
                    controller.chatStore.loadConversation(originalID)
                case 3:
                    report("after reload   ")
                default:
                    guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { exit(1) }
                    let height = panel.contentRect(forFrameRect: panel.frame).height
                    let clamped = clamp(panel, NSSize(width: 400, height: 197))
                    // The field must keep its designed bottom clearance (5+6+12
                    // = 23pt) — a smaller gap means the input capsule is being
                    // squeezed out of the panel (e.g. by safe-area insets the
                    // compact height report can't see).
                    var gapOK = false
                    if let scroll = findFieldScroll(panel.contentView), let root = panel.contentView {
                        let frame = scroll.convert(scroll.bounds, to: root)
                        let bottomGap = root.isFlipped ? root.bounds.height - frame.maxY : frame.minY
                        gapOK = bottomGap >= 20
                    }
                    // Oversized restore must have been shrunk onto a real screen.
                    let frame = panel.frame
                    let fits = NSScreen.screens.contains { screen in
                        frame.width <= screen.visibleFrame.width + 0.5
                            && frame.height <= screen.visibleFrame.height + 0.5
                    }
                    print("restored-from-9000x9000 frame=\(Int(frame.width))x\(Int(frame.height)) fitsAScreen=\(fits)")
                    let ok = !controller.chatStore.messages.isEmpty
                        && height >= 319 && clamped.width >= 519 && clamped.height >= 319 && gapOK && fits
                    print(ok ? "PASS" : "FAIL: settled height=\(Int(height)) clamp=\(Int(clamped.width))x\(Int(clamped.height)) gapOK=\(gapOK)")
                    try? FileManager.default.removeItem(at: scratch)
                    exit(ok ? 0 : 1)
                }
            }
        }
        app.run()
    }
}

// UI layout stress (no network): builds the real panel with a synthetic long
// conversation and bounces the transcript scroll while a watchdog thread checks
// main-thread responsiveness. Catches layout-convergence hangs.
if CommandLine.arguments.contains("--smoke-scroll") {
    nonisolated(unsafe) var lastPong = Date()
    nonisolated(unsafe) var maxPingLatency = 0.0
    Thread.detachNewThread {
        while true {
            let sent = Date()
            DispatchQueue.main.async {
                lastPong = Date()
                maxPingLatency = max(maxPingLatency, Date().timeIntervalSince(sent))
            }
            Thread.sleep(forTimeInterval: 0.25)
            if Date().timeIntervalSince(lastPong) > 3 {
                print("HANG pid=\(ProcessInfo.processInfo.processIdentifier) — main thread stalled >3s")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 60) // stay alive so the stack can be sampled
                exit(2)
            }
        }
    }
    MainActor.assumeIsolated {
        let scratch = installBenchmarkConversation(minLength: 20_000)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        var elapsed = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                elapsed += 0.05
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }),
                      let scroll = transcriptScrollView(in: panel.contentView),
                      let doc = scroll.documentView else {
                    if elapsed > 3 { print("FAIL: no transcript scroll view found"); exit(1) }
                    return
                }
                let maxY = max(0, doc.frame.height - scroll.contentSize.height)
                let phase = (sin(elapsed * 1.5) + 1) / 2
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * phase))
                scroll.reflectScrolledClipView(scroll.contentView)
                if Int(elapsed * 20) % 20 == 0 {
                    print(String(format: "t=%.1fs offset=%.0f of %.0f", elapsed, maxY * phase, maxY))
                    fflush(stdout)
                }
                if elapsed >= 12 {
                    print(String(format: "PASS: 12s of scrolling, max main-thread ping latency %.0f ms", maxPingLatency * 1000))
                    try? FileManager.default.removeItem(at: scratch)
                    if maxY < 500 {
                        print("FAIL: transcript content did not exceed the viewport — layout suspect")
                        exit(1)
                    }
                    exit(0)
                }
            }
        }
        app.run()
    }
}

// Typing responsiveness check: real panel + synthetic 20k-char conversation in a
// scratch store, simulated edits in the real composer after warmup. Reports max
// warmed main-thread stall and whether transcript measurements scale with
// keystrokes. Fails (exit 3) on stalls above 50 ms.
if CommandLine.arguments.contains("--smoke-typing") {
    nonisolated(unsafe) var maxWarmStall = 0.0
    nonisolated(unsafe) var warmed = false
    nonisolated(unsafe) var warmStart = Date()
    nonisolated(unsafe) var stallLog: [(Double, Double)] = [] // (s since warm, ms)
    Thread.detachNewThread {
        while true {
            let sent = Date()
            DispatchQueue.main.async {
                let latency = Date().timeIntervalSince(sent)
                if warmed {
                    maxWarmStall = max(maxWarmStall, latency)
                    if latency > 0.02 {
                        stallLog.append((Date().timeIntervalSince(warmStart), latency * 1000))
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    MainActor.assumeIsolated {
        let scratch = installBenchmarkConversation(minLength: 20_000)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        func focusedEditor() -> NSTextView? {
            guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { return nil }
            if let editor = panel.firstResponder as? NSTextView { return editor }
            func findTextView(_ view: NSView?) -> NSTextView? {
                guard let view else { return nil }
                if let textView = view as? NSTextView, textView.isEditable { return textView }
                for sub in view.subviews {
                    if let found = findTextView(sub) { return found }
                }
                return nil
            }
            if let textView = findTextView(panel.contentView) {
                panel.makeFirstResponder(textView)
                return panel.firstResponder as? NSTextView
            }
            return nil
        }

        var elapsed = 0.0
        var edits = 0
        var measurementsAtWarm = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                elapsed += 0.03
                if elapsed < 2.0 { return } // cold construction + prewarm window
                if !warmed {
                    warmed = true
                    warmStart = Date()
                    measurementsAtWarm = SelectableText.measurementCount
                    print("warmup done; measurements so far: \(measurementsAtWarm)")
                }
                guard let editor = focusedEditor() else {
                    print("FAIL: no focused editor")
                    try? FileManager.default.removeItem(at: scratch)
                    exit(1)
                }
                if edits < 150 {
                    // Alternate grow/shrink so height changes are exercised too.
                    if edits % 10 == 9 {
                        editor.deleteBackward(nil)
                    } else {
                        editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    edits += 1
                } else {
                    let typedMeasurements = SelectableText.measurementCount - measurementsAtWarm
                    let stallMs = maxWarmStall * 1000
                    print(String(format: "edits=%d transcript+composer measurements during typing=%d maxWarmedStall=%.1f ms",
                                 edits, typedMeasurements, stallMs))
                    for (at, ms) in stallLog.prefix(20) {
                        print(String(format: "  stall %.0f ms at t=%.2fs", ms, at))
                    }
                    try? FileManager.default.removeItem(at: scratch)
                    if stallMs > 50 {
                        print("FAIL: warmed main-thread stall exceeded 50 ms")
                        exit(3)
                    }
                    print("PASS")
                    exit(0)
                }
            }
        }
        app.run()
    }
}

// Composer keeps focus when messages appear: types into the empty panel, sends,
// then types again — through real key events, so a lost first responder shows up
// as "the keystroke went nowhere" exactly as it does for the user. `/nope` is an
// unknown slash command: it drives the real send path (rows appended, panel grows
// 120→440) without touching the network.
if CommandLine.arguments.contains("--smoke-input") {
    MainActor.assumeIsolated {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("popchat-input-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        ConversationStore.overrideDirectory = scratch
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: ShortcutStore())
        controller.show()

        // Unbundled, this binary gets its own UserDefaults domain, so the provider
        // list is freshly generated and the app's stored key (keyed by the app's
        // provider UUID) doesn't match. --live borrows POPCHAT_API_KEY like the
        // other live harnesses; the entry is removed again on the way out.
        // SecretStore writes the REAL secrets file (it has no scratch override),
        // so put back exactly what was there — deleting unconditionally would
        // destroy a key this debug profile already had.
        var borrowedAccount: String?
        var displacedSecret: String?
        if CommandLine.arguments.contains("--live"),
           let key = ProcessInfo.processInfo.environment["POPCHAT_API_KEY"], !key.isEmpty,
           let provider = providerStore.selectedProvider {
            borrowedAccount = provider.id.uuidString
            displacedSecret = SecretStore.get(account: provider.id.uuidString)
            SecretStore.set(key, account: provider.id.uuidString)
        }
        func cleanup() {
            if let borrowedAccount {
                if let displacedSecret {
                    SecretStore.set(displacedSecret, account: borrowedAccount)
                } else {
                    SecretStore.delete(account: borrowedAccount)
                }
            }
            try? FileManager.default.removeItem(at: scratch)
        }

        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            cleanup()
            exit(1)
        }
        func composer(in view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let textView = view as? NSTextView, textView.isEditable { return textView }
            for sub in view.subviews { if let found = composer(in: sub) { return found } }
            return nil
        }
        // A real keystroke: through the window, to whatever holds first responder.
        func type(_ character: String, into panel: NSWindow) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: 0
            ) else { fail("could not synthesize a keystroke") }
            panel.sendEvent(event)
        }

        var step = 0
        weak var focusedBefore: NSTextView?
        var lastReplyID: UUID?
        var markedString = ""
        var composing = false
        var committedCJK = 0
        var lastTargetLength = 0
        var ticksSinceArrival = 0
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { fail("no panel") }
                step += 1
                switch step {
                case 1: return // settle
                case 2:
                    guard let field = composer(in: panel.contentView) else { fail("no composer field") }
                    panel.makeFirstResponder(field)
                    focusedBefore = field
                    type("a", into: panel)
                case 3:
                    guard let field = composer(in: panel.contentView) else { fail("composer vanished") }
                    if field.string != "a" { fail("baseline typing did not reach the composer (draft=\(field.string.debugDescription))") }
                    controller.chatStore.send("/nope") // rows appear, panel grows
                case 4...5:
                    return // let the growth animation and layout settle
                case 6:
                    guard let field = composer(in: panel.contentView) else { fail("composer vanished after send") }
                    let same = field === focusedBefore
                    let isFirst = panel.firstResponder === field
                    print("after send: sameTextView=\(same) firstResponder=\(isFirst) rows=\(controller.chatStore.messages.count)")
                    type("b", into: panel)
                    // Assert on the keystroke, not on first responder: what matters
                    // is whether the user's next character lands.
                    if field.string != "ab" {
                        fail("typing after a new message went nowhere (draft=\(field.string.debugDescription), "
                             + "sameTextView=\(same), firstResponder=\(isFirst))")
                    }
                    print("static rows: ok")
                    // Phase 2: an IME composition (Chinese/Japanese/Korean pinyin
                    // etc.) is MARKED text — uncommitted, owned by the input
                    // context, and destroyed by any write to textView.string. A
                    // committed keystroke survives a transcript update; marked text
                    // is the thing that doesn't, so it needs its own check.
                    field.setMarkedText(
                        "ni", selectedRange: NSRange(location: 2, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0)
                    )
                    if !field.hasMarkedText() { fail("could not start a marked-text composition") }
                    markedString = field.string
                    controller.chatStore.send("/nope again") // rows appear → transcript re-renders
                case 7:
                    guard let field = composer(in: panel.contentView) else { fail("composer vanished mid-composition") }
                    if !field.hasMarkedText() {
                        fail("IME composition was cancelled by a transcript update — "
                             + "marked text lost (was \(markedString.debugDescription), now \(field.string.debugDescription))")
                    }
                    // And it must still be composable: extend, then commit.
                    field.setMarkedText(
                        "niha", selectedRange: NSRange(location: 4, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0)
                    )
                    field.insertText("你好", replacementRange: field.markedRange())
                    if !field.string.contains("你好") {
                        fail("committing the composition did not reach the composer (draft=\(field.string.debugDescription))")
                    }
                    print("IME composition survived a transcript update and committed: \(field.string.debugDescription)")
                    // Phase 3 (--live, needs a configured provider): the same checks
                    // WHILE a reply streams and the typewriter re-renders the
                    // transcript ~30×/s. That is the state the user reported.
                    guard CommandLine.arguments.contains("--live") else {
                        print("PASS (offline; pass --live to also test during streaming)")
                        cleanup()
                        exit(0)
                    }
                    field.string = ""
                    controller.chatStore.send("Write about 250 words on the history of the fountain pen.")
                default:
                    guard CommandLine.arguments.contains("--live") else { fail("harness ran past its steps") }
                    guard let field = composer(in: panel.contentView) else { fail("composer vanished mid-stream") }
                    // Wait for the reply to start, then type one character per tick.
                    let reply = controller.chatStore.messages.last(where: { $0.role == .assistant })?.text ?? ""
                    if reply.isEmpty {
                        if step > 60 {
                            let rows = controller.chatStore.messages
                                .map { "\($0.role.rawValue): \($0.text.prefix(120))" }
                                .joined(separator: "\n  ")
                            fail("no reply after 20s. Rows:\n  \(rows)")
                        }
                        return
                    }
                    if composing {
                        // The composition has now lived across a tick of streaming
                        // re-renders — the exact thing that used to abort it.
                        if !field.hasMarkedText() {
                            fail("IME composition was cancelled by the streaming transcript "
                                 + "(draft=\(field.string.debugDescription), replyChars=\(reply.count))")
                        }
                        field.insertText("好", replacementRange: field.markedRange())
                        composing = false
                        if !field.string.hasSuffix("好") {
                            fail("committing a mid-stream composition failed (draft=\(field.string.debugDescription))")
                        }
                        committedCJK += 1
                    } else {
                        let before = field.string
                        type("x", into: panel)
                        if field.string != before + "x" {
                            fail("keystroke lost while the reply was streaming "
                                 + "(draft=\(field.string.debugDescription), expected \((before + "x").debugDescription), "
                                 + "firstResponder=\(panel.firstResponder === field), replyChars=\(reply.count))")
                        }
                        field.setMarkedText(
                            "hao", selectedRange: NSRange(location: 3, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0)
                        )
                        composing = true
                    }
                    // `streamTarget` stops growing the moment the LAST chunk lands —
                    // the network turn is over there, whatever the typewriter is
                    // still doing. Ticks since that point measure how long the
                    // composer stayed locked afterwards.
                    let target = controller.chatStore.streamTargetLength
                    if target > lastTargetLength {
                        lastTargetLength = target
                        ticksSinceArrival = 0
                    } else if target > 0 {
                        ticksSinceArrival += 1
                    }
                    if !controller.chatStore.isStreaming, !composing, committedCJK >= 2 {
                        print("during a \(reply.count)-char reply: \(field.string.count) chars in the draft, "
                              + "\(committedCJK) IME compositions survived and committed")
                        // isStreaming must drop when the NETWORK turn ends, not when
                        // the typewriter finishes revealing: while it is true the send
                        // button is a Stop button and Return is a no-op, so a lagging
                        // reveal locked the composer for seconds after the reply had
                        // arrived. Being mid-reveal here is the point of the check.
                        let revealed = controller.chatStore.messages.last(where: { $0.role == .assistant })?.text.count ?? 0
                        let lockedFor = Double(ticksSinceArrival) * 0.4
                        print(String(format: "composer released %.1fs after the last chunk, with %d/%d chars revealed",
                                     lockedFor, revealed, target))
                        if lockedFor > 1.2 {
                            fail(String(format: "composer stayed locked %.1fs after the reply arrived — "
                                        + "isStreaming is tracking the typewriter, not the network", lockedFor))
                        }
                        // Forking mid-reveal: fork() persists the PARENT and then
                        // re-points the store at the branch, so a partial row here
                        // would be frozen into the parent's file and never
                        // corrected — the reply truncated for good.
                        if let replyID = controller.chatStore.messages.last(where: { $0.role == .assistant })?.id {
                            let parentID = controller.chatStore.conversationID
                            controller.chatStore.fork(at: replyID)
                            let onDisk = ConversationStore.loadResolved(id: parentID)?.messages
                                .last(where: { $0.role == .assistant })?.text.count ?? 0
                            print("forked mid-reveal: parent holds \(onDisk)/\(target) chars on disk")
                            if onDisk != target {
                                fail("forking mid-reveal persisted a truncated reply (\(onDisk)/\(target) chars)")
                            }
                        }
                        let userRows = controller.chatStore.messages.filter { $0.role == .user }.count
                        controller.chatStore.send("second turn")
                        if controller.chatStore.messages.filter({ $0.role == .user }).count != userRows + 1 {
                            fail("could not start a new turn while the reply was still revealing")
                        }
                        let tail = controller.chatStore.messages.first(where: { $0.id == lastReplyID })?.text.count ?? 0
                        if tail != target {
                            fail("sending mid-reveal left the previous reply truncated (\(tail)/\(target) chars)")
                        }
                        print("PASS")
                        cleanup()
                        exit(0)
                    }
                    lastReplyID = controller.chatStore.messages.last(where: { $0.role == .assistant })?.id
                }
            }
        }
        app.run()
    }
}

// ⌘Y history popover: asserts the shortcut opens it, that the filter field takes
// focus, and that ↓/↩ select and open a chat (the popover tears down).
if CommandLine.arguments.contains("--smoke-history") {
    MainActor.assumeIsolated {
        let scratch = installFindConversation()
        for title in ["alpha chat", "beta chat"] {
            ConversationStore.save(Conversation(
                id: UUID(), title: title, updatedAt: Date(),
                messages: [ChatMessage(role: .user, text: title)]
            ))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        func filterField() -> NSTextField? {
            var found: NSTextField?
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, field.placeholderString == "Filter chats…" { found = field }
                for sub in view.subviews where found == nil { walk(sub) }
            }
            // Visible windows only: a dismissed popover keeps its window (and
            // view tree) around, so an unfiltered walk still finds the field.
            for window in app.windows where found == nil && window.isVisible {
                walk(window.contentView ?? NSView())
            }
            return found
        }

        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            try? FileManager.default.removeItem(at: scratch)
            exit(1)
        }

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { return }
                step += 1
                switch step {
                case 1...2:
                    return
                case 3:
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil,
                        characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16
                    ) else { fail("could not synthesize ⌘Y") }
                    if !panel.performKeyEquivalent(with: event) { fail("⌘Y was not handled by the panel") }
                case 4...5:
                    guard let field = filterField() else {
                        if step == 5 { fail("history popover did not appear on ⌘Y") }
                        return // popover animates in; give it one more tick
                    }
                    guard let editor = field.currentEditor(), field.window?.firstResponder === editor else {
                        fail("history filter field did not take first responder")
                    }
                    editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    step = 6
                case 6...7:
                    if filterField() != nil {
                        if step == 7 { fail("↩ did not open the selected chat / dismiss the popover") }
                        return
                    }
                    print("PASS")
                    try? FileManager.default.removeItem(at: scratch)
                    exit(0)
                default:
                    fail("harness ran past its steps")
                }
            }
        }
        app.run()
    }
}

// ⌘F find-in-chat: drives the real panel through open → type → step → close and
// asserts the find field takes focus, that stepping matches moves the transcript
// scroller, and that ⎋ tears the bar down again.
if CommandLine.arguments.contains("--smoke-find") {
    MainActor.assumeIsolated {
        let scratch = installFindConversation()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        func findField(in root: NSView?) -> NSTextField? {
            var found: NSTextField?
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, field.placeholderString == "Find in chat" { found = field }
                for sub in view.subviews where found == nil { walk(sub) }
            }
            if let root { walk(root) }
            return found
        }

        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            try? FileManager.default.removeItem(at: scratch)
            exit(1)
        }

        /// Every painted highlight in the transcript, as (field, rect in field
        /// coordinates). Laid out independently of the app's own reveal code so
        /// the check isn't just the implementation agreeing with itself.
        func highlights(in root: NSView?) -> [(field: NSTextField, rect: NSRect, active: Bool)] {
            var result: [(NSTextField, NSRect, Bool)] = []
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, field.isSelectable {
                    let attributed = field.attributedStringValue
                    attributed.enumerateAttribute(
                        .backgroundColor,
                        in: NSRange(location: 0, length: attributed.length)
                    ) { value, range, _ in
                        guard let color = value as? NSColor else { return }
                        let storage = NSTextStorage(attributedString: attributed)
                        let manager = NSLayoutManager()
                        let container = NSTextContainer(size: NSSize(
                            width: field.bounds.width, height: .greatestFiniteMagnitude
                        ))
                        container.lineFragmentPadding = 0
                        manager.addTextContainer(container)
                        storage.addLayoutManager(manager)
                        manager.ensureLayout(for: container)
                        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
                        let top = field.isFlipped ? bounds.minY : field.bounds.height - bounds.maxY
                        result.append((
                            field,
                            NSRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.height),
                            color.alphaComponent > 0.3
                        ))
                    }
                }
                for sub in view.subviews { walk(sub) }
            }
            if let root { walk(root) }
            return result
        }

        func typeQuery(_ query: String) {
            guard let editor = findField(in: NSApp.windows.first(where: { $0 is FloatingPanel })?.contentView)?
                .currentEditor() else { fail("find field vanished") }
            editor.selectAll(nil)
            editor.insertText(query)
        }

        var step = 0
        var offsetAtFirstMatch: CGFloat = 0
        var measurementsBeforeTyping = 0
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { return }
                let scroll = transcriptScrollView(in: panel.contentView)
                step += 1
                switch step {
                case 1...2:
                    return // let the panel settle
                case 3:
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil,
                        characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
                    ) else { fail("could not synthesize ⌘F") }
                    if !panel.performKeyEquivalent(with: event) { fail("⌘F was not handled by the panel") }
                case 4:
                    guard let field = findField(in: panel.contentView) else { fail("find bar did not appear on ⌘F") }
                    guard let editor = field.currentEditor(), panel.firstResponder === editor else {
                        fail("find field did not take first responder")
                    }
                    measurementsBeforeTyping = SelectableText.measurementCount
                    editor.insertText("needle")
                case 5:
                    guard let scroll else { fail("no transcript scroll view") }
                    // Highlights must be painted in place, and exactly one of
                    // them is the active hit.
                    let painted = highlights(in: panel.contentView)
                    let active = painted.filter(\.active)
                    print("painted highlights=\(painted.count) active=\(active.count)")
                    // 4: messages 1, 4 and 7 carry "needleN", plus "tailneedle".
                    if painted.count != 4 { fail("expected 4 painted matches, got \(painted.count)") }
                    if active.count != 1 { fail("expected exactly 1 active match, got \(active.count)") }
                    offsetAtFirstMatch = scroll.contentView.bounds.origin.y
                    guard let editor = findField(in: panel.contentView)?.currentEditor() else {
                        fail("find field vanished mid-search")
                    }
                    // doCommand routes through the field editor's delegate — the
                    // same path a real ↓ keypress takes.
                    editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                case 6:
                    guard let scroll else { fail("no transcript scroll view") }
                    let moved = abs(scroll.contentView.bounds.origin.y - offsetAtFirstMatch)
                    print(String(format: "match 1 at offset %.0f, ↓ moved %.0f pt", offsetAtFirstMatch, moved))
                    if moved < 20 { fail("stepping to the next match did not scroll the transcript") }
                    // The exactness check: this needle sits at the END of a
                    // multi-page message.
                    typeQuery("tailneedle")
                case 7:
                    guard let scroll, let document = scroll.documentView else { fail("no transcript scroll view") }
                    let painted = highlights(in: panel.contentView)
                    guard painted.count == 1, let hit = painted.first else {
                        fail("expected 1 match for the tail needle, got \(painted.count)")
                    }
                    let inDocument = hit.field.convert(hit.rect, to: document)
                    let visible = scroll.documentVisibleRect
                    print(String(format: "tail hit y=%.0f (h=%.0f) visible %.0f…%.0f",
                                 inDocument.midY, hit.field.frame.height, visible.minY, visible.maxY))
                    if !visible.insetBy(dx: 0, dy: -1).intersects(inDocument) {
                        fail("the matched characters are off screen — scrolled to the message, not the hit")
                    }
                    let typed = SelectableText.measurementCount - measurementsBeforeTyping
                    print("transcript measurements during find typing=\(typed)")
                    if typed > 8 { fail("highlighting re-measured the transcript (\(typed) measurements)") }
                    guard let editor = findField(in: panel.contentView)?.currentEditor() else {
                        fail("find field vanished before ⎋")
                    }
                    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                case 8:
                    if findField(in: panel.contentView) != nil { fail("⎋ did not close the find bar") }
                    if !panel.isVisible { fail("⎋ closed the panel instead of the find bar") }
                    // Same IME rule as the composer, other widget: searching in
                    // Chinese means composing in this field while the transcript
                    // may re-render underneath it.
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil,
                        characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
                    ) else { fail("could not synthesize ⌘F") }
                    _ = panel.performKeyEquivalent(with: event)
                case 9:
                    guard let editor = findField(in: panel.contentView)?.currentEditor() as? NSTextView else {
                        fail("find field did not reopen")
                    }
                    editor.setMarkedText(
                        "zhong", selectedRange: NSRange(location: 5, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0)
                    )
                    if !editor.hasMarkedText() { fail("could not start a composition in the find field") }
                    controller.chatStore.send("/nope") // rows appear → the whole panel re-renders
                case 10:
                    guard let editor = findField(in: panel.contentView)?.currentEditor() as? NSTextView else {
                        fail("find field vanished mid-composition")
                    }
                    if !editor.hasMarkedText() {
                        fail("IME composition in the find field was cancelled by a transcript update "
                             + "(now \(editor.string.debugDescription))")
                    }
                    print("find-field IME composition survived a transcript update")
                    print("PASS")
                    try? FileManager.default.removeItem(at: scratch)
                    exit(0)
                default:
                    fail("harness ran past its steps")
                }
            }
        }
        app.run()
    }
}

// Accent-color laws (no GUI, no network): .build/debug/PopChat --smoke-accent
//
// The custom accent turns any hex into HSB and back on every popover open, so
// that round trip has to be lossless; and the reason the picker is hand-rolled
// at all is that a color leaving 0…1 packs into #FFFFFF (the system color
// panel's extended-range colors did exactly that — "my accent turns white").
if CommandLine.arguments.contains("--smoke-accent") {
    func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }

    // 1. HSB → hex → HSB is stable at 8-bit precision.
    var checked = 0
    for hueStep in 0...20 {
        for saturation in [0.15, 0.5, 0.85, 1.0] {
            for brightness in [0.2, 0.6, 1.0] {
                let hue = Double(hueStep) / 20
                let first = Theme.hex(hue: hue, saturation: saturation, brightness: brightness)
                let (h, s, b) = Theme.hsb(first)
                let second = Theme.hex(hue: h, saturation: s, brightness: b)
                guard first == second else {
                    fail("hsb round trip drifted: \(first) → \(second) (h\(hue) s\(saturation) b\(brightness))")
                }
                guard first.count == 7, first.hasPrefix("#"), UInt64(first.dropFirst(), radix: 16) != nil else {
                    fail("emitted malformed hex \(first)")
                }
                checked += 1
            }
        }
    }

    // 2. Out-of-range input clamps instead of overflowing the hex. This is the
    //    white bug in miniature: 1.4 × 255 = 357 formatted as %02X is "165",
    //    which shifts every channel and reads back as a different color.
    //    Hue is an angle and WRAPS (1.4 → 0.4); saturation and brightness clamp.
    let clamped = Theme.hex(hue: 1.4, saturation: 2, brightness: 3)
    guard clamped == Theme.hex(hue: 0.4, saturation: 1, brightness: 1) else {
        fail("out-of-range HSB did not wrap hue / clamp saturation+brightness: \(clamped)")
    }
    for (hue, saturation, brightness) in [(1.4, 2.0, 3.0), (-0.3, -1.0, -2.0), (7.5, 0.5, 9.0)] {
        let hex = Theme.hex(hue: hue, saturation: saturation, brightness: brightness)
        guard hex.count == 7, UInt64(hex.dropFirst(), radix: 16) != nil else {
            fail("out-of-range HSB emitted malformed hex \(hex)")
        }
    }

    // 3. A malformed stored value falls back to the default accent, not black.
    let fallback = Theme.components(Theme.defaultAccentHex)
    for bad in ["", "#12", "#GGGGGG", "0A84FF00", "not a color"] {
        let parsed = Theme.components(bad)
        guard parsed == fallback else { fail("bad hex \(bad.isEmpty ? "<empty>" : bad) did not fall back to the default accent") }
    }
    guard Theme.components("#0a84ff") == Theme.components("#0A84FF") else { fail("hex parsing is case-sensitive") }

    // 4. Filled bubbles pick the more legible of black/white. Pale accents are
    //    exactly what fixed white text got wrong; mid-tone blues and purples are
    //    what a pure max-WCAG-ratio rule gets wrong in the other direction.
    let expectations: [(String, NSColor)] = [
        ("#FFFFFF", .black), ("#FFD60A", .black), ("#30D158", .black),
        ("#FF9F0A", .black), ("#9BE8F0", .black),
        ("#000000", .white), ("#0A84FF", .white), ("#BF5AF2", .white),
        ("#FF3B30", .white), ("#5A2AA0", .white),
    ]
    for (hex, expected) in expectations {
        let picked = Theme.contrastingNSColor(on: hex)
        guard picked == expected else {
            fail("\(hex) picked \(picked == NSColor.white ? "white" : "black") text")
        }
    }
    // The decision must be monotonic in lightness — one flip along a ramp, white
    // below and black above. An oscillating rule would strobe while dragging the
    // Brightness slider.
    for hue in [0.0, 0.25, 0.6, 0.85] {
        let decisions = (0...20).map { step -> Bool in
            let hex = Theme.hex(hue: hue, saturation: 0.7, brightness: Double(step) / 20)
            return Theme.contrastingNSColor(on: hex) == NSColor.black
        }
        // Brightness 0 is black, so every ramp starts on white text; saturated
        // reds and blues stay there even at full brightness (they are still
        // perceptually dark), so the flip to black is allowed, not required.
        guard decisions.first == false else { fail("hue \(hue): a black fill must take white text") }
        let flips = zip(decisions, decisions.dropFirst()).filter { $0 != $1 }.count
        guard flips <= 1 else { fail("hue \(hue): text color flipped \(flips) times along a brightness ramp") }
    }
    guard Theme.bubbleForegroundNSColor(style: .accentTint, accentHex: "#FFD60A") == .labelColor else {
        fail("tinted bubbles must keep label color — the fill is mostly panel")
    }

    // 5. Bubble-style migration: "quietGray" is gone, and decodes to the default.
    guard BubbleStyle(rawValue: "quietGray") == nil else { fail("quietGray is still a case") }
    guard BubbleStyle(rawValue: "quietGray") ?? .accentTint == .accentTint else { fail("quietGray must fall back to accentTint") }

    print("OK: \(checked) HSB round trips, clamping, hex fallbacks, contrast and bubble-style migration")
    exit(0)
}

// Drop-target laws (no GUI, no network): .build/debug/PopChat --smoke-drop
//
// "Drag a fresh screenshot in" is a FILE-PROMISE drag: the PNG doesn't exist
// on disk until the destination receives the promise, so the old URL-only
// `.dropDestination(for: URL.self)` ignored it — that was the bug. In-process
// promise RESOLUTION cannot be simulated (the pasteboard server never calls a
// source back inside its own process — verified while writing this), so the
// promise law checks acceptance and that the receive was initiated; a live
// screenshot-thumbnail drag is the end-to-end check.
if CommandLine.arguments.contains("--smoke-drop") {
    MainActor.assumeIsolated {
        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            exit(1)
        }
        func pump(timeout: TimeInterval, until check: () -> Bool, what: String) {
            let deadline = Date().addingTimeInterval(timeout)
            while !check() {
                guard Date() < deadline else { fail("timed out waiting for \(what)") }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        final class PromiseSource: NSObject, NSFilePromiseProviderDelegate {
            func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
                "Screenshot Smoke.png"
            }
            func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
                // Never reached in-process; the law only needs the promise on
                // the pasteboard to be well-formed.
                completionHandler(NSError(domain: "smoke-drop", code: 1))
            }
        }
        func scratchPasteboard(_ suffix: String) -> NSPasteboard {
            let pasteboard = NSPasteboard(name: .init("popchat-smoke-drop-\(suffix)-\(ProcessInfo.processInfo.processIdentifier)"))
            pasteboard.clearContents()
            return pasteboard
        }

        let view = PanelDropView()
        let model = ComposerModel()
        view.onFileURLs = { model.handleFiles($0) }
        view.onImage = { model.handleImage($0, suggestedName: "dropped-image.jpg") }
        view.onError = { model.attachNotice = $0 }

        // 1. Registration: refuse any of these types and the drag never even
        //    highlights the panel. The promise list is the screenshot thumbnail.
        let registered = Set(view.registeredDraggedTypes.map(\.rawValue))
        for type in NSFilePromiseReceiver.readableDraggedTypes where !registered.contains(type) {
            fail("not registered for promise type \(type) — a screenshot-thumbnail drag would be refused")
        }
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff] where !registered.contains(type.rawValue) {
            fail("not registered for \(type.rawValue)")
        }

        // 2. A promise-only drag (the screenshot thumbnail) is accepted and
        //    initiates a receive; nothing attaches synchronously.
        let promiseSource = PromiseSource()
        let promisePasteboard = scratchPasteboard("promise")
        guard promisePasteboard.writeObjects([NSFilePromiseProvider(fileType: "public.png", delegate: promiseSource)]) else {
            fail("couldn't write a file promise to the scratch pasteboard")
        }
        guard view.accepts(promisePasteboard) else { fail("a file-promise drag is not accepted") }
        guard view.handleDrop(from: promisePasteboard) else { fail("a file-promise drop was not handled") }
        guard model.pendingAttachments.isEmpty else { fail("a promise drop attached synchronously — it must wait for the promised file") }
        guard let promiseDestination = view.lastPromiseDestination,
              FileManager.default.fileExists(atPath: promiseDestination.path) else {
            fail("a promise drop did not initiate a receive into a destination directory")
        }

        // 3. A plain file-URL drag still attaches end-to-end.
        let textURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("popchat-smoke-drop-\(ProcessInfo.processInfo.processIdentifier).txt")
        do { try "drop smoke".write(to: textURL, atomically: true, encoding: .utf8) } catch {
            fail("couldn't write scratch file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: textURL) }
        let filePasteboard = scratchPasteboard("file")
        guard filePasteboard.writeObjects([textURL as NSURL]) else { fail("couldn't write the file URL") }
        guard view.accepts(filePasteboard), view.handleDrop(from: filePasteboard) else { fail("a file-URL drop was not handled") }
        pump(timeout: 5, until: { !model.pendingAttachments.isEmpty }, what: "the file-URL attachment")
        guard case .text(let text) = model.pendingAttachments[0].content, text.contains("drop smoke") else {
            fail("the file-URL drop did not attach the file's text")
        }

        // 4. Raw image data with no file behind it (browser image drags; also
        //    the screenshot path on pasteboards that carry bitmap data).
        model.clear()
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let imagePasteboard = scratchPasteboard("image")
        guard imagePasteboard.writeObjects([image]) else { fail("couldn't write the image") }
        guard view.accepts(imagePasteboard), view.handleDrop(from: imagePasteboard) else { fail("a raw-image drop was not handled") }
        guard model.pendingAttachments.count == 1, case .image = model.pendingAttachments[0].content else {
            fail("the raw-image drop did not attach an image")
        }

        // 5. Priority: file URLs beat promises (no pointless copy through the
        //    temp dir) and beat image data (a Finder drag can carry the file
        //    icon as an image — matching images first would attach the icon).
        model.clear()
        let mixedPasteboard = scratchPasteboard("mixed")
        guard mixedPasteboard.writeObjects([
            textURL as NSURL,
            NSFilePromiseProvider(fileType: "public.png", delegate: promiseSource),
            image,
        ]) else { fail("couldn't write the mixed drag") }
        guard view.handleDrop(from: mixedPasteboard) else { fail("the mixed drop was not handled") }
        pump(timeout: 5, until: { !model.pendingAttachments.isEmpty }, what: "the mixed-drop attachment")
        guard model.pendingAttachments.count == 1, case .text = model.pendingAttachments[0].content else {
            fail("a drag carrying a file URL must attach the file, not the image data")
        }
        guard view.lastPromiseDestination == promiseDestination else {
            fail("a drag carrying a file URL must not also receive its file promise")
        }

        // 6. A text-only drag is someone dragging selected text — not ours.
        let stringPasteboard = scratchPasteboard("string")
        stringPasteboard.setString("just text", forType: .string)
        guard !view.accepts(stringPasteboard) else { fail("a text-only drag must not be accepted") }
        guard !view.handleDrop(from: stringPasteboard) else { fail("a text-only drop must not be handled") }

        print("OK: promise accepted + receive initiated, file URL and raw image attach, URL-first priority, text refused")
        exit(0)
    }
}

// Design QA: renders a view to PNG in-process (`--shot <settings|switcher> <path>`),
// so the layout can be checked without screen-recording permission.
if let shotIndex = CommandLine.arguments.firstIndex(of: "--shot"),
   CommandLine.arguments.count > shotIndex + 2 {
    MainActor.assumeIsolated {
        let which = CommandLine.arguments[shotIndex + 1]
        let path = CommandLine.arguments[shotIndex + 2]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--dark") {
            app.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--light") {
            app.appearance = NSAppearance(named: .aqua)
        }

        let defaults = UserDefaults.standard
        let providerKeys = [
            "providersJSON", "selectedProviderID", "knownModelsJSON", "selectedModelsJSON",
            "knownModelEffortsJSON", "defaultModelEffortsJSON", "selectedModelEffortsJSON",
            "accentColor", "customAccentColor", "bubbleStyle",
        ]
        let snapshot = providerKeys.reduce(into: [String: Any?]()) { $0[$1] = defaults.object(forKey: $1) }
        func restore() {
            for key in providerKeys {
                if let value = snapshot[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        // A custom accent already chosen, so the row renders its selected state
        // (`--no-custom` renders the untouched state instead).
        if which == "general", !CommandLine.arguments.contains("--no-custom") {
            // `--accent <hex>` overrides, for checking a fill's text color.
            var accent = "#E0655B"
            if let index = CommandLine.arguments.firstIndex(of: "--accent"),
               CommandLine.arguments.count > index + 1 {
                accent = CommandLine.arguments[index + 1]
            }
            defaults.set(accent, forKey: "accentColor")
            defaults.set(accent, forKey: "customAccentColor")
            if CommandLine.arguments.contains("--fill") {
                defaults.set(BubbleStyle.accentFill.rawValue, forKey: "bubbleStyle")
            }
        }

        let store = ProviderStore()
        let deepseek = Provider(id: UUID(), name: "DeepSeek", baseURL: "https://api.deepseek.com", isPreset: true, defaultModel: "deepseek-chat")
        let chatgpt = ProviderStore.chatGPTPreset()
        let router = Provider(id: UUID(), name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", isPreset: true, defaultModel: "openrouter/auto")
        let ollama = Provider(id: UUID(), name: "Ollama (local)", baseURL: "http://localhost:11434/v1", isPreset: true, defaultModel: "")
        let groq = Provider(id: UUID(), name: "Groq", baseURL: "https://api.groq.com/openai/v1", isPreset: false, defaultModel: "llama-3.3-70b")
        store.providers = [chatgpt, deepseek, groq, router, ollama]
        store.knownModels = [
            chatgpt.id: ChatGPTAuth.modelCatalog,
            deepseek.id: ["deepseek-chat", "deepseek-coder", "deepseek-reasoner"],
            groq.id: ["llama-3.3-70b", "mixtral-8x7b"],
        ]
        store.knownModelEfforts = [chatgpt.id: Dictionary(uniqueKeysWithValues: ChatGPTAuth.modelCatalog.map {
            ($0, ChatGPTAuth.supportedReasoningEfforts(for: $0))
        })]
        store.defaultModelEfforts = [chatgpt.id: Dictionary(uniqueKeysWithValues: ChatGPTAuth.modelCatalog.compactMap { model in
            ChatGPTAuth.defaultReasoningEffort(for: model).map { (model, $0) }
        })]
        store.selectedModels = [
            chatgpt.id: ChatGPTAuth.defaultModel,
            deepseek.id: "deepseek-chat",
            groq.id: "llama-3.3-70b",
        ]
        store.selectedID = which == "switcher-effort" ? chatgpt.id : deepseek.id

        let content: NSView
        let size: NSSize
        switch which {
        case "switcher", "switcher-effort":
            content = NSHostingView(rootView: ProviderSwitcher(store: store)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: which == "switcher-effort" ? 530 : 412, height: 340)
        case "general":
            content = NSHostingView(rootView: SettingsView(
                store: store, shortcutStore: ShortcutStore(), tab: .general
            ))
            size = NSSize(width: 540, height: 620)
        case "accent":
            content = NSHostingView(rootView: AccentPickerPopover(
                accentHex: .constant("#E0655B"), customHex: .constant("#E0655B")
            )
                .background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: 268, height: 190)
        default:
            content = NSHostingView(rootView: SettingsView(
                store: store, shortcutStore: ShortcutStore(), tab: .providers, editing: groq.id
            ))
            size = NSSize(width: 540, height: 620)
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    print("FAIL: could not build a bitmap")
                    restore()
                    exit(1)
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    print("FAIL: could not encode PNG")
                    restore()
                    exit(1)
                }
                try? data.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
                restore()
                exit(0)
            }
        }
        app.run()
    }
}

// Delta 5's core rule, which is a BEHAVIOUR and not a look: browsing providers
// must never switch what the next message uses. Drives the real 7c switcher
// through provider → model → effort and asserts nothing commits until ↩, then asserts the
// catalog side (addCustom must not select) and that the green-dot predicate and
// the rail agree.
//
// Runs against the real ProviderStore — the provider defaults keys are
// snapshotted and restored on every exit path, and only `.test` base URLs are
// ever installed, so no network and no lasting change to the user's setup.
private actor CodexRefreshProbe {
    private(set) var calls = 0

    func inspect(includeModels: Bool) async throws -> CodexAppServerClient.Inspection {
        calls += 1
        try await Task.sleep(for: .milliseconds(150))
        return CodexAppServerClient.Inspection(
            email: "fake@example.test",
            plan: "test",
            models: includeModels ? ["fake-model"] : [],
            defaultModel: includeModels ? "fake-model" : nil,
            supportedEfforts: includeModels ? ["fake-model": ["low", "high"]] : [:],
            defaultEfforts: includeModels ? ["fake-model": "low"] : [:]
        )
    }
}

// Three simultaneous callers must share one inspection and publish one coherent
// result. This is intentionally independent of a real Codex installation.
if CommandLine.arguments.contains("--smoke-codex-refresh-coalescing") {
    Task { @MainActor in
        let defaults = UserDefaults.standard
        let keys = [
            "providersJSON", "selectedProviderID", "knownModelsJSON", "selectedModelsJSON",
            "knownModelEffortsJSON", "defaultModelEffortsJSON", "selectedModelEffortsJSON",
        ]
        let snapshot = keys.reduce(into: [String: Any?]()) { $0[$1] = defaults.object(forKey: $1) }
        func restore() {
            for key in keys {
                if let value = snapshot[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let store = ProviderStore()
        let provider = ProviderStore.codexAppServerPreset()
        store.providers = [provider]
        store.selectedID = provider.id
        let probe = CodexRefreshProbe()
        async let first: Void = store.refreshCodexAppServer(
            includeModels: true,
            inspection: { try await probe.inspect(includeModels: $0) }
        )
        async let second: Void = store.refreshCodexAppServer(
            includeModels: true,
            inspection: { try await probe.inspect(includeModels: $0) }
        )
        async let third: Void = store.refreshCodexAppServer(
            includeModels: true,
            inspection: { try await probe.inspect(includeModels: $0) }
        )
        _ = await (first, second, third)

        let calls = await probe.calls
        let ready: Bool
        if case .ready = store.codexAppServerStatus { ready = true } else { ready = false }
        let passed = calls == 1
            && ready
            && store.knownModels[provider.id] == ["fake-model"]
            && !store.fetchingProviders.contains(provider.id)
        print("refresh-calls=\(calls) ready=\(ready) \(passed ? "PASS" : "FAIL")")
        restore()
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--smoke-providers") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let defaults = UserDefaults.standard
        let providerKeys = [
            "providersJSON", "selectedProviderID", "knownModelsJSON", "selectedModelsJSON",
            "knownModelEffortsJSON", "defaultModelEffortsJSON", "selectedModelEffortsJSON",
        ]
        let snapshot = providerKeys.reduce(into: [String: Any?]()) { $0[$1] = defaults.object(forKey: $1) }
        func restore() {
            for key in providerKeys {
                if let value = snapshot[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            restore()
            exit(1)
        }

        let store = ProviderStore()
        let alpha = Provider(id: UUID(), name: "Harness A", baseURL: "https://a.test/v1", isPreset: true, defaultModel: "a-1")
        let beta = Provider(id: UUID(), name: "Harness B", baseURL: "https://b.test/v1", isPreset: true, defaultModel: "b-1")
        store.providers = [alpha, beta]
        store.knownModels = [alpha.id: ["a-1", "a-2"], beta.id: ["b-1", "b-2"]]
        store.selectedModels = [alpha.id: "a-1", beta.id: "b-1"]
        store.knownModelEfforts = [
            beta.id: ["b-1": ["low", "medium", "high"], "b-2": ["low", "medium", "high"]],
        ]
        store.defaultModelEfforts = [beta.id: ["b-1": "medium", "b-2": "medium"]]
        store.selectedModelEfforts = [:]
        store.selectedID = alpha.id
        guard store.configuredProviders.map(\.id) == [alpha.id, beta.id] else {
            fail("seeded providers are not both offered by the switcher")
        }
        guard store.currentReasoningEffort == nil else {
            fail("provider without effort capabilities acquired an effort value")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: ProviderSwitcher(store: store))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        /// The switcher's invisible first responder (ProviderSwitcher.KeyCaptureView).
        func captureView() -> NSView? {
            // Match the AppKit view itself, not SwiftUI's representable host —
            // the host's class name embeds the wrapped type's name too.
            var found: NSView?
            func walk(_ view: NSView) {
                if String(describing: type(of: view)).contains("CaptureView"), view.acceptsFirstResponder {
                    found = view
                }
                for sub in view.subviews where found == nil { walk(sub) }
            }
            walk(window.contentView ?? NSView())
            return found
        }

        func send(_ keyCode: UInt16, _ label: String) {
            guard let view = captureView() else { fail("switcher key capture view vanished") }
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
            ) else { fail("could not synthesize \(label)") }
            view.keyDown(with: event)
        }

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                step += 1
                switch step {
                case 1:
                    return // let the popover body appear and claim first responder
                case 2:
                    guard let view = captureView() else { fail("switcher did not install its key capture view") }
                    guard window.firstResponder === view else {
                        fail("switcher key capture view did not take first responder")
                    }
                    send(125, "↓")             // rail: Harness A → Harness B
                    if store.selectedID != alpha.id {
                        fail("arrowing the provider rail COMMITTED — preview must not switch (delta 5, 7c)")
                    }
                case 3:
                    send(124, "→")             // into the model column
                    send(125, "↓")             // b-1 → b-2
                    if store.selectedID != alpha.id {
                        fail("moving into the model column committed a provider switch")
                    }
                    if store.currentModel != "a-1" {
                        fail("previewing another provider's models changed the live model")
                    }
                case 4:
                    send(124, "→")             // into the effort column (default medium)
                    send(125, "↓")             // medium → high
                    if store.selectedID != alpha.id || store.selectedModelEfforts[beta.id] != nil {
                        fail("previewing effort committed before ↩")
                    }
                case 5:
                    send(36, "↩")
                case 6:
                    if store.selectedID != beta.id { fail("↩ did not commit the previewed provider") }
                    if store.selectedModels[beta.id] != "b-2" { fail("↩ did not commit the focused model") }
                    if store.selectedModelEfforts[beta.id]?["b-2"] != "high" {
                        fail("↩ did not commit the focused effort")
                    }
                    if store.currentConfig()?.reasoningEffort != "high" {
                        fail("committed effort did not reach ProviderConfig")
                    }
                    print("preview stayed inert; ↩ committed Harness B · b-2 · high")

                    // Catalog side (7b): adding a provider in Settings must not
                    // redirect the live conversation.
                    let added = store.addCustom()
                    if store.selectedID != beta.id {
                        fail("addCustom() switched the live provider — Settings must never write selectedID")
                    }
                    store.remove(added)

                    // The green dot and the rail are one predicate: every
                    // configured provider is offered, and the only row the rail
                    // adds is the live one.
                    let rail = Set(store.configuredProviders.map(\.id))
                    for provider in store.providers {
                        let configured = store.isConfigured(provider)
                        if configured && !rail.contains(provider.id) {
                            fail("\(provider.name) is green in Settings but missing from the switcher")
                        }
                        if !configured && rail.contains(provider.id) && provider.id != store.selectedID {
                            fail("\(provider.name) is offered by the switcher but gray in Settings")
                        }
                    }
                    print("green-dot law matches the switcher rail")
                    print("PASS")
                    restore()
                    exit(0)
                default:
                    fail("harness ran past its steps")
                }
            }
        }
        app.run()
    }
}

// An LSUIElement app that opens nothing on launch reads as broken, and
// double-clicking it again — the natural retry — used to be a literal no-op.
// This drives the REAL launch path with the install marker cleared:
//   .build/debug/PopChat --smoke-firstrun
// (a GUI harness: it takes key window, so don't run it beside the others.)
if CommandLine.arguments.contains("--smoke-firstrun") {
    let launchDelegate = MainActor.assumeIsolated { AppDelegate() }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.delegate = launchDelegate
        app.setActivationPolicy(.accessory)

        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: AppDelegate.hasLaunchedKey)
        func restore() {
            if let saved { defaults.set(saved, forKey: AppDelegate.hasLaunchedKey) }
            else { defaults.removeObject(forKey: AppDelegate.hasLaunchedKey) }
        }
        // Pretend this machine has never run PopChat.
        defaults.removeObject(forKey: AppDelegate.hasLaunchedKey)

        var failures: [String] = []
        func check(_ passed: Bool, _ law: String) {
            print("\(passed ? "ok  " : "FAIL") \(law)")
            if !passed { failures.append(law) }
        }
        func step(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
        }

        // The launch UI is posted from applicationDidFinishLaunching via
        // main.async, and the hint waits a further 0.35s behind the panel.
        step(1.0) {
            check(launchDelegate.isPanelOnScreen, "first launch opens the panel")
            check(FirstRunHint.isShowing, "first launch points at the menu bar icon")
            check(defaults.bool(forKey: AppDelegate.hasLaunchedKey), "the install marker is recorded")
            check(!FirstRunHint.shortcutDescription.isEmpty, "the hint names a real recorded shortcut")

            FirstRunHint.dismiss()
            launchDelegate.hidePanel()
        }
        // Second launch on the same machine: silent, as it has always been.
        step(1.5) {
            launchDelegate.presentLaunchUI(loginItem: false)
        }
        step(2.0) {
            check(!launchDelegate.isPanelOnScreen, "a later launch stays out of the way")

            // ...and a login-item launch stays silent even on a fresh install:
            // the user asked for PopChat to be READY at boot, not to greet them.
            defaults.removeObject(forKey: AppDelegate.hasLaunchedKey)
            launchDelegate.presentLaunchUI(loginItem: true)
        }
        step(2.5) {
            check(!launchDelegate.isPanelOnScreen, "a login-item launch never opens the panel")

            // The headline fix: double-clicking an already-running app.
            _ = launchDelegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
        }
        step(3.0) {
            check(launchDelegate.isPanelOnScreen, "reopening the app shows the panel")
            restore()
            print(failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}

// NSApplication.delegate is held unowned — the top-level constant keeps it alive
// for the app's lifetime.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    // Accessory: no Dock icon, no menu bar takeover. The status item is the only chrome.
    app.setActivationPolicy(.accessory)
    app.run()
}
