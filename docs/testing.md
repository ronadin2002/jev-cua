# Tests and diagnostics

[← Back to the README](../README.md)


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


GitHub Actions builds the app on a macOS ARM64 runner, verifies its signature, and runs the two local suites. The workflow uses ad-hoc signing and no API credentials. See [GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

The local suites test code and HTTP handling. They do not measure model accuracy or guarantee that an arbitrary task will finish. Live router tests make paid API calls with the key configured in Keychain. Recorded-audio execution and normal commands can act on your Mac.
