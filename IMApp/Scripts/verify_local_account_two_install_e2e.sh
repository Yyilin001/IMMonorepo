#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${app_dir}/.." && pwd)"
local_stack_script="${repo_root}/IMV2/scripts/run_v2_local_account_stack.sh"
local_ca="${IMAPP_LOCAL_TWO_INSTALL_CA_PATH:-${repo_root}/IMV2/local-ca/root.crt}"
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
accessibility_profile="${IMAPP_LOCAL_TWO_INSTALL_ACCESSIBILITY_PROFILE:-default}"
external_stack="${IMAPP_LOCAL_TWO_INSTALL_EXTERNAL_STACK:-false}"

source "${repo_root}/IMV2/scripts/local_compose.sh"
# shellcheck source=../../IMV2/scripts/local_admission_pool.sh
source "${repo_root}/IMV2/scripts/local_admission_pool.sh"
# shellcheck source=../../IMV2/scripts/local_gateway_tls.sh
source "${repo_root}/IMV2/scripts/local_gateway_tls.sh"

local_compose() {
  v2_local_compose "${local_env_file}" --project-name "${local_compose_project}" --file "${local_compose_file}" "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for command in xcrun xcodebuild curl jq uuidgen; do
  require_command "${command}"
done

case "${external_stack}" in
  true) ;;
  false) require_command docker ;;
  *)
    printf 'unsupported IMAPP_LOCAL_TWO_INSTALL_EXTERNAL_STACK: %s\n' "${external_stack}" >&2
    exit 2
    ;;
esac

if [[ -z "${receiver_simulator_id}" || -z "${sender_simulator_id}" ]]; then
  printf '%s\n' 'missing IMAPP_LOCAL_TWO_INSTALL_RECEIVER_SIMULATOR_ID or IMAPP_LOCAL_TWO_INSTALL_SENDER_SIMULATOR_ID; choose two explicitly booted simulators.' >&2
  exit 2
fi

if [[ "${receiver_simulator_id}" == "${sender_simulator_id}" ]]; then
  printf '%s\n' 'the receiver and sender simulator IDs must be different.' >&2
  exit 2
fi

case "${accessibility_profile}" in
  default) ;;
  accessibility-xl-rtl)
    ;;
  *)
    printf 'unsupported IMAPP_LOCAL_TWO_INSTALL_ACCESSIBILITY_PROFILE: %s\n' "${accessibility_profile}" >&2
    exit 2
    ;;
esac

for simulator_id in "${receiver_simulator_id}" "${sender_simulator_id}"; do
  if ! xcrun simctl list devices | grep -Fq "(${simulator_id}) (Booted)"; then
    printf 'selected simulator is not booted: %s\n' "${simulator_id}" >&2
    exit 2
  fi
done

printf '%s\n' 'preflight: manually unlock both selected simulators at least once since boot, and keep the Mac unlocked. This script never boots, restarts, erases, or shuts down a simulator.' >&2

if [[ "${external_stack}" == false ]]; then
  running_services="$(local_compose ps --status running --services 2>/dev/null || true)"
  if ! grep -qx 'account' <<<"${running_services}" || ! grep -qx 'gateway' <<<"${running_services}" || ! grep -qx 'caddy' <<<"${running_services}"; then
    "${local_stack_script}"
  fi
  v2_seed_local_admission_pool
  v2_ensure_local_gateway_tls "${local_ca}"
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
receiver_self_group_title="自测群${scenario_suffix:0:6}"
receiver_group_title="跨装群${scenario_suffix:0:6}"
group_message="two-install-group-${scenario_suffix:0:16}"
group_message_mentions='@all'

result_directory="$(mktemp -d "${TMPDIR:-/tmp}/im-v2-local-two-install-e2e.XXXXXX")"
build_products_directory="$(xcodebuild -showBuildSettings -json \
  -project "${project_file}" \
  -scheme "${scheme}" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${receiver_simulator_id}" \
  | jq --raw-output 'map(select(.target == "IMApp"))[0].buildSettings.BUILT_PRODUCTS_DIR')"
app_bundle="${build_products_directory}/IMApp.app"
cleanup_attempted=false
audit_failure_count=0
withdrawal_failure_count=0
receiver_original_increase_contrast=""
sender_original_increase_contrast=""
receiver_original_content_size=""
sender_original_content_size=""
receiver_accessibility_settings_applied=false
sender_accessibility_settings_applied=false

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
  if [[ "${accessibility_profile}" == "accessibility-xl-rtl" ]]; then
    xcrun simctl launch --terminate-running-process "${simulator_id}" "${app_bundle_id}" "$@" \
      -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge \
      -AppleLanguages '(ar)' \
      -AppleLocale ar_SA >/dev/null
  else
    xcrun simctl launch --terminate-running-process "${simulator_id}" "${app_bundle_id}" "$@" >/dev/null
  fi
}

is_supported_content_size() {
  case "$1" in
    extra-small|small|medium|large|extra-large|extra-extra-large|extra-extra-extra-large|accessibility-medium|accessibility-large|accessibility-extra-large|accessibility-extra-extra-large|accessibility-extra-extra-extra-large)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

configure_accessibility_profile() {
  [[ "${accessibility_profile}" == "accessibility-xl-rtl" ]] || return 0

  receiver_original_increase_contrast="$(xcrun simctl ui "${receiver_simulator_id}" increase_contrast)"
  sender_original_increase_contrast="$(xcrun simctl ui "${sender_simulator_id}" increase_contrast)"
  receiver_original_content_size="$(xcrun simctl ui "${receiver_simulator_id}" content_size)"
  sender_original_content_size="$(xcrun simctl ui "${sender_simulator_id}" content_size)"

  for contrast in "${receiver_original_increase_contrast}" "${sender_original_increase_contrast}"; do
    case "${contrast}" in
      enabled|disabled) ;;
      *)
        printf 'unable to determine simulator increase-contrast state: %s\n' "${contrast}" >&2
        return 1
        ;;
    esac
  done
  for content_size in "${receiver_original_content_size}" "${sender_original_content_size}"; do
    if ! is_supported_content_size "${content_size}"; then
      printf 'unable to determine simulator content-size state: %s\n' "${content_size}" >&2
      return 1
    fi
  done

  xcrun simctl ui "${receiver_simulator_id}" increase_contrast enabled >/dev/null
  xcrun simctl ui "${receiver_simulator_id}" content_size accessibility-extra-extra-extra-large >/dev/null
  receiver_accessibility_settings_applied=true
  xcrun simctl ui "${sender_simulator_id}" increase_contrast enabled >/dev/null
  xcrun simctl ui "${sender_simulator_id}" content_size accessibility-extra-extra-extra-large >/dev/null
  sender_accessibility_settings_applied=true
  printf '%s\n' 'accessibility profile: enabled system increase contrast and maximum accessibility content size; original simulator settings will be restored on exit.'
}

restore_accessibility_profile() {
  local restore_status=0

  if [[ "${receiver_accessibility_settings_applied}" == true ]]; then
    xcrun simctl ui "${receiver_simulator_id}" increase_contrast "${receiver_original_increase_contrast}" >/dev/null || restore_status=1
    xcrun simctl ui "${receiver_simulator_id}" content_size "${receiver_original_content_size}" >/dev/null || restore_status=1
  fi
  if [[ "${sender_accessibility_settings_applied}" == true ]]; then
    xcrun simctl ui "${sender_simulator_id}" increase_contrast "${sender_original_increase_contrast}" >/dev/null || restore_status=1
    xcrun simctl ui "${sender_simulator_id}" content_size "${sender_original_content_size}" >/dev/null || restore_status=1
  fi

  if [[ "${restore_status}" -ne 0 ]]; then
    printf '%s\n' 'failed to restore one or more simulator accessibility settings.' >&2
  fi
  return "${restore_status}"
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
  local xcode_status=0
  xcodebuild test \
    -quiet \
    -collect-test-diagnostics never \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 300 \
    -maximum-test-execution-time-allowance 300 \
    -project "${project_file}" \
    -scheme "${scheme}" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=${simulator_id}" \
    -only-testing:"${test_class}/${test_name}" \
    -resultBundlePath "${result_bundle}" &
  local test_pid="$!" deadline=$((SECONDS + 360))
  while kill -0 "${test_pid}" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      printf 'two-install stage exceeded wall-clock deadline: %s\n' "${test_name}" >&2
      kill -INT "${test_pid}" 2>/dev/null || true
      local drain_deadline=$((SECONDS + 15))
      while kill -0 "${test_pid}" 2>/dev/null && ((SECONDS < drain_deadline)); do sleep 1; done
      kill -TERM "${test_pid}" 2>/dev/null || true
      drain_deadline=$((SECONDS + 5))
      while kill -0 "${test_pid}" 2>/dev/null && ((SECONDS < drain_deadline)); do sleep 1; done
      if kill -0 "${test_pid}" 2>/dev/null; then kill -KILL "${test_pid}" 2>/dev/null || true; fi
      break
    fi
    sleep 1
  done
  wait "${test_pid}" || xcode_status="$?"

  test_summary="$(xcrun xcresulttool get test-results summary --path "${result_bundle}" --compact)"
  test_result="$(jq --raw-output '.result' <<<"${test_summary}")"
  failed_test_count="$(jq --raw-output '.failedTests' <<<"${test_summary}")"
  passed_test_count="$(jq --raw-output '.passedTests' <<<"${test_summary}")"
  total_test_count="$(jq --raw-output '.totalTestCount' <<<"${test_summary}")"
  local test_activities
  test_activities="$(xcrun xcresulttool get test-results activities --path "${result_bundle}" \
    --test-id "IMAppLocalTwoInstallE2ETests/${test_name}()" --compact)"
  printf '%s\n' "${test_activities}" > "${result_directory}/${simulator_id}-${test_name}-activities.json"
  # This exact known audit issue is retained as a failed stage, not waived.
  # Continue only when no business assertion or other failure was recorded;
  # the aggregate still exits 1 after all available functional stages.
  if [[ "${xcode_status}" -ne 0 && "${failed_test_count}" == "1" && "${total_test_count}" == "1" ]] &&
     jq --exit-status '(.testFailures | length) > 0 and all(.testFailures[]; .failureText == "Dynamic Type font sizes are partially unsupported" or .failureText == "Text clipped" or .failureText == "Hit area is too small")' <<<"${test_summary}" >/dev/null &&
     jq --exit-status '([.. | objects | select(.isAssociatedWithFailure == true) | .title // ""] | all(. == "" or . == "Dynamic Type font sizes are partially unsupported" or . == "Text clipped" or . == "Hit area is too small")) and ([.. | objects | .title?] | any(. == "two-install-functional-stage-complete"))' <<<"${test_activities}" >/dev/null; then
    audit_failure_count=$((audit_failure_count + 1))
    printf 'retained accessibility audit failure; continuing functional stages: %s\n' "${test_name}" >&2
    return 0
  fi
  # Group creation and offline replay have no dependency on this direct-room
  # withdrawal projection. Preserve this exact failed acceptance and run those
  # independent stages; the aggregate still fails, never waives the issue.
  if [[ "${test_name}" == "testReceiverRestoresScopedInstallationAndProjectsOfflineMessageThenSendsGroupMessage" &&
        "${xcode_status}" -ne 0 && "${failed_test_count}" == "1" && "${total_test_count}" == "1" ]] &&
     jq --exit-status '(.testFailures | length) > 0 and all(.testFailures[]; (.failureText | startswith("Asynchronous wait failed: Exceeded timeout of 30 seconds")) and (.failureText | contains("label == \"消息已撤回\"")))' <<<"${test_summary}" >/dev/null; then
    withdrawal_failure_count=$((withdrawal_failure_count + 1))
    printf 'retained direct withdrawal projection failure; continuing independent stages: %s\n' "${test_name}" >&2
    return 0
  fi
  if [[ "${xcode_status}" -ne 0 || "${test_result}" != "Passed" || "${failed_test_count}" != "0" || "${passed_test_count}" != "1" || "${total_test_count}" != "1" ]]; then
    printf 'local two-install stage mismatch: stage=%s result=%s passed=%s failed=%s total=%s\n' \
      "${test_name}" "${test_result}" "${passed_test_count}" "${failed_test_count}" "${total_test_count}" >&2
    return 1
  fi
}

cleanup() {
  local original_status="$?"
  local restore_status=0
  local simulator_id container
  if [[ "${cleanup_attempted}" == false ]]; then
    cleanup_attempted=true
    for simulator_id in "${receiver_simulator_id}" "${sender_simulator_id}"; do
      container="$(xcrun simctl get_app_container "${simulator_id}" "${app_bundle_id}" data)" || continue
      /usr/bin/python3 "${repo_root}/scripts/v2_app_work_state_snapshot.py" "${container}" \
        "${result_directory}/${simulator_id}-work-state.json" || true
    done
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
  restore_accessibility_profile || restore_status=1
  if [[ "${keep_result_bundle}" == true ]]; then
    printf 'preserving local two-install result bundles: %s\n' "${result_directory}" >&2
  else
    rm -rf -- "${result_directory}"
  fi
  if [[ "${original_status}" -eq 0 && "${restore_status}" -ne 0 ]]; then
    original_status="${restore_status}"
  fi
  exit "${original_status}"
}
trap cleanup EXIT

configure_accessibility_profile

launch_fixture "${receiver_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-e2e-scope "${receiver_scope}" \
  -v2-ui-testing-password-register \
  -v2-ui-testing-local-password localpassword \
  -v2-ui-testing-account-handle "${receiver_account_handle}" \
  -v2-ui-testing-public-handle "${receiver_public_handle}" \
  -v2-ui-testing-display-name 'Two install receiver' \
  -v2-ui-testing-group-title "${receiver_self_group_title}"
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
  -v2-ui-testing-e2e-scope "${receiver_scope}" \
  -v2-ui-testing-group-title "${receiver_group_title}" \
  -v2-ui-testing-group-members "@${sender_public_handle}" \
  -v2-ui-testing-message "${group_message}" \
  -v2-ui-testing-message-mentions "${group_message_mentions}"
run_stage "${receiver_simulator_id}" testReceiverRestoresScopedInstallationAndProjectsOfflineMessageThenSendsGroupMessage

launch_fixture "${receiver_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-restore-local-account \
  -v2-ui-testing-e2e-scope "${receiver_scope}" \
  -v2-ui-testing-group-title "${receiver_group_title}" \
  -v2-ui-testing-group-members "@${sender_public_handle}" \
  -v2-ui-testing-message "${group_message}" \
  -v2-ui-testing-message-mentions "${group_message_mentions}"
run_stage "${receiver_simulator_id}" testReceiverCreatesIndependentGroupAndSendsMessage

launch_fixture "${sender_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-restore-local-account \
  -v2-ui-testing-unavailable-realtime \
  -v2-ui-testing-e2e-scope "${sender_scope}"
run_stage "${sender_simulator_id}" testSenderQueuesDirectMessageWhileRealtimeEndpointIsUnavailable

launch_fixture "${sender_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-restore-local-account \
  -v2-ui-testing-e2e-scope "${sender_scope}"
run_stage "${sender_simulator_id}" testSenderRestoresIndependentGroupAndProjectsMessage

launch_fixture "${receiver_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-restore-local-account \
  -v2-ui-testing-e2e-scope "${receiver_scope}"
run_stage "${receiver_simulator_id}" testReceiverRestoresIndependentGroupMemberReply

if [[ "${audit_failure_count}" -gt 0 || "${withdrawal_failure_count}" -gt 0 ]]; then
  printf 'local two-install stages completed; overall FAILED with %s retained accessibility and %s direct withdrawal projection stage(s).\n' "${audit_failure_count}" "${withdrawal_failure_count}" >&2
  exit 1
fi
printf '%s\n' 'local two-install direct-and-group-message E2E: pass'
printf '%s\n' 'scope: two different booted simulators independently register real App installations; the receiver is terminated before the sender opens a direct room and sends through the ordinary UI, then restores its scoped Keychain/SQLite state to create a group containing the sender and send a group message with @all through the ordinary composer. The sender then restores the same SQLite state with a DEBUG-only unavailable realtime endpoint, submits one ordinary direct message and must receive the durable-retry UI feedback. A normal sender restore replays that exact queued message before it projects the group message with its mention summary and replies through the ordinary composer. The receiver finally restores only its own scope and projects both the group reply and the queued direct message after authenticated realtime catch-up. This does not cover APNs, production deployment, or capacity.'
