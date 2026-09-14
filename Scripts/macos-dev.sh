#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DOCTOR="${ROOT_DIR}/Scripts/dev-doctor.sh"
RDP_ENSURE="${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh"
DERIVED_DATA="${SERVERDASH_DERIVED_DATA_PATH:-${ROOT_DIR}/.build/macos-dev/DerivedData}"

usage() {
    cat <<'EOF'
Usage: ./Scripts/macos-dev.sh COMMAND [arguments]

Commands:
  doctor [doctor options]       Check worktree, versions, project generation and RDP state.
  bootstrap [ensure options]    Materialize verified RDP links from the shared cache.
  open                          Verify/bootstrap and open the checked-in Xcode project.
  build [Debug|Release] [...]   Build the macOS app with the shared ServerDash scheme.
  test [...]                    Run the macOS ServerDash scheme tests.
  generate-check               Verify the checked-in project matches project.yml.

Extra build/test arguments are passed to xcodebuild. Direct xcodebuild -target builds
are unsupported because target builds bypass the shared scheme bootstrap action.
EOF
}

require_script() {
    script_path="$1"
    if [[ ! -f "${script_path}" ]]; then
        echo "Required script is missing: ${script_path}" >&2
        exit 1
    fi
}

run_doctor() {
    require_script "${DOCTOR}"
    bash "${DOCTOR}" "$@"
}

run_bootstrap() {
    require_script "${RDP_ENSURE}"
    bash "${RDP_ENSURE}" "$@"
    bash "${RDP_ENSURE}" --verify-only --quiet
}

if [[ $# -lt 1 ]]; then
    usage
    exit 2
fi

COMMAND="$1"
shift

case "${COMMAND}" in
    doctor)
        run_doctor "$@"
        ;;
    bootstrap)
        run_doctor --skip-generated-check
        run_bootstrap "$@"
        ;;
    open)
        if [[ $# -ne 0 ]]; then
            echo "open does not accept arguments" >&2
            exit 2
        fi
        run_doctor
        run_bootstrap --quiet
        open "${ROOT_DIR}/ServerDash.xcodeproj"
        ;;
    build)
        CONFIGURATION="${1:-Debug}"
        if [[ $# -gt 0 ]]; then
            shift
        fi
        case "${CONFIGURATION}" in
            Debug|Release) ;;
            *)
                echo "Build configuration must be Debug or Release; received ${CONFIGURATION}." >&2
                exit 2
                ;;
        esac
        run_doctor
        run_bootstrap --quiet
        xcodebuild \
            -project "${ROOT_DIR}/ServerDash.xcodeproj" \
            -scheme ServerDash \
            -configuration "${CONFIGURATION}" \
            -destination "platform=macOS" \
            -derivedDataPath "${DERIVED_DATA}" \
            -skipPackagePluginValidation \
            -onlyUsePackageVersionsFromResolvedFile \
            -disableAutomaticPackageResolution \
            "$@" \
            build
        ;;
    test)
        run_doctor
        run_bootstrap --quiet
        xcodebuild \
            -project "${ROOT_DIR}/ServerDash.xcodeproj" \
            -scheme ServerDash \
            -destination "platform=macOS" \
            -derivedDataPath "${DERIVED_DATA}" \
            -skipPackagePluginValidation \
            -onlyUsePackageVersionsFromResolvedFile \
            -disableAutomaticPackageResolution \
            "$@" \
            test
        ;;
    generate-check)
        if [[ $# -ne 0 ]]; then
            echo "generate-check does not accept arguments" >&2
            exit 2
        fi
        run_doctor
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown command: ${COMMAND}" >&2
        usage >&2
        exit 2
        ;;
esac
