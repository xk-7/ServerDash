#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${SERVERDASH_DERIVED_DATA:-${ROOT_DIR}/.build/concurrency-gate}"
LOG_FILE="${SERVERDASH_BUILD_LOG:-${DERIVED_DATA}/build.log}"

"${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh" --verify-only >/dev/null 2>&1 || \
    "${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh" --quiet

if [[ "${REUSE_BUILD:-0}" != "1" ]]; then
    rm -rf "${DERIVED_DATA}"
fi
mkdir -p "${DERIVED_DATA}"
mkdir -p "$(dirname "${LOG_FILE}")"

set +e
xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDash \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    SWIFT_STRICT_CONCURRENCY=complete \
    build-for-testing >"${LOG_FILE}" 2>&1
BUILD_STATUS=$?

if [[ ${BUILD_STATUS} -eq 0 ]]; then
    printf '\n=== ServerDashMacQA strict build-for-testing ===\n' >>"${LOG_FILE}"
    xcodebuild \
        -project "${ROOT_DIR}/ServerDash.xcodeproj" \
        -scheme ServerDashMacQA \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${DERIVED_DATA}" \
        -skipPackagePluginValidation \
        -onlyUsePackageVersionsFromResolvedFile \
        -disableAutomaticPackageResolution \
        CODE_SIGNING_ALLOWED=NO \
        COMPILER_INDEX_STORE_ENABLE=NO \
        SWIFT_STRICT_CONCURRENCY=complete \
        build-for-testing >>"${LOG_FILE}" 2>&1
    BUILD_STATUS=$?
fi
set -e

if [[ ${BUILD_STATUS} -ne 0 ]]; then
    echo "Strict-concurrency app or Mac QA build failed. Last 80 log lines:" >&2
    tail -80 "${LOG_FILE}" >&2
    exit ${BUILD_STATUS}
fi

FIRST_PARTY_WARNINGS="${DERIVED_DATA}/first-party-warnings.txt"
awk -v root="${ROOT_DIR}/" '
    index($0, root "Sources/") || index($0, root "Tests/") || index($0, root "MacUITests/") || index($0, root "Native/") {
        start = index($0, root)
        relative = substr($0, start + length(root))
        path = relative
        sub(/:[0-9]+(:[0-9]+)?: warning:.*/, "", path)
        if (path ~ /^(Sources|Tests|MacUITests|Native)\/.*\.(swift|m|mm|c|cc|cpp|h)$/ && $0 ~ /: warning:/) {
            print $0
        }
    }
    /^@__swiftmacro_.*ServerDash.*: warning:/ {
        print $0
    }
    /(^|[[:space:]"])(Sources|Tests|MacUITests|Native)\/[^:]+\.(swift|m|mm|c|cc|cpp|h):[0-9]+(:[0-9]+)?: warning:/ {
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
    }
    END {
        printf "Third-party warning instances in the Xcode log (informational): SwiftTerm=%d, ZIPFoundation=%d, NIOSSH=%d, Citadel=%d; FreeRDP/WinPR are recorded from the RDP bootstrap log.\n", swiftterm + 0, zipfoundation + 0, niossh + 0, citadel + 0
    }
' "${LOG_FILE}"
echo "Full log: ${LOG_FILE}"
