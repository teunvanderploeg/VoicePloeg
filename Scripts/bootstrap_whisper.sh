#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/whisper.cpp"
BUILD_DIR="$VENDOR_DIR/build"

if [[ ! -d "$VENDOR_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp "$VENDOR_DIR"
fi

cmake -S "$VENDOR_DIR" -B "$BUILD_DIR" -DWHISPER_METAL=ON -DWHISPER_COREML=OFF
cmake --build "$BUILD_DIR" --config Release -j

echo "whisper-cli built at: $BUILD_DIR/bin/whisper-cli"
