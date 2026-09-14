#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-}"
XCFRAMEWORK_PATH="${2:-${ROOT_DIR}/.build/rdp/ServerDashRDP.xcframework}"

if [[ -z "${APP_PATH}" ]]; then
    echo "Usage: $0 <ServerDash.app> [ServerDashRDP.xcframework]" >&2
    exit 64
fi

APP_BINARY="${APP_PATH}/Contents/MacOS/ServerDash"
XCFRAMEWORK_INFO="${XCFRAMEWORK_PATH}/Info.plist"

for required in "${APP_BINARY}" "${XCFRAMEWORK_INFO}"; do
    if [[ ! -f "${required}" ]]; then
        echo "Required release artifact is missing: ${required}" >&2
        exit 1
    fi
done

normalized_architectures() {
    lipo -archs "$1" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

require_universal_binary() {
    local binary="$1"
    local label="$2"
    local architectures
    architectures="$(normalized_architectures "${binary}")"
    if [[ "${architectures}" != "arm64 x86_64" ]]; then
        echo "${label} must contain exactly arm64 and x86_64; found: ${architectures}" >&2
        exit 1
    fi
}

require_universal_binary "${APP_BINARY}" "ServerDash executable"

library_count="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "${XCFRAMEWORK_INFO}" | grep -c 'Dict {' | tr -d ' ')"
if [[ "${library_count}" != "1" ]]; then
    echo "RDP XCFramework must contain exactly one macOS library; found: ${library_count}" >&2
    exit 1
fi

library_identifier="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries:0:LibraryIdentifier' "${XCFRAMEWORK_INFO}")"
library_binary="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries:0:LibraryPath' "${XCFRAMEWORK_INFO}")"
rdp_archive="${XCFRAMEWORK_PATH}/${library_identifier}/${library_binary}"
if [[ ! -f "${rdp_archive}" ]]; then
    echo "RDP archive declared by the XCFramework is missing: ${rdp_archive}" >&2
    exit 1
fi
require_universal_binary "${rdp_archive}" "ServerDash RDP archive"

verify_loader_paths() {
    local binary="$1"
    local label="$2"
    local linked_paths
    local forbidden_linked_paths=""
    local linked_path
    local rpaths
    local absolute_rpaths=""
    local rpath

    linked_paths="$(otool -L "${binary}" | awk '/^[[:space:]]+/ {print $1}')"
    while IFS= read -r linked_path; do
        [[ -z "${linked_path}" ]] && continue
        case "${linked_path}" in
            /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*)
                ;;
            *)
                forbidden_linked_paths="${forbidden_linked_paths}${forbidden_linked_paths:+
}${linked_path}"
                ;;
        esac
    done <<EOF
${linked_paths}
EOF

    if [[ -n "${forbidden_linked_paths}" ]]; then
        echo "${label} links against non-system absolute or unsupported loader paths:" >&2
        printf '%s\n' "${forbidden_linked_paths}" >&2
        exit 1
    fi

    rpaths="$(otool -l "${binary}" | awk '$1 == "cmd" && $2 == "LC_RPATH" { in_rpath=1; next } in_rpath && $1 == "path" { print $2; in_rpath=0 }')"
    while IFS= read -r rpath; do
        [[ -z "${rpath}" ]] && continue
        case "${rpath}" in
            /System/Library/*|/usr/lib|/usr/lib/*)
                ;;
            /*)
                absolute_rpaths="${absolute_rpaths}${absolute_rpaths:+
}${rpath}"
                ;;
        esac
    done <<EOF
${rpaths}
EOF

    if [[ -n "${absolute_rpaths}" ]]; then
        echo "${label} contains non-system absolute runtime search paths:" >&2
        printf '%s\n' "${absolute_rpaths}" >&2
        exit 1
    fi
}

verify_loader_paths "${APP_BINARY}" "ServerDash"

# Apply the same checks to future frameworks, helpers, plug-ins and extensions.
while IFS= read -r -d '' candidate; do
    [[ "${candidate}" == "${APP_BINARY}" ]] && continue
    file_description="$(file -b "${candidate}" 2>/dev/null || true)"
    case "${file_description}" in
        *Mach-O*) ;;
        *) continue ;;
    esac
    relative_path="${candidate#${APP_PATH}/}"
    require_universal_binary "${candidate}" "Bundled Mach-O ${relative_path}"
    verify_loader_paths "${candidate}" "Bundled Mach-O ${relative_path}"
done < <(find "${APP_PATH}" -type f -print0)

echo "Release artifacts are universal and contain only approved linked paths and LC_RPATH values."
