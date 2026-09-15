#!/bin/bash
set -euo pipefail
# Copy the dedicated ServerDashMacQA Debug application into a disposable location.
# A renamed ServerDash build is not isolated because its QA boundaries are compiled out.
source_app="${1:?Usage: bash Scripts/prepare-mac-ui-fixture.sh '/path/to/ServerDash Mac QA.app'}"
if [[ ! -d "$source_app" || ! -f "$source_app/Contents/Info.plist" ]]; then
  printf 'Not an application bundle: %s\n' "$source_app" >&2
  exit 64
fi
source_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
if [[ "$source_bundle_id" != "com.serverdash.app.macqa" ]]; then
  printf 'Expected the dedicated ServerDashMacQA app (com.serverdash.app.macqa), got: %s\n' "$source_bundle_id" >&2
  exit 64
fi
target_dir="$(mktemp -d /tmp/serverdash-mac-ui.XXXXXX)"
target_app="$target_dir/ServerDash Mac QA.app"
ditto "$source_app" "$target_app"
codesign --force --deep --sign - "$target_app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")" = "com.serverdash.app.macqa"
printf '%s\n' "$target_app"
