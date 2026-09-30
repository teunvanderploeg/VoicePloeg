# Signing, Hardened Runtime, and Notarization

## Required Permission Keys

`/Users/teun/Code/VoicePloeg/App/Info.plist` includes:
- `NSMicrophoneUsageDescription`
- `LSUIElement` (menu bar app behavior)

## Accessibility Permission

Accessibility trust is managed with `AXIsProcessTrustedWithOptions`.
macOS will require the app to be explicitly enabled under:
System Settings > Privacy & Security > Accessibility

## Direct Distribution Path

0. Run release preflight:
   ```bash
   /Users/teun/Code/VoicePloeg/Scripts/release_preflight.sh
   ```
1. Build Release archive in Xcode.
2. Sign with `Developer ID Application`.
3. Ensure Hardened Runtime is enabled.
4. Notarize and staple:
   ```bash
   /Users/teun/Code/VoicePloeg/Scripts/notarize.sh <VoicePloeg.app> <apple-id> <team-id> <app-password>
   ```

## Known Risks

- Accessibility behavior varies per target app.
- Secure input fields (passwords, protected views) may reject insertion.
- Incorrect signing order of embedded binaries can break notarization.
- Model downloads are external artifacts; maintain checksum metadata before release.

## CrisperWhisper Runtime

- Run `Scripts/bootstrap_crisper_runtime.sh` before archiving so the pinned `uv` installer is embedded.
- CrisperWhisper is Apple Silicon-only and installs its Python/PyTorch environment under Application Support on demand.
- The runtime and model downloads are the only networked operations. Inference explicitly enables Hugging Face and Transformers offline modes.
- Standard CrisperWhisper weights use the Nyra Health Non-Commercial Research License. Do not commercially distribute them without a separate agreement.
- Ensure the embedded `uv` executable is signed as nested code before the outer app is sealed and notarized.

## Bundled Whisper runtime

The Xcode app build runs `Scripts/bundle_whisper.py` to package the pinned
`whisper-cli` and its dynamic libraries under `Contents/Helpers/Whisper.app`.
The script replaces development rpaths with paths relative to the helper,
includes the upstream licenses in the helper resources, and signs libraries,
the executable, and the helper app before the outer app.
Build the vendored CLI before building the app. A missing CLI fails the app
build rather than producing an installation that requires Homebrew.

The shipped app resolves this helper before development and Homebrew paths.
An explicitly configured CLI path or environment override still takes priority.
The bootstrap builds Apple Silicon and Intel slices by default. For a local
single-architecture build, set `WHISPER_ARCHITECTURES=arm64` or `x86_64`.
App packaging checks that every bundled binary supports the app's architectures.
