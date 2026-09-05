#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-1.0.0}"
BUILD_ROOT="${ROOT_DIR}/.build/release-${VERSION}"
DIST_DIR="${ROOT_DIR}/dist/v${VERSION}"
MAC_DERIVED_DATA="${BUILD_ROOT}/macOS"
IPHONE_DERIVED_DATA="${BUILD_ROOT}/iPhone"
IPAD_DERIVED_DATA="${BUILD_ROOT}/iPad"
DEVICE_DERIVED_DATA="${BUILD_ROOT}/iOS-device-verify"
MAC_APP="${MAC_DERIVED_DATA}/Build/Products/Release/ServerDash.app"
IPHONE_APP="${IPHONE_DERIVED_DATA}/Build/Products/Release-iphonesimulator/ServerDashMobile.app"
IPAD_APP="${IPAD_DERIVED_DATA}/Build/Products/Release-iphonesimulator/ServerDashMobile.app"
MAC_DMG="${DIST_DIR}/ServerDash-${VERSION}-macOS.dmg"
IPHONE_ZIP="${DIST_DIR}/ServerDash-${VERSION}-iPhone-Simulator.zip"
IPAD_ZIP="${DIST_DIR}/ServerDash-${VERSION}-iPad-Simulator.zip"
CHECKSUMS="${DIST_DIR}/ServerDash-${VERSION}-SHA256SUMS.txt"
RELEASE_NOTICE="${DIST_DIR}/ServerDash-${VERSION}-Release-Notice.md"
SOURCE_RELEASE_NOTICE="${ROOT_DIR}/Docs/RELEASE_NOTES_${VERSION}.md"

for tool in xcodegen xcodebuild codesign hdiutil ditto shasum; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Missing required tool: ${tool}" >&2
        exit 1
    fi
done

if [[ ! -f "${SOURCE_RELEASE_NOTICE}" ]]; then
    echo "Release notice missing at ${SOURCE_RELEASE_NOTICE}" >&2
    exit 1
fi

cd "${ROOT_DIR}"
xcodegen generate

if [[ "${REUSE_BUILD:-0}" == "1" ]]; then
    rm -rf \
        "${DIST_DIR}" \
        "${BUILD_ROOT}/macOS-staging" \
        "${BUILD_ROOT}/ServerDash-iPhone-Simulator" \
        "${BUILD_ROOT}/ServerDash-iPad-Simulator"
else
    rm -rf "${BUILD_ROOT}" "${DIST_DIR}"
fi
mkdir -p "${BUILD_ROOT}" "${DIST_DIR}"

xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDash \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${MAC_DERIVED_DATA}" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

if [[ ! -d "${MAC_APP}" ]]; then
    echo "macOS app missing at ${MAC_APP}" >&2
    exit 1
fi

codesign --force --deep --sign - "${MAC_APP}"
codesign --verify --deep --strict --verbose=2 "${MAC_APP}"

MAC_STAGING="${BUILD_ROOT}/macOS-staging"
mkdir -p "${MAC_STAGING}"
cp -R "${MAC_APP}" "${MAC_STAGING}/ServerDash.app"
ln -s /Applications "${MAC_STAGING}/Applications"
hdiutil create -volname "ServerDash ${VERSION}" -srcfolder "${MAC_STAGING}" -format UDZO -ov "${MAC_DMG}"
hdiutil verify "${MAC_DMG}"

xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDashMobile \
    -configuration Release \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
    -derivedDataPath "${IPHONE_DERIVED_DATA}" \
    -skipPackagePluginValidation \
    build

xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDashMobile \
    -configuration Release \
    -destination "platform=iOS Simulator,name=iPad Air 11-inch (M3)" \
    -derivedDataPath "${IPAD_DERIVED_DATA}" \
    -skipPackagePluginValidation \
    build

xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDashMobile \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "${DEVICE_DERIVED_DATA}" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    build

for app in "${IPHONE_APP}" "${IPAD_APP}"; do
    if [[ ! -d "${app}" ]]; then
        echo "Simulator app missing at ${app}" >&2
        exit 1
    fi
done

IPHONE_STAGING="${BUILD_ROOT}/ServerDash-iPhone-Simulator"
IPAD_STAGING="${BUILD_ROOT}/ServerDash-iPad-Simulator"
mkdir -p "${IPHONE_STAGING}" "${IPAD_STAGING}"
cp -R "${IPHONE_APP}" "${IPHONE_STAGING}/ServerDashMobile.app"
cp -R "${IPAD_APP}" "${IPAD_STAGING}/ServerDashMobile.app"
cp "${ROOT_DIR}/Docs/SIMULATOR_INSTALL.md" "${IPHONE_STAGING}/安装说明.md"
cp "${ROOT_DIR}/Docs/SIMULATOR_INSTALL.md" "${IPAD_STAGING}/安装说明.md"
ditto -c -k --sequesterRsrc --keepParent "${IPHONE_STAGING}" "${IPHONE_ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${IPAD_STAGING}" "${IPAD_ZIP}"
cp "${SOURCE_RELEASE_NOTICE}" "${RELEASE_NOTICE}"

shasum -a 256 "${MAC_DMG}" "${IPHONE_ZIP}" "${IPAD_ZIP}" "${RELEASE_NOTICE}" \
    | sed "s#${DIST_DIR}/##" > "${CHECKSUMS}"

echo "Release artifacts created in ${DIST_DIR}:"
ls -lh "${DIST_DIR}"
echo "macOS architectures: $(lipo -archs "${MAC_APP}/Contents/MacOS/ServerDash")"
echo "iPhone simulator architectures: $(lipo -archs "${IPHONE_APP}/ServerDashMobile")"
echo "iPad simulator architectures: $(lipo -archs "${IPAD_APP}/ServerDashMobile")"
