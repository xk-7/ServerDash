#!/bin/bash
set -euo pipefail
RDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RDP_PREFIX="$RDP_ROOT/.build/rdp/install-$(uname -m)"
RDP_TEST_DIR="$(mktemp -d "$RDP_ROOT/.build/rdp/native-test.XXXXXX")"
xcrun clang -g -O1 -fobjc-arc -fmodules -fmodules-cache-path="$RDP_ROOT/.build/rdp/clang-modules" \
    -fsanitize=address,undefined -fno-omit-frame-pointer -mmacosx-version-min=14.0 \
    -I"$RDP_PREFIX/include/freerdp3" -I"$RDP_PREFIX/include/winpr3" -I"$RDP_PREFIX/include" \
    "$RDP_ROOT/Native/Tests/SDRDPDriveTests.m" "$RDP_ROOT/Native/SDRDPDirectory.m" \
    "$RDP_ROOT/.build/rdp/libServerDashRDP-$(uname -m).a" \
    -framework Foundation -framework AppKit -framework Security -framework Carbon \
    -framework SystemConfiguration -framework AudioToolbox -framework CoreAudio -framework AVFoundation \
    -lc++ -lz -liconv -o "$RDP_TEST_DIR/rdp-drive-tests"
"$RDP_TEST_DIR/rdp-drive-tests"
