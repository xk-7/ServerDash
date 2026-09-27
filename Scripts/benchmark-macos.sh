#!/bin/bash
# Optimized, isolated microbenchmarks. These numbers are not event-to-frame latency.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DERIVED_DATA="${SERVERDASH_DERIVED_DATA:-${ROOT_DIR}/.build/performance-tests}"
OUTPUT_ROOT="${SERVERDASH_BENCHMARK_OUTPUT:-${ROOT_DIR}/.build/performance-results}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="${OUTPUT_ROOT}/${RUN_ID}"
RESULT_BUNDLE="${RUN_DIR}/tests.xcresult"
STARTED_AT="$(python3 -c 'import time; print(time.time_ns())')"

usage() {
    cat <<'EOF'
Usage: Scripts/benchmark-macos.sh [--only-testing Class[/method]]...

Builds and runs isolated benchmarks using ServerDash, Release, and ENABLE_TESTABILITY=YES.
The default selection covers dashboard, SFTP, editor/terminal, startup, and monitoring history.

Environment:
  SERVERDASH_DERIVED_DATA       Reusable build products; never removed by this script.
  SERVERDASH_BENCHMARK_OUTPUT   Parent directory for unique, timestamped run artifacts.

Results include build/test logs, xcresult, test summary, toolchain metadata, raw
/usr/bin/time resource totals, and only benchmark JSON modified during this run.
Each benchmark reports its own scope and samples. UI layout, PTY rendering, CUA/AX
and end-to-end frame timing must be measured separately in the isolated QA app.
EOF
}

SELECTORS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only-testing)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo '--only-testing requires Class[/method].' >&2; exit 2
            fi
            SELECTORS+=("-only-testing:ServerDashTests/$2")
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [[ ${#SELECTORS[@]} -eq 0 ]]; then
    SELECTORS=(
        '-only-testing:ServerDashTests/DashboardFilterCatalogTests'
        '-only-testing:ServerDashTests/MacSFTPPerformanceTests'
        '-only-testing:ServerDashTests/MacSearchPerformanceTests'
        '-only-testing:ServerDashTests/MacStartupPerformanceTests'
        '-only-testing:ServerDashTests/MacHistoryPerformanceTests'
    )
fi

mkdir -p "${OUTPUT_ROOT}" "${DERIVED_DATA}"
# A unique directory makes reruns non-destructive, including failed builds.
mkdir "${RUN_DIR}"
collect_results() {
    status=$?
    trap - EXIT
    if [[ -d "${RESULT_BUNDLE}" ]]; then
        xcrun xcresulttool get test-results summary --path "${RESULT_BUNDLE}" \
            >"${RUN_DIR}/test-summary.json" 2>"${RUN_DIR}/summary-error.log" || true
    fi
    python3 - "${STARTED_AT}" "${RUN_DIR}" <<'PY'
import json, os, pathlib, shutil, sys, tempfile
started, destination = int(sys.argv[1]), pathlib.Path(sys.argv[2])
roots = {pathlib.Path('/tmp').resolve(), pathlib.Path(tempfile.gettempdir()).resolve()}
copied = []
for root in sorted(roots):
    for candidate in sorted(root.glob('serverdash-*-benchmark.json')):
        if candidate.is_file() and candidate.stat().st_mtime_ns >= started:
            target = destination / candidate.name
            # The same filename from distinct temp roots is retained separately.
            if target.exists():
                target = destination / (str(len(copied)) + '-' + candidate.name)
            shutil.copy2(candidate, target)
            copied.append(target.name)
(destination / 'benchmark-files.json').write_text(json.dumps(copied, indent=2) + '\n')
PY
    printf '%s\n' "${status}" >"${RUN_DIR}/exit-status.txt"
    printf 'Benchmark run artifacts: %s\n' "${RUN_DIR}"
    exit "${status}"
}
trap collect_results EXIT

# Include new files as well as tracked edits; a dirty worktree still has an exact source identity.
python3 - "${ROOT_DIR}" "${RUN_DIR}/source-manifest.json" <<'MANIFEST'
import hashlib, json, pathlib, subprocess, sys
root, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', 'Sources', 'Tests', 'Scripts', 'project.yml'])
manifest = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
            for name in sorted(set(paths.decode().split('\0'))) if name and (root / name).is_file()}
target.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
MANIFEST

{
    printf 'commit=%s\n' "$(git -C "${ROOT_DIR}" rev-parse HEAD)"
    printf 'branch=%s\n' "$(git -C "${ROOT_DIR}" branch --show-current)"
    printf 'configuration=Release\noptimization=-O\nlarge_benchmarks=1\n'
    printf 'started_utc=%s\n' "${RUN_ID}"
    printf 'derived_data=%s\n' "${DERIVED_DATA}"
    printf 'tracked_diff_sha256=%s\n' "$(git -C "${ROOT_DIR}" diff HEAD -- Sources Tests Scripts | shasum -a 256 | awk '{print $1}')"
    printf 'source_manifest_sha256=%s\n' "$(shasum -a 256 "${RUN_DIR}/source-manifest.json" | awk '{print $1}')"
    printf 'architecture=%s\n' "$(uname -m)"
    sw_vers
    sysctl hw.memsize hw.logicalcpu
    xcodebuild -version
    xcrun swift --version 2>&1
    xcrun --sdk macosx --show-sdk-version
    xcrun --sdk macosx --show-sdk-build-version
    git -C "${ROOT_DIR}" status --short
    printf '%s\n' "${SELECTORS[@]}"
} >"${RUN_DIR}/environment.txt"

bash "${ROOT_DIR}/Scripts/dev-doctor.sh" --skip-generated-check >"${RUN_DIR}/doctor.log" 2>&1
bash "${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh" --quiet >"${RUN_DIR}/rdp.log" 2>&1

COMMON=(
    -project "${ROOT_DIR}/ServerDash.xcodeproj"
    -scheme ServerDash
    -configuration Release
    -destination "platform=macOS,arch=$(uname -m)"
    -derivedDataPath "${DERIVED_DATA}"
    -skipPackagePluginValidation
    -onlyUsePackageVersionsFromResolvedFile
    -disableAutomaticPackageResolution
    -parallel-testing-enabled NO
    ENABLE_TESTABILITY=YES
    ONLY_ACTIVE_ARCH=YES
    SWIFT_OPTIMIZATION_LEVEL=-O
    COMPILER_INDEX_STORE_ENABLE=NO
    SWIFT_STRICT_CONCURRENCY=complete
)
printf 'Building optimized benchmark host. Log: %s\n' "${RUN_DIR}/build.log"
xcodebuild "${COMMON[@]}" "${SELECTORS[@]}" build-for-testing >"${RUN_DIR}/build.log" 2>&1
printf 'Running isolated benchmarks. Log: %s\n' "${RUN_DIR}/test.log"
SERVERDASH_RUN_LARGE_BENCHMARKS=1 TEST_RUNNER_SERVERDASH_RUN_LARGE_BENCHMARKS=1 \
    /usr/bin/time -l xcodebuild "${COMMON[@]}" "${SELECTORS[@]}" \
    -resultBundlePath "${RESULT_BUNDLE}" test-without-building >"${RUN_DIR}/test.log" 2>&1
