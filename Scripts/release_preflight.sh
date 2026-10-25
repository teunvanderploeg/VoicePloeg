#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/VoicePloeg.xcodeproj"
SCHEME="VoicePloeg"
MODEL_CATALOG="$ROOT_DIR/Resources/ModelCatalog.json"
WHISPER_CLI="$ROOT_DIR/Vendor/whisper.cpp/build/bin/whisper-cli"
WHISPER_REPO="$ROOT_DIR/Vendor/whisper.cpp"
WHISPER_VERSION_FILE="$ROOT_DIR/Scripts/whisper.version"
CRISPER_VERSION_FILE="$ROOT_DIR/Scripts/crisper.version"
CRISPER_REQUIREMENTS="$ROOT_DIR/Resources/CrisperWorker/requirements.lock"
CRISPER_WORKER="$ROOT_DIR/Resources/CrisperWorker/worker.py"
CRISPER_UV="$ROOT_DIR/Resources/CrisperWorker/uv"

STRICT_MODEL_CHECKSUMS="${STRICT_MODEL_CHECKSUMS:-1}"
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
require_cmd python3

cd "$ROOT_DIR"

if [[ "$STRICT_MODEL_CHECKSUMS" == "1" ]]; then
  python3 Scripts/validate_model_catalog.py "$MODEL_CATALOG"
else
  python3 Scripts/validate_model_catalog.py "$MODEL_CATALOG" --allow-unverified
fi
python3 -m unittest discover -s "$ROOT_DIR/Tests/CatalogValidationTests" -v

info "Step 1/5: Swift build"
swift build

info "Swift tests"
swift test

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
  fail "whisper-cli missing; run Scripts/bootstrap_whisper.sh"
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
    warn "Model catalog still contains UNVERIFIED sha256 entries (STRICT_MODEL_CHECKSUMS=$STRICT_MODEL_CHECKSUMS)"
  fi
fi

if [[ ! -f "$CRISPER_VERSION_FILE" || ! -f "$CRISPER_REQUIREMENTS" || ! -f "$CRISPER_WORKER" ]]; then
  fail "CrisperWhisper pinned runtime resources are incomplete"
fi

# shellcheck source=/dev/null
source "$CRISPER_VERSION_FILE"
pattern_exists "crisperwhisper.*==${CRISPERWHISPER_VERSION}" "$CRISPER_REQUIREMENTS" \
  || fail "CrisperWhisper lock does not match Scripts/crisper.version"
pattern_exists 'sha256:' "$CRISPER_REQUIREMENTS" \
  || fail "CrisperWhisper lock has no package hashes"

[[ -x "$CRISPER_UV" ]] || fail "Pinned uv executable missing; run Scripts/bootstrap_crisper_runtime.sh"
/usr/bin/lipo -verify_arch arm64 "$CRISPER_UV" || fail "Runtime installer must support Apple Silicon"
if [[ "$(uname -m)" == "arm64" ]]; then
  UV_OUTPUT="$("$CRISPER_UV" --version)"
  [[ "$UV_OUTPUT" == "uv ${UV_VERSION}"* ]] || fail "Bundled uv version mismatch"
fi

python3 -m unittest discover -s "$ROOT_DIR/Tests/CrisperWorkerTests" -v
python3 -m unittest discover -s "$ROOT_DIR/Tests/BarkWorkerTests" -v

python3 - "$MODEL_CATALOG" "$ROOT_DIR/Resources/BarkWorker" <<'PY'
import json
from pathlib import Path
import re
import sys

bark_resources = Path(sys.argv[2])
for name in ["bark_worker.py", "bark_loader.py", "bark_mlx.py", "BARK_NOTICE", "BARK_PLUS_NOTICE", "BARK_PRO_NOTICE", "BARK_SOURCE.txt", "bark-model-files.json", "bark-requirements.lock"]:
    if not (bark_resources / name).is_file():
        raise SystemExit(f"missing Bark resource: {name}")
lock = (bark_resources / "bark-requirements.lock").read_text()
for package in ["mlx==0.32.2", "mlx-audio==0.5.3", "constriction==0.5.0"]:
    if package not in lock or "--hash=sha256:" not in lock:
        raise SystemExit(f"Bark dependency lock is incomplete: {package}")
items = json.load(open(sys.argv[1], encoding="utf-8"))
bark = [item for item in items if item.get("backend") == "bark"]
variants = json.loads((bark_resources / "bark-model-files.json").read_text())
expected_ids = {"underdog-bark-3", "underdog-bark-3-plus", "underdog-bark-3-pro"}
if {item["id"] for item in bark} != expected_ids or set(variants) != expected_ids:
    raise SystemExit("expected Standard, Plus, and Pro Bark models")
for item in bark:
    variant = variants[item["id"]]
    if item.get("revision") != variant["revision"] or item.get("repositoryID") != variant["repository"]:
        raise SystemExit(f"Bark catalog and pinned manifest differ: {item['id']}")
    if not re.fullmatch(r"[0-9a-f]{40}", variant["revision"]):
        raise SystemExit(f"unpinned Bark revision: {item['id']}")
    if item.get("languageSupport") != ["en"] or item.get("licenseIdentifier") != "cc-by-4.0":
        raise SystemExit(f"invalid Bark language or license metadata: {item['id']}")
    for entry in variant["files"].values():
        if not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", "")) or entry.get("size", 0) <= 0:
            raise SystemExit("invalid Bark model checksum metadata")
crisper = [item for item in items if item.get("backend") == "crisperWhisper"]
if len(crisper) != 4:
    raise SystemExit("expected four CrisperWhisper models")
for item in crisper:
    if not re.fullmatch(r"[0-9a-f]{40}", item.get("revision", "")):
        raise SystemExit(f"unpinned CrisperWhisper revision: {item.get('id')}")
    if item.get("licenseIdentifier") != "nyra-health-non-commercial-research":
        raise SystemExit(f"missing CrisperWhisper license metadata: {item.get('id')}")
PY

info "Release preflight completed"
