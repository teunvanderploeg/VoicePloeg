# VoicePloeg Improvement Backlog (Deep Dive)

Date: 2026-02-18
Scope: First-party code only (`App`, `Core`, `UI`, `Resources`, `Scripts`, `Docs`). `Vendor/whisper.cpp` internals excluded.

## Executive Summary

The project is a solid v1 prototype with clean module boundaries and successful strict-concurrency compilation, but it has four high-impact gaps:

1. Long-running work is pinned to the main actor, which can freeze UI during model checks/download/transcription.
2. Model supply-chain integrity is not enforced (`UNVERIFIED` checksums across catalog entries).
3. There is no app-level automated test suite.
4. Build reproducibility is weak because `whisper.cpp` is cloned from floating HEAD.

## Current Snapshot

- First-party files reviewed: 31
- First-party LOC reviewed: ~2,599
- Build status: `swift build` passes
- Strict concurrency build: passes (`-strict-concurrency=complete -warnings-as-errors`)
- Test status: `swift test` reports no tests

## Priority Findings

## P0 (Fix first)

### 1) Main-thread blocking in transcription and model management

- Evidence:
  - `Core/STT/SpeechTranscriber.swift:16` marks transcriber API `@MainActor`.
  - `Core/STT/WhisperCppTranscriber.swift:84` uses blocking `process.waitUntilExit()`.
  - `Core/Models/ModelManager.swift:50` marks manager `@MainActor`.
  - `Core/Models/ModelManager.swift:149` hashes full model files via `Data(contentsOf:)` (can be multi-GB).
- Impact:
  - UI stalls during long transcriptions, checksum verification, and downloads.
  - Large-model validation can cause high memory pressure.
- Improvement:
  - Move heavy I/O and subprocess work to a dedicated actor/background executor.
  - Keep only UI state mutations on main actor.
  - Replace full-file hashing with streaming hash (incremental read).

### 2) Model integrity not enforced

- Evidence:
  - All catalog entries are `sha256: "UNVERIFIED"` in `Resources/ModelCatalog.json`.
  - Preflight only warns unless strict mode is manually set (`Scripts/release_preflight.sh:86`-`Scripts/release_preflight.sh:91`).
  - `Core/Models/ModelManager.swift:145` skips verification when checksum is `UNVERIFIED`.
- Impact:
  - Silent acceptance of tampered/corrupt model artifacts.
- Improvement:
  - Populate real SHA-256 hashes for all shipped catalog models.
  - Make checksum verification mandatory in release and default preflight.
  - Add expected file-size validation against `sizeBytes`.

### 3) No app test target

- Evidence:
  - `project.yml:31` has `testTargets: []`.
  - `swift test` fails with “no tests found”.
- Impact:
  - High regression risk for permissions, insertion logic, and state transitions.
- Improvement:
  - Add unit tests for:
    - `AppCoordinator` state machine and error paths.
    - `ModelManager` checksum and download behaviors.
    - `WhisperCLIResolver` candidate resolution.
    - `HotkeyCombination` parsing/serialization.
  - Add protocol-backed fakes for audio, transcriber, and text output in tests.

### 4) Non-reproducible vendor bootstrap

- Evidence:
  - `Scripts/bootstrap_whisper.sh:9` clones `whisper.cpp` with `--depth 1` from default branch.
- Impact:
  - Breakages can appear without project code changes.
  - Difficult release debugging and rollback.
- Improvement:
  - Pin a specific `whisper.cpp` commit/tag.
  - Persist pinned revision in script/docs and validate it during preflight.

## P1 (Next wave)

### 5) Unsafe force-cast in text insertion path

- Evidence:
  - `Core/TextOutput/TextOutputController.swift:65` uses `as! AXUIElement`.
- Impact:
  - Potential crash on unexpected AX focused object types.
- Improvement:
  - Replace with safe cast/guard and fallback path.

### 6) Clipboard fallback is lossy

- Evidence:
  - `Core/TextOutput/TextOutputController.swift:81` stores only string content and restores only that.
- Impact:
  - Rich clipboard data can be lost.
  - Clipboard can be overwritten if app crashes before delayed restore.
- Improvement:
  - Snapshot and restore full pasteboard items/types.
  - Consider pasteboard-change-count checks before restore.

### 7) No timeout/cancellation for whisper subprocess

- Evidence:
  - `Core/STT/WhisperCppTranscriber.swift:84` waits indefinitely.
- Impact:
  - Hung process can trap app in processing state.
- Improvement:
  - Add timeout and cooperative cancellation.
  - Terminate/kill process on task cancellation.

### 8) Input device/permission changes are pull-based only

- Evidence:
  - Device list/permissions refresh mostly through explicit refresh calls (`App/AppCoordinator.swift:111`, `App/AppCoordinator.swift:116`, `UI/Settings/SettingsView.swift:40`).
- Impact:
  - UI can become stale when system settings/devices change externally.
- Improvement:
  - Add system listeners for audio-device changes and app-activation permission re-check.

### 9) Hotkey key label mapping is inaccurate

- Evidence:
  - `Core/Hotkey/GlobalHotkeyService.swift:42` maps keyCode to letter via `UnicodeScalar(keyCode + 0x41)`.
- Impact:
  - Incorrect labels for many keys/layouts.
- Improvement:
  - Use Carbon/TIS keyboard layout APIs for keycode-to-display translation.

### 10) Global default input switching has failure edge cases

- Evidence:
  - App switches system default input before recording (`App/AppCoordinator.swift:263`-`App/AppCoordinator.swift:274`) and restores best-effort (`App/AppCoordinator.swift:277`-`App/AppCoordinator.swift:280`).
- Impact:
  - If app exits unexpectedly mid-session, system input may remain changed.
- Improvement:
  - Add explicit user warning and robust recovery path on next app launch.
  - Prefer app-scoped routing if feasible with capture API choices.

## P2 (Quality and maintainability)

### 11) Minor unsafe/inefficient data handling in WAV writer

- Evidence:
  - `Core/STT/WavWriter.swift:25` and nearby uses forced unwraps for ASCII constants.
  - Per-sample appends allocate repeatedly (`Core/STT/WavWriter.swift:15`-`Core/STT/WavWriter.swift:19`).
- Improvement:
  - Remove forced unwraps for fixed headers.
  - Use batched writes for PCM conversion.

### 12) Release metadata/process hardening

- Evidence:
  - Empty entitlements file at `App/VoicePloeg.entitlements`.
  - Manual release flow in `Docs/RELEASE.md` with limited automated verification.
- Improvement:
  - Add explicit release manifest (app version, whisper revision, model hash set).
  - Expand preflight with deterministic artifact checks and a smoke-run gate.

### 13) Docs mismatch with runtime behavior

- Evidence:
  - QA suggests “model remains loaded” (`Docs/QA.md:35`), but current implementation invokes `whisper-cli` per request (`Core/STT/WhisperCppTranscriber.swift:60`-`Core/STT/WhisperCppTranscriber.swift:85`).
- Improvement:
  - Align QA/doc language with current architecture or implement persistent in-process model loading.

## Suggested Execution Plan

### Phase 1 (1-2 weeks)

- Move STT/model heavy work off main actor.
- Add timeout/cancellation in `WhisperCppTranscriber`.
- Replace unsafe AX cast.
- Add minimal test target with core coordinator/model tests.

### Phase 2 (1-2 weeks)

- Populate and enforce model checksums + size validation.
- Pin whisper.cpp revision and validate in preflight.
- Improve clipboard restore robustness.

### Phase 3 (2-3 weeks)

- Add listeners for dynamic device/permission changes.
- Improve hotkey label translation.
- Harmonize docs with actual runtime behavior.

## Acceptance Criteria for “v1 hardening complete”

- No blocking transcription/download/checksum work on main actor.
- Release preflight fails by default on missing/invalid model checksums.
- Reproducible `whisper.cpp` version pin in bootstrap + docs.
- At least 15-20 unit tests covering coordinator/model/output core logic.
- No force-cast crash path in text insertion module.
