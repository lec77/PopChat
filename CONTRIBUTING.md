# Developing PopChat

PopChat is built for personal use and shared as-is, so there is no roadmap and no guarantee a pull request gets merged — but bug reports are welcome, and if you want to build on it yourself, this is what you need to know.

## Layout

Plain SwiftPM, no Xcode project. `Package.swift` builds a single executable target; `build.sh` wraps the binary in an app bundle (`LSUIElement`, ad-hoc signed) and `release.sh` does the Developer-ID + notarization path.

```
Sources/PopChat/         AppKit shell, SwiftUI views, Theme
Sources/PopChat/Chat/    providers, streaming clients, stores, web tools
Resources/               Info.plist, app icon
Tools/                   fake app-server fixtures used by the smoke harnesses
```

`KeyboardShortcuts` is pinned to exactly 1.15.0: later versions use `#Preview` macros, which need full Xcode and fail to compile with the Command Line Tools alone.

## Test harnesses

`swift build` produces `.build/debug/PopChat`, which doubles as a headless test harness — there is no XCTest suite; the flags below are the test suite.

```sh
POPCHAT_API_KEY=… .build/debug/PopChat --smoke              # live streaming round-trip
POPCHAT_API_KEY=… .build/debug/PopChat --smoke-search       # tool-calling loop
.build/debug/PopChat --smoke-file <path>                    # attachment extraction
.build/debug/PopChat --smoke-typing                         # composer latency budget
.build/debug/PopChat --smoke-scroll                         # transcript scroll perf
.build/debug/PopChat --smoke-find                           # find-in-chat behavior
```

`--smoke-persist`, `--smoke-history`, `--smoke-minsize`, `--smoke-pasteable`, `--smoke-providers`, `--smoke-accent`, `--smoke-typewriter`, `--chatgpt-login` and `--smoke-chatgpt` cover the rest. `--check-codex-app-server` checks the installed Codex, ChatGPT login and available model catalog without starting a model turn; `--smoke-codex-refresh-coalescing` verifies overlapping checks share one process. `--shot <settings|general|switcher> <path> [--dark|--light]` renders a view to PNG in-process.

Three harnesses drive a fake app-server instead of the real one, so they cost no subscription quota and need no Codex install:

```sh
.build/debug/PopChat --smoke-codex-app-server-streaming    Tools/fake-codex-stream
.build/debug/PopChat --smoke-codex-app-server-timeout      Tools/fake-codex-stall
.build/debug/PopChat --smoke-codex-app-server-backpressure Tools/fake-codex-wedge
```

They guard, in order: turn assembly and notification ordering (both agent messages must survive, the first delta must not wait on the `turn/start` response, a replayed `item/completed` must not duplicate its item, and a `willRetry` error must drop the aborted in-flight partial and surface a retry status rather than gluing the re-stream onto it in silence); recovery from a process that goes silent mid-turn; and the rule that a process which stops draining its stdin cannot wedge PopChat — never hold a lock across the blocking write, or Stop and the watchdog both block behind it.

Two rules when running these:

- Each GUI harness builds a real key window, so **run them one at a time**, not back-to-back — otherwise they fight over key status and stray keystrokes land in the wrong field, failing spuriously.
- The performance harnesses fail on main-thread stalls, so run `--smoke-typing` and `--smoke-scroll` after touching the transcript, the composer or panel sizing.

## Performance constraints

Responsiveness is a hard requirement, and several obvious-looking changes break it badly. Before touching the transcript or composer, know that: the transcript is a plain `VStack` (a `LazyVStack` fights `NSScrollView` into a freeze), message rows are `Equatable`-gated so a streaming tick re-renders only the changed row, the root `NSHostingView` has `sizingOptions = []` so composer resizing can't re-measure the whole tree, and panel show/hide animates a `CALayer` transform rather than the window frame. Visual fidelity matters; implementation fidelity does not — prefer the cheapest technique that looks the same.

## Releasing

`./release.sh` builds, signs with a Developer ID, notarizes and staples both the app and the disk image, then verifies it as Gatekeeper would. It needs a stored notarytool profile (see the header comment in the script) and only works with my certificate.
