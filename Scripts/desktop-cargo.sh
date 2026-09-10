#!/bin/sh
set -eu
DESKTOP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -x "$DESKTOP_ROOT/.build/windows-toolchain/cargo/bin/cargo" ]; then
    export CARGO_HOME="$DESKTOP_ROOT/.build/windows-toolchain/cargo"
    export RUSTUP_HOME="$DESKTOP_ROOT/.build/windows-toolchain/rustup"
    export PATH="$CARGO_HOME/bin:$PATH"
fi
export CARGO_TARGET_DIR="$DESKTOP_ROOT/.build/desktop-target"
cd "$DESKTOP_ROOT/Desktop"
exec cargo "$@"
