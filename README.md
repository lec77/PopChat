# PopChat

A lightweight macOS menu bar app: press a global hotkey (default **⌥Space**) and a
floating chat panel appears with the input already focused. Press it again (or **Esc**)
and the panel disappears, returning focus to whatever app you were in.

It restores the old ChatGPT-app popup experience — instant, non-activating, always a
keystroke away — but you point it at whichever model you want: your ChatGPT
subscription, an API key, or a model running locally.

Native Swift + SwiftUI, no Electron. Menu-bar only, no Dock icon.

## Features

- **Instant panel** — a non-activating `NSPanel`, so showing it never steals focus from
  the app underneath and dismissing it returns focus immediately. Remembers where you
  last dragged it. ⌘P pins it open.
- **Any OpenAI-compatible provider** — OpenAI, OpenRouter, Ollama, or any custom endpoint
  (DeepSeek, Groq, LM Studio, …), plus model discovery via `/models`. Switch provider and
  model from a pill in the panel header.
- **Sign in with ChatGPT** — use your own ChatGPT Plus/Pro subscription instead of an API
  key, via the same OAuth flow the Codex CLI uses.
- **Streaming with a typewriter feel**, a stop button, and errors surfaced in the
  transcript rather than swallowed.
- **Web search & fetch** — the model can call `web_search` and `fetch_url` in a capped
  loop, shown as gray activity rows in the transcript. Backends: DuckDuckGo (default, no
  key), Tavily, Brave, or OpenRouter's native web plugin. Globe toggle in the input bar.
- **Attachments** — drag & drop, ⌘V paste (files *and* raw screenshots), or the paperclip
  picker. Images become vision blocks; PDF / docx / rtf / xlsx / csv are extracted to
  text. Anything it can't handle produces an explicit error instead of degrading silently.
- **Conversations** — persisted as JSON, most recent auto-resumed at launch, filterable
  history popover (⌘Y) with day groups. Any assistant message can be **forked** into a
  new branch that shares the history up to that point.
- **Slash commands** — your own prompt templates with a `{input}` placeholder and an
  autocomplete popup when the draft starts with `/`.
- **Rich rendering** — markdown with cross-block text selection, syntax-highlighted code
  blocks, LaTeX (`$…$`, `$$…$$`), hairline tables, and `<pasteable>` blocks: one-click-copy
  cards for reusable content the model produces.
- **Find in chat** (⌘F) — match count, wrapping ↑/↓ navigation, highlights painted at the
  exact character range and scrolled into view.
- **Large editor** (⌘E) — the input capsule morphs into a full draft editor; ⌘↩ sends.
- **Liquid-glass look** on macOS 26 (translucent panel with an adjustable tint), a solid
  fallback below that, Light/Dark/Auto appearance, four accent presets plus a custom
  color picker, and full support for Reduce Motion / Reduce Transparency.

## Install

Download the latest `PopChat-x.y.z.dmg` from
[Releases](https://github.com/lec77/PopChat/releases), open it, and drag PopChat to
Applications. The disk image is signed and notarized, so it opens without a Gatekeeper
detour. Settings → General has a launch-at-login toggle.

Requires **macOS 14 or later**. The liquid-glass backdrop needs macOS 26; older systems
get a solid panel.

## Build from source

Needs a Swift toolchain — Xcode, or just the Command Line Tools
(`xcode-select --install`).

```sh
git clone https://github.com/lec77/PopChat.git
cd PopChat
./build.sh              # release build → dist/PopChat.app
open dist/PopChat.app
```

`./build.sh debug` builds the debug configuration. The script wraps the SwiftPM binary in
an app bundle and **ad-hoc signs** it, which is fine for a build you made yourself.
`./release.sh` is the other path — it signs with a Developer ID, builds the disk image,
and notarizes it; that one only works with my certificate.

There is no Xcode project — it's plain SwiftPM (`Package.swift`) plus `build.sh`.

## Setup

Open Settings from the menu bar icon or **⌘,** inside the panel.

- **Providers** — pick a preset or add a custom OpenAI-compatible endpoint, paste an API
  key, and fetch the model list. For ChatGPT-subscription access, use *Sign in with
  ChatGPT* (opens your browser; needs port 1455 free during the flow).
- **Web Search** — choose the engine; Tavily/Brave need keys, DuckDuckGo doesn't.
- **Commands** — edit the system prompt and define slash commands.
- **Hotkey** — record whatever global shortcut you want (⌥Space by default).

Local models need no key at all: run Ollama and pick its preset, or point a custom
endpoint at LM Studio's server.

### Where things are stored

| What | Where |
| --- | --- |
| Providers, models, preferences | `UserDefaults` (`com.chenle.PopChat`) |
| API keys & OAuth tokens | `~/Library/Application Support/PopChat/secrets.json` (chmod 600) |
| Conversations | `~/Library/Application Support/PopChat/conversations/*.json` |

Secrets are a plain JSON file, not the Keychain: with ad-hoc signing every rebuild
changes the binary identity, and macOS would then demand the login-keychain password on
every launch. The file matches the trust model of the `.env` the keys usually come from.

## Keyboard shortcuts

| | |
| --- | --- |
| ⌥Space | show / hide the panel (recordable) |
| Esc | hide the panel |
| ⌘N | new chat |
| ⌘Y | history popover (↑/↓ select, ↩ open, ⌘⌫ delete) |
| ⌘F | find in chat (↑/↓ or ⌘G/⇧⌘G to step, ⎋ to close) |
| ⌘E | large draft editor (⌘↩ sends) |
| ⌘P | pin the panel open |
| ⌘, | Settings |
| ↩ / ⇧↩ | send / newline |

## Development

`swift build` produces `.build/debug/PopChat`, which doubles as a headless test harness.
The interesting flags:

```sh
POPCHAT_API_KEY=… .build/debug/PopChat --smoke              # live streaming round-trip
POPCHAT_API_KEY=… .build/debug/PopChat --smoke-search       # tool-calling loop
.build/debug/PopChat --smoke-file <path>                    # attachment extraction
.build/debug/PopChat --smoke-typing                         # composer latency budget
.build/debug/PopChat --smoke-scroll                         # transcript scroll perf
.build/debug/PopChat --smoke-find                           # find-in-chat behavior
```

`--smoke-persist`, `--smoke-history`, `--smoke-minsize`, `--smoke-pasteable`,
`--smoke-providers`, `--smoke-accent`, `--smoke-typewriter`, `--chatgpt-login` and
`--smoke-chatgpt` cover the rest. The performance harnesses fail the build on
main-thread stalls, so run them after touching the transcript, the composer, or panel
sizing. Each GUI harness builds a real key window, so run them one at a time rather than
back-to-back.

## License

MIT — see [LICENSE](LICENSE).

## Status

Version 0.1.0 — built for personal use and shared as-is. Out of scope by design: code
execution, arbitrary tool plugins, voice, multi-window.

The ChatGPT-subscription path uses an unofficial-but-tolerated backend (your own
subscription, your own machine); expect it to occasionally need updating.
