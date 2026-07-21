import AppKit

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
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()
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
                    let ok = !controller.chatStore.messages.isEmpty
                        && height >= 319 && clamped.width >= 519 && clamped.height >= 319 && gapOK
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
