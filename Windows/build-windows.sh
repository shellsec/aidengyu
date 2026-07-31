#!/bin/zsh

set -euo pipefail

WINDOWS_DIR="${0:A:h}"
PROJECT_DIR="${WINDOWS_DIR:h}"
OUTPUT_DIR="$PROJECT_DIR/dist-windows"
PACKAGE_DIR="$OUTPUT_DIR/Codex Claude Signal-win32-x64"
ZIP_PATH="$OUTPUT_DIR/CodexClaudeSignal-Windows-x64.zip"

cd "$WINDOWS_DIR"
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
npm install
npm test
npm run make-icon
npm run pack:win

cp "$WINDOWS_DIR/README.md" "$PACKAGE_DIR/README-Windows.md"
rm -f "$ZIP_PATH"
cd "$OUTPUT_DIR"
/usr/bin/zip -X -q -r "${ZIP_PATH:t}" "${PACKAGE_DIR:t}"
echo "$ZIP_PATH"
