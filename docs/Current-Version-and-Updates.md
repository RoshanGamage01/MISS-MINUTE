# Miss Minute — current version and updates

Give this file to the same AI that already has `docs/Windows-Port-Brief.md`. That brief describes the app as it was at **2.1**. This file is what changed after that. Where the two disagree, follow this file.

---

## Current version

| | |
|---|---|
| **Last tagged release** | **2.1.0** (`v2.1.0`). The app bundle (`Info.plist`) still says `2.1.0`. That number has not been bumped. |
| **What is actually running** | The working copy on `main`, two commits past that tag, plus roles and clones that are in the project but not yet committed. This is the product to copy. |
| **Settings file version** | `5`. That number is only for upgrading old `settings.json` files. It is not the product version. |

The personality text in the code names the steps after 2.1 as 2.2, 2.3, 2.4, and 2.5. Roles and clones came after 2.5. Treat the working copy as one product: **2.1, plus everything in this document.**

Still a personal fan project. Miss Minute belongs to Marvel. Do not publish or sell it.

---

## What to change in the old brief

These lines in the 2.1 brief are no longer how she works.

| 2.1 brief said | Current behavior |
|---|---|
| She says "Sure thing, one sec!" herself before a slow tool | The **app** says a short "On it!" out loud. She must not say it. She calls the tool in the same reply. She never says something is done unless a tool result confirms it. |
| Look, act, check, repeat for every computer step | For familiar low-risk jobs (open an app or page, play media, make folders, move or rename files, install, a quick lookup), the tool result is the check. Look again only when the result is unclear, the step was a risky or unfamiliar click, or something already failed. |
| She asks the user which song, folder name, or app | She picks. She uses what she remembers, or a sensible popular choice. She only stops for passwords, payments, one-time codes, purchases, deleting their files, and sending messages, emails, or posts (she confirms the final text first). |
| Computer control defaults to **Ask first** | New installs default to **Allowed**. People who had Ask first are moved to Allowed when their settings file upgrades to version 5. Off still means she cannot act. Sending, paying, and deleting still wait, and Alt+Esc still stops her. |
| Agent loop stops around 10 steps | Up to **40** steps on a turn she is doing for the user. A background clone stops at **30**. |
| She only speaks up with briefings, due tasks, and musings | She also starts real work on her own (goals, tidying, meeting prep), within a daily cap. |
| One orange hologram look, plus Classic | Five outfits, on top of Hologram or Classic. She can change them when asked. |
| Click her, or use the hotkeys | She also wakes on **"Hey Minute"** (on by default). |
| Tools are tasks, reminders, memory, calendar, apps, clipboard, shortcuts, web, and screen control | Add shell commands, YouTube, a coding agent, goals, role switching, clones, and changing her look. |

---

## Version history

### 2.0 — she can see and use the computer

Screenshots and reading the front window as text. Click, type, shortcuts, scroll, drag, press controls by id, and drive the signed-in browser. Optional always-aware glances. Local model through Ollama, and a local-only switch. This is already in the first brief.

### 2.1 — friendlier, faster, remembers on her own

Tagged release. Speech starts on the first few words. Replies stay short. After a personal chat, a background pass adds, corrects, or drops memories. Custom personality text is left alone; only an old default prompt is replaced.

### 2.2 — she stopped announcing and then stopping

Telling her to say "one sec" before a tool made local models treat that sentence as the whole reply. The app now speaks the acknowledgement. Her prompt says: do the tool in this reply, and do not announce it.

### 2.3 — goals, and work she starts herself

Bigger jobs become a saved plan with steps. About once a minute, when she is idle, she looks at the desktop and either does something, offers it, or stays quiet. A Mind tab shows the plan and her reasoning.

### 2.4 — she was too careful

She checked every action and planned every multi-step job. That made ordinary requests slow. Replaced by the next step.

### 2.5 — fast execution

Commands beat the mouse. Related shell steps are chained into one command. She does not narrate between steps. She reports once at the end. A second look is only for UI actions whose result cannot confirm themselves.

### Current working copy — roles, clones, and the body catching up

She can narrow her tools to one kind of work, and she can send a small copy of herself to do a side job while she keeps talking. Running copies are drawn orbiting her face. Her pose follows the tool she just used.

---

## She works on her own

About once a minute, if she is not talking, listening, or running a build, she takes a snapshot of the world: Downloads, Desktop, free disk space, the next few hours of the calendar, overdue tasks, apps that are open but unused today, and any open goals. She scores what she finds and picks **at most one** thing: do it, offer it, or let it be.

She will not start while the user is in the middle of talking to her. She will not touch the mouse or keyboard on her own until the user has been idle for **2 minutes**. A message from the user pauses her.

### How much she may do alone

Settings → Awareness, and the Mind tab. Default is **Safe**.

| Level | What she does unasked |
|---|---|
| Off | Nothing. She only acts when asked. |
| Suggest | She looks and offers. She does not change anything. |
| Safe (default) | Tasks, reminders, opening apps, tidying files without overwriting, and continuing goals. |
| Trusted | Also shell commands and operating apps while the user is away. |

At every level, **sending, paying, and deleting wait for the user.** This is enforced in code before the tool runs, not only in the prompt. A confused model cannot talk past it. Unknown tools are treated as impactful until they are classified.

Shell commands she starts herself are classified too. `ls`, `du`, `df`, and similar reads are only looking. `mkdir` and `mv -n` (no overwrite) are safe. `mv` that can overwrite is impactful. `rm`, `sudo`, `curl`, `git push`, `git reset`, and similar are sensitive and always refused when she started the work.

### What she notices

| Situation | What she does |
|---|---|
| An open goal the user set | Picks it back up. User goals are preferred. Cooldown about 4 minutes. |
| A goal she set herself | Picks it up less often (about 15 minutes). |
| A goal she has tried **6** times without finishing | Stops doing it and asks for help. |
| A meeting in **5–25 minutes** | Gets ready: reads the event, sets a reminder for 2 minutes before, opens the link or notes if there are any. |
| Downloads or Desktop has **30+** loose files, or **15+** untouched for a month | Tidies into Images, Documents, Installers, Archives, Audio, Videos, Code, Other. Uses `mkdir` and `mv -n`. Never deletes. Then counts again so nothing is lost. Cooldown 3 days. |
| Under **15 GB** free (more urgent under 5 GB) | Finds the biggest folders and **tells** the user. Does not delete. |
| **3 or more** overdue tasks | Offers to triage. Never does this unasked. |
| **6 or more** apps open that were not used today | Offers to close them. Never does this unasked. |

### Limits

- At most **12** self-started actions a day (the user can change this). Offers do not count toward that cap.
- At most **6** offers a day.
- At least **8 minutes** between things she starts.
- Score threshold about **0.45**. While the user is busy at the keyboard, only urgent things (a meeting soon) are worth interrupting.
- Each kind of idea has a cooldown so she does not repeat it.
- In a call, she stays quiet the same way the older proactive engine does.

### Seeing her think

The chat panel has a **Mind** tab: open goals with step checklists, and a live stream of what she noticed, weighed, decided, did, and held back. The same lines go to `thoughts.log`. Open goals also appear in the system-tray menu.

New files next to the old ones:

| File | Contents |
|---|---|
| `goals.json` | Goals and their steps |
| `thoughts.json` | Recent thought-log entries |
| `thoughts.log` | The same stream as plain text |

A goal has an objective, who started it (the user or her), a status (active, waiting on the user, done, abandoned), ordered steps (pending, doing, done, skipped, failed, needs the user), an attempt count, and an optional outcome.

Tools: `start_goal`, `update_goal`, `list_goals`, `finish_goal`. Use a goal for a long or unfamiliar objective. A routine she already knows how to do, she just does, even if it takes a few commands.

---

## Roles

She changes hats with `switch_role`. A role hides tools she does not need for that job and adds one line to her prompt. Fewer tools make local models faster. The default is General, which sees everything.

| Role | She is for | Extra prompt, in short |
|---|---|---|
| General | Mixed or casual requests | None |
| Developer | Builds, debugging, QA | Prefer the shell; hand big builds to the coding agent; verify with a real build and tests |
| Secretary | Tasks, reminders, calendar, the day | Stay organized; confirm before anything is sent |
| System-Admin | Installs, cleanup, Mac health | Check state before changing it; never delete or overwrite without asking |
| Researcher | A question that needs sources | Read pages, cross-check at least two sources, answer short |

`switch_role`, `spawn_clone`, `list_clones`, `stop_clone`, `remember`, `recall`, and `change_look` stay available in every role. If she calls a tool the role does not have, the tool fails with a note to switch back to General. The active role is included in the context block.

She should switch when a request is clearly one kind of work, and switch back to General for a mixed request.

---

## Clones

A clone is a small copy of her that runs one job in the background while she keeps talking. She starts one with `spawn_clone(purpose, task, tools)`. Examples she is prompted to use: a web scraper, a file watcher, a price checker. She does not clone a one-step job.

Rules:

- Up to **3** at once. Each one gets at most **30** steps and lives at most **2 hours**.
- She names the tools it may use. A role name expands to that role's tools. If she names none, it gets web search, page reading, the shell, and recall.
- A clone **never** uses the mouse or keyboard, never changes her role or outfit, and never spawns another clone.
- It posts updates with `report_progress` and can wait between checks with `pause`.
- When it finishes, the result is handed back to her and she tells the user. `list_clones` shows them. `stop_clone` calls one back. Alt+Esc stops them too.
- A clone she sent on her own is held to the same autonomy rules as she is.

On screen, each running clone is a small dashed-rim clock orbiting her face, tied to her by a beam, labeled with what it is doing ("🔍 Searching the web…"). A finished clone turns green, a failed one red, and it fades after a few seconds.

---

## Doing real work

### Shell

`run_shell` runs a command in the user's login shell (zsh on the Mac; PowerShell or `cmd` on Windows) and returns the output. Default timeout 120 seconds, max 1200. She should chain related steps (`&&`, loops) instead of many tiny calls. New projects go in the user's projects folder unless they say otherwise. Computer control Off blocks this.

On Windows, keep the same idea and the same safety classes: reads are safe, moving without overwrite is safe, delete / admin / network-upload / destructive git is sensitive when she started it herself.

### Play something

`play_youtube` takes a search she chooses from the request or from memory ("lofi hip hop radio", "Taylor Swift Cruel Summer official"), picks a video, and starts it in the user's real browser. If she cannot pick one, she opens the search and looks at the screen.

### Coding agent

`start_coding_agent` hands a build to Claude Code or Cursor's agent, in a project folder, in the background, with a complete prompt (what to build, the stack, how to run and test). When it reports back she QA's it herself: build, run, test, look at the UI. If it is broken she sends a precise fix and checks again. She tells the user in a sentence or two when it works. `coding_job_status` answers "how's the build going?"

While a job runs:

- Chat shows a strip: project, how long, current step. Click it for the last 8 steps. The header shows the step when she is otherwise idle.
- The tray icon gets a dot. The menu shows the step and can open the log.
- If chat is closed and she is not talking, a bubble line ("Still on todo-app: running the tests…") at most about every 75 seconds. Settings → Computer → *Narrate coding jobs in her bubble* (on by default).
- Logs: `~/Library/Logs/Miss Minute/coding-<date>-<project>.log` on the Mac. On Windows, a log folder under the app data directory.

### Follow-through

If the last action in a turn was a UI action (click, type, press a control, drag, browser, AppleScript, a shortcut, creating a calendar event) and she has not looked or run a command since, the app nudges her once to confirm it worked before she says she is done. Opening an app, opening a URL, playing media, scrolling, and a shell command do not need that second look.

If the user asked her to do something ordinary and her reply asks them to choose ("what would you like to play?"), the app nudges her to pick and do it. It does not nudge when the request itself is sensitive (send, pay, delete, password, book).

### When the user looks stuck

She watches the front window. An error that stays up for about **2.5 minutes** gets an offer. The same window for about **25 minutes** while they are actively there gets a gentle check-in. If they walk away for 3 minutes, those clocks reset. The same finding is not repeated for a while.

---

## Mood

A small tracker reads what the user says and what just happened (a finished task, an overdue task, a long job ending, coming back from a break, looking stuck). Stress and cheer fade with about a **20 minute** half-life, so one grumpy line does not last all day.

| Mood | When | How she sounds |
|---|---|---|
| Steady | Normal | Usual charm |
| Gentle | They seem stressed or frustrated | Slower, lower, almost no sass. Help, don't joke at them. |
| Upbeat | A win, or they sound pleased | A bit faster and brighter |
| Cozy | Late, or they have been at it a long time | Soft. Suggest a break only if it fits. |

The mood is one line in the context block, and it nudges speech rate and pitch. It also tones down her physical jokes when she is in Gentle.

---

## Memory links

Memories are no longer a flat list only. Facts that share a name or the same keywords get linked (at most 5 links each). "Maya lives in Austin" sits next to "Maya's birthday is May 3". Recalling one brings the neighbours along, at a lower score than a direct hit. The curator can also ask for a link. Secrets are still never stored.

---

## Wake word

On by default. She listens on device for **"Hey Minute"** (and the ways speech recognition mishears it: "hey miss minute", "ok minute", "minnie"). "Wait a minute" and "in a minute" do not count. Words after the phrase are the command and are sent as a spoken message. The phrase alone means she is listening. She does not listen while she is talking. It can be turned off in Settings → Voice.

---

## How she looks now

Hologram and Classic are still the two skins. On top of that, five outfits. They cross-fade in about 1.4 seconds. Task glows draw on top of the outfit.

| Look | What you see |
|---|---|
| Signature (default) | TVA orange |
| Night | Deep purple, a crescent moon, stars |
| Sunny | Warm gold, sun rays behind her |
| TVA Formal | Muted amber, a bow tie, no glitch |
| Variant | Loki green and gold, small horns |

The user picks one in Settings → Character, or from the tray menu. She can change it with `change_look` when they ask ("go formal", "your night look", "back to normal").

### Body language follows the work

| What she just did | Body |
|---|---|
| Look at or read the screen | Perch on the front window, hand shading her eyes |
| Click, scroll, or drag | Glide beside that spot and point |
| Open an app, a link, the browser, or play media | A "time door" teleport onto that window. Calm liveliness glides instead of teleporting |
| Search, recall, calendar | Chin-tap, a thought bubble |
| Shell, coding agent, a job running | Focused: heavy lids, cyan glow, `</>` orbiting |
| Thinking or running tools | A halo turning around her rim |
| A task or reminder saved | Thumbs up |
| A task completed, or a coding job that succeeds | Arms up, a bounce, confetti, a gold glow |
| A tool error or a failed job | A shrug and a red pulse |
| A reply that names a file | Point at the front window |

When the work is done she goes home. She does not travel while being dragged, for 90 seconds after the user places her, or when liveliness is Stay put. Gestures and glows still play.

---

## Tools added since 2.1

| Tool | Does |
|---|---|
| `run_shell` | Run a command, return output. Chain steps. |
| `play_youtube` | Search, pick a video, play it in the user's browser |
| `start_coding_agent` | Background build in a project folder |
| `coding_job_status` | Latest steps, or the report of a finished job |
| `start_goal` / `update_goal` / `list_goals` / `finish_goal` | A multi-step objective that survives restarts |
| `switch_role` | General, developer, secretary, systemAdmin, researcher |
| `spawn_clone` / `list_clones` / `stop_clone` | A background copy with a limited tool list |
| `report_progress` / `pause` | Only a clone has these |
| `change_look` | One of the five outfits |

Instant tools (no spoken "On it!", because the real answer follows immediately) now also include the goal, role, and clone tools.

Context on every message also includes: her current role, open goals, and the mood line when she is not in her usual mood.

---

## New settings

| Where | Setting | Default |
|---|---|---|
| Voice | Wake her with "Hey Minute" | On |
| Awareness | How much she does alone: Off, Suggest, Safe, Trusted | Safe |
| Awareness | Daily cap on things she does herself | 12 |
| Computer | Use mouse and keyboard | Allowed |
| Computer | Narrate coding jobs in her bubble | On |
| Character | Outfit | Signature |
| General appearance | | Dark |

---

## Personality

Replace the 2.1 system prompt with the current one. The important new rules, in her own words:

- They give the order; she does the work.
- She can play music and videos, run commands, and build apps with a coding agent.
- Do the tool in the same reply. Do not say "one sec". Do not say it is done unless a tool result says so.
- Make ordinary choices. Do not hand them back.
- Prefer a command over the mouse. Batch the command. Do not narrate between steps.
- `start_goal` only for long or unfamiliar work. Open goals can be picked up without being asked.
- `switch_role` when the job is clearly one kind of work. `spawn_clone` for a side job that would make them wait. Do not wait on the clone.
- For a build: see what is installed, make a project folder, hand it to the coding agent, then QA it until it works.
- The only stops: passwords, payments, one-time codes, purchases, deleting their files, and sending anything (confirm the text first).
- When she starts something herself, keep it safe and undoable, and tell them in one line what she did.

The full prompt is `Persona.defaultPrompt` in `Sources/MinutesCore/Models/AppSettings.swift`. Copy that text. Change "Mac" to "Windows PC", `run_shell` examples to PowerShell, and AppleScript or Shortcuts to whatever Windows stand-in you already chose. Keep the voice and the rules.

If the user still has an older default prompt saved, replace it. If they wrote their own, leave it.

---

## Build order for the Windows port, after the 2.1 brief

1. Fix the prompt and the acknowledgement so she acts in the same reply and the app says "On it!"
2. Shell tool, with the safety classes, and fast execution (no extra look after a command that already returned).
3. Goals and the Mind tab.
4. The once-a-minute initiative loop, the four autonomy levels, and the code-level policy that blocks sensitive tools.
5. Mood, memory links, and "Hey Minute".
6. Outfits and body language tied to tools.
7. YouTube playback and the coding-agent handoff, with the progress strip, tray dot, and bubble narration.
8. Roles, then clones, including the orbiting clocks.

Do not start at step 8. Roles and clones only make sense once tools, goals, and the safety policy exist.
