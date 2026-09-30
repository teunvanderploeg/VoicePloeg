# QA Checklist

## Permissions

- Launch with no permissions and verify clear state/error handling.
- Deny microphone and verify app transitions to `Error`.
- Grant microphone and verify recording works.
- Deny accessibility and verify clipboard fallback still inserts text.
- Grant accessibility and verify AX insertion works in TextEdit/Notes.

## Hotkey

- Default hotkey toggles start/stop.
- Custom hotkey can be recorded and saved.
- Hotkey works while another app is focused.
- Start cue sound plays on recording start.
- Stop cue sound plays on recording stop.

## Audio/STT

- 5s dictation transcribes successfully.
- 30s dictation transcribes successfully.
- Silence does not crash and produces empty/near-empty output.
- Missing `whisper-cli` path produces actionable error.
- Missing model path triggers download flow.
- Existing installations remain on `whisper.cpp` after upgrade.
- CrisperWhisper rejects Auto language before recording starts.
- Accepting the non-commercial license enables local model download.
- All four Crisper models show their independent installed state.
- Crisper inference works after disconnecting the network.
- Switching back to `whisper.cpp` unloads the Python worker.
- Interrupted runtime/model installation can be retried without appearing installed.

## Text Output

- AX insertion in TextEdit and Notes.
- Clipboard fallback in app where AX fails.
- Existing clipboard contents are restored.

## Performance

- Verify model remains loaded between transcriptions.
- Measure end-to-end latency for 10s and 30s recordings on Apple Silicon.
- Monitor memory while recording up to 120s cap.
- Verify recording automatically stops and transcribes at 120s and the timer is visible.
- Press the recording hotkey repeatedly while permission/startup is pending; only one recording should start.
- Verify model download, removal, and runtime repair cannot overlap dictation.
- Choose Dutch with an English-only model; recording should explain the incompatibility.
- Install the release app without the project checkout or Homebrew and verify bundled Whisper works.
- Verify a failed insertion leaves a transcript in History and available from Copy transcript.
- Run `Scripts/benchmark_crisper_macos.py <local-model> <wav>` for cold/warm MPS timing and peak RSS.
