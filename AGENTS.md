# VoicePloeg Agent Notes

This file is for agentic coding assistants working in this repo.
It summarizes how to build, test, and follow project conventions.

## Project overview
- Native macOS menu bar app (Swift + SwiftUI).
- Xcode project is generated from `project.yml` via XcodeGen.
- Swift Package manifest exists for `swift build`/`swift test` flows.
- Local transcription uses a vendored `whisper.cpp` CLI.

## Commands (build, lint, test)

### Bootstrap whisper.cpp CLI
```bash
/Users/teun/Code/VoicePloeg/Scripts/bootstrap_whisper.sh
```

### Generate Xcode project
```bash
xcodegen generate --spec /Users/teun/Code/VoicePloeg/project.yml
```

### Open Xcode project
```bash
open /Users/teun/Code/VoicePloeg/VoicePloeg.xcodeproj
```

### Swift Package build (CLI)
```bash
swift build
```

### Strict concurrency build (warnings as errors)
```bash
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

### Run all tests (Swift Package)
```bash
swift test
```

### List tests
```bash
swift test --list-tests
```

### Run a single test (Swift Package)
Use `--filter` with the fully-qualified test name.
```bash
swift test --filter VoicePloegTests.AppStateTests/testIdleStateMetadata
```

### Run a test case class (Swift Package)
```bash
swift test --filter VoicePloegTests.AppStateTests
```

### Release preflight (build + gating checks)
```bash
/Users/teun/Code/VoicePloeg/Scripts/release_preflight.sh
```

### Notarization (manual)
```bash
/Users/teun/Code/VoicePloeg/Scripts/notarize.sh <app-path> <apple-id> <team-id> <app-password>
```

### Linting
No dedicated SwiftLint/SwiftFormat configuration in this repo.
Use Xcode warnings and `swift build` for validation.

## Code style guidelines

### General Swift style
- Use 4-space indentation, braces on the same line.
- Prefer `struct` for value types, `final class` for reference types.
- Prefer `enum` for state machines and simple namespaces.
- Keep functions small; extract helpers for repeated logic.
- Use `guard` and early returns to reduce nesting.
- Use `defer` for cleanup (see recording stop flows).
- Keep user-facing strings in `UserFacingMessage`.

### Imports
- Import only what you need.
- Common order in this repo: platform frameworks first, then Foundation.
- Example pattern: `import AppKit`, `import Foundation`.

### Naming
- Types: `UpperCamelCase` (e.g., `AppCoordinator`).
- Methods/vars: `lowerCamelCase` (e.g., `refreshInputDevices`).
- Booleans: `is/has/should` prefixes (e.g., `isDownloadingModel`).
- Errors: `SomethingError` and conform to `LocalizedError` when user-facing.

### SwiftUI conventions
- Use `@StateObject` at ownership boundaries and `@ObservedObject` for dependents.
- Keep view state local with `@State` when it does not belong in the model.
- Prefer computed subviews to keep `body` readable.
- Use `ViewBuilder` only when needed for generic content blocks.

### Concurrency
- UI state changes occur on the main actor (`@MainActor`).
- Use `Task { @MainActor in ... }` when bridging from non-actor callbacks.
- Avoid blocking calls on the main thread.
- Propagate `async`/`throws` rather than hiding errors.

### Error handling
- Use typed `Error` enums (e.g., `InputRoutingError`).
- Provide `LocalizedError` descriptions for display in UI state.
- Prefer `do/try/catch` with explicit error handling.
- `try?` is acceptable for best-effort cleanup only.

### State management
- `AppState` is the canonical UI state; update it consistently.
- Keep `AppSettings` as the single source of truth for user preferences.
- Update `permissionStatus` and `accessibilityDiagnostics` together.

### Resources and paths
- Use `Resources/ModelCatalog.json` for model metadata.
- Vendored whisper.cpp is in `Vendor/whisper.cpp`.
- Pinned whisper.cpp version is stored in `Scripts/whisper.version`.

### Testing conventions
- Tests live in `Tests/VoicePloegTests`.
- Test classes inherit from `XCTestCase`.
- Test method names start with `test` and describe behavior.
- Use `@testable import VoicePloeg`.

### Formatting and layout
- Align multiline parameters and initializers for readability.
- Use trailing closures when the last parameter is a closure.
- Keep SwiftUI modifier chains vertically aligned and readable.

## Repo-specific notes
- Xcode project is generated; edit `project.yml`, then run XcodeGen.
- Swift Package excludes `VoicePloeg.xcodeproj` and test sources.
- The app expects permissions (microphone + accessibility) at runtime.

## Cursor/Copilot rules
- No `.cursor/rules/`, `.cursorrules`, or `.github/copilot-instructions.md` found.
