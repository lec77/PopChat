import AppKit

// Headless streaming checks (no UI):
//   POPCHAT_API_KEY=… .build/debug/PopChat --smoke          plain streaming
//   POPCHAT_API_KEY=… .build/debug/PopChat --smoke-search   agentic loop w/ DuckDuckGo
let smokePlain = CommandLine.arguments.contains("--smoke")
let smokeSearch = CommandLine.arguments.contains("--smoke-search")
if smokePlain || smokeSearch {
    Task {
        let env = ProcessInfo.processInfo.environment
        let config = ProviderConfig(
            baseURL: env["POPCHAT_BASE_URL"] ?? ProviderConfig.defaultBaseURL,
            apiKey: env["POPCHAT_API_KEY"] ?? "",
            model: env["POPCHAT_MODEL"] ?? ProviderConfig.defaultModel
        )
        let prompt = smokeSearch
            ? "What is the latest stable release version of the Zed editor? Use web_search to check — do not answer from memory. Reply with just the version number and the source URL."
            : "Reply with exactly: PopChat streaming OK"
        print("smoke: \(config.baseURL) model=\(config.model) search=\(smokeSearch)")
        var chunks = 0
        let history = [OpenAIChatClient.WireMessage(role: "user", content: .text(prompt))]
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
