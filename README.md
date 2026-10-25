# Miss Minute

A personal AI agent for macOS, built around Miss Minute from *Loki*: a holographic, orange, rubber-hose clock who lives on your desktop, talks out loud, listens when you push to talk, and actually *does things*. She tracks your tasks, sets reminders and timers, remembers what matters to you, checks your calendar, opens apps, runs your Shortcuts, searches the web, and speaks up on her own when something needs you.

> **Fan project for personal use.** Miss Minute and the TVA belong to Marvel/Disney. This project isn't affiliated with them; don't distribute it.

## New in 2.1: friendlier, faster, remembers on her own

- **Starts talking right away.** Her voice kicks in at the first natural pause instead of waiting for a full sentence. On local models (Ollama), quick replies skip the silent "thinking" phase, and the model is loaded at launch so the first answer isn't stuck behind a cold start. ElevenLabs now defaults to its low-latency Flash model and streaming endpoint, and upcoming lines render further ahead.
- **Shorter replies.** Usually one or two sentences; longer only when you ask for detail or it truly needs it. When she has to look something up first, she says so ("Sure thing, one sec!") so you're not left in silence.
- **A friendly assistant, not a robot.** A warmer personality: she reacts to what you say, never talks about tools or steps, and leads with the answer. If you kept the old default personality, it upgrades automatically. Custom ones are left alone.
- **Memories update themselves.** After a chat that sounds personal, a quick background check adds new details (people, preferences, routines), corrects ones that changed ("I moved to Austin"), and drops ones you say are no longer true. Turn it off or review and delete memories in Settings → You → Memory.

## New in 2.0: she sees your screen and uses your Mac

- **Sees what you're doing.** Ask "what am I doing?" or "what does this error mean?" and she looks: screenshots via ScreenCaptureKit (her own windows are left out), or the front app's UI read as text through Accessibility, which also works in Chrome, Electron apps, and for text-only models.
- **Operates the computer like a person.** Observe → act → check → repeat, for up to 40 steps per task: click, type, shortcuts, scroll, drag, press buttons and fill fields by id, switch apps, and drive your real signed-in browser (open tabs, read the page). For example: "check my Claude usage" opens the usage page in Chrome, reads it, and tells you. AppleScript covers scriptable apps.
- **Always aware (optional).** Every few minutes she glances at the screen, keeps short notes on what you're working on (included in every conversation), and offers help when she spots something real, like an error she could explain. No canned small talk: if the model has nothing real to say, she stays quiet.
- **Safe by default.** Computer control is *Ask first*: one approval per task, her windows become click-through while she works, and **⌥Esc** stops everything instantly. She refuses to type passwords or payment details and won't send messages without your OK.
- **Runs on Gemma 4, fully local.** One click in Settings → Brain → **Use Gemma 4**: Ollama with vision, a 32K+ context, the model kept loaded, and automatic fallback to a text-based tool protocol for models without native tool calling. LM Studio / llama.cpp / MLX servers work too. **Local-only mode** blocks cloud AI and cloud voices. Free web search (DuckDuckGo) and page reading work with any model.

### Permissions (Settings → Computer)

| Permission | Why |
|---|---|
| Screen Recording | screenshots (`look_at_screen`, always-aware glances) |
| Accessibility | reading apps as text, mouse and keyboard |
| Automation | controlling your browser (asked per app on first use) |

To read whole web pages, enable **Allow JavaScript from Apple Events** (Chrome: View → Developer; Safari: Develop menu). Without it she falls back to Accessibility.

## What makes her an agent, not a chatbot

| | |
|---|---|
| **Acts with tools** | Each reply runs a real agent loop (model → tools → model…, up to 10 steps). Tools: tasks (add/list/complete/update/delete), reminders & timers, long-term memory (remember/recall/forget), calendar (read/create), open apps & links, clipboard, Apple Shortcuts, Mac status, today's screen time, and hosted web search on Claude. |
| **Knows your situation** | Every message you send carries a context snapshot: time, the app you're in and for how long, time since your last break, today's screen time, open tasks (with overdue flags), pending reminders, today's calendar, and what she remembers about you. |
| **Speaks up first** | Daily briefing on your first activity of the day, heads-up 15 min before a task is due, a check-in when something goes overdue, break suggestions after long stretches, finished builds/commands, and a welcome back when you return. Proactivity is rate-limited (Quiet / Balanced / Chatty), and she stays quiet during Zoom/Teams/FaceTime. |
| **Talks like a person** | Free natural voices first: your Mac's **system voice**, which can be a **Siri voice** (rendered with `say`, so the Siri voices apps normally can't use work too), or **Kokoro**, a free local neural voice (`./Scripts/start-kokoro.sh`). ElevenLabs/OpenAI are optional paid upgrades. Speech starts on the first finished sentence, the next one renders while the current one plays, lip-sync follows the real audio, and a failing engine falls through to the next one. |
| **Listens** | Push-to-talk speech recognition (on-device when available) that ends when you pause. In conversation mode, when she asks you something out loud, the mic opens for a few seconds so you can just answer. |
| **Has a life of her own** | She strolls along the bottom of your screen, wanders toward your cursor, hops up to sit on top of your front window (and falls off when it closes), dozes off with "zz" after you've been away a few minutes, and yawns awake when you're back. Hover to pet her, drag her anywhere. Every so often she starts a conversation: an observation, a question about your day, a tip, a joke. |
| **Remembers** | Tasks, memories, reminders, and conversation persist locally. Memories stay current automatically after each chat. |

## The character

Drawn live in SwiftUI `Canvas` at 30 fps, no image assets:

- Orange clock face with a winding crown, hour ticks, and **clock hands that show the real time** (they spin while she's thinking).
- Big lashed eyes that **follow your cursor**, blink, and emote with expressive brows.
- Black rubber-hose arms and legs with white cartoon gloves, posed by mood: hands on hips (idle), gesturing (talking), hand to chin (thinking), waving (announcing), hand to ear (listening), wringing hands (concerned).
- **Lip-sync** driven by the voice engine: word boundaries for macOS voices, audio amplitude for neural voices.
- **Hologram skin** (default): translucent amber with glow, scanlines, a travelling light sweep, flicker, occasional signal tears, and a projector beam. **Classic** skin is a solid cartoon finish.
- A speech bubble types out what she says next to her. Click her to chat, right-click for Talk / Brief me / Settings, drag to move.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (Swift 5.9+)
- One AI backend:
  - **Gemma 4 locally (free, private):** install [Ollama](https://ollama.com), then `ollama pull gemma4` (or `gemma4:26b` on 32 GB+ Macs), and click **Use Gemma 4** in Settings → Brain.
  - **Anthropic:** strongest at long computer-use tasks, plus hosted web search. Defaults to `claude-opus-5-5`.
  - OpenAI / xAI, or any OpenAI-compatible local server (LM Studio, llama.cpp, MLX).
- Optional: an OpenAI key for the neural voice.

## Build & run

```bash
swift build
swift test
./Scripts/run-dev.sh        # builds .build/dev/Minutes.app and launches it
```

Always run the bundled `.app` (`run-dev.sh` or `build-app.sh`). Notifications, microphone, speech recognition, and calendar access all need a real bundle. A bare `swift run` binary crashes on the first permission request.

```bash
./Scripts/build-app.sh                       # dist/Minutes.app (ad-hoc signed)
SIGN_IDENTITY="Developer ID Application: …" MAKE_DMG=1 ./Scripts/build-app.sh
```

Ad-hoc signed builds change identity on every rebuild, so macOS may ask for mic/speech/Keychain permission again. Sign with a stable identity to avoid that.

## First run

1. **Settings → Brain:** pick a provider, paste the API key (stored in the macOS Keychain), and pick a model.
2. **Settings → Persona:** tell her your name.
3. **Settings → Voice:** for a free natural voice, set System Settings → Accessibility → Spoken Content → System voice to a **Siri voice** (or download *Zoe/Ava (Premium)*), then click **Preview voice**. For an even more human voice, run `./Scripts/start-kokoro.sh` (Docker) and *Automatic* switches to Kokoro while it's running.
5. **Settings → Character → Life:** Lively, Calm, or Stay put.
4. **Settings → Awareness:** set how chatty she is, and turn on calendar access if you want briefings to include your schedule.

| Shortcut | Action |
|---|---|
| ⌥Space | Open/close chat |
| ⌥⇧Space | Push to talk (stops after a pause) |

Try: *"Brief me."*, *"I need to send the invoice by Friday at 5."*, *"Start a 25 minute focus timer."*, *"Remember my sister's birthday is May 3."*, *"What's on my calendar tomorrow?"*, *"Open Spotify."*, *"Run my Good Morning shortcut."*

## Architecture

```
Sources/MinutesCore/            Testable core (no AppKit)
  Agent/                        Agent loop types, tool registry, core tools, context snapshot, transcript rules
  Chat/ChatService.swift        The agent loop: stream → tool calls → results → … → spoken reply
  Providers/                    Anthropic (raw SSE + tool use), OpenAI-compatible, Ollama
  Tasks/ Memory/ Reminders/     Persistent stores
  Activity/                     Usage tracking, briefing, fallback lines
Sources/Minutes/                macOS app
  Character/                    MissMinuteView (Canvas renderer), window, speech bubble
  Voice/                        SpeechManager (TTS + lip-sync), VoiceInputManager (push-to-talk)
  Agent/SystemTools.swift       Apps, links, clipboard, Shortcuts, calendar, Mac status
  Computer/                     Screen capture, Accessibility reader, mouse/keyboard, browser bridge,
                                ComputerController (tools + approval gate), ScreenWatcher (always aware)
  Proactive/ProactiveEngine     When and why she speaks up
  Chat/ Settings/ MenuBar/ Hotkey/ Notifications/
```

**History is append-only.** Situational context is stored on each user message instead of in the system prompt, so the system prompt and tool list never change between requests. That keeps prompt caching warm and keeps Claude's thinking blocks valid inside a tool loop. Raw provider blocks (thinking signatures, search results) are replayed only within the current turn and dropped afterwards.

Data lives in `~/Library/Application Support/Minutes/` (`settings.json`, `conversation.json`, `tasks.json`, `memory.json`, `reminders.json`, `usage.json`). API keys live only in the Keychain.

## Adding a tool

Register an `AgentTool` (a JSON-schema `ToolSpec` plus an async handler that returns a `ToolOutcome`) in `CoreTools` (pure, testable) or `SystemTools` (needs AppKit). The `summary` you return shows up as an action chip in the chat.

## Privacy

Activity awareness records which app is frontmost and for how long, idle time, and the names of long-running build processes. There's no keylogging. Screenshots and window text are taken only when a task needs them (*When needed*) or every few minutes if you choose *Always aware*. They go only to the model you picked and are dropped from history when the task ends. Keep everything on your Mac with Gemma 4 and Local-only mode; set *See my screen* to *Never* to turn it off entirely.
