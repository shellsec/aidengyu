#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/.native-tests"
TEST_BINARY="$BUILD_DIR/SignalCoreTests"

mkdir -p "$BUILD_DIR"

clang \
    -fobjc-arc \
    -fmodules \
    -O0 \
    -g \
    -mmacosx-version-min=13.0 \
    -I "$PROJECT_DIR/Native" \
    "$PROJECT_DIR/Native/SignalCore.m" \
    "$PROJECT_DIR/NativeTests/SignalCoreTests.m" \
    -framework Foundation \
    -o "$TEST_BINARY"

"$TEST_BINARY"
