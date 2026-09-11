#!/bin/bash
set -euo pipefail
# Copy a Debug build, keeping the real app and its defaults domain untouched.
source_app="${1:?Usage: bash Scripts/prepare-mac-ui-fixture.sh /path/to/Debug/ServerDash.app}"
target_dir="$(mktemp -d /tmp/serverdash-mac-ui.XXXXXX)"
target_app="$target_dir/ServerDash Mac QA.app"
ditto "$source_app" "$target_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.serverdash.app.macqa' "$target_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName ServerDash Mac QA' "$target_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName ServerDash Mac QA' "$target_app/Contents/Info.plist"
codesign --force --deep --sign - "$target_app"
printf '%s\n' "$target_app"
