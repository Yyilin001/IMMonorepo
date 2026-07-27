#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${app_dir}/.." && pwd)"
local_stack_script="${repo_root}/IMV2/scripts/run_v2_local_account_stack.sh"
local_ca="${repo_root}/IMV2/local-ca/root.crt"
local_compose_file="${repo_root}/IMV2/docker-compose.local-account.yml"
local_env_file="${repo_root}/IMV2/.env.local"
local_compose_project="${V2_LOCAL_COMPOSE_PROJECT:-imv2localaccount}"
project_file="${app_dir}/IMApp.xcodeproj"
scheme="${IMAPP_LOCAL_TWO_INSTALL_E2E_SCHEME:-IMAppLocalTwoInstallE2E}"
app_bundle_id="com.stskcxfz.imapp"
receiver_simulator_id="${IMAPP_LOCAL_TWO_INSTALL_RECEIVER_SIMULATOR_ID:-}"
sender_simulator_id="${IMAPP_LOCAL_TWO_INSTALL_SENDER_SIMULATOR_ID:-}"
test_class="IMAppLocalTwoInstallE2ETests/IMAppLocalTwoInstallE2ETests"
keep_result_bundle="${IMAPP_LOCAL_TWO_INSTALL_E2E_KEEP_RESULTS:-false}"

source "${repo_root}/IMV2/scripts/local_compose.sh"

local_compose() {
  v2_local_compose "${local_env_file}" --project-name "${local_compose_project}" --file "${local_compose_file}" "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for command in xcrun xcodebuild curl docker jq uuidgen; do
  require_command "${command}"
done

if [[ -z "${receiver_simulator_id}" || -z "${sender_simulator_id}" ]]; then
  printf '%s\n' 'missing IMAPP_LOCAL_TWO_INSTALL_RECEIVER_SIMULATOR_ID or IMAPP_LOCAL_TWO_INSTALL_SENDER_SIMULATOR_ID; choose two explicitly booted simulators.' >&2
  exit 2
fi

if [[ "${receiver_simulator_id}" == "${sender_simulator_id}" ]]; then
  printf '%s\n' 'the receiver and sender simulator IDs must be different.' >&2
  exit 2
fi

for simulator_id in "${receiver_simulator_id}" "${sender_simulator_id}"; do
  if ! xcrun simctl list devices | grep -Fq "(${simulator_id}) (Booted)"; then
    printf 'selected simulator is not booted: %s\n' "${simulator_id}" >&2
    exit 2
  fi
done

printf '%s\n' 'preflight: manually unlock both selected simulators at least once since boot, and keep the Mac unlocked. This script never boots, restarts, erases, or shuts down a simulator.' >&2

running_services="$(local_compose ps --status running --services 2>/dev/null || true)"
if ! grep -qx 'account' <<<"${running_services}" || ! grep -qx 'gateway' <<<"${running_services}" || ! grep -qx 'caddy' <<<"${running_services}"; then
  "${local_stack_script}"
fi

if [[ ! -f "${local_ca}" ]]; then
  printf 'missing local CA after starting stack: %s\n' "${local_ca}" >&2
  exit 1
fi

status="$(curl --silent --output /dev/null --write-out '%{http_code}' --cacert "${local_ca}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"accountHandle":"bad","password":"short","deviceID":"00000000-0000-4000-8000-000000000000"}' \
  'https://localhost:8443/v2/account-auth/password/assertion')"
[[ "${status}" == "400" ]] || { printf 'local HTTPS readiness returned %s, expected 400\n' "${status}" >&2; exit 1; }

for simulator_id in "${receiver_simulator_id}" "${sender_simulator_id}"; do
  xcrun simctl keychain "${simulator_id}" add-root-cert "${local_ca}"
done

scenario_suffix="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
receiver_scope="$(uuidgen | tr '[:upper:]' '[:lower:]')"
sender_scope="$(uuidgen | tr '[:upper:]' '[:lower:]')"
receiver_account_handle="twor_${scenario_suffix:0:20}"
receiver_public_handle="twor${scenario_suffix:0:20}"
sender_account_handle="twos_${scenario_suffix:0:20}"
sender_public_handle="twos${scenario_suffix:0:20}"
message="two-install-${scenario_suffix:0:16}"

result_directory="$(mktemp -d "${TMPDIR:-/tmp}/im-v2-local-two-install-e2e.XXXXXX")"
build_products_directory="$(xcodebuild -showBuildSettings -json \
  -project "${project_file}" \
  -scheme "${scheme}" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${receiver_simulator_id}" \
  | jq --raw-output 'map(select(.target == "IMApp"))[0].buildSettings.BUILT_PRODUCTS_DIR')"
app_bundle="${build_products_directory}/IMApp.app"
cleanup_attempted=false

xcodebuild build \
  -quiet \
  -project "${project_file}" \
  -scheme "${scheme}" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${receiver_simulator_id}"

if [[ ! -d "${app_bundle}" ]]; then
  printf '%s\n' 'failed to locate the built two-install app bundle.' >&2
  exit 1
fi

for simulator_id in "${receiver_simulator_id}" "${sender_simulator_id}"; do
  xcrun simctl install "${simulator_id}" "${app_bundle}"
done

launch_fixture() {
  local simulator_id="$1"
  shift
  xcrun simctl launch --terminate-running-process "${simulator_id}" "${app_bundle_id}" "$@" >/dev/null
}

run_stage() {
  local simulator_id="$1"
  local test_name="$2"
  local result_bundle="${result_directory}/${simulator_id}-${test_name}.xcresult"
  local test_summary
  local test_result
  local failed_test_count
  local passed_test_count
  local total_test_count

  printf 'running local two-install stage=%s simulator=%s\n' "${test_name}" "${simulator_id}"
  xcodebuild test \
    -quiet \
    -project "${project_file}" \
    -scheme "${scheme}" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=${simulator_id}" \
    -only-testing:"${test_class}/${test_name}" \
    -resultBundlePath "${result_bundle}"

  test_summary="$(xcrun xcresulttool get test-results summary --path "${result_bundle}" --compact)"
  test_result="$(jq --raw-output '.result' <<<"${test_summary}")"
  failed_test_count="$(jq --raw-output '.failedTests' <<<"${test_summary}")"
  passed_test_count="$(jq --raw-output '.passedTests' <<<"${test_summary}")"
  total_test_count="$(jq --raw-output '.totalTestCount' <<<"${test_summary}")"
  if [[ "${test_result}" != "Passed" || "${failed_test_count}" != "0" || "${passed_test_count}" != "1" || "${total_test_count}" != "1" ]]; then
    printf 'local two-install stage mismatch: stage=%s result=%s passed=%s failed=%s total=%s\n' \
      "${test_name}" "${test_result}" "${passed_test_count}" "${failed_test_count}" "${total_test_count}" >&2
    return 1
  fi
}

cleanup() {
  local original_status="$?"
  if [[ "${cleanup_attempted}" == false ]]; then
    cleanup_attempted=true
    launch_fixture "${receiver_simulator_id}" \
      -v2-ui-testing-live-local-account \
      -v2-ui-testing-cleanup-local-account \
      -v2-ui-testing-e2e-scope "${receiver_scope}"
    run_stage "${receiver_simulator_id}" testCleansOnlyRequestedIndependentInstallationScope || true
    launch_fixture "${sender_simulator_id}" \
      -v2-ui-testing-live-local-account \
      -v2-ui-testing-cleanup-local-account \
      -v2-ui-testing-e2e-scope "${sender_scope}"
    run_stage "${sender_simulator_id}" testCleansOnlyRequestedIndependentInstallationScope || true
  fi
  if [[ "${keep_result_bundle}" == true ]]; then
    printf 'preserving local two-install result bundles: %s\n' "${result_directory}" >&2
  else
    rm -rf -- "${result_directory}"
  fi
  exit "${original_status}"
}
trap cleanup EXIT

launch_fixture "${receiver_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-e2e-scope "${receiver_scope}" \
  -v2-ui-testing-password-register \
  -v2-ui-testing-local-password localpassword \
  -v2-ui-testing-account-handle "${receiver_account_handle}" \
  -v2-ui-testing-public-handle "${receiver_public_handle}" \
  -v2-ui-testing-display-name 'Two install receiver'
run_stage "${receiver_simulator_id}" testReceiverRegistersIndependentInstallation

launch_fixture "${sender_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-e2e-scope "${sender_scope}" \
  -v2-ui-testing-password-register \
  -v2-ui-testing-local-password localpassword \
  -v2-ui-testing-account-handle "${sender_account_handle}" \
  -v2-ui-testing-public-handle "${sender_public_handle}" \
  -v2-ui-testing-display-name 'Two install sender' \
  -v2-ui-testing-direct-target "@${receiver_public_handle}" \
  -v2-ui-testing-message "${message}"
run_stage "${sender_simulator_id}" testSenderOpensDirectConversationAndSendsFromIndependentInstallation

launch_fixture "${receiver_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-restore-local-account \
  -v2-ui-testing-e2e-scope "${receiver_scope}"
run_stage "${receiver_simulator_id}" testReceiverRestoresScopedInstallationAndProjectsOfflineMessage

printf '%s\n' 'local two-install direct-message E2E: pass'
printf '%s\n' 'scope: two different booted simulators independently register real App installations; the receiver is terminated before the sender opens a direct room and sends through the ordinary UI, then the receiver restores only its random Keychain/SQLite scope and projects the message after authenticated realtime catch-up. This does not cover APNs, production deployment, or capacity.'
