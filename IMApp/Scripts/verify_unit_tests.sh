#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${IMAPP_PROJECT_FILE:-${PROJECT_DIR}/IMApp.xcodeproj}"
SCHEME="${IMAPP_SCHEME:-IMApp}"
CONFIGURATION="${IMAPP_CONFIGURATION:-Debug}"
# Keep the app's minimum supported runtime explicit. Callers with a different
# installed test runtime can still override the full destination.
DESTINATION="${IMAPP_UNIT_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.2}"

xcodebuild test \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -only-testing:IMAppTests \
  CODE_SIGNING_ALLOWED=NO

printf 'iOS unit tests result=pass project=%s scheme=%s configuration=%s destination=%s\n' \
  "${PROJECT_FILE}" "${SCHEME}" "${CONFIGURATION}" "${DESTINATION}"
