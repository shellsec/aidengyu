#!/bin/zsh

set -euo pipefail

WINDOWS_DIR="${0:A:h}"
PROJECT_DIR="${WINDOWS_DIR:h}"
OUTPUT_DIR="$PROJECT_DIR/dist-windows"
EXE_PATH="$OUTPUT_DIR/aidengyu.exe"
STAGE_DIR="$OUTPUT_DIR/aidengyu-Windows-x64"
ZIP_PATH="$OUTPUT_DIR/aidengyu-Windows-x64.zip"

if ! command -v go >/dev/null 2>&1; then
  echo "Go toolchain is required." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
cd "$WINDOWS_DIR"

go test ./internal/core/ -count=1
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags='-H windowsgui -s -w' -o "$EXE_PATH" ./cmd/signal/

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp "$EXE_PATH" "$STAGE_DIR/aidengyu.exe"
cp "$WINDOWS_DIR/README.md" "$STAGE_DIR/README-Windows.md"
rm -f "$ZIP_PATH"
cd "$OUTPUT_DIR"
/usr/bin/zip -X -9 -q -r "${ZIP_PATH:t}" "${STAGE_DIR:t}"
echo "$ZIP_PATH"
