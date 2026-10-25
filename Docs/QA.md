# QA Checklist

## Live dictation

- Enable live dictation, relaunch, and verify the preference persists. Disable it and verify the existing stop-then-transcribe behavior.
- Start with the hotkey in an empty text field. Speak two sentences with pauses. Verify the first appears while recording and Stop inserts only the final words.
- In Firefox textarea and contenteditable fields, and in the ChatGPT app composer, test existing text, selected text, Dutch accents, repeated sentences, and several phrases. Verify the editor recognizes the draft and no message is submitted.
- Switch apps or focus another field before a phrase finishes. Verify no focus is stolen, output pauses, and the full transcript is available in History after Stop.
- Speak without pauses for over 12 seconds. Verify bounded chunks continue in order.
- Stop during model inference or a pending paste. Verify every phrase appears at most once and the final tail is drained.
- Try a slow model with several queued phrases and verify recording remains responsive.
- Record silence and short background clicks. Verify no model requests or History entries.
- Verify the automatic two-minute stop drains live audio and saves one History entry.
- Start live mode from Settings or a password field and verify the message directs you to an editable field.
- Verify clipboard restoration and that copying during a pending paste preserves the newly copied content.

## Permissions

- Launch with no permissions and verify clear state/error handling.
- Deny microphone and verify app transitions to `Error`.
- Grant microphone and verify recording works.
- Deny Accessibility and verify recording is rejected before capture, with a recovery action in Settings.
- Grant accessibility and verify AX insertion works in TextEdit/Notes.

## Hotkey

- Default hotkey toggles start/stop.
- Custom hotkey can be recorded and saved.
- Hotkey works while another app is focused.
- Start cue sound plays on recording start.
- Stop cue sound plays on recording stop.
- Cycle English/Dutch rapidly at least 20 times while models are loading. Verify the app remains running, shows the final language immediately, and dictation still works in both languages.

## Audio/STT

- 5s dictation transcribes successfully.
- 30s dictation transcribes successfully.
- Silence does not crash and produces empty/near-empty output.
- Missing `whisper-cli` path produces actionable error.
- Missing or corrupt models prevent capture and point to an explicit model download in Settings.
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
- Dictate into Codex and ChatGPT composers with existing text and with selected text. Verify insertion at the caret or replacement of the selection, and that the app recognizes the edited draft.
- Stop dictation while holding the hotkey modifiers. Verify paste waits for release and inserts only once.
- Start dictation in Codex/ChatGPT, switch to another app while processing, and verify output returns to the original app. If activation fails, verify no text is pasted elsewhere and the transcript remains in History.
- Existing clipboard contents are restored.

## Performance

- Verify Bark and Crisper remain loaded between transcriptions, then unload after ten minutes idle. Whisper warms its filesystem cache and starts a new CLI per request.
- Measure end-to-end latency for 10s and 30s recordings on Apple Silicon.
- Monitor memory while recording up to 120s cap.
- Verify recording automatically stops and transcribes at 120s and the timer is visible.
- Press the recording hotkey repeatedly while permission/startup is pending; only one recording should start.
- Verify model download, removal, and runtime repair cannot overlap dictation.
- Choose Dutch with an English-only model; recording should explain the incompatibility.
- Install the release app without the project checkout or Homebrew and verify bundled Whisper works.
- Verify a failed insertion leaves a transcript in History and available from Copy transcript.
- Run `Scripts/benchmark_crisper_macos.py <local-model> <wav>` for cold/warm MPS timing and peak RSS.

## Model-switch cancellation diagnostic

With the listed models already installed, run:

```bash
VOICEPLOEG_MODEL_SWITCH_SMOKE=underdog-bark-3-pro,crisper-whisper-2-turbo \
  swift test --filter ModelSwitchingSmokeTests
```

This cancels twelve alternating model loads and verifies both backends can still load. The worker regression suite also checks broken pipes, concurrent requests, cancellation, and shutdown without terminating the app.

## Upgrade regression checks

- Select Auto and dictate Dutch with a multilingual Whisper model. Assign Crisper as Default and confirm Auto keeps its independent Whisper assignment.
- Attempt a conflicting shortcut while idle. The previous shortcut must stay active. Hotkey editing must be disabled during recording; Escape cancels shortcut recording.
- Disconnect or change the recording input during capture. Verify capture stops and Retry recovers already captured audio. Retry must not paste into an old editor.
- Change the system input externally while recording, then stop. VoicePloeg must preserve the external choice. Quit during capture and verify its own temporary input change is restored.
- Force a backend error, retry, discard, and start a new recording. Check that no audio is retained after success, discard, or quit, and that insertion failure does not offer a duplicate transcription.
- Try Off, 7 days, 30 days and Until cleared for history. Verify expiry after relaunch, persistent per-entry deletion, and Clear all transcripts clearing the current transcript too.
- Interrupt runtime repair and retry it. Check that the previous usable runtime remains recoverable and incomplete candidates never appear ready.
- Inspect preparation, transcription and text delivery timings in Settings. Test a slow or unresponsive editor and confirm Accessibility timeouts permit fallback.

## Offline recognition corpus

With these models already installed, run:

```bash
VOICEPLOEG_OFFLINE_SMOKE_MODELS=ggml-base-q5_1,underdog-bark-3,crisper-whisper-2-medium \
  swift test --filter OfflineBackendSmokeTests
```

The default corpus combines the vendored English JFK sample and a short synthetic Dutch fixture. It tests explicit language and Auto where supported, with raw, normalized and attenuated-then-normalized audio. Each JSON observation records model load time, inference time, duration and word error rate. These fixtures test integration and regression; they do not establish everyday dictation accuracy or compare model quality across speakers.

Set `VOICEPLOEG_DICTATION_CORPUS` to an absolute path to another manifest with the same format as `Tests/Fixtures/dictation-corpus.example.json`. Audio must be nonempty 16 kHz mono WAV. Paths resolve relative to the manifest. Add real quiet/noisy speech, short words, names and domain vocabulary in English and Dutch before changing models or segmentation policies. The test never records or downloads anything.
