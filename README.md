# Minutes

A cheerful macOS desktop assistant with an original cartoon clock character. Floating helper, menu-bar controls, streaming chat, local reminders, and pluggable AI backends (OpenAI, Anthropic, xAI, and local Ollama).

**Not affiliated with Marvel, Disney, or Loki.** The character is drawn with SwiftUI shapes; no trademarked artwork or names are used.

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ or Swift 5.9+ Command Line Tools
- (Optional) [Ollama](https://ollama.com) for local models
- (Optional) API keys for OpenAI / Anthropic / xAI

> **Note for this repository’s CI/Linux agents:** this environment cannot compile macOS/AppKit targets. Build and run on a Mac.

## Project layout

```
Package.swift                 SwiftPM manifest
Sources/
  MinutesCore/               Testable core (providers, reminders, chat, settings models)
  Minutes/                   macOS app (SwiftUI + AppKit windows, Keychain, hotkey, notifications)
Tests/
  MinutesCoreTests/          Unit tests for providers + reminder parsing
Scripts/
  build-app.sh               Produce dist/Minutes.app (optional .dmg)
  run-dev.sh                 Debug build + launch
```

## Build & run (Mac)

### Quick dev run

```bash
swift build
swift test                     # MinutesCore unit tests
./Scripts/run-dev.sh           # launches the accessory app
```

Or:

```bash
swift run Minutes
```

You should see a menu-bar clock icon and a floating character. Click the character or press **⌥Space** to open chat. Use the menu-bar item for **Settings** / **Quit**.

### Build a `.app` (unsigned / ad-hoc)

```bash
./Scripts/build-app.sh
open dist/Minutes.app
```

### Signed `.app` + `.dmg`

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" MAKE_DMG=1 ./Scripts/build-app.sh
```

Without a Developer ID, macOS Gatekeeper may quarantine the app. Right-click → **Open**, or:

```bash
xattr -dr com.apple.quarantine dist/Minutes.app
```

### Xcode

```bash
swift package generate-xcodeproj   # older toolchains
# or: open Package.swift in Xcode (File > Open)
```

Select the **Minutes** scheme, destination **My Mac**, Run.

## Configure AI backends

Open **Settings → Provider**.

| Provider   | Key storage                          | Notes |
|-----------|---------------------------------------|-------|
| Ollama    | none                                  | Talks to `http://localhost:11434` |
| OpenAI    | Keychain (`minutes.provider.openAI…`) | Models via `/v1/models` when available |
| Anthropic | Keychain                              | Messages API streaming |
| xAI       | Keychain                              | OpenAI-compatible Chat Completions |

API keys are written only to the **macOS Keychain** (`service` = `com.minutes.app`). They are never stored in settings JSON.

Conversation history, settings, and reminders live under:

```
~/Library/Application Support/Minutes/
  settings.json
  conversation.json
  reminders.json
```

### Ollama setup

```bash
# Install from https://ollama.com then:
ollama pull llama3.2
ollama list
```

In Minutes Settings, choose **Ollama (local)**, click **Refresh**, and pick a model.

### Cloud keys

1. Create an API key at the provider’s console.
2. Minutes → Settings → Provider → paste key → **Save key**.
3. Refresh models and start chatting.

## Features

1. **Floating character** — borderless, transparent, always-on-top, draggable; idle / thinking / talking animations; click to open chat.
2. **Menu bar** — Open Chat, Settings, Quit; optional **Launch at login** via `SMAppService` (best with a real `.app` bundle).
3. **Global hotkey** — default **⌥Space** toggles the chat panel.
4. **Chat** — streaming replies, persisted history, editable cheerful persona (time-aware Southern charm).
5. **Providers** — protocol-based `ChatProvider` + `ChatProviderFactory`; add new backends by conforming and registering.
6. **Reminders** — natural language (“remind me in 20 minutes to…”) or Settings list; `UserNotifications` + in-character announcement; optional periodic check-in nudge.

## Tests

```bash
swift test
```

Coverage focuses on `ReminderParser`, SSE/token parsers, and `ChatProviderFactory` / Keychain abstractions (`InMemoryKeychainBox` on the test side).

## Adding a provider

1. Conform to `ChatProvider` in `Sources/MinutesCore/Providers/`.
2. Add a `ProviderKind` case.
3. Wire it in `ChatProviderFactory.makeProvider(for:)`.
4. Settings UI picks up `ProviderKind.allCases` automatically.

## Limitations

- Must be built on macOS; Linux/CI cannot link AppKit/SwiftUI.
- Launch at login and notification permissions need a packaged `.app` and user approval.
- Hotkey customization UI is display-only in v1 (defaults to ⌥Space; codes live in `settings.json`).
- Cloud model lists depend on each vendor’s API; curated fallbacks are used when listing fails.
