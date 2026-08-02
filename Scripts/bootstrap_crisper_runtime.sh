#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/Scripts/crisper.version"
DESTINATION="$ROOT_DIR/Resources/CrisperWorker/uv"

# shellcheck source=/dev/null
source "$VERSION_FILE"

if [[ "$(uname -m)" != "arm64" ]]; then
  printf 'CrisperWhisper runtime is supported only on Apple Silicon.\n' >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
ARCHIVE="$TEMP_DIR/uv.tar.gz"
URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-aarch64-apple-darwin.tar.gz"

curl --fail --location --silent --show-error "$URL" --output "$ARCHIVE"
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$UV_ARCHIVE_SHA256" ]]; then
  printf 'uv checksum mismatch. expected=%s actual=%s\n' "$UV_ARCHIVE_SHA256" "$ACTUAL_SHA256" >&2
  exit 1
fi

tar -xzf "$ARCHIVE" -C "$TEMP_DIR"
install -m 0755 "$TEMP_DIR/uv-aarch64-apple-darwin/uv" "$DESTINATION"
printf 'Installed uv %s at %s\n' "$UV_VERSION" "$DESTINATION"
