#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${IMAPP_PROJECT_FILE:-${PROJECT_DIR}/IMApp.xcodeproj}"
SCHEME="${IMAPP_SCHEME:-IMApp}"
CONFIGURATION="${IMAPP_CONFIGURATION:-Debug}"
# Keep the device name stable while allowing the installed Xcode runtime to
# select its current compatible iOS version on local machines and CI.
DESTINATION="${IMAPP_UNIT_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"

xcodebuild test \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -only-testing:IMAppTests \
  CODE_SIGNING_ALLOWED=NO

printf 'iOS unit tests result=pass project=%s scheme=%s configuration=%s destination=%s\n' \
  "${PROJECT_FILE}" "${SCHEME}" "${CONFIGURATION}" "${DESTINATION}"
