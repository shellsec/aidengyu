#!/usr/bin/env bash
# create-dmg.sh — 用系统自带的 hdiutil 生成「拖到应用程序」安装 DMG。
#
# 只能在 macOS 上运行（依赖 hdiutil、可选的 Finder/osascript）。
# 在 Windows / Linux 上执行会直接报错退出；请勿在非 Mac 环境假装已打出 DMG。
#
# 布局：左侧 .app，右侧 /Applications 符号链接，打开后拖拽即可安装。
# 不依赖 create-dmg 等第三方或付费工具；无自定义背景图时使用 Finder 标准图标视图。
#
# 用法：
#   Scripts/create-dmg.sh
#   Scripts/create-dmg.sh dist/aidengyu.app
#   Scripts/create-dmg.sh dist/aidengyu.app dist/aidengyu-macOS-universal.dmg

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: create-dmg.sh 只能在 macOS 上运行（需要 hdiutil）。" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${1:-$PROJECT_DIR/dist/aidengyu.app}"
APP_NAME="$(basename "$APP_PATH")"
APP_BASENAME="${APP_NAME%.app}"
DMG_PATH="${2:-$PROJECT_DIR/dist/${APP_BASENAME}-macOS-universal.dmg}"
# 卷标用 ASCII，避免无头 CI / AppleScript 对中文卷名不稳定。
VOLNAME="$APP_BASENAME"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: 找不到应用包：$APP_PATH（请先运行 Scripts/build-app.sh）" >&2
  exit 1
fi
if [[ "$APP_NAME" != *.app ]]; then
  echo "error: 期望 .app 包，收到：$APP_PATH" >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aidengyu-dmg-stage.XXXXXX")"
RW_DMG=""
MOUNT_DIR=""
DEVICE=""

cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
  elif [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet -force 2>/dev/null || true
  fi
  [[ -n "$RW_DMG" && -f "$RW_DMG" ]] && rm -f "$RW_DMG"
  rm -rf "$STAGE"
}
trap cleanup EXIT

echo "==> 暂存 DMG 内容（$APP_NAME + Applications）"
ditto "$APP_PATH" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

RW_DMG="$(mktemp "${TMPDIR:-/tmp}/aidengyu-dmg-rw.XXXXXX").dmg"
rm -f "$RW_DMG"

echo "==> 创建可写镜像：$VOLNAME"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -fs HFS+ \
  -format UDRW \
  "$RW_DMG" >/dev/null

ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(echo "$ATTACH_OUT" | awk 'NR==1 {print $1}')"
MOUNT_DIR="$(echo "$ATTACH_OUT" | awk '/\/Volumes\// {print $NF; exit}')"

if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "error: 挂载可写 DMG 失败" >&2
  echo "$ATTACH_OUT" >&2
  exit 1
fi

echo "==> 设置拖拽安装窗口布局"
# Finder 在无图形会话的 CI 上可能失败；失败时仍保留 .app + Applications 链接，可拖拽安装。
if ! osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 760, 460}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set position of item "$APP_NAME" of container window to {150, 180}
    set position of item "Applications" of container window to {410, 180}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "warning: Finder 布局脚本失败，继续打包（仍含 Applications 链接）。" >&2
fi

sync
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNT_DIR=""
DEVICE=""

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

echo "==> 压缩为 UDZO：$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
