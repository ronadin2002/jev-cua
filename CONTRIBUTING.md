# Contributing to Jev Voice

Thanks for helping make voice control more useful on the Mac.

## Run it locally

Follow the [build and setup instructions](README.md#get-started). Before submitting a change, run:

```sh
bash build.sh
'dist/Jev Voice.app/Contents/MacOS/JevVoice' --self-test
'dist/Jev Voice.app/Contents/MacOS/JevVoice' --activity-test
```

The local suites use synthetic data and HTTP fixtures. A passing result does not replace a real-app check when changing action execution. Describe what you tested and distinguish recorded audio, typed commands, and physical-microphone tests.

## Report a task that fails

Open an issue with the macOS and app version, the target app, a non-sensitive example command, expected behavior, and what actually happened. Note whether the command was spoken or typed. Include only the relevant, redacted Jev activity excerpt; full traces can contain private screen text and URLs. Do not post API keys or authorization headers.

## Keep the decision loop general

Discover capabilities from the current interface and let Jev choose. Avoid app-name rules, website aliases, task-specific macros, and hardcoded command recipes. Verify an action against fresh state before reporting success, and keep cancellation, API failures, and unavailable evidence visible.

Keep changes focused. Add a regression check for a behavior change where it meaningfully catches the failure, and explain any remaining live-test limits in the pull request.
