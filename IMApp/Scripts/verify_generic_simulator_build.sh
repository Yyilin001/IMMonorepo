#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${IMAPP_PROJECT_FILE:-${PROJECT_DIR}/IMApp.xcodeproj}"
SCHEME="${IMAPP_SCHEME:-IMApp}"
CONFIGURATION="${IMAPP_CONFIGURATION:-Debug}"
DESTINATION="${IMAPP_DESTINATION:-generic/platform=iOS Simulator}"

# This produces app, unit-test, and UI-test bundles without creating or booting
# a CoreSimulator device. Keep all derived artifacts outside the repository.
derived_data_path="${IMAPP_GENERIC_BUILD_DERIVED_DATA_PATH:-}"
remove_derived_data=false
if [[ -z "${derived_data_path}" ]]; then
  derived_data_path="$(mktemp -d "${TMPDIR:-/tmp}/imapp-generic-simulator-build.XXXXXX")"
  remove_derived_data=true
fi

cleanup() {
  if [[ "${remove_derived_data}" == "true" ]]; then
    rm -rf "${derived_data_path}"
  fi
}
trap cleanup EXIT

xcodebuild build-for-testing \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${derived_data_path}" \
  CODE_SIGNING_ALLOWED=NO

printf 'generic-simulator-build result=pass project=%s scheme=%s configuration=%s destination=%s\n' \
  "${PROJECT_FILE}" "${SCHEME}" "${CONFIGURATION}" "${DESTINATION}"
