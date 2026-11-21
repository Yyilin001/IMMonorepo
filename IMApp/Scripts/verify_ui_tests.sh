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
ui_test_runtime="${IMAPP_UI_TEST_RUNTIME:-}"
if [[ -n "$ui_test_runtime" ]]; then
  # CI owns this simulator so its photo fixture and Files state are isolated.
  ui_test_device="${IMAPP_UI_TEST_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
  ui_test_simulator="$(xcrun simctl create 'IMApp UI CI' "$ui_test_device" "$ui_test_runtime")"
  cleanup_ui_test_simulator() {
    xcrun simctl shutdown "$ui_test_simulator" || true
    xcrun simctl delete "$ui_test_simulator"
  }
  trap cleanup_ui_test_simulator EXIT
  xcrun simctl boot "$ui_test_simulator"
  xcrun simctl bootstatus "$ui_test_simulator" -b
  xcrun simctl addmedia "$ui_test_simulator" "$SCRIPT_DIR/test-fixtures/system-photo.png"
  DESTINATION="platform=iOS Simulator,id=$ui_test_simulator"
fi
if [[ $# -eq 0 ]]; then set -- IMAppUITests; fi
test_filters=()
for test_id in "$@"; do test_filters+=("-only-testing:${test_id}"); done
result_options=()
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  result_options=(-resultBundlePath "$RUNNER_TEMP/IMAppUITests.xcresult")
fi

xcodebuild test \
  -project "${PROJECT_FILE}" \
  -scmProvider system \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -parallel-testing-enabled NO \
  "${result_options[@]}" \
  "${test_filters[@]}" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-

printf 'iOS UI tests result=pass project=%s scheme=%s configuration=%s destination=%s selection=%s\n' \
  "${PROJECT_FILE}" "${SCHEME}" "${CONFIGURATION}" "${DESTINATION}" "$*"
