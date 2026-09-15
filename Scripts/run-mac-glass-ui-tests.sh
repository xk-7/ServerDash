#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_dir/.." && pwd -P)"

fail_configuration() {
  printf 'Invalid Mac glass UI test configuration: %s\n' "$*" >&2
  exit 64
}

canonical_directory_path() {
  local label="$1"
  local candidate="$2"
  local existing component parent suffix=""

  [[ -n "$candidate" ]] || fail_configuration "$label must not be empty."
  if [[ "$candidate" != /* ]]; then
    candidate="$repository_root/$candidate"
  fi
  while [[ "$candidate" != "/" && "$candidate" == */ ]]; do
    candidate="${candidate%/}"
  done
  case "/${candidate#/}/" in
    */../*) fail_configuration "$label must not contain '..' path components: $candidate" ;;
  esac

  existing="$candidate"
  while [[ ! -e "$existing" && ! -L "$existing" ]]; do
    component="${existing##*/}"
    case "$component" in
      ""|.) ;;
      *) suffix="/$component$suffix" ;;
    esac
    parent="${existing%/*}"
    existing="${parent:-/}"
    while [[ "$existing" != "/" && "$existing" == */ ]]; do
      existing="${existing%/}"
    done
  done
  [[ -d "$existing" ]] || fail_configuration "$label is not a directory path: $candidate"
  existing="$(cd "$existing" && pwd -P)"
  printf '%s%s\n' "$existing" "$suffix"
}

require_build_subdirectory() {
  local label="$1"
  local candidate="$2"
  case "$candidate" in
    "$build_root"/*) ;;
    *) fail_configuration "$label must resolve below $build_root; received $candidate" ;;
  esac
}

if [[ -L "$repository_root/.build" ]]; then
  fail_configuration "$repository_root/.build must not be a symbolic link."
fi
if [[ -e "$repository_root/.build" && ! -d "$repository_root/.build" ]]; then
  fail_configuration "$repository_root/.build must be a directory."
fi
if [[ "${SERVERDASH_MAC_QA_DERIVED_DATA+x}" == "x" ]]; then
  [[ -n "$SERVERDASH_MAC_QA_DERIVED_DATA" ]] || \
    fail_configuration "SERVERDASH_MAC_QA_DERIVED_DATA must not be empty."
fi
if [[ "${SERVERDASH_MAC_QA_ARTIFACTS_DIR+x}" == "x" ]]; then
  [[ -n "$SERVERDASH_MAC_QA_ARTIFACTS_DIR" ]] || \
    fail_configuration "SERVERDASH_MAC_QA_ARTIFACTS_DIR must not be empty."
fi

build_root="$(canonical_directory_path "Build root" "$repository_root/.build")"
derived_data="$(canonical_directory_path \
  "SERVERDASH_MAC_QA_DERIVED_DATA" \
  "${SERVERDASH_MAC_QA_DERIVED_DATA:-$build_root/mac-glass-ui-tests}")"
artifact_dir="$(canonical_directory_path \
  "SERVERDASH_MAC_QA_ARTIFACTS_DIR" \
  "${SERVERDASH_MAC_QA_ARTIFACTS_DIR:-$derived_data/glass-ui-artifacts}")"
result_dir="$(canonical_directory_path "UI test result directory" "$derived_data/glass-ui-results")"
require_build_subdirectory "Derived data" "$derived_data"
require_build_subdirectory "Artifact directory" "$artifact_dir"
require_build_subdirectory "Result directory" "$result_dir"
summary_file="$artifact_dir/test-summaries.jsonl"

default_tests=(
  testDashboardWindowMatrix
  testMachineGridWindowMatrix
  testMachineListWindowMatrix
  testCorePagesAtReferenceSize
  testAccessibilityAppearanceOverrides
  testDashboardRefreshActionsRemainReachable
  testSettingsEntriesStayInTheControlledFixtureWindow
  testSFTPFixtureUsesStableOfflineRows
  testGridCardHoverUsesExpectedGeometryWithoutClippingTheWindow
  testThousandHostsCanFilterAndScroll
)
if [[ $# -gt 0 ]]; then
  tests=("$@")
else
  tests=("${default_tests[@]}")
fi

for test_name in "${tests[@]}"; do
  if [[ ! "$test_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    fail_configuration "test name must be a Swift identifier: $test_name"
  fi
done

mkdir -p "$build_root"

if [[ $# -gt 0 ]]; then
  mkdir -p "$artifact_dir" "$result_dir"
  touch "$summary_file"
else
  rm -rf "$artifact_dir" "$result_dir"
  mkdir -p "$artifact_dir" "$result_dir"
  : > "$summary_file"
fi

cd "$repository_root"
xcodebuild -quiet \
  -project ServerDash.xcodeproj \
  -scheme ServerDashGlassUITests \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGN_IDENTITY=- \
  build-for-testing

export_dir=""
cleanup_export_dir() {
  if [[ -n "$export_dir" && -d "$export_dir" ]]; then
    if ! rm -rf "$export_dir"; then
      printf 'Could not remove temporary UI attachment directory: %s\n' "$export_dir" >&2
    fi
  fi
  export_dir=""
  return 0
}
trap cleanup_export_dir EXIT

for test_name in "${tests[@]}"; do
  result_path="$result_dir/$test_name.xcresult"
  export_dir="$(mktemp -d "${TMPDIR:-/tmp}/serverdash-glass-ui.XXXXXX")"
  rm -rf "$result_path"

  echo "Running $test_name"
  set +e
  xcodebuild -quiet \
    -project ServerDash.xcodeproj \
    -scheme ServerDashGlassUITests \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -collect-test-diagnostics never \
    -only-testing:"ServerDashGlassUITests/ServerDashGlassUITests/$test_name" \
    -resultBundlePath "$result_path" \
    test-without-building \
    CODE_SIGNING_ALLOWED=NO
  test_status=$?
  set -e

  result_processing_status=0
  summary_output="$export_dir/summary.json"
  attachment_export_dir="$export_dir/attachments"
  if ! xcrun xcresulttool get test-results summary --path "$result_path" --compact \
    > "$summary_output"; then
    printf 'Could not read UI test result bundle for %s; retaining %s for diagnosis.\n' \
      "$test_name" "$result_path" >&2
    result_processing_status=1
  elif [[ ! -s "$summary_output" ]]; then
    printf 'UI test result summary is empty for %s; retaining %s for diagnosis.\n' \
      "$test_name" "$result_path" >&2
    result_processing_status=1
  elif ! cat "$summary_output" >> "$summary_file"; then
    printf 'Could not append the UI test summary for %s to %s.\n' \
      "$test_name" "$summary_file" >&2
    result_processing_status=1
  fi

  if [[ $result_processing_status -eq 0 ]] && \
    ! xcrun xcresulttool export attachments --path "$result_path" --output-path "$attachment_export_dir" \
      >/dev/null; then
    printf 'Could not export UI test attachments for %s; retaining %s for diagnosis.\n' \
      "$test_name" "$result_path" >&2
    result_processing_status=1
  fi

  if [[ $result_processing_status -eq 0 ]] && ! /usr/bin/python3 - "$attachment_export_dir" "$artifact_dir" <<'PY'
import json
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
system_prefixes = (
    "App UI hierarchy",
    "Debug description",
    "Screen Recording",
    "Spindump",
    "Synthesized Event",
    "UI Snapshot",
)
for test in manifest:
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "")
        if not name or name.startswith(system_prefixes):
            continue
        exported = source / attachment["exportedFileName"]
        suffix = exported.suffix or ".png"
        safe_name = "".join(c if c.isalnum() or c in "-_." else "-" for c in name)
        output_name = safe_name if pathlib.Path(safe_name).suffix == suffix else f"{safe_name}{suffix}"
        shutil.copy2(exported, destination / output_name)
PY
  then
    printf 'Could not collect UI test attachments for %s; retaining %s for diagnosis.\n' \
      "$test_name" "$result_path" >&2
    result_processing_status=1
  fi

  cleanup_export_dir
  if [[ "${SERVERDASH_KEEP_UI_RESULTS:-0}" != "1" && \
    $test_status -eq 0 && $result_processing_status -eq 0 ]]; then
    rm -rf "$result_path"
  fi
  if [[ $test_status -ne 0 ]]; then
    echo "UI test failed: $test_name (xcodebuild exit $test_status; result retained at $result_path)" >&2
    exit "$test_status"
  fi
  if [[ $result_processing_status -ne 0 ]]; then
    echo "UI test result processing failed: $test_name (result retained at $result_path)" >&2
    exit "$result_processing_status"
  fi
done

echo "Mac glass UI matrix passed."
echo "Screenshots: $artifact_dir"
echo "Summaries: $summary_file"
