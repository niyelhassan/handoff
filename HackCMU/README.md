# Event-tap implementation (`HackCMU/`)

This folder is a second Handoff, from https://github.com/AA2026/handoff. **The primary app is the Swift package at the repo root** (`scripts/build-app.sh`). Commands in this file are for this tree only.

---

# Handoff

**Handoff watches how you work, notices when you're doing the same multi-step
task over and over, and offers to finish the rest for you — after showing you
exactly what it will do.**

It's a macOS menu-bar app. No scripting, no macro recording, no "teach it a
workflow." You just work; when Handoff sees a repeated task take shape, a small
window appears: *"Repeating a 5-step task across Numbers and Safari — automate
the rest?"* You review, adjust the count, and it takes over — stopping the
instant anything looks wrong.

---

## What makes it different from a macro recorder

A macro replays coordinates and keystrokes blindly. Handoff understands the
task:

- **It targets elements, not pixels.** "Click the 4th row" is re-found in the
  live accessibility tree each pass, so it survives the window moving, resizing,
  or scrolling. A recorded coordinate does not.
- **It knows what varies.** Walking down a list, a value read off one screen and
  typed into another, a number that counts up, a name pasted from the clipboard
  — Handoff works out the *rule* from a few passes and reproduces it, instead of
  replaying the old value.
- **Identity is structural, not literal.** A tab titled "…to 520 Chestnut St -
  Google Maps" and one titled "…to 88 Oak Ave - Google Maps" are recognised as
  the *same step* with a changing value — which is why real tasks, where the
  data lives in the labels, are detectable at all.
- **It stops when the world isn't what it expected.** An error dialog, a
  "replace existing file?" sheet, a search that returned nothing — Handoff flags
  that row and moves on, rather than pasting garbage or clicking through an
  alert.
- **It hands the risky part back.** By default it does all the mechanical work
  and stops before the irreversible step (Send, Save, Post) for you to confirm.

---

## How it works

```
   watch  →  normalize  →  detect  →  understand  →  confirm  →  replay
   event      keystrokes    shortest   name it +      editable    re-find
   tap        become        repeating  what "the      dialog +    elements
   (all       "steps":      sequence   rest" means    dry-run     live, and
   apps)      Copy, Click   + which    (Claude,       preview,    guard every
              a row, …      parts vary optional)      run count   committing step
```

**Privacy is built into the pipeline, not bolted on:**

- Everything above happens **locally**. The learned-pattern library on disk
  (`~/.handoff/patterns.json`, mode 0600) stores **structure only** — step
  kinds, role paths, hashes — never file names, typed text, URLs, or window
  titles. You can read the file; it doesn't reveal what you did.
- The **only** thing that ever leaves the machine is the optional task-naming
  request to Claude, and it sends **structure plus the site hostname** by
  default (`Copy`, `Click item 4 of 12`, `mail.google.com`) — never the
  contents. It's off unless you configure an API key, and a network failure
  never costs you the suggestion.
- Keystrokes typed while macOS secure input is on (password fields) never enter
  the pipeline at all.

---

## Requirements

- macOS (built and tested on macOS 15/26, Apple Silicon).
- Xcode toolchain (the build uses it directly; it does **not** use `xcodebuild`,
  which is broken on the dev machine — see `HackCMU/scripts/env.sh`).
- Two macOS permissions, granted once: **Accessibility** and **Input
  Monitoring**. Handoff cannot function without both, and there is no
  App-Store-able way around that — reading other apps' UI and watching input
  require them.

The project lives in `HackCMU/`. All commands below run from there.

---

## Quick start

```sh
cd HackCMU
./handoff cert      # one-time: create the "Handoff Dev" signing identity
./handoff run       # build, sign, launch (menu-bar icon appears)
# → grant Accessibility + Input Monitoring (menu-bar panel has Grant buttons)
./handoff doctor    # verify everything is ready
```

`./handoff demo` shows the suggestion dialog immediately, with no detection
needed — the fastest way to see what Handoff looks like.

---

## Demo playbook (for judges)

The single most important lesson from testing: **detection needs the passes to
be consistent.** Do the task the *same way* each time. That's the whole trick.

### Before you present

1. **`./handoff doctor`** until every line is green. It checks signing,
   permissions, and a live event tap. If permissions show red, click the
   menu-bar icon → Grant, or System Settings ▸ Privacy & Security ▸
   Accessibility / Input Monitoring ▸ enable **Handoff**.
2. Have your demo apps open and a **scratch folder / sheet prepared**, so
   nothing depends on live typing you might fumble.
3. Keep **`./handoff demo`** ready as a zero-risk fallback.

### Demo A — guaranteed (the dialog)

```sh
./handoff demo
```

Shows the full flow on a built-in sample: the suggestion, the step breakdown
with the *varying* values flagged, then (click **Automate the rest…**) the
confirmation screen — editable name, editable run count, stop-before-commit
toggle, and a **dry-run preview** of exactly what the next pass would do. This
never depends on live detection. Lead with it for a sure thing, or use it to
explain the UX after a live run.

### Demo B — live detection (the "wow")

The reliable live demo is a **Finder list walk** — Finder exposes clean,
enumerable rows.

1. Make a scratch folder with ~8 files, open it in Finder **as List view**.
2. Do the *same* action to three files in a row — e.g. click a row → ⌘I (Get
   Info) → ⌘W (close). **Exactly the same each time.**
3. After the third pass, the suggestion window appears. Click through to the
   confirmation and its dry-run preview.

What makes or breaks it:
- **Be consistent** — same clicks, same order, no detours. One stray click is
  tolerated; two, or clicking different things each pass, breaks the period.
- **Don't do unrelated things mid-task** — a detour to Messages/Terminal adds
  noise the detector must see past.
- Click the **menu-bar icon** any time to show the live readout: steps seen,
  patterns found, and — if nothing popped up — *why* (e.g. "this is just
  typing").

### If a live run doesn't fire

Open the menu-bar panel and read the reason aloud — that transparency is part of
the story ("it saw the steps; it didn't offer because…"). Then fall back to
`./handoff demo`. To capture a run for diagnosis: `./handoff trace`, do the task,
then read `/tmp/handoff-trace.txt`.

---

## Use cases it's built for

Cross-app, repetitive "handoff" tasks where only the data changes:

| Task | Shape Handoff detects |
|---|---|
| Copy each Canvas assignment into Google Calendar | walk a list → copy → switch app → paste |
| Rename / Get-Info each file in a folder | walk rows → ⌘I → type → ⌘W |
| Address → drive time (read Maps, back into a sheet) | copy → Maps → **read the "N min" off screen** → back → paste |
| Batch-create folders from a client list | copy name → Finder → ⌘⇧N → paste → Enter |
| Bulk-open & save URLs from a list | copy URL → new tab → paste → save |
| Dedupe leads: search an email, paste the result URL back | copy → search → **copy result** → paste back |

The last three carry a **wrinkle** — an invalid name, a "replace file?" sheet, a
zero-results search — and Handoff's guarded replay flags that row and continues
instead of corrupting data.

---

## Commands

| Command | What it does |
|---|---|
| `./handoff run` | build, sign, launch |
| `./handoff demo` | show the suggestion dialog on a sample (no detection needed) |
| `./handoff doctor` | **go-time preflight** — signing, permissions, live tap |
| `./handoff test` | full self-test suite (191 checks) + render the dialog |
| `./handoff trace` | run with step/URL tracing to `/tmp/handoff-trace.txt` |
| `./handoff axdump` | dump what the resolver sees in Finder/Safari (reads only) |
| `./handoff cert` | create the stable "Handoff Dev" signing identity |
| `./handoff reset` | reset the TCC permission grants |
| `./handoff dr` | print the designated requirement (must be cert-based) |
| `./handoff clean` | remove build artifacts |

Optional task naming with Claude: set `HANDOFF_ANTHROPIC_API_KEY` (or write
`~/.handoff/anthropic-key`). Without it, a built-in namer is used — fine for the
demo. `./handoff understand` prints the exact payload that would be sent.

---

## Architecture

Swift, no external dependencies. Source under `HackCMU/Sources/Handoff/`:

- **`Capture/`** — the global event tap on its own thread, a lock-free ring
  buffer, and the enrich queue. The tap callback does one thing (copy a POD
  struct into the ring) so it never overruns the budget that would get it
  silently disabled.
- **`Detect/`** — normalizes raw events into human-legible *steps*, then finds
  the shortest repeating sequence. Strict identity first, **structural identity**
  (position over label) as the fallback that catches value-in-title loops.
  `ValueBinding` / `NumberTransform` / `TitleTemplate` work out how each varying
  step advances. `TaskValue` gates out things not worth automating.
- **`AX/`** — accessibility: hit-test a click to a real element, re-find it
  later by role path, read values off other windows, detect blocking dialogs.
- **`Understand/`** — the optional, privacy-minimal Claude task-naming call.
- **`Suggest/`** — the non-activating panel and the two-stage dialog.
- **`Replay/`** — re-finds each element live, prefers `AXPress` over synthetic
  clicks, paces web tasks, and **guards every committing step** (`ReplayGuard`).
  Any real keypress aborts instantly.
- **`Library/`** — the local, structure-only pattern store + prefix recognition.

Detection logic is covered by a headless suite (`./handoff test`); the UI is
verified by rendering it; AX and replay are exercised against live windows with
read-only probes.

---

## Team Members

- Aayan Ali
- Niyel Hassan
- Yug Agarwal
- Idris Kagalwala
