# VoicePloeg

Native macOS menu bar app built with Swift and SwiftUI. Local transcription uses the vendored `whisper.cpp` CLI.

## Validate changes

```bash
swift build
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Before a release, run:

```bash
Scripts/release_preflight.sh
```

## Project rules

- `VoicePloeg.xcodeproj` is generated. Edit `project.yml`, then run `xcodegen generate --spec project.yml`.
- Bootstrap the transcription CLI with `Scripts/bootstrap_whisper.sh` when needed.
- Keep UI state changes on `@MainActor`; do not block the main thread.
- Treat `AppState` as canonical UI state and `AppSettings` as canonical preferences.
- Keep user-facing strings in `UserFacingMessage`.
- Follow the existing Swift style: 4-space indentation, early returns, typed errors, and small focused functions.
- Add tests under `Tests/VoicePloegTests` for behavior changes.
- The app requires microphone and accessibility permissions at runtime.
