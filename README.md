# Routine Scout

A native macOS menu-bar app that notices when you repeat a procedure, offers to take it over, builds the automation with Grok, lets you try it, and then runs it when you ask, when the context matches, when a file appears, or on a schedule. No recording, no teaching, no scripting.

## How it works

```
Observer  →  Memory (SQLite)  →  Pattern finder  →  AI judge  →  suggestion card
                                                        ↓ Automate
                                       AI build → validate → verify → review sheet → Try it
                                                        ↓
                                  Runner (Accessibility · files · tables · AppleScript) + Undo
                                                        ↓
                          triggers: manual · context · file · schedule · loop continuation
```

- **Observer** (`Sources/RoutineScout/Observer.swift`): app activations, clicks resolved to accessible elements, copy/paste, command shortcuts only (never plain typing), file events in Downloads/Desktop/Documents, spreadsheet and mail context via read-only AppleScript. Password fields, private windows, ignored apps and sites, and paused time produce nothing.
- **Memory** (`Sources/ScoutCore/Memory.swift`): local SQLite. Activity 14 days, content details 48 hours, undo copies 1 minute. "Delete everything" wipes it and the API key.
- **Pattern finder** (`Sources/ScoutCore/PatternFinder.swift`): deterministic; groups repeated token windows across distinct instances, tags the shape (`loop`, `transform`, `pipeline`, `transfer`, `collect`), and scores them. No model calls.
- **AI** (`Sources/ScoutCore/AIClient.swift`): Grok via the xAI OpenAI-compatible API with strict JSON-schema output. Four uses: judge a candidate, build a routine, fix a step target from the current UI structure, edit with words. The model can only pick steps from the catalog (`Sources/ScoutCore/Catalog.swift`); it never returns code.
- **Runner** (`Sources/ScoutCore/Runner.swift`, `Sources/RoutineScout/MacExecutor.swift`): interprets the catalog deterministically, verifies each step, journals progress so loops resume without duplicating work, and offers exact Undo for files, appended rows, and filled fields.

## Build and run

Requires macOS 14+ and Swift 5.10+ (Command Line Tools are enough).

```sh
scripts/build-app.sh          # builds "../Routine Scout.app" and signs it
open "../Routine Scout.app"
```

On first launch click **Allow access** and enable Routine Scout under System Settings → Privacy & Security → Accessibility. The build script signs with your "Apple Development" identity when one exists so this grant survives rebuilds; ad-hoc builds must be re-allowed after every build.

Add a Grok API key in **Preferences** (stored in the macOS Keychain). Without a key, the local examples still work using saved offline plans.

## Try it without waiting for a routine

Preferences → **Try a local example**:

- **Replay a routine being repeated** (CSV cleanup, Form from a table, Listing collection): feeds three recorded repetitions into memory, shows the suggestion card, builds the offline plan, and opens the matching local practice page in Safari.
- **Open a ready-made routine**: skips detection and goes straight to a routine you can **Try it now**.

The practice pages are served on `127.0.0.1:8790` by the app itself.

## Tests

```sh
swift run ScoutTests            # core: CSV, transforms, patterns, privacy, SQLite, runner, undo, resume, triggers
SCOUT_LIVE_TEST=1 swift run ScoutTests   # also exercises the real Grok API with synthetic evidence (needs a key)
scripts/native-test.sh          # native rehearsal: real Safari pages, Accessibility reads/writes, files, Undo (needs Accessibility)
```

The native rehearsal writes `integration-report.txt` and the Safari accessibility snapshot of the practice page into `TestResults/`. It launches the app through LaunchServices (`open`) so macOS applies the app's own Accessibility grant rather than the terminal's, and it stops the moment you touch the keyboard or mouse (the same safety stop real runs use), so leave the Mac idle for about a minute while it runs.

## Layout

```
Package.swift
Sources/ScoutCore      platform-independent core: models, catalog, memory, pattern finder, runner, tables, triggers, AI client, fixtures
Sources/RoutineScout   the app: menu bar, views, observer, accessibility, executor, AppleScript templates, practice server, self-test
Sources/CSQLite        system SQLite module map
Tests/ScoutCoreTests   portable test runner (no XCTest dependency)
scripts/               build-app.sh, native-test.sh
```
