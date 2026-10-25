# VoicePloeg

Native macOS (Swift + SwiftUI) menu bar app for offline dictation:
- Global hotkey toggles recording
- Selectable local transcription via `whisper.cpp`, CrisperWhisper 2.0, or Underdog Bark 3.0
- Text insertion into the active app (AX first, clipboard fallback)

## Current v1 Prototype Status

Implemented:
- Menu bar app with `Idle`, `Listening`, `Processing`, `Error` states
- Global hotkey (`Control + Option + Space` default)
- Microphone and accessibility permission flows
- Preferred recording input device selection (with temporary switch/restore during recording)
- Bluetooth/HFP input warning guardrail in Settings
- 16kHz mono audio capture and normalization
- Local model catalog + on-demand model download to `~/Library/Application Support/VoicePloeg/Models`
- Offline transcription through local `whisper-cli`
- Optional local CrisperWhisper 2.0 intended-mode transcription on Apple Silicon
- App-managed Python/PyTorch runtime and local small/medium/turbo/large model downloads
- Text output into focused app with accessibility-first strategy and clipboard fallback
- Settings for model, hotkey, language, and `whisper-cli` path

## Project Layout

- `/Users/teun/Code/VoicePloeg/VoicePloeg.xcodeproj`
- `/Users/teun/Code/VoicePloeg/App/VoicePloegApp.swift`
- `/Users/teun/Code/VoicePloeg/App/MenuBarRoot.swift`
- `/Users/teun/Code/VoicePloeg/App/AppCoordinator.swift`
- `/Users/teun/Code/VoicePloeg/Core/State/AppState.swift`
- `/Users/teun/Code/VoicePloeg/Core/Hotkey/GlobalHotkeyService.swift`
- `/Users/teun/Code/VoicePloeg/Core/Permissions/PermissionController.swift`
- `/Users/teun/Code/VoicePloeg/Core/Audio/AudioCaptureService.swift`
- `/Users/teun/Code/VoicePloeg/Core/STT/SpeechTranscriber.swift`
- `/Users/teun/Code/VoicePloeg/Core/STT/WhisperCppTranscriber.swift`
- `/Users/teun/Code/VoicePloeg/Core/STT/WhisperBridge.mm`
- `/Users/teun/Code/VoicePloeg/Core/TextOutput/TextOutputController.swift`
- `/Users/teun/Code/VoicePloeg/Core/Models/ModelManager.swift`
- `/Users/teun/Code/VoicePloeg/UI/Settings/SettingsView.swift`
- `/Users/teun/Code/VoicePloeg/UI/Settings/HotkeyRecorderView.swift`
- `/Users/teun/Code/VoicePloeg/UI/Settings/ModelPickerView.swift`
- `/Users/teun/Code/VoicePloeg/Resources/ModelCatalog.json`
- `/Users/teun/Code/VoicePloeg/Scripts/bootstrap_whisper.sh`
- `/Users/teun/Code/VoicePloeg/Scripts/notarize.sh`

## Build and Run

1. Build `whisper.cpp` CLI:
   ```bash
   /Users/teun/Code/VoicePloeg/Scripts/bootstrap_whisper.sh
   ```
2. Bootstrap the optional CrisperWhisper runtime installer:
   ```bash
   /Users/teun/Code/VoicePloeg/Scripts/bootstrap_crisper_runtime.sh
   ```
3. Generate/update project (if you modify `project.yml`):
   ```bash
   cd /Users/teun/Code/VoicePloeg
   xcodegen generate
   ```
4. Open the project:
   ```bash
   open /Users/teun/Code/VoicePloeg/VoicePloeg.xcodeproj
   ```
5. In Xcode:
   - Select your signing team
   - Build and run `VoicePloeg`
6. Grant permissions when prompted:
   - Microphone
   - Accessibility
7. Open settings and click `Download / Activate` for a model.

## Notes on Whisper Integration

`WhisperCppTranscriber` currently executes local `whisper-cli` as a child process.
This keeps integration stable and maintainable for v1 while remaining fully offline.

`WhisperBridge.mm` is included as a placeholder for future direct ObjC++ bridging to `whisper.cpp` APIs for lower overhead and potential streaming.

## CrisperWhisper 2.0

Select **CrisperWhisper 2.0** on the Transcription settings page, accept the non-commercial model license, install the runtime, choose a model, and download it. Internet access is required only for installation. Inference is local: VoicePloeg loads safetensors from Application Support, forces Hugging Face/Transformers offline mode, and never sends audio to an API.

CrisperWhisper is enabled only on Apple Silicon. Its standard weights are licensed for non-commercial research use; commercial use requires a license from Nyra. The existing `whisper.cpp` backend remains available on all supported Macs.

## Underdog Bark 3.0

In **Transcription → Models by language**, select **Underdog Bark 3.0** for English. Install its local runtime and download the weights under **Model downloads**. Bark requires Apple Silicon and supports English only. Existing Whisper and CrisperWhisper models remain available for Dutch and other languages.

The English picker offers **Bark 3.0**, **Bark 3.0 Plus**, and **Bark 3.0 Pro** independently. Standard and Plus use compressed downloads of approximately 163 MB and 180 MB, unpacked to FP16 MLX weights. Pro downloads approximately 1.25 GB of BF16 weights and retains BF16 when converting tensor layouts for the same MLX graph. Each variant has its own pinned revision, checksums, installation directory, and model notice. Selecting another variant does not change Dutch or Default.

English, Dutch, and Default are saved independently. Changing the language in Settings or with the language shortcut automatically selects its assigned model and backend. English and Dutch can also be set to **Use default**. Other languages and Auto use Default; Auto requires a whisper.cpp model. The menu bar shows the model selected for the current language. A recording keeps the language and model it started with even if the selection changes before it finishes.

Existing settings migrate once. For an existing Bark selection, Bark stays assigned to English, the previous multilingual Whisper choice becomes Default, and a previously selected CrisperWhisper model is retained for Dutch. Model download controls do not change these assignments.

The app uses the pinned reference MLX loader with a separate, hash-locked Python environment. It verifies the model data against pinned sizes and SHA-256 checksums, unpacks weights during installation, and runs a persistent offline worker for dictation. Installation needs internet access. Audio stays on the Mac. Long recordings are split at quiet points into windows of at most 20 seconds to limit encoder memory.

The Standard and Plus downloads expand to approximately 1.25 GB of weights each, plus runtime packages. Initial unpacking needs about 6 GB of memory. Bark preserves fillers and false starts. Its CC BY 4.0 attribution is in Settings and the `BARK_NOTICE`, `BARK_PLUS_NOTICE`, and `BARK_PRO_NOTICE` files under `Resources/BarkWorker`.

See [the model assessment](Docs/BARK_ASSESSMENT.md) for local timing measurements, published results, and limits of the comparison. `Scripts/benchmark_bark_macos.py` runs a repeatable offline diagnostic with the Bark runtime's Python.

## Distribution

See:
- `/Users/teun/Code/VoicePloeg/Docs/ARCHITECTURE.md`
- `/Users/teun/Code/VoicePloeg/Docs/DISTRIBUTION.md`
- `/Users/teun/Code/VoicePloeg/Docs/QA.md`
- `/Users/teun/Code/VoicePloeg/Docs/RELEASE.md`

Pre-release automation:
```bash
/Users/teun/Code/VoicePloeg/Scripts/release_preflight.sh
```
