#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-1.0.4}"
BUILD_ROOT="${ROOT_DIR}/.build/release-${VERSION}"
DIST_DIR="${ROOT_DIR}/dist/v${VERSION}"
MAC_DERIVED_DATA="${BUILD_ROOT}/macOS"
IPHONE_DERIVED_DATA="${BUILD_ROOT}/mobile-iPhone"
IPAD_DERIVED_DATA="${BUILD_ROOT}/mobile-iPad"
DEVICE_DERIVED_DATA="${BUILD_ROOT}/mobile-device"
PACKAGE_CACHE="${BUILD_ROOT}/SourcePackages"
MAC_APP="${MAC_DERIVED_DATA}/Build/Products/Release/ServerDash.app"
IPHONE_APP="${IPHONE_DERIVED_DATA}/Build/Products/Release-iphonesimulator/ServerDashMobile.app"
IPAD_APP="${IPAD_DERIVED_DATA}/Build/Products/Release-iphonesimulator/ServerDashMobile.app"
MAC_DMG="${DIST_DIR}/ServerDash-${VERSION}-macOS.dmg"
IPHONE_ZIP="${DIST_DIR}/ServerDash-${VERSION}-iPhone-Simulator.zip"
IPAD_ZIP="${DIST_DIR}/ServerDash-${VERSION}-iPad-Simulator.zip"
CHECKSUMS="${DIST_DIR}/ServerDash-${VERSION}-SHA256SUMS.txt"
RELEASE_NOTICE="${DIST_DIR}/ServerDash-${VERSION}-Release-Notice.md"
SOURCE_RELEASE_NOTICE="${ROOT_DIR}/Docs/RELEASE_NOTES_${VERSION}.md"
DOCTOR_SCRIPT="${ROOT_DIR}/Scripts/dev-doctor.sh"
RDP_ENSURE_SCRIPT="${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh"
RELEASE_VERIFIER="${ROOT_DIR}/Scripts/verify-ci-release.sh"
EXPECTED_BUILD="$(awk '$1 == "CURRENT_PROJECT_VERSION:" { value = $2; gsub(/\042/, "", value); print value; exit }' "${ROOT_DIR}/project.yml")"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use numeric MAJOR.MINOR.PATCH form; received ${VERSION}." >&2
    exit 2
fi

for tool in xcodegen xcodebuild codesign hdiutil ditto shasum lipo otool; do
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
bash "${DOCTOR_SCRIPT}" --release "${VERSION}"

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

if [[ "${SERVERDASH_RELEASE_USE_SHARED_RDP_CACHE:-0}" == "1" ]]; then
    echo "WARNING: using the shared RDP cache for a diagnostic release build." >&2
    bash "${RDP_ENSURE_SCRIPT}" ensure
else
    RELEASE_RDP_CACHE="${BUILD_ROOT}/rdp-cache"
    mkdir -p "${RELEASE_RDP_CACHE}"
    export SERVERDASH_RDP_CACHE_DIR="${RELEASE_RDP_CACHE}"
    bash "${RDP_ENSURE_SCRIPT}" ensure --force-source-build
fi
bash "${RDP_ENSURE_SCRIPT}" --verify-only --quiet

echo "Resolving the versions pinned by Package.resolved..."
xcodebuild \
    -resolvePackageDependencies \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -clonedSourcePackagesDirPath "${PACKAGE_CACHE}" \
    -onlyUsePackageVersionsFromResolvedFile

xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDash \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${MAC_DERIVED_DATA}" \
    -clonedSourcePackagesDirPath "${PACKAGE_CACHE}" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

if [[ ! -d "${MAC_APP}" ]]; then
    echo "macOS app missing at ${MAC_APP}" >&2
    exit 1
fi

MAC_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${MAC_APP}/Contents/Info.plist")"
MAC_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${MAC_APP}/Contents/Info.plist")"
if [[ "${MAC_VERSION}" != "${VERSION}" || "${MAC_BUILD}" != "${EXPECTED_BUILD}" ]]; then
    echo "macOS app metadata mismatch: expected ${VERSION} (build ${EXPECTED_BUILD}), found ${MAC_VERSION} (build ${MAC_BUILD})" >&2
    exit 1
fi

codesign --force --deep --sign - "${MAC_APP}"
codesign --verify --deep --strict --verbose=2 "${MAC_APP}"
bash "${RELEASE_VERIFIER}" "${MAC_APP}"

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
    -clonedSourcePackagesDirPath "${PACKAGE_CACHE}" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDashMobile \
    -configuration Release \
    -destination "platform=iOS Simulator,name=iPad Air 11-inch (M3)" \
    -derivedDataPath "${IPAD_DERIVED_DATA}" \
    -clonedSourcePackagesDirPath "${PACKAGE_CACHE}" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDashMobile \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "${DEVICE_DERIVED_DATA}" \
    -clonedSourcePackagesDirPath "${PACKAGE_CACHE}" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    build

for app in "${IPHONE_APP}" "${IPAD_APP}"; do
    if [[ ! -d "${app}" ]]; then
        echo "Simulator app missing at ${app}" >&2
        exit 1
    fi
done

for app in "${IPHONE_APP}" "${IPAD_APP}"; do
    mobile_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${app}/Info.plist")"
    mobile_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${app}/Info.plist")"
    if [[ "${mobile_version}" != "${VERSION}" || "${mobile_build}" != "${EXPECTED_BUILD}" ]]; then
        echo "Simulator app metadata mismatch: expected ${VERSION} (build ${EXPECTED_BUILD}), found ${mobile_version} (build ${mobile_build}) at ${app}" >&2
        exit 1
    fi
    app_architectures="$(lipo -archs "${app}/ServerDashMobile" | tr ' ' '\n' | LC_ALL=C sort | paste -sd, -)"
    if [[ "${app_architectures}" != "arm64,x86_64" ]]; then
        echo "Simulator app must contain exactly arm64 and x86_64; found ${app_architectures} at ${app}" >&2
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

(
    cd "${DIST_DIR}"
    shasum -a 256 \
        "$(basename "${MAC_DMG}")" \
        "$(basename "${IPHONE_ZIP}")" \
        "$(basename "${IPAD_ZIP}")" \
        "$(basename "${RELEASE_NOTICE}")"
) > "${CHECKSUMS}"
(
    cd "${DIST_DIR}"
    shasum -a 256 -c "$(basename "${CHECKSUMS}")"
)

echo "Release artifacts created in ${DIST_DIR}:"
ls -lh "${DIST_DIR}"
echo "macOS architectures: $(lipo -archs "${MAC_APP}/Contents/MacOS/ServerDash")"
echo "iPhone simulator architectures: $(lipo -archs "${IPHONE_APP}/ServerDashMobile")"
echo "iPad simulator architectures: $(lipo -archs "${IPAD_APP}/ServerDashMobile")"
