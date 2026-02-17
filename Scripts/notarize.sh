#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  cat <<USAGE
Usage: $0 <app-path> <apple-id> <team-id> <app-password>
Example:
  $0 build/Release/VoicePloeg.app you@example.com TEAMID1234 abcd-efgh-ijkl-mnop
USAGE
  exit 1
fi

APP_PATH="$1"
APPLE_ID="$2"
TEAM_ID="$3"
APP_PASSWORD="$4"
ZIP_PATH="${APP_PATH%.app}.zip"

/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

xcrun stapler staple "$APP_PATH"

echo "Notarization complete for $APP_PATH"
