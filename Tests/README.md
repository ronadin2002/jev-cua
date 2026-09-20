# Test fixtures

The local code and HTTP fixture suites are implemented in `Sources/SelfTests.swift` and `Sources/ActivityTests.swift`. Build the app, then run `--self-test` and `--activity-test` as described in the main README. These checks do not require an API key.

Audio recordings are intentionally excluded from Git. To exercise speech recognition, use Settings → General → Voice diagnostics → Replay audio command and select your own local audio file. Replaying a command uses the normal action loop and can control your computer.

The build can optionally bundle local `Tests/FullRequest.aiff` and `Tests/Demo.wav` recordings when present. These files are ignored and are not required to build or run the app.
