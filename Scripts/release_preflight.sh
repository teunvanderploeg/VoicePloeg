#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/VoicePloeg.xcodeproj"
SCHEME="VoicePloeg"
MODEL_CATALOG="$ROOT_DIR/Resources/ModelCatalog.json"
WHISPER_CLI="$ROOT_DIR/Vendor/whisper.cpp/build/bin/whisper-cli"
WHISPER_REPO="$ROOT_DIR/Vendor/whisper.cpp"
WHISPER_VERSION_FILE="$ROOT_DIR/Scripts/whisper.version"

STRICT_MODEL_CHECKSUMS="${STRICT_MODEL_CHECKSUMS:-0}"
SKIP_XCODEBUILD="${SKIP_XCODEBUILD:-0}"

info() { printf "\033[1;34m[info]\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$1"; }
fail() { printf "\033[1;31m[fail]\033[0m %s\n" "$1"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

pattern_exists() {
  local pattern="$1"
  local file="$2"
  if has_cmd rg; then
    rg -q "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}

info "VoicePloeg release preflight started"

require_cmd swift
require_cmd xcodegen
require_cmd xcodebuild

cd "$ROOT_DIR"

info "Step 1/5: Swift build"
swift build

info "Step 2/5: Strict concurrency build"
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

info "Step 3/5: Regenerate Xcode project"
xcodegen generate --spec "$ROOT_DIR/project.yml"

if [[ "$SKIP_XCODEBUILD" != "1" ]]; then
  info "Step 4/5: Unsigned release build via xcodebuild"

  XCODE_LOG="$(mktemp -t voiceploeg-xcodebuild.XXXXXX.log)"
  set +e
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build >"$XCODE_LOG" 2>&1
  XCODE_STATUS=$?
  set -e

  if [[ $XCODE_STATUS -ne 0 ]]; then
    if pattern_exists "runFirstLaunch|required plug-in|DVTPlugIn|IDESimulatorFoundation" "$XCODE_LOG"; then
      warn "xcodebuild environment looks incomplete. Try: xcodebuild -runFirstLaunch"
    fi
    tail -n 80 "$XCODE_LOG"
    fail "Release xcodebuild failed"
  fi
else
  warn "Skipping xcodebuild release compile because SKIP_XCODEBUILD=1"
fi

info "Step 5/5: Release gating checks"

if [[ ! -x "$WHISPER_CLI" ]]; then
  warn "whisper-cli not found or not executable at: $WHISPER_CLI"
  warn "Build it with: $ROOT_DIR/Scripts/bootstrap_whisper.sh"
fi

if [[ ! -f "$WHISPER_VERSION_FILE" ]]; then
  fail "Missing pinned whisper.cpp version file: $WHISPER_VERSION_FILE"
fi

PINNED_WHISPER_REF="$(tr -d '[:space:]' < "$WHISPER_VERSION_FILE")"
if [[ -z "$PINNED_WHISPER_REF" ]]; then
  fail "Pinned whisper.cpp version file is empty: $WHISPER_VERSION_FILE"
fi

if [[ ! -d "$WHISPER_REPO/.git" ]]; then
  fail "Vendored whisper.cpp repository missing at: $WHISPER_REPO"
fi

CURRENT_WHISPER_REF="$(git -C "$WHISPER_REPO" rev-parse HEAD)"
if [[ "$CURRENT_WHISPER_REF" != "$PINNED_WHISPER_REF" ]]; then
  fail "whisper.cpp revision mismatch. expected=$PINNED_WHISPER_REF current=$CURRENT_WHISPER_REF"
fi

if pattern_exists '"sha256"[[:space:]]*:[[:space:]]*"UNVERIFIED"' "$MODEL_CATALOG"; then
  if [[ "$STRICT_MODEL_CHECKSUMS" == "1" ]]; then
    fail "Model catalog contains UNVERIFIED sha256 entries (STRICT_MODEL_CHECKSUMS=1)"
  else
    warn "Model catalog still contains UNVERIFIED sha256 entries"
  fi
fi

info "Release preflight completed"
