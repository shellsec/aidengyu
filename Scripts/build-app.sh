#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/aidengyu.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR"

COMMON_FLAGS=(
    -fobjc-arc
    -fmodules
    -Os
    -mmacosx-version-min=13.0
    -arch arm64
    -arch x86_64
    -I "$PROJECT_DIR/Native"
)

clang "${COMMON_FLAGS[@]}" \
    "$PROJECT_DIR/Native/SignalCore.m" \
    "$PROJECT_DIR/Native/AgentSignalApp.m" \
    -framework Cocoa \
    -framework QuartzCore \
    -framework UserNotifications \
    -o "$MACOS_DIR/AgentSignalApp"
strip -x "$MACOS_DIR/AgentSignalApp"

clang "${COMMON_FLAGS[@]}" \
    "$PROJECT_DIR/Native/SignalCore.m" \
    "$PROJECT_DIR/Native/AgentSignalHook.m" \
    -framework Foundation \
    -o "$HELPERS_DIR/AgentSignalHook"
strip -x "$HELPERS_DIR/AgentSignalHook"

cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Assets/openai.svg" "$PROJECT_DIR/Assets/claude.svg" \
    "$PROJECT_DIR/Assets/cursor.svg" "$RESOURCES_DIR/"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"

# 拖拽安装 DMG（左侧 .app，右侧 Applications）。仅 macOS；失败时不阻断 .app 产物。
if [[ "$(uname -s)" == "Darwin" ]]; then
    if ! "$PROJECT_DIR/Scripts/create-dmg.sh" "$APP_DIR"; then
        echo "warning: DMG 生成失败，.app 仍可用：$APP_DIR" >&2
    fi
fi
