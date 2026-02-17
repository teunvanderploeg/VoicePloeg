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

## Text Output

- AX insertion in TextEdit and Notes.
- Clipboard fallback in app where AX fails.
- Existing clipboard contents are restored.

## Performance

- Verify model remains loaded between transcriptions.
- Measure end-to-end latency for 10s and 30s recordings on Apple Silicon.
- Monitor memory while recording up to 120s cap.
