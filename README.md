# Routine Scout

A native macOS menu-bar app that notices when you repeat a procedure, offers to take it over, builds the automation with Grok, lets you try it, and then runs it when you ask, when the context matches, when a file appears, or on a schedule. No recording, no teaching, no scripting.

## How it works

```
Observer  →  Memory (SQLite)  →  Pattern finder  →  Grok judge  →  notification + suggestion card
                                                        ↓ Automate
                                       AI build → validate → verify → review sheet → Try it
                                                        ↓
                                  Runner (Accessibility · files · tables · AppleScript) + Undo
                                                        ↓
                          triggers: manual · context · file · schedule · loop continuation
```

- **Observer** (`Sources/RoutineScout/Observer.swift`): app activations, clicks resolved to accessible elements, copy/paste, command shortcuts only (never plain typing), file events in Downloads/Desktop/Documents, spreadsheet and mail context via read-only AppleScript. Password fields, private windows, ignored apps and sites, and paused time produce nothing.
- **Memory** (`Sources/ScoutCore/Memory.swift`): local SQLite. Activity 14 days, content details 48 hours, undo copies 1 minute. "Delete everything" wipes it and the API key.
- **Pattern finder** (`Sources/ScoutCore/PatternFinder.swift`): deterministic; groups repeated token windows across distinct instances, tags the shape (`loop`, `transform`, `image`, `pipeline`, `transfer`, `collect`), and scores them. No model calls.
- **AI** (`Sources/ScoutCore/AIClient.swift`): Grok via the xAI OpenAI-compatible API with strict JSON-schema output. Default model `grok-4.3`. Four uses: judge a candidate, build a routine, fix a step target from the current UI structure, edit with words. The model can only pick steps from the catalog (`Sources/ScoutCore/Catalog.swift`); it never returns code. Every plan is validated against the catalog, checked against the evidence (a CSV cleanup must reproduce the observed output), made generic (`{{file}}`, `{{folder}}`, `{{stem}}`, `{{today}}`), and repaired deterministically (a confirmation is inserted before any submit, unused reads are dropped, browser targets are completed).
- **Runner** (`Sources/ScoutCore/Runner.swift`, `Sources/RoutineScout/MacExecutor.swift`): interprets the catalog deterministically, verifies each step, journals progress so loops resume without duplicating work, and offers exact Undo for files, appended rows, and filled fields.

## Build and run

Requires macOS 14+ and Swift 5.10+ (Command Line Tools are enough).

```sh
scripts/build-app.sh          # builds "../Routine Scout.app" and signs it
open "../Routine Scout.app"
```

On first launch click **Allow access** and enable Routine Scout under System Settings → Privacy & Security → Accessibility. The build script signs with your "Apple Development" identity when one exists so this grant survives rebuilds; ad-hoc builds must be re-allowed after every build.

Add a Grok API key in **Preferences**. It is stored in `~/Library/Application Support/RoutineScout/xai-key.txt` (owner-only permissions); `XAI_API_KEY` in the environment also works. The Keychain is intentionally not used because items created by one build prompt for the login password from every other build. Without a key, the examples still work using saved offline plans.

## The five demo routines

| Case | What the person kept doing | What Routine Scout builds | Runs when |
|---|---|---|---|
| New hires into the HR form | Copy name and email from a people table into a web form, submit, next row | `readCSV → forEach → setValue Name, Email → ask → click Submit → endLoop` | The form page is open (loop trigger) or on demand |
| Weekly sales export cleanup | Open the downloaded CSV, drop a column, trim, fix amounts, sort, export a clean copy | `readCSV → transformTable… → writeCSV {{stem}}-clean.csv` proven against the observed output | A CSV lands in the folder (file trigger) |
| Apartment hunt: save each listing | Copy listing name, price and link from each listing page into a spreadsheet | `readText Listing name, Price → readURL → appendCSV` | A listing page is open (context trigger) |
| Invoice filing by date | Rename each downloaded invoice with today’s date and move it to Invoices | `moveFile {{file}} → {{folder}}/Invoices/{{today}}-{{stem}}.pdf` | A PDF lands in the folder (file trigger) |
| Screenshots to web JPEGs | Resize each screenshot to 1280 px and export as JPEG into Web | `resizeImage → convertImage → Web/{{stem}}.jpg` | A PNG lands in the folder (file trigger) |

Menu bar → **Replay an example** (or Preferences → **Try an example**) feeds three recorded repetitions into memory exactly as the observer would have stored them, then runs the real pipeline: pattern finder → Grok judge → notification and suggestion card → **Automate** → Grok build → review sheet → **Try it now** → choose when it should run. Sample files live in `~/Downloads/Routine Scout Demo` (its own folder, so file triggers can be shown live without touching real files); the practice web pages are served on `127.0.0.1:8790` by the app itself. **Open a ready-made routine** skips detection.

## Tests

```sh
swift run ScoutTests            # core: CSV, transforms, patterns, privacy, SQLite, runner, undo, resume, triggers
SCOUT_LIVE_TEST=1 swift run ScoutTests   # also judges, builds, validates and runs all five demo cases through the real Grok API (SCOUT_MODEL overrides the model)
scripts/native-test.sh          # native rehearsal: real Safari pages, Accessibility reads/writes, files, Undo, plus two Grok-built routines run live (needs Accessibility)
```

The native rehearsal writes `integration-report.txt` and the Safari accessibility snapshot of the practice page into `TestResults/`. It launches the app through LaunchServices (`open`) so macOS applies the app's own Accessibility grant rather than the terminal's, and it stops the moment you touch the keyboard or mouse (the same safety stop real runs use), so leave the Mac idle for two to three minutes while it runs.

## Layout

```
Package.swift
Sources/ScoutCore      platform-independent core: models, catalog, memory, pattern finder, runner, tables, triggers, AI client, fixtures
Sources/RoutineScout   the app: menu bar, views, observer, accessibility, executor, AppleScript templates, practice server, self-test
Sources/CSQLite        system SQLite module map
Tests/ScoutCoreTests   portable test runner (no XCTest dependency)
scripts/               build-app.sh, native-test.sh
```
