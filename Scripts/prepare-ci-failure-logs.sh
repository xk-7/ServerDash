#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:-.build/ci-logs}"
DESTINATION_DIR="${2:-.build/ci-failure-logs}"
MAX_LINES="${SERVERDASH_CI_FAILURE_LOG_LINES:-300}"

case "${MAX_LINES}" in
    ''|*[!0-9]*|0)
        echo "SERVERDASH_CI_FAILURE_LOG_LINES must be a positive integer." >&2
        exit 2
        ;;
esac

mkdir -p "${DESTINATION_DIR}"
find "${DESTINATION_DIR}" -mindepth 1 -maxdepth 1 -type f -delete

copied=0
for source in "${SOURCE_DIR}"/*.log; do
    [[ -f "${source}" ]] || continue
    destination="${DESTINATION_DIR}/$(basename "${source}")"
    awk '!/^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=/' "${source}" \
        | tail -n "${MAX_LINES}" \
        | sed -E \
            -e 's#/(Users|private/(tmp|var/folders)|tmp)/[^[:space:]"'"'"']+#/<redacted-path>#g' \
            -e 's#(token|password|secret|credential)=([^[:space:]]+)#\1=<redacted>#Ig' \
            > "${destination}"
    copied=$((copied + 1))
done

if [[ "${copied}" -eq 0 ]]; then
    echo "No CI log files found in ${SOURCE_DIR}." >&2
fi
