# Release Stabilization Checklist

## Scope

This checklist is the minimum bar before shipping a direct-download notarized build.

## 1. Automated Preflight

Run from project root:

```bash
/Users/teun/Code/VoicePloeg/Scripts/release_preflight.sh
```

Default preflight behavior enforces model checksum verification. To temporarily relax this for local development:

```bash
STRICT_MODEL_CHECKSUMS=0 /Users/teun/Code/VoicePloeg/Scripts/release_preflight.sh
```

If your local Xcode installation is still setting up, you can skip the xcodebuild step temporarily:

```bash
SKIP_XCODEBUILD=1 /Users/teun/Code/VoicePloeg/Scripts/release_preflight.sh
```

## 2. Manual Functional Gates

Verify all of these in a clean session:

- First launch with no permissions shows clear UX.
- Microphone denied path shows error and recoverability.
- Accessibility denied path shows error and recoverability.
- Accessibility granted path inserts text in TextEdit.
- Global hotkey start/stop works from another frontmost app.
- Start and stop sound cues play consistently.
- Preferred input device switch/restore works.
- Bluetooth/HFP warning appears when effective input is Bluetooth.
- Model download + activation works on first run.
- Offline transcription succeeds with network disconnected.

## 3. Release Artifact Process

1. Build Release app archive in Xcode.
2. Sign with Developer ID Application.
3. Notarize and staple:

```bash
/Users/teun/Code/VoicePloeg/Scripts/notarize.sh <VoicePloeg.app> <apple-id> <team-id> <app-password>
```

4. Install notarized `.app` on a second machine/user account.
5. Re-run functional gates (especially Accessibility + insertion).

## 4. Known Risk Gates

- Accessibility trust is identity/path sensitive; always validate with the exact shipped app binary.
- Input automation can differ by target app security policy.
- `whisper-cli` process path must be valid in distributed environment.
- Model checksum metadata must be finalized before strict release gate.
