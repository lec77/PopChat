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

// UI layout stress (no network): builds the real panel — which auto-resumes the
// most recent conversation — and bounces the transcript scroll while a watchdog
// thread checks main-thread responsiveness. Catches layout-convergence hangs.
if CommandLine.arguments.contains("--smoke-scroll") {
    nonisolated(unsafe) var lastPong = Date()
    Thread.detachNewThread {
        while true {
            DispatchQueue.main.async { lastPong = Date() }
            Thread.sleep(forTimeInterval: 0.5)
            if Date().timeIntervalSince(lastPong) > 3 {
                print("HANG pid=\(ProcessInfo.processInfo.processIdentifier) — main thread stalled >3s")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 60) // stay alive so the stack can be sampled
                exit(2)
            }
        }
    }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        func findScrollView(_ view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let scroll = view as? NSScrollView { return scroll }
            for sub in view.subviews {
                if let found = findScrollView(sub) { return found }
            }
            return nil
        }

        var elapsed = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                elapsed += 0.05
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }),
                      let scroll = findScrollView(panel.contentView),
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
                    print("PASS: 12s of scrolling, main thread responsive")
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
