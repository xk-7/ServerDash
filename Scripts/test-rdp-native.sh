#!/bin/bash
set -euo pipefail

RDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$RDP_ROOT/Scripts/ensure-rdp-dependencies.sh" --quiet

RDP_XCFRAMEWORK="$RDP_ROOT/.build/rdp/ServerDashRDP.xcframework"
RDP_HEADERS="$RDP_ROOT/.build/rdp/universal/Headers"
RDP_INFO="$RDP_XCFRAMEWORK/Info.plist"
RDP_IDENTIFIER="$(/usr/bin/plutil -extract AvailableLibraries.0.LibraryIdentifier raw -o - "$RDP_INFO")"
RDP_LIBRARY_PATH="$(/usr/bin/plutil -extract AvailableLibraries.0.LibraryPath raw -o - "$RDP_INFO")"
RDP_ARCHIVE="$RDP_XCFRAMEWORK/$RDP_IDENTIFIER/$RDP_LIBRARY_PATH"
RDP_NATIVE_BUILD="$RDP_ROOT/.build/rdp-native-test"
mkdir -p "$RDP_NATIVE_BUILD"
RDP_TEST_DIR="$(mktemp -d "$RDP_NATIVE_BUILD/run.XXXXXX")"

cleanup() {
    rm -rf "$RDP_TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$RDP_NATIVE_BUILD/clang-modules"
xcrun clang -g -O1 -fobjc-arc -fmodules -fmodules-cache-path="$RDP_NATIVE_BUILD/clang-modules" \
    -fsanitize=address,undefined -fno-omit-frame-pointer -mmacosx-version-min=14.0 \
    -I"$RDP_HEADERS/freerdp3" -I"$RDP_HEADERS/winpr3" -I"$RDP_HEADERS" \
    "$RDP_ROOT/Native/Tests/SDRDPDriveTests.m" "$RDP_ROOT/Native/SDRDPDirectory.m" \
    "$RDP_ARCHIVE" \
    -framework Foundation -framework AppKit -framework Security -framework Carbon \
    -framework SystemConfiguration -framework AudioToolbox -framework CoreAudio -framework AVFoundation \
    -lc++ -lz -liconv -o "$RDP_TEST_DIR/rdp-drive-tests"
"$RDP_TEST_DIR/rdp-drive-tests"
