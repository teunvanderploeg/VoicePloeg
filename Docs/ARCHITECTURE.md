# Architecture

## Runtime Flow

1. Global hotkey event arrives in `GlobalHotkeyService`.
2. `AppCoordinator` toggles recording/transcription state.
3. `AudioCaptureService` captures mic audio with `AVAudioEngine` and converts to 16kHz mono PCM float.
4. `SpeechTranscriptionService` routes the immutable request to the selected local backend:
   - `WhisperCppTranscriber` writes a temporary WAV and invokes local `whisper-cli`.
   - `CrisperWhisperTranscriber` sends the temporary WAV to a persistent local Python/PyTorch worker using newline-delimited JSON.
5. Transcription result is inserted by `ActiveAppTextOutputController`:
   - Clipboard paste for Codex and ChatGPT composers
   - Accessibility insertion first in other apps, with clipboard paste fallback
   - Paste shortcuts use the macOS session event stream after verifying the original app is frontmost

## Core Interfaces

- `RecordingController`
- `SpeechTranscribing`
- `TextOutputController`
- `PermissionController`

These interfaces isolate implementation details so ML backend and output strategy can be swapped without UI rewrites.

## CrisperWhisper 2.0

- Optional Apple Silicon backend; `whisper.cpp` remains the default and fallback.
- The app provisions a pinned Python 3.12 environment under Application Support.
- Small, medium, turbo, and large snapshots are downloaded at immutable Hugging Face revisions.
- Inference receives a local snapshot path and forces `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`.
- Audio is never uploaded and no inference API or API key is used.
- Intended/clean mode is fixed and an explicit language is required.
- The active model remains warm until backend/model change, memory pressure, app exit, or ten minutes idle.

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
