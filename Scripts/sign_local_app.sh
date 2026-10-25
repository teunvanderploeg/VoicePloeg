#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?Usage: sign_local_app.sh <VoicePloeg.app>}"

# Include the app entitlements explicitly when signing an unsigned Xcode build.
/usr/bin/codesign --force --sign - --options runtime \
  --entitlements "$ROOT_DIR/App/VoicePloeg.entitlements" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

python3 - "$APP_PATH" <<'PY'
import plistlib
import subprocess
import sys

result = subprocess.run(
    ['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', sys.argv[1]],
    check=True, capture_output=True,
)
entitlements = plistlib.loads(result.stdout)
if entitlements.get('com.apple.security.device.audio-input') is not True:
    raise SystemExit('Signed app is missing its microphone entitlement.')
print('Verified microphone entitlement in signed app.')
PY
