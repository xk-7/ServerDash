#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${ROOT_DIR}/.build/concurrency-gate"
LOG_FILE="${DERIVED_DATA}/build.log"

if [[ "${REUSE_BUILD:-0}" != "1" ]]; then
    rm -rf "${DERIVED_DATA}"
fi
mkdir -p "${DERIVED_DATA}"

set +e
xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDash \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_STRICT_CONCURRENCY=complete \
    build-for-testing >"${LOG_FILE}" 2>&1
BUILD_STATUS=$?
set -e

if [[ ${BUILD_STATUS} -ne 0 ]]; then
    echo "Strict-concurrency build failed. Last 80 log lines:" >&2
    tail -80 "${LOG_FILE}" >&2
    exit ${BUILD_STATUS}
fi

FIRST_PARTY_WARNINGS="${DERIVED_DATA}/first-party-warnings.txt"
awk -v root="${ROOT_DIR}/" '
    index($0, root "Sources/") || index($0, root "Tests/") {
        start = index($0, root)
        relative = substr($0, start + length(root))
        path = relative
        sub(/:[0-9]+(:[0-9]+)?: warning:.*/, "", path)
        if (path ~ /^(Sources|Tests)\/.*\.swift$/ && $0 ~ /: warning:/) {
            print $0
        }
    }
    /^@__swiftmacro_.*ServerDash.*: warning:/ {
        print $0
    }
' "${LOG_FILE}" | sort -u >"${FIRST_PARTY_WARNINGS}"

if [[ -s "${FIRST_PARTY_WARNINGS}" ]]; then
    echo "First-party compiler warnings found:" >&2
    cat "${FIRST_PARTY_WARNINGS}" >&2
    exit 1
fi

echo "Strict concurrency gate passed with zero first-party warnings."
awk '
    /: warning:/ {
        if ($0 ~ /\/Vendor\/SwiftTerm\//) swiftterm++
        else if ($0 ~ /\/Vendor\/ZIPFoundation\//) zipfoundation++
        else if ($0 ~ /\/(SourcePackages\/.*|Vendor\/)swift-nio-ssh\//) niossh++
        else if ($0 ~ /\/SourcePackages\/.*Citadel\// || $0 ~ /\/Vendor\/Citadel\//) citadel++
        else if ($0 ~ /\/\.build\/rdp\//) rdp++
    }
    END {
        printf "Third-party warning instances (informational): SwiftTerm=%d, ZIPFoundation=%d, NIOSSH=%d, Citadel=%d, FreeRDP/WinPR=%d\n", swiftterm + 0, zipfoundation + 0, niossh + 0, citadel + 0, rdp + 0
    }
' "${LOG_FILE}"
echo "Full log: ${LOG_FILE}"
