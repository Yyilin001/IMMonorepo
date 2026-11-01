#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${IMAPP_PROJECT_FILE:-${PROJECT_DIR}/IMApp.xcodeproj}"
SCHEME="${IMAPP_SCHEME:-IMApp}"
CONFIGURATION="${IMAPP_CONFIGURATION:-Debug}"
# Use an installed matching simulator. CI can pin an OS or UDID explicitly.
DESTINATION="${IMAPP_UNIT_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
if [[ $# -eq 0 ]]; then set -- IMAppTests; fi
test_filters=()
for test_id in "$@"; do test_filters+=("-only-testing:${test_id}"); done

# Xcode can exit successfully when a misspelled Swift Testing identifier
# matches no tests. Keep a result bundle and verify that tests actually ran.
if [[ -n "${IMAPP_UNIT_TEST_RESULT_BUNDLE:-}" ]]; then
  result_bundle="${IMAPP_UNIT_TEST_RESULT_BUNDLE}"
else
  results_root="${PROJECT_DIR}/../build/test-results"
  mkdir -p "${results_root}"
  result_directory="$(mktemp -d "${results_root}/IMAppTests.XXXXXX")"
  result_bundle="${result_directory}/Result.xcresult"
fi

xcodebuild test \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -resultBundlePath "${result_bundle}" \
  "${test_filters[@]}" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-

xcrun xcresulttool get test-results summary --path "${result_bundle}" | python3 -c '
import json, sys
summary = json.load(sys.stdin)
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
if passed <= 0 or failed != 0:
    sys.exit(f"iOS unit tests did not pass an executed selection: passed={passed}, failed={failed}, skipped={skipped}. Check complete test identifiers in the result bundle.")
print(f"iOS unit tests executed: passed={passed}, failed={failed}, skipped={skipped}")
'

printf 'iOS unit tests result=pass project=%s scheme=%s configuration=%s destination=%s selection=%s\n' \
  "${PROJECT_FILE}" "${SCHEME}" "${CONFIGURATION}" "${DESTINATION}" "$*"
printf 'iOS unit tests result_bundle=%s\n' "${result_bundle}"
