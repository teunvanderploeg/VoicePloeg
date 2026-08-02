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
