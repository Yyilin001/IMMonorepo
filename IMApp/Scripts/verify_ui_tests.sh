#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${IMAPP_PROJECT_FILE:-${PROJECT_DIR}/IMApp.xcodeproj}"
SCHEME="${IMAPP_SCHEME:-IMApp}"
CONFIGURATION="${IMAPP_CONFIGURATION:-Debug}"
# The UI suite uses a signed-out launch fixture and no real network. CI can
# pin an OS or UDID; local runs use an installed matching simulator.
DESTINATION="${IMAPP_UI_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
if [[ $# -eq 0 ]]; then set -- IMAppUITests; fi
test_filters=()
for test_id in "$@"; do test_filters+=("-only-testing:${test_id}"); done

xcodebuild test \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  "${test_filters[@]}" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-

printf 'iOS UI tests result=pass project=%s scheme=%s configuration=%s destination=%s selection=%s\n' \
  "${PROJECT_FILE}" "${SCHEME}" "${CONFIGURATION}" "${DESTINATION}" "$*"
