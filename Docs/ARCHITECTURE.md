# Architecture

## Runtime Flow

1. Global hotkey event arrives in `GlobalHotkeyService`.
2. `AppCoordinator` toggles recording/transcription state.
3. `AudioCaptureService` captures mic audio with `AVAudioEngine` and converts to 16kHz mono PCM float.
4. `WhisperCppTranscriber` writes WAV temp file and invokes local `whisper-cli` with selected model.
5. Transcription result is inserted by `ActiveAppTextOutputController`:
   - Accessibility insertion first
   - Clipboard paste fallback

## Core Interfaces

- `RecordingController`
- `SpeechTranscriber`
- `TextOutputController`
- `PermissionController`

These interfaces isolate implementation details so ML backend and output strategy can be swapped without UI rewrites.

## Key Tradeoffs (Current)

- Chosen: `whisper-cli` process invocation in v1
- Benefit: reliable, low integration risk, easy updates
- Cost: process startup overhead and no partial streaming yet

- Chosen: stop-and-transcribe
- Benefit: simpler state model and predictable CPU/memory
- Cost: no continuous live partial transcript

- Chosen: AX insertion + clipboard fallback
- Benefit: best compatibility across apps
- Cost: some secure apps/fields may reject both methods
