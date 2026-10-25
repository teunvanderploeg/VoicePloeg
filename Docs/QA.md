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
- Cycle English/Dutch rapidly at least 20 times, including while a model is still loading. The app must remain running, show the final language immediately, and warm only the final selection after a short pause. Repeat with Bark for English and Crisper for Dutch, then dictate in each language.

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
- Dictate into Codex and ChatGPT composers with existing text and with selected text. Verify insertion at the caret or replacement of the selection, and that the app recognizes the edited draft.
- Stop dictation while holding the hotkey modifiers. Verify paste waits for release and inserts only once.
- Start dictation in Codex/ChatGPT, switch to another app while processing, and verify output returns to the original app. If activation fails, verify no text is pasted elsewhere and the transcript remains in History.
- Existing clipboard contents are restored.

## Live dictation

- Confirm Live dictation defaults off, persists across relaunch, and is available in Transcription settings and the menu bar. Mode controls should be disabled during a recording.
- Enable it, place the cursor in TextEdit, start with the hotkey, and dictate two phrases separated by a one-second pause. Each phrase should arrive before Stop. Stop during the next phrase and verify the final words arrive once, with correct spacing. History should contain one entry for the full session.
- Repeat in Notes, a browser text area, and Codex/ChatGPT. These web-backed editors must expose readable text and cursor information for live mode. Check that the draft recognizes each edit and that the original clipboard is restored.
- Hold the hotkey modifiers when stopping in a clipboard-based editor. Paste should wait for release, keep its leading space, and never repeat the full transcript.
- Move the caret, select text, type, click, or switch apps between phrases. Insertion should remain paused even after returning. No app should be brought forward. Continue speaking and verify all recognized phrases are saved in History after Stop.
- In ChatGPT/Codex, start with an empty composer and dictate several phrases. Placeholder newlines, nonbreaking spaces, and delayed Accessibility updates must not stop insertion. Repeat with existing text, emoji, and accented words. Confirm actual cursor movement still pauses insertion, and no phrase is retried or duplicated if delivery cannot be confirmed.
- Start in a secure field, a field with a selection, or an editor without readable text/cursor data. Recording should be rejected with an explanation. Turn Live dictation off and verify normal mode still works.
- Choose a slow model and dictate several phrases. Check the Catching up status, phrase ordering, and responsiveness while finishing. Cancel remaining dictation while processing and verify no later result is inserted.
- Test quiet speech, a single short word, silence, fan noise, and continuous speech longer than 15 seconds. Energy-based detection can defer boundaries in noisy rooms. Listen for words cut at a forced boundary and check for invented text on noise.
- Switch language/model settings during recording. The active session must keep its starting selection, and the next recording must use the new selection.
- Check automatic Stop at two minutes and a single History entry after successful insertion, paused insertion, and transcription failure. A transcription failure should stop capture and retain completed phrases.

An opt-in offline smoke test runs the actual segmenter and installed backends against two copies of the bundled JFK recording separated by silence. It never downloads models. Substitute any installed catalog IDs:

```bash
VOICEPLOEG_LIVE_SMOKE_MODELS=ggml-base.en-q5_1,ggml-base-q5_1,underdog-bark-3,crisper-whisper-2-medium \
  swift test --filter LiveDictationSmokeTests
```

For Dutch or another fixture, set `VOICEPLOEG_LIVE_SMOKE_WAV` to an absolute path to a 16 kHz mono WAV and `VOICEPLOEG_LIVE_SMOKE_LANGUAGE=nl`. Use multilingual Whisper or Crisper models for Dutch. The diagnostic prints per-phrase text and recognition time, excluding pause detection and editor insertion. A fixture smoke test is not a representative accuracy benchmark.

To verify real Accessibility and clipboard delivery, compile the disposable editor and run the opt-in native smoke test. It covers native text, clipboard fallback, a rich-text placeholder/NBSP representation, and an asynchronous AX write. It briefly opens its own windows, restores the previous active app, and requires the test runner to already have Accessibility permission. It does not open user documents.

```bash
swiftc Tests/Fixtures/LiveTextEditor.swift -o /tmp/VoicePloegLiveTextEditor
VOICEPLOEG_LIVE_TEXT_FIXTURE=/tmp/VoicePloegLiveTextEditor \
  swift test --filter LiveTextOutputSmokeTests
```

To stress-test worker cancellation with already installed models, run:

```bash
VOICEPLOEG_MODEL_SWITCH_SMOKE=underdog-bark-3-pro,crisper-whisper-2-turbo \
  swift test --filter ModelSwitchingSmokeTests
```

This alternates real model loads twelve times, cancels pending loads, and confirms both backends can still load afterward. It never downloads models. The regular worker tests also isolate the broken-pipe regression in a subprocess with default SIGPIPE handling so it cannot terminate the test suite.

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
