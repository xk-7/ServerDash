#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${1:-${ROOT_DIR}/.build/mac-ui-qa}"

# The fixture path is compiled into ServerDashMacQA. Re-signing or renaming the
# production app cannot enable it, which keeps production Debug builds safe too.
xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDashMacQA \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    build

QA_APP="${DERIVED_DATA}/Build/Products/Debug/ServerDashMacQA.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${QA_APP}/Contents/Info.plist")"
if [[ "${BUNDLE_ID}" != "com.serverdash.app.macqa" ]]; then
    echo "Unexpected Mac QA bundle identifier: ${BUNDLE_ID}" >&2
    exit 1
fi
printf '%s\n' "${QA_APP}"
