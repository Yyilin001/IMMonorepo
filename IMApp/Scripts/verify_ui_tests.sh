#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${IMAPP_PROJECT_FILE:-${PROJECT_DIR}/IMApp.xcodeproj}"
SCHEME="${IMAPP_SCHEME:-IMApp}"
CONFIGURATION="${IMAPP_CONFIGURATION:-Debug}"
# The UI suite uses a signed-out launch fixture and no real network. Keep the
# destination configurable for a local simulator while keeping CI on the
# app's explicit minimum supported runtime.
DESTINATION="${IMAPP_UI_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.2}"

xcodebuild test \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -only-testing:IMAppUITests \
  CODE_SIGNING_ALLOWED=NO

printf 'iOS UI tests result=pass project=%s scheme=%s configuration=%s destination=%s\n' \
  "${PROJECT_FILE}" "${SCHEME}" "${CONFIGURATION}" "${DESTINATION}"
