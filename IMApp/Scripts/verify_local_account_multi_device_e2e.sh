#!/usr/bin/env bash
set -Eeuo pipefail

# Real account/device regression: one account is registered on the first
# simulator and signed in on the second. It deliberately requires two already
# booted simulators; it never erases, restarts, or shuts down user devices.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${app_dir}/.." && pwd)"
project_file="${app_dir}/IMApp.xcodeproj"
scheme="${IMAPP_LOCAL_MULTI_DEVICE_E2E_SCHEME:-IMAppLocalTwoInstallE2E}"
first_simulator_id="${IMAPP_LOCAL_MULTI_DEVICE_FIRST_SIMULATOR_ID:-}"
second_simulator_id="${IMAPP_LOCAL_MULTI_DEVICE_SECOND_SIMULATOR_ID:-}"
test_timeout_seconds="${IMAPP_LOCAL_MULTI_DEVICE_TEST_TIMEOUT_SECONDS:-180}"
app_bundle_id="com.stskcxfz.imapp"
test_class="IMAppLocalTwoInstallE2ETests/IMAppLocalTwoInstallE2ETests"
local_stack_script="${repo_root}/IMV2/scripts/run_v2_local_account_stack.sh"
local_ca="${repo_root}/IMV2/local-ca/root.crt"
local_env_file="${repo_root}/IMV2/.env.local"
local_compose_file="${repo_root}/IMV2/docker-compose.local-account.yml"
local_compose_project="${V2_LOCAL_COMPOSE_PROJECT:-imv2localaccount}"

for command in xcrun xcodebuild docker jq uuidgen; do
  command -v "${command}" >/dev/null 2>&1 || { printf 'missing required command: %s\n' "${command}" >&2; exit 1; }
done
if [[ -z "${first_simulator_id}" || -z "${second_simulator_id}" || "${first_simulator_id}" == "${second_simulator_id}" ]]; then
  printf '%s\n' 'set two distinct booted simulators in IMAPP_LOCAL_MULTI_DEVICE_FIRST_SIMULATOR_ID and IMAPP_LOCAL_MULTI_DEVICE_SECOND_SIMULATOR_ID.' >&2
  exit 2
fi
[[ "${test_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  printf '%s\n' 'IMAPP_LOCAL_MULTI_DEVICE_TEST_TIMEOUT_SECONDS must be a positive integer.' >&2
  exit 2
}
for simulator_id in "${first_simulator_id}" "${second_simulator_id}"; do
  xcrun simctl list devices | grep -Fq "(${simulator_id}) (Booted)" || { printf 'selected simulator is not booted: %s\n' "${simulator_id}" >&2; exit 2; }
done

printf '%s\n' 'preflight: unlock both selected simulators and keep this Mac unlocked; no simulator state will be destructively changed.' >&2
if [[ "${IMAPP_LOCAL_MULTI_DEVICE_SKIP_STACK_START:-0}" != "1" ]]; then
  "${local_stack_script}"
else
  printf '%s\n' 'using an already-running local account stack.' >&2
fi
[[ -f "${local_ca}" ]] || { printf 'missing local CA: %s\n' "${local_ca}" >&2; exit 1; }
source "${repo_root}/IMV2/scripts/local_compose.sh"
# shellcheck source=../../IMV2/scripts/local_admission_pool.sh
source "${repo_root}/IMV2/scripts/local_admission_pool.sh"
compose() {
  v2_local_compose "${local_env_file}" --project-name "${local_compose_project}" --file "${local_compose_file}" "$@"
}
# A caller may intentionally reuse an already-running disposable local stack
# to avoid rebuilding the server image. Keep that path equivalent to the
# normal stack launcher: group creation requires this fenced admission pool.
v2_seed_local_admission_pool
for simulator_id in "${first_simulator_id}" "${second_simulator_id}"; do
  xcrun simctl keychain "${simulator_id}" add-root-cert "${local_ca}"
done

scenario_suffix="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
first_scope="$(uuidgen | tr '[:upper:]' '[:lower:]')"
second_scope="$(uuidgen | tr '[:upper:]' '[:lower:]')"
account_handle="multi_${scenario_suffix:0:20}"
public_handle="multi${scenario_suffix:0:20}"
group_title="同账号群${scenario_suffix:0:6}"
result_directory="$(mktemp -d "${TMPDIR:-/tmp}/im-v2-local-multi-device-e2e.XXXXXX")"

cleanup() {
  local status="$?"
  # Scope cleanup is a normal App route, so it removes only credentials and
  # SQLite files named by this random regression run.
  for pair in "${first_simulator_id}:${first_scope}" "${second_simulator_id}:${second_scope}"; do
    local simulator_id="${pair%%:*}" scope="${pair#*:}"
    xcrun simctl launch --terminate-running-process "${simulator_id}" "${app_bundle_id}" \
      -v2-ui-testing-live-local-account -v2-ui-testing-cleanup-local-account -v2-ui-testing-e2e-scope "${scope}" >/dev/null 2>&1 || true
  done
  if [[ "${status}" -eq 0 ]]; then
    rm -rf -- "${result_directory}"
  else
    printf 'same-account E2E failed; retained result bundle directory: %s\n' "${result_directory}" >&2
  fi
  exit "${status}"
}
trap cleanup EXIT

build_products_directory="$(xcodebuild -showBuildSettings -json -project "${project_file}" -scheme "${scheme}" -configuration Debug -destination "platform=iOS Simulator,id=${first_simulator_id}" | jq --raw-output 'map(select(.target == "IMApp"))[0].buildSettings.BUILT_PRODUCTS_DIR')"
xcodebuild build -quiet -project "${project_file}" -scheme "${scheme}" -configuration Debug -destination "platform=iOS Simulator,id=${first_simulator_id}"
app_bundle="${build_products_directory}/IMApp.app"
[[ -d "${app_bundle}" ]] || { printf '%s\n' 'failed to locate built app bundle.' >&2; exit 1; }
for simulator_id in "${first_simulator_id}" "${second_simulator_id}"; do xcrun simctl install "${simulator_id}" "${app_bundle}"; done

run_stage() {
  local simulator_id="$1" test_name="$2"
  local result_bundle="${result_directory}/${test_name}.xcresult"
  xcodebuild test -quiet -project "${project_file}" -scheme "${scheme}" -configuration Debug \
    -destination "platform=iOS Simulator,id=${simulator_id}" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "${test_timeout_seconds}" \
    -maximum-test-execution-time-allowance "${test_timeout_seconds}" \
    -only-testing:"${test_class}/${test_name}" -resultBundlePath "${result_bundle}" &
  local test_pid="$!"
  local deadline=$((SECONDS + test_timeout_seconds))
  while kill -0 "${test_pid}" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      printf 'same-account E2E stage timed out after %ss: %s\n' "${test_timeout_seconds}" "${test_name}" >&2
      kill -TERM "${test_pid}" >/dev/null 2>&1 || true
      wait "${test_pid}" || true
      xcrun xcresulttool get test-results tests --path "${result_bundle}" >&2 || true
      return 1
    fi
    sleep 1
  done
  if ! wait "${test_pid}"; then
    printf 'same-account E2E stage failed: %s\n' "${test_name}" >&2
    xcrun xcresulttool get test-results tests --path "${result_bundle}" >&2 || true
    return 1
  fi
}
launch() { xcrun simctl launch --terminate-running-process "$1" "${app_bundle_id}" "${@:2}" >/dev/null; }
postgres_scalar() {
  compose exec -T postgres psql -U im_v2 -d im_v2 -v ON_ERROR_STOP=1 -tAc "$1"
}
assert_same_account_read_receipt() {
  local user_id group_room_id sequence attempt
  user_id="$(postgres_scalar "SELECT user_id FROM im_v2.account_password_credentials WHERE account_handle = '${account_handle}'")"
  group_room_id="$(postgres_scalar "SELECT room_id FROM im_v2.group_rooms WHERE owner_user_id = '${user_id}' AND title = '${group_title}'")"
  [[ -n "${user_id}" && -n "${group_room_id}" ]] || { printf '%s\n' 'cannot locate same-account E2E user or group room.' >&2; return 1; }
  for attempt in {1..10}; do
    sequence="$(postgres_scalar "SELECT read_through_room_sequence FROM im_v2.room_read_receipts WHERE room_id = '${group_room_id}' AND user_id = '${user_id}'")"
    [[ "${sequence}" =~ ^[1-9][0-9]*$ ]] && return 0
    sleep 1
  done
  printf '%s\n' 'same-account group viewing did not persist a user-level read receipt.' >&2
  return 1
}
stage_second_device_snapshot_reset() {
  local user_id operation_id operator_token body response
  user_id="$(postgres_scalar "SELECT user_id FROM im_v2.account_password_credentials WHERE account_handle = '${account_handle}'")"
  [[ -n "${user_id}" ]] || { printf '%s\n' 'cannot locate same-account E2E user for snapshot reset.' >&2; return 1; }
  operator_token="$(sed -n 's/^IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64=//p' "${local_env_file}" | head -n 1)"
  [[ -n "${operator_token}" ]] || { printf '%s\n' 'missing local operator bearer token.' >&2; return 1; }
  operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  body="$(jq --null-input --compact-output --arg operationID "${operation_id}" --arg userID "${user_id}" --arg deviceID "${second_scope}" '{operationID: $operationID, userID: $userID, deviceID: $deviceID}')"
  if compose exec -T operator sh -c 'command -v curl' >/dev/null 2>&1; then
    response="$(compose exec -T operator curl --fail --silent --show-error --request POST \
      --header "Authorization: Bearer ${operator_token}" \
      --header 'Content-Type: application/json' \
      --data "${body}" \
      http://127.0.0.1:9445/internal/v2/device-snapshots/reset)"
  else
    # The production image includes curl. Keep this fallback for a minimal
    # source-built test image, where Python is present but curl is omitted.
    response="$(compose exec -T \
      --env "IMAPP_OPERATOR_TOKEN=${operator_token}" \
      --env "IMAPP_OPERATOR_BODY=${body}" \
      operator python3 -c '
import os
import urllib.request

request = urllib.request.Request(
    "http://127.0.0.1:9445/internal/v2/device-snapshots/reset",
    data=os.environ["IMAPP_OPERATOR_BODY"].encode("utf-8"),
    headers={
        "Authorization": "Bearer " + os.environ["IMAPP_OPERATOR_TOKEN"],
        "Content-Type": "application/json",
    },
    method="POST",
)
with urllib.request.urlopen(request) as response:
    print(response.read().decode("utf-8"))
')"
  fi
  jq --exit-status --arg operationID "${operation_id}" '(.operationID | ascii_downcase) == $operationID and (.generation | type == "number") and .wasIdempotent == false' <<<"${response}" >/dev/null
}

launch "${first_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-e2e-scope "${first_scope}" \
  -v2-ui-testing-password-register -v2-ui-testing-local-password localpassword \
  -v2-ui-testing-account-handle "${account_handle}" -v2-ui-testing-public-handle "${public_handle}" \
  -v2-ui-testing-display-name 'Multi-device owner' -v2-ui-testing-group-title "${group_title}"
run_stage "${first_simulator_id}" testReceiverRegistersIndependentInstallation

launch "${second_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-e2e-scope "${second_scope}" \
  -v2-ui-testing-local-password localpassword -v2-ui-testing-account-handle "${account_handle}"
run_stage "${second_simulator_id}" testSameAccountSecondInstallationListsDevicesAndSendsToSharedGroup

launch "${first_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${first_scope}"
run_stage "${first_simulator_id}" testSameAccountFirstInstallationProjectsEditsAndChangesPreference
assert_same_account_read_receipt

launch "${second_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${second_scope}"
run_stage "${second_simulator_id}" testSameAccountSecondInstallationProjectsEditPreferenceAndWithdraws

launch "${second_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-unavailable-realtime -v2-ui-testing-e2e-scope "${second_scope}"
run_stage "${second_simulator_id}" testSameAccountSecondInstallationQueuesOfflineGroupMessage

launch "${second_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${second_scope}"
run_stage "${second_simulator_id}" testSameAccountSecondInstallationReplaysOfflineGroupMessageAndWithdraws

stage_second_device_snapshot_reset

launch "${second_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${second_scope}"
run_stage "${second_simulator_id}" testSameAccountSecondInstallationProjectsSnapshotReset

launch "${first_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${first_scope}"
run_stage "${first_simulator_id}" testSameAccountFirstInstallationProjectsWithdrawal

printf '%s\n' 'local same-account multi-device E2E: pass'
