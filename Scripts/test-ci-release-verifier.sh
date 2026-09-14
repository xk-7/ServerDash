#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="${ROOT_DIR}/Scripts/verify-ci-release.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/serverdash-ci-release-verifier.XXXXXX")"

cleanup() {
    rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT HUP INT TERM

APP_PATH="${TEMP_ROOT}/ServerDash.app"
APP_BINARY="${APP_PATH}/Contents/MacOS/ServerDash"
XCFRAMEWORK_PATH="${TEMP_ROOT}/ServerDashRDP.xcframework"
LIBRARY_IDENTIFIER="macos-arm64_x86_64"
LIBRARY_DIR="${XCFRAMEWORK_PATH}/${LIBRARY_IDENTIFIER}"
ARCHIVE_PATH="${LIBRARY_DIR}/libServerDashRDP.a"

mkdir -p "$(dirname "${APP_BINARY}")" "${LIBRARY_DIR}"

cat > "${TEMP_ROOT}/app.c" <<'SOURCE'
int main(void) {
    return 0;
}
SOURCE

cat > "${TEMP_ROOT}/rdp.c" <<'SOURCE'
int serverdash_rdp_fixture(void) {
    return 0;
}
SOURCE

for architecture in arm64 x86_64; do
    /usr/bin/clang \
        -arch "${architecture}" \
        -mmacosx-version-min=14.0 \
        -Wl,-headerpad_max_install_names \
        "${TEMP_ROOT}/app.c" \
        -o "${TEMP_ROOT}/ServerDash-${architecture}"

    /usr/bin/clang \
        -arch "${architecture}" \
        -mmacosx-version-min=14.0 \
        -c "${TEMP_ROOT}/rdp.c" \
        -o "${TEMP_ROOT}/rdp-${architecture}.o"

    /usr/bin/libtool \
        -static \
        -o "${TEMP_ROOT}/libServerDashRDP-${architecture}.a" \
        "${TEMP_ROOT}/rdp-${architecture}.o"
done

/usr/bin/lipo \
    -create \
    "${TEMP_ROOT}/ServerDash-arm64" \
    "${TEMP_ROOT}/ServerDash-x86_64" \
    -output "${APP_BINARY}"

/usr/bin/lipo \
    -create \
    "${TEMP_ROOT}/libServerDashRDP-arm64.a" \
    "${TEMP_ROOT}/libServerDashRDP-x86_64.a" \
    -output "${ARCHIVE_PATH}"

cat > "${XCFRAMEWORK_PATH}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key>
            <string>${LIBRARY_IDENTIFIER}</string>
            <key>LibraryPath</key>
            <string>libServerDashRDP.a</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
                <string>x86_64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF

/usr/bin/plutil -lint "${XCFRAMEWORK_PATH}/Info.plist" >/dev/null

/bin/bash "${VERIFIER}" "${APP_PATH}" "${XCFRAMEWORK_PATH}"

/bin/cp "${TEMP_ROOT}/ServerDash-arm64" "${APP_BINARY}"
if /bin/bash "${VERIFIER}" "${APP_PATH}" "${XCFRAMEWORK_PATH}" \
    >"${TEMP_ROOT}/single-architecture.stdout" \
    2>"${TEMP_ROOT}/single-architecture.stderr"; then
    echo "Expected a single-architecture app executable to fail verification." >&2
    exit 1
fi

if ! /usr/bin/grep -q \
    'ServerDash executable must contain exactly arm64 and x86_64; found: arm64' \
    "${TEMP_ROOT}/single-architecture.stderr"; then
    echo "Single-architecture verification failed for an unexpected reason:" >&2
    /bin/cat "${TEMP_ROOT}/single-architecture.stderr" >&2
    exit 1
fi

/usr/bin/lipo \
    -create \
    "${TEMP_ROOT}/ServerDash-arm64" \
    "${TEMP_ROOT}/ServerDash-x86_64" \
    -output "${APP_BINARY}"

system_library="$(/usr/bin/otool -L "${APP_BINARY}" | /usr/bin/awk '$1 ~ /^\/usr\/lib\// { print $1; exit }')"
if [[ -z "${system_library}" ]]; then
    echo "Fixture executable did not link a /usr/lib system library." >&2
    exit 1
fi

/usr/bin/install_name_tool \
    -change "${system_library}" "/opt/libServerDashFixture.dylib" \
    "${APP_BINARY}"

if /bin/bash "${VERIFIER}" "${APP_PATH}" "${XCFRAMEWORK_PATH}" \
    >"${TEMP_ROOT}/non-system-library.stdout" \
    2>"${TEMP_ROOT}/non-system-library.stderr"; then
    echo "Expected a non-system absolute dylib path to fail verification." >&2
    exit 1
fi

if ! /usr/bin/grep -q \
    'ServerDash links against non-system absolute or unsupported loader paths:' \
    "${TEMP_ROOT}/non-system-library.stderr" || \
    ! /usr/bin/grep -q \
    '/opt/libServerDashFixture.dylib' \
    "${TEMP_ROOT}/non-system-library.stderr"; then
    echo "Non-system absolute dylib verification failed for an unexpected reason:" >&2
    /bin/cat "${TEMP_ROOT}/non-system-library.stderr" >&2
    exit 1
fi

/usr/bin/lipo \
    -create \
    "${TEMP_ROOT}/ServerDash-arm64" \
    "${TEMP_ROOT}/ServerDash-x86_64" \
    -output "${APP_BINARY}"

/usr/bin/install_name_tool \
    -change "${system_library}" "@rpath/libSystem.B.dylib" \
    "${APP_BINARY}"

/usr/bin/install_name_tool \
    -add_rpath "/opt/homebrew/lib" \
    "${APP_BINARY}"

if /bin/bash "${VERIFIER}" "${APP_PATH}" "${XCFRAMEWORK_PATH}" \
    >"${TEMP_ROOT}/absolute-rpath.stdout" \
    2>"${TEMP_ROOT}/absolute-rpath.stderr"; then
    echo "Expected an absolute LC_RPATH to fail verification." >&2
    exit 1
fi

if ! /usr/bin/grep -q \
    'ServerDash contains non-system absolute runtime search paths:' \
    "${TEMP_ROOT}/absolute-rpath.stderr" || \
    ! /usr/bin/grep -q \
    '/opt/homebrew/lib' \
    "${TEMP_ROOT}/absolute-rpath.stderr"; then
    echo "Absolute LC_RPATH verification failed for an unexpected reason:" >&2
    /bin/cat "${TEMP_ROOT}/absolute-rpath.stderr" >&2
    exit 1
fi

# A nested framework/helper must be subject to the same loader-path policy as
# the main executable. Keep this after the main-executable fixtures so a broken
# helper cannot mask which earlier assertion failed.
/usr/bin/lipo \
    -create \
    "${TEMP_ROOT}/ServerDash-arm64" \
    "${TEMP_ROOT}/ServerDash-x86_64" \
    -output "${APP_BINARY}"
HELPER_PATH="${APP_PATH}/Contents/Helpers/ServerDashFixtureHelper"
/bin/mkdir -p "$(/usr/bin/dirname "${HELPER_PATH}")"
/usr/bin/lipo \
    -create \
    "${TEMP_ROOT}/ServerDash-arm64" \
    "${TEMP_ROOT}/ServerDash-x86_64" \
    -output "${HELPER_PATH}"
/usr/bin/install_name_tool \
    -change "${system_library}" "/opt/libServerDashNestedFixture.dylib" \
    "${HELPER_PATH}"

if /bin/bash "${VERIFIER}" "${APP_PATH}" "${XCFRAMEWORK_PATH}" \
    >"${TEMP_ROOT}/nested-library.stdout" \
    2>"${TEMP_ROOT}/nested-library.stderr"; then
    echo "Expected a nested Mach-O with a non-system dylib path to fail verification." >&2
    exit 1
fi

if ! /usr/bin/grep -q \
    'Bundled Mach-O Contents/Helpers/ServerDashFixtureHelper links against non-system absolute or unsupported loader paths:' \
    "${TEMP_ROOT}/nested-library.stderr" || \
    ! /usr/bin/grep -q \
    '/opt/libServerDashNestedFixture.dylib' \
    "${TEMP_ROOT}/nested-library.stderr"; then
    echo "Nested Mach-O verification failed for an unexpected reason:" >&2
    /bin/cat "${TEMP_ROOT}/nested-library.stderr" >&2
    exit 1
fi

echo "CI release verifier fixture tests passed."
