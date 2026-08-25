#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${ROOT_DIR}/.build/test-dmg"
DERIVED_DATA="${BUILD_ROOT}/DerivedData"
STAGING_DIR="${BUILD_ROOT}/staging"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="ServerDash"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"

for tool in xcodegen xcodebuild codesign hdiutil; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Missing required tool: ${tool}" >&2
        exit 1
    fi
done

echo "Generating Xcode project..."
cd "${ROOT_DIR}"
xcodegen generate

echo "Building unsigned universal Release app..."
rm -rf "${BUILD_ROOT}"
mkdir -p "${DERIVED_DATA}" "${STAGING_DIR}" "${DIST_DIR}"

xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDash \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Release app was not produced at ${APP_PATH}" >&2
    exit 1
fi

echo "Applying ad-hoc signature..."
codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
DMG_FILENAME="${APP_NAME}-${VERSION}-test.dmg"
DMG_PATH="${DIST_DIR}/${DMG_FILENAME}"
CHECKSUM_PATH="${DMG_PATH}.sha256"

echo "Preparing DMG contents..."
cp -R "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "Creating ${DMG_PATH}..."
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

hdiutil verify "${DMG_PATH}"

CHECKSUM="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
printf '%s  %s\n' "${CHECKSUM}" "${DMG_FILENAME}" > "${CHECKSUM_PATH}"

echo
echo "Created test DMG:"
echo "  ${DMG_PATH}"
echo "  ${CHECKSUM_PATH}"
echo "SHA-256: ${CHECKSUM}"
echo
echo "Architectures:"
lipo -archs "${STAGING_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
