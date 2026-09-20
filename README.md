# Jev Voice 4.3 — floating command bar

A small floating command bar that stays above your Mac apps, keeps listening, and repeatedly asks `~typesafe/jev-latest` on OpenRouter to select from the actions available in the current computer state.

## How the loop works

1. Apple on-device speech recognition accumulates the full spoken request.
2. The app preserves that request verbatim. It does not split it into scripted tasks.
3. It discovers installed applications and reads the current app's Accessibility tree: controls, menu items, windows, fields, values, and exposed actions.
4. It supplies these actions plus generic keyboard, scrolling, dragging, typing, waiting, and completion choices to Jev.
5. Jev picks one action. Parameter choices (text, complete key combinations, drag targets) also go to Jev.
6. The app executes that primitive and observes its result. The next Jev choice includes completion alongside actions from the fresh catalogue, with the unchanged original request and history.
7. Jev selects completion. A separate Jev check compares the current screen against the entire request and its literal values before the app reports success.

There are no website aliases, app-specific task recipes, navigation macros, command-to-action regular expressions, or automatic completion after typing/launching. The capability catalogue does not take the request as an argument. The small fixed vocabulary is the execution machinery itself: physical keys, pointer events, Accessibility APIs, and voice session controls such as “cancel task.”

## Options and typing

Every discovered option is retained. Jev's 255-choice limit is handled by groups: compact action labels select a group; full descriptions select the action. Generic operations remain directly selectable. Large catalogues route through operation categories and alphabetical target groups. Only the selected branch is evaluated, avoiding exhaustive parallel nominations. Every discovered leaf remains reachable. Category and group selection execute nothing; UI actions remain sequential. Accessibility scans have a time/node budget and explicitly report incomplete scans; Jev can request a deeper scan.

Typing is also selection. Insertion and whole-field replacement are separate choices. Replacement selects all text, verifies that selection, pastes the chosen literal, and verifies the resulting field value; it never submits automatically. Jev selects a source (your request or observed text), the first token, then the complete substring to insert. Code preserves its spelling, punctuation and internal whitespace. Typing does not switch apps, focus another field, submit, navigate, or silently add a domain. “Open YouTube” can therefore lead to entering “YouTube” in a browser and following a search result. A website mapping does not supply “youtube.com.”

Jev cannot generate new prose or understand screenshots. Original writing, custom-drawn/inaccessible controls, arbitrary pixel-level editing and unrestricted human-equivalent operation are **not** supported. Some UI trees provide incomplete or stale information. This app is a general Accessibility-based action picker, not a guarantee that every task will succeed. Secure fields are excluded. Pointer targets are checked; uncertain text insertion stops to prevent duplication. Model completion checks reduce false success but are not infallible.

## Use

Open **Jev Voice.app**. Setup needs an OpenRouter key (stored in Keychain), Microphone, Speech Recognition, and Accessibility permissions. Once configured, normal launch starts continuous listening and displays a compact command bar below the menu bar. It follows app/Space changes and remains available in full-screen apps. The microphone, live transcript, typed command and task status are the everyday interface; a stop button appears while working.

Speak full requests and pause when finished. “End command” explicitly ends an utterance. Keep speaking additional requests while earlier ones run. “Cancel task” stops the current task and clears queued requests; “stop listening” turns off the mic; Option–Space toggles it. “Status” reads the current progress. There is no action-confirmation queue.

Type directly in the bar and press Return, or speak. Reopening the app shows the bar. The menu-bar waveform offers Show/Hide command bar and Settings & diagnostics. Settings contains General and Jev activity; the old dashboard and sidebar have been removed. The text box is always visible. Typed requests queue even with the mic off. Switching off the mic or recovering from a speech error does not cancel an active task. Temporary connection errors retry up to twice; authentication and credit errors do not. Saved keys remain in Keychain and are cached in memory during the session. Settings show connection status and the provider key expiration date. Menu-bar settings and diagnostics remain available. Spoken results are optional and off by default. Recognition currently uses English.

## Build

Requires an Apple silicon Mac running macOS 14 or later and Xcode command-line tools. The current source was built with Swift 6.2.3 in Swift 5 language mode.

```sh
git clone https://github.com/ronadin2002/jev-cua.git
cd jev-cua
bash build.sh
open 'dist/Jev Voice.app'
```

The build writes to `dist/` (override with `JEV_OUTPUT_DIR`). It uses an available Developer ID Application signing identity, falling back to ad-hoc signing. Set `JEV_SIGNING_IDENTITY` to choose an identity, or `-` for ad-hoc signing. Keep the signing identity and installed app path stable to retain macOS permissions between builds.

No API key is included. Enter your own funded OpenRouter key in Settings → General; the app stores it in macOS Keychain. Account funding and key expiration are managed by OpenRouter. Grant Accessibility, Microphone and Speech Recognition permissions when setting up the app. Text commands work with the microphone off, but computer control still requires Accessibility permission.

## Tests and diagnostics

Run the local checks without making paid API calls or executing UI actions:

```sh
'dist/Jev Voice.app/Contents/MacOS/JevVoice' --self-test
'dist/Jev Voice.app/Contents/MacOS/JevVoice' --activity-test
```

The commands below use the same executable in `dist/Jev Voice.app/Contents/MacOS/`:

- `JevVoice --activity-test`: real-client HTTP fixtures for response validation, cancellation, timeouts, automatic recovery, credit failures and a 4,000-option bounded routing regression.
- `JevVoice --self-test`: catalogue retention, literal span integrity, keyboard coverage, speech endpoints and continuous queue checks.
- `JevVoice --router-test --report /absolute/path/report.json`: paid API selection tests with synthetic states, no UI actions.
- `open 'dist/Jev Voice.app' --args --diagnostics`: start with Settings, the command bar and mic off. Use Back to bar to close Settings.
- In diagnostics, typing into the command bar uses the same production action loop. Each run writes `jev-picker-last-run.json` beside the app, including original request, every choice catalogue, API inputs/outputs, executed actions and observations. It contains screen text; credentials and headers are excluded. Ordinary launch does not persist these traces.
- Settings → General → Voice diagnostics → Replay audio command accepts a local recording through the real continuous speech engine and command queue. This is a recorded-audio test, not a physical microphone test. Recordings are not included in this repository; supply your own audio fixture to test continuous recognition and execution. Requests are preserved literally; absent apps are no longer silently substituted.

## Privacy and repository contents

Microphone audio is transcribed on-device. Commands, relevant Accessibility text and available action choices are sent to OpenRouter for Jev decisions. API credentials stay in Keychain and process memory; request authorization headers are excluded from the activity trace.

This repository contains source, the app icon and build configuration. Keys, recordings, compiled apps and local diagnostic traces are excluded. Diagnostics can contain private screen text, commands and URLs; keep them local. Optional speech fixture setup is described in `Tests/README.md`.

The local test suites validate code and HTTP handling. They do not establish model accuracy or guarantee that an arbitrary task will finish. Live model tests require a configured key; recorded-audio execution and normal commands can act on your Mac.
