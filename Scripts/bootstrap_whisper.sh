#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/whisper.cpp"
BUILD_DIR="$VENDOR_DIR/build"
WHISPER_VERSION_FILE="$ROOT_DIR/Scripts/whisper.version"
WHISPER_REF="${WHISPER_REF:-$(tr -d '[:space:]' < "$WHISPER_VERSION_FILE")}"
WHISPER_REPO_URL="https://github.com/ggerganov/whisper.cpp"
WHISPER_ARCHITECTURES="${WHISPER_ARCHITECTURES:-arm64;x86_64}"

if [[ ! -d "$VENDOR_DIR/.git" ]]; then
  git clone --filter=blob:none "$WHISPER_REPO_URL" "$VENDOR_DIR"
fi

CURRENT_REF="$(git -C "$VENDOR_DIR" rev-parse HEAD)"
if [[ "$CURRENT_REF" != "$WHISPER_REF" ]]; then
  git -C "$VENDOR_DIR" fetch --depth 1 origin "$WHISPER_REF"
  git -C "$VENDOR_DIR" checkout --detach FETCH_HEAD
fi

cmake -S "$VENDOR_DIR" -B "$BUILD_DIR" \
  -DCMAKE_OSX_ARCHITECTURES="$WHISPER_ARCHITECTURES" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DWHISPER_METAL=ON -DWHISPER_COREML=OFF -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$BUILD_DIR" --config Release -j

echo "whisper-cli built at: $BUILD_DIR/bin/whisper-cli"
