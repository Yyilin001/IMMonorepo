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
if [[ "${IMAPP_LOCAL_TWO_INSTALL_READ_RECEIPT_ONLY:-false}" == true || "${IMAPP_LOCAL_TWO_INSTALL_GROUP_READ_ONLY:-false}" == true ]]; then
  export TEST_RUNNER_IMAPP_DIRECT_READ_RECEIPT_ONLY=1
fi
receiver_scope="$(uuidgen | tr '[:upper:]' '[:lower:]')"
sender_scope="$(uuidgen | tr '[:upper:]' '[:lower:]')"
receiver_account_handle="twor_${scenario_suffix:0:20}"
receiver_public_handle="twor${scenario_suffix:0:20}"
sender_account_handle="twos_${scenario_suffix:0:20}"
sender_public_handle="twos${scenario_suffix:0:20}"
message="two-install-${scenario_suffix:0:16}"
if [[ "${IMAPP_LOCAL_TWO_INSTALL_DIRECT_EDIT_ONLY:-false}" == true ]]; then
  export TEST_RUNNER_IMAPP_DIRECT_EDIT_ONLY=1
  export TEST_RUNNER_IMAPP_DIRECT_EDIT_EXPECTED="x${message}"
fi
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
background_fixture_directory=""
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
  local execution_allowance=300
  # Hundreds of genuine, remote accessibility checks are functional evidence;
  # the generic five-minute budget can cut off a progressing full-directory
  # scan. Keep its exact member assertions, with a bounded dedicated budget.
  case "${test_name}" in
    testFirstInstallationColdRestoresLargeMemberDirectory|testSecondInstallationLogsInAndReadsLargeMemberDirectory|testSecondInstallationColdRestoresLargeMemberDirectory)
      execution_allowance=600
      ;;
  esac

  printf 'running local two-install stage=%s simulator=%s\n' "${test_name}" "${simulator_id}"
  local xcode_status=0
  xcodebuild test \
    -quiet \
    -collect-test-diagnostics never \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "${execution_allowance}" \
    -maximum-test-execution-time-allowance "${execution_allowance}" \
    -project "${project_file}" \
    -scheme "${scheme}" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=${simulator_id}" \
    -only-testing:"${test_class}/${test_name}" \
    -resultBundlePath "${result_bundle}" &
  local test_pid="$!" deadline=$((SECONDS + execution_allowance + 60))
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
     jq --exit-status '(.testFailures | length) > 0 and all(.testFailures[]; .failureText == "Dynamic Type font sizes are partially unsupported" or .failureText == "Text clipped" or .failureText == "Hit area is too small" or .failureText == "Contrast failed")' <<<"${test_summary}" >/dev/null &&
     jq --exit-status '([.. | objects | select(.isAssociatedWithFailure == true) | .title // ""] | all(. == "" or . == "Dynamic Type font sizes are partially unsupported" or . == "Text clipped" or . == "Hit area is too small" or . == "Contrast failed")) and ([.. | objects | .title?] | any(. == "two-install-functional-stage-complete"))' <<<"${test_activities}" >/dev/null; then
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
  if [[ -n "${background_fixture_directory}" && "${background_fixture_directory}" == */"File Provider Storage/IMV2-Background-${scenario_suffix}" ]]; then
    rm -rf -- "${background_fixture_directory}"
  fi
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

if [[ "${IMAPP_LOCAL_TWO_INSTALL_BACKGROUND_UPLOAD_ONLY:-false}" == true ]]; then
  [[ "${external_stack}" == true ]] || exit 1
  : "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT:?owned PG port required}"
  : "${IMAPP_BACKGROUND_FIXTURE_TOKEN:?owned fixture token required}"
  # This Xcode's advertised individual-group form returns usage/117. Select
  # the exact group from the supported tab-separated inventory instead.
  provider="$(xcrun simctl get_app_container "${receiver_simulator_id}" com.apple.DocumentsApp groups | /usr/bin/python3 -c 'import sys; rows=[line.rstrip("\n").split("\t",1) for line in sys.stdin]; paths=[row[1] for row in rows if len(row)==2 and row[0]=="group.com.apple.FileProvider.LocalStorage"]; assert len(paths)==1; print(paths[0])')"
  background_fixture_directory="${provider}/File Provider Storage/IMV2-Background-${scenario_suffix}"
  /usr/bin/python3 - "${repo_root}" "${background_fixture_directory}" "${receiver_simulator_id}" <<'PY'
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / 'IMV2/scripts'))
from v2_native_background_upload_gate import BACKGROUND_FIXTURE_BYTES
directory = pathlib.Path(sys.argv[2]).resolve()
assert sys.argv[3] in directory.parts and directory.parent.name == 'File Provider Storage'
assert directory.name.startswith('IMV2-Background-')
directory.mkdir(exist_ok=False)
(directory / 'background-upload.txt').write_bytes(BACKGROUND_FIXTURE_BYTES)
PY
  export TEST_RUNNER_IMAPP_BACKGROUND_FIXTURE_TOKEN="${IMAPP_BACKGROUND_FIXTURE_TOKEN}"
  export TEST_RUNNER_IMAPP_BACKGROUND_GROUP_TITLE="${receiver_self_group_title}"
  export TEST_RUNNER_IMAPP_BACKGROUND_FILE_FOLDER="IMV2-Background-${scenario_suffix}"
  export TEST_RUNNER_IMAPP_BACKGROUND_MESSAGE_TEXT="background-upload-${scenario_suffix}"
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testRealAppUploadsAttachmentWhileSuspended
  /opt/homebrew/opt/postgresql@16/bin/psql -X -A -t -h 127.0.0.1 -p "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT}" -U imv2_e2e -d imv2_e2e -v ON_ERROR_STOP=1 -c "SELECT json_build_object('count',count(*),'messageID',min(message_id::text),'withdrawn',coalesce(bool_or(withdrawn_at IS NOT NULL),false),'completedUploads',(SELECT count(*) FROM im_v2.resource_upload_sessions WHERE state='completed'),'availableMedia',(SELECT count(*) FROM im_v2.media_objects WHERE state='available'))::text FROM im_v2.messages" > "${result_directory}/background-message-facts.json"
  jq --exit-status '.count == 1 and .withdrawn == false and .completedUploads == 1 and .availableMedia == 1' "${result_directory}/background-message-facts.json" >/dev/null
  export TEST_RUNNER_IMAPP_BACKGROUND_MESSAGE_ID="$(jq --raw-output '.messageID' "${result_directory}/background-message-facts.json")"
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testRealAppColdRestoresBackgroundAttachment
  curl --fail --silent --show-error --cacert "${local_ca}" --header "X-Background-Fixture: ${IMAPP_BACKGROUND_FIXTURE_TOKEN}" 'https://localhost:8443/__fixture__/background-upload/state' > "${result_directory}/background-upload-observation.json"
  jq --exit-status '.hits == 1 and .completed == 1 and .status >= 200 and .status < 300 and .readBytes == 524288 and .checksumMatches and .released and .durableActiveMappings == 1 and (.expired | not)' "${result_directory}/background-upload-observation.json" >/dev/null
  if [[ "${audit_failure_count}" -gt 0 ]]; then printf '%s\n' 'App native background upload stages complete; retained accessibility failure.' >&2; exit 1; fi
  printf '%s\n' 'local App native background upload E2E: pass'
  exit 0
fi

if [[ "${IMAPP_LOCAL_TWO_INSTALL_MEMBER_DIRECTORY_ONLY:-false}" == true ]]; then
  [[ "${external_stack}" == true ]] || exit 1
  : "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT:?owned PG port required}"
  directory_sql() {
    /opt/homebrew/opt/postgresql@16/bin/psql -X -A -t -h 127.0.0.1 -p "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT}" -U imv2_e2e -d imv2_e2e -v ON_ERROR_STOP=1 -c "$1"
  }
  directory_room="$(directory_sql "SELECT room_id FROM im_v2.group_rooms WHERE title='${receiver_self_group_title}'")"
  [[ "${directory_room}" =~ ^[0-9a-fA-F-]{36}$ ]] || exit 1
  # Only the pagination population is seeded. The account, room creation,
  # device login and every App directory read use their normal public paths.
  directory_sql "BEGIN; CREATE TEMP TABLE directory_seed ON COMMIT DROP AS SELECT md5('${directory_room}' || i::text)::uuid AS user_id,'目录成员' || lpad(i::text,4,'0') AS name FROM generate_series(1,257) i;
    INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) SELECT user_id,replace(user_id::text,'-',''),name,now(),now() FROM directory_seed;
    UPDATE im_v2.rooms SET membership_revision=membership_revision+1 WHERE room_id='${directory_room}';
    INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role) SELECT '${directory_room}',s.user_id,r.membership_revision,'member' FROM directory_seed s CROSS JOIN im_v2.rooms r WHERE r.room_id='${directory_room}';
    INSERT INTO im_v2.room_member_nicknames(room_id,user_id,nickname,revision,updated_at) SELECT '${directory_room}',user_id,name,1,now() FROM directory_seed;
    UPDATE im_v2.room_admission SET eligible_member_count=258 WHERE room_id='${directory_room}'; COMMIT;" > "${result_directory}/directory-seed.log"
  directory_sql "SELECT json_object_agg(upper(m.user_id::text),coalesce(n.nickname,p.display_name)) FROM im_v2.room_memberships m JOIN im_v2.public_user_profiles p USING(user_id) LEFT JOIN im_v2.room_member_nicknames n ON n.room_id=m.room_id AND n.user_id=m.user_id WHERE m.room_id='${directory_room}' AND m.left_revision IS NULL" > "${result_directory}/directory-members.json"
  jq --exit-status 'length == 258' "${result_directory}/directory-members.json" >/dev/null
  export TEST_RUNNER_IMAPP_DIRECTORY_GROUP_TITLE="${receiver_self_group_title}"
  export TEST_RUNNER_IMAPP_DIRECTORY_MEMBERS="$(cat "${result_directory}/directory-members.json")"
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testFirstInstallationColdRestoresLargeMemberDirectory
  launch_fixture "${sender_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-e2e-scope "${sender_scope}" -v2-ui-testing-local-password localpassword -v2-ui-testing-account-handle "${receiver_account_handle}"
  run_stage "${sender_simulator_id}" testSecondInstallationLogsInAndReadsLargeMemberDirectory
  launch_fixture "${sender_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${sender_scope}"
  run_stage "${sender_simulator_id}" testSecondInstallationColdRestoresLargeMemberDirectory
  directory_sql "SELECT json_build_object('devices',count(*)) FROM im_v2.auth_devices WHERE user_id=(SELECT user_id FROM im_v2.account_password_credentials WHERE account_handle='${receiver_account_handle}') AND revoked_at IS NULL" > "${result_directory}/directory-device-facts.json"
  jq --exit-status '.devices == 2' "${result_directory}/directory-device-facts.json" >/dev/null
  if [[ "${audit_failure_count}" -gt 0 ]]; then printf '%s\n' 'App member directory stages complete; retained accessibility failure.' >&2; exit 1; fi
  printf '%s\n' 'local App member directory E2E: pass'
  exit 0
fi

if [[ "${IMAPP_LOCAL_TWO_INSTALL_CREDENTIAL_REFRESH_ONLY:-false}" == true ]]; then
  [[ "${external_stack}" == true ]] || { printf '%s\n' 'credential refresh mode requires the owned native stack.' >&2; exit 1; }
  : "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT:?owned PG port required}"
  refresh_facts() {
    local phase="$1"
    /opt/homebrew/opt/postgresql@16/bin/psql -X -A -t -h 127.0.0.1 -p "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT}" -U imv2_e2e -d imv2_e2e -c "SELECT json_build_object('devices',count(*),'deviceID',min(s.device_id::text),'generation',max(s.family_generation),'refreshOperations',(SELECT count(*) FROM im_v2.device_credential_operations o JOIN im_v2.account_password_credentials p USING(user_id) WHERE p.account_handle='${receiver_account_handle}' AND o.operation_kind='refresh'),'history',(SELECT count(*) FROM im_v2.device_refresh_token_history h JOIN im_v2.account_password_credentials p USING(user_id) WHERE p.account_handle='${receiver_account_handle}'))::text FROM im_v2.device_refresh_sessions s JOIN im_v2.account_password_credentials p USING(user_id) WHERE p.account_handle='${receiver_account_handle}'" > "${result_directory}/${phase}-credential-facts.json"
  }
  refresh_control() {
    curl --fail --silent --show-error --cacert "${local_ca}" --request POST --data '' "https://localhost:8443/__fixture__/app-refresh-$1" > "${result_directory}/$1-refresh-control.json"
  }
  refresh_facts before
  jq --exit-status '.devices == 1 and .generation == 1 and .refreshOperations == 0 and .history == 0' "${result_directory}/before-credential-facts.json" >/dev/null
  export TEST_RUNNER_IMAPP_REFRESH_DEVICE_ID="$(jq --raw-output '.deviceID' "${result_directory}/before-credential-facts.json")"
  if [[ "${IMAPP_LOCAL_TWO_INSTALL_NATURAL_EXPIRY:-false}" == true ]]; then
    if ! xcrun simctl terminate "${receiver_simulator_id}" "${app_bundle_id}" > "${result_directory}/natural-expiry-terminate.log" 2>&1; then
      # XCTest normally closes its App after the registration stage. That
      # already-stopped result is harmless; preserve any other simctl error.
      if ! rg --quiet 'found nothing to terminate' "${result_directory}/natural-expiry-terminate.log"; then
        cat "${result_directory}/natural-expiry-terminate.log" >&2
        exit 1
      fi
    fi
    expired=false
    for attempt in {1..96}; do
      /opt/homebrew/opt/postgresql@16/bin/psql -X -A -t -h 127.0.0.1 -p "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT}" -U imv2_e2e -d imv2_e2e -c "SELECT json_build_object('tokens',count(*),'expired',coalesce(bool_and(t.expires_at <= CURRENT_TIMESTAMP),false),'remainingSeconds',greatest(0,ceil(extract(epoch FROM max(t.expires_at)-CURRENT_TIMESTAMP))))::text FROM im_v2.device_access_tokens t JOIN im_v2.account_password_credentials p USING(user_id) WHERE p.account_handle='${receiver_account_handle}'" > "${result_directory}/natural-expiry-facts.json"
      jq --exit-status '.tokens == 1' "${result_directory}/natural-expiry-facts.json" >/dev/null
      if jq --exit-status '.expired == true' "${result_directory}/natural-expiry-facts.json" >/dev/null; then expired=true; break; fi
      if (( attempt % 6 == 1 )); then printf 'waiting for real credential expiry: %s seconds remaining\n' "$(jq '.remainingSeconds' "${result_directory}/natural-expiry-facts.json")"; fi
      sleep 10
    done
    [[ "${expired}" == true ]] || { printf '%s\n' 'real access token did not expire within bounded observation.' >&2; exit 1; }
    refresh_facts expired
    jq --exit-status '.generation == 1 and .refreshOperations == 0 and .history == 0' "${result_directory}/expired-credential-facts.json" >/dev/null
  else
    refresh_control arm
  fi
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  if [[ "${IMAPP_LOCAL_TWO_INSTALL_NATURAL_EXPIRY:-false}" == true ]]; then
    run_stage "${receiver_simulator_id}" testRealAppRotatesNaturallyExpiredCredentials
  else
    run_stage "${receiver_simulator_id}" testRealAppRotatesCredentialsAfterBusinessHTTPUnauthorized
  fi
  refresh_facts rotated
  jq --exit-status '.devices == 1 and .generation == 2 and .refreshOperations == 1 and .history == 1' "${result_directory}/rotated-credential-facts.json" >/dev/null
  refresh_control cold
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testRealAppColdRestoreUsesRotatedCredentials
  refresh_facts cold
  jq --exit-status '.devices == 1 and .generation == 2 and .refreshOperations == 1 and .history == 1' "${result_directory}/cold-credential-facts.json" >/dev/null
  curl --fail --silent --show-error --cacert "${local_ca}" 'https://localhost:8443/__fixture__/app-refresh-status' > "${result_directory}/refresh-status.json"
  expected_injected=1
  if [[ "${IMAPP_LOCAL_TWO_INSTALL_NATURAL_EXPIRY:-false}" == true ]]; then expected_injected=0; fi
  jq --exit-status --argjson expected "${expected_injected}" '.injected == $expected and .refreshResponses == 1 and .coldFreshDeviceReads > 0' "${result_directory}/refresh-status.json" >/dev/null
  if [[ "${audit_failure_count}" -gt 0 ]]; then
    printf '%s\n' 'App credential refresh stages complete; retained accessibility failure.' >&2
    exit 1
  fi
  printf '%s\n' 'local App credential refresh E2E: pass'
  exit 0
fi

if [[ "${IMAPP_LOCAL_TWO_INSTALL_GROUP_JOIN_ONLY:-false}" == true ]]; then
  [[ "${external_stack}" == true ]] || { printf '%s\n' 'group join mode requires the owned native stack.' >&2; exit 1; }
  : "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT:?owned PG port required}"
  export TEST_RUNNER_IMAPP_JOIN_OWNER_GROUP="${receiver_self_group_title}"
  join_facts() {
    local phase="$1"
    /opt/homebrew/opt/postgresql@16/bin/psql -X -A -t -h 127.0.0.1 -p "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT}" -U imv2_e2e -d imv2_e2e -c "SELECT json_build_object('pending',count(*) FILTER (WHERE r.state='pending'),'cancelled',count(*) FILTER (WHERE r.state='cancelled'),'approved',count(*) FILTER (WHERE r.state='approved'),'rejected',count(*) FILTER (WHERE r.state='rejected'),'activeInvites',(SELECT count(*) FROM im_v2.group_invite_links i WHERE i.room_id=g.room_id AND i.state='active'),'members',(SELECT count(*) FROM im_v2.room_memberships m WHERE m.room_id=g.room_id AND m.left_revision IS NULL),'messages',(SELECT count(*) FROM im_v2.messages msg WHERE msg.room_id=g.room_id))::text FROM im_v2.group_rooms g LEFT JOIN im_v2.group_join_requests r ON r.room_id=g.room_id WHERE g.title='${receiver_self_group_title}' GROUP BY g.room_id" > "${result_directory}/${phase}-join-facts.json"
  }
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testGroupOwnerCreatesInvitationQRCode
  xcrun xcresulttool export attachments --path "${result_directory}/${receiver_simulator_id}-testGroupOwnerCreatesInvitationQRCode.xcresult" --output-path "${result_directory}/invite-qr-attachments" >/dev/null
  cat > "${result_directory}/read-invite-qr.swift" <<'SWIFT'
import Foundation
import Vision
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
var links = Set<String>()
for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension.lowercased() == "png" {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try VNImageRequestHandler(url: file).perform([request])
    for result in request.results ?? [] {
        if let value = result.payloadStringValue, let url = URL(string: value), url.scheme == "iim", url.host == "group-invite" { links.insert(value) }
    }
}
guard links.count == 1, let link = links.first else { fatalError("expected one actual App invitation QR") }
try link.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
SWIFT
  swift "${result_directory}/read-invite-qr.swift" "${result_directory}/invite-qr-attachments" "${result_directory}/invite-link.txt"
  chmod 600 "${result_directory}/invite-link.txt"
  launch_fixture "${sender_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-e2e-scope "${sender_scope}" -v2-ui-testing-password-register -v2-ui-testing-local-password localpassword -v2-ui-testing-account-handle "${sender_account_handle}" -v2-ui-testing-public-handle "${sender_public_handle}" -v2-ui-testing-display-name 'Two install applicant'
  run_stage "${sender_simulator_id}" testApplicantRegistersForGroupInvitation
  open_applicant_invite() {
    launch_fixture "${sender_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${sender_scope}"
    xcrun simctl pbcopy "${sender_simulator_id}" < "${result_directory}/invite-link.txt"
  }
  open_applicant_invite
  run_stage "${sender_simulator_id}" testApplicantSubmitsActualGroupJoinRequest
  join_facts first-pending
  jq --exit-status '.pending == 1 and .members == 1' "${result_directory}/first-pending-join-facts.json" >/dev/null
  if [[ "${IMAPP_LOCAL_TWO_INSTALL_GROUP_JOIN_REJECT_ONLY:-false}" == true ]]; then
    launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
    run_stage "${receiver_simulator_id}" testGroupOwnerRejectsActualJoinRequest
    join_facts rejected
    jq --exit-status '.rejected == 1 and .approved == 0 and .pending == 0 and .members == 1' "${result_directory}/rejected-join-facts.json" >/dev/null
    open_applicant_invite
    run_stage "${sender_simulator_id}" testApplicantRestoresActualRejectedJoinRequest
    launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
    run_stage "${receiver_simulator_id}" testGroupOwnerRevokesActualInvitation
    join_facts revoked
    jq --exit-status '.activeInvites == 0 and .rejected == 1 and .members == 1' "${result_directory}/revoked-join-facts.json" >/dev/null
    open_applicant_invite
    run_stage "${sender_simulator_id}" testApplicantCannotPreviewActualRevokedInvitation
    if [[ "${audit_failure_count}" -gt 0 ]]; then
      printf '%s\n' 'group join rejection functional stages complete; retained accessibility failure.' >&2
      exit 1
    fi
    printf '%s\n' 'local group join rejection E2E: pass'
    exit 0
  fi
  open_applicant_invite
  run_stage "${sender_simulator_id}" testApplicantCancelsActualGroupJoinRequest
  join_facts cancelled
  jq --exit-status '.pending == 0 and .cancelled == 1 and .members == 1' "${result_directory}/cancelled-join-facts.json" >/dev/null
  open_applicant_invite
  run_stage "${sender_simulator_id}" testApplicantResubmitsAfterActualCancellation
  join_facts resubmitted
  jq --exit-status '.pending == 1 and .cancelled == 1 and .members == 1' "${result_directory}/resubmitted-join-facts.json" >/dev/null
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testGroupOwnerApprovesActualJoinRequest
  join_facts approved
  jq --exit-status '.approved == 1 and .pending == 0 and .members == 2' "${result_directory}/approved-join-facts.json" >/dev/null
  open_applicant_invite
  if [[ "${IMAPP_LOCAL_TWO_INSTALL_GROUP_JOIN_COLD_SEND_ONLY:-false}" == true ]]; then
    run_stage "${sender_simulator_id}" testApplicantRestoresApprovedGroupAndPersistsSend
    send_confirmation_deadline=$((SECONDS + 30))
    while true; do
      join_facts send-confirmation
      if jq --exit-status '.messages == 1' "${result_directory}/send-confirmation-join-facts.json" >/dev/null; then break; fi
      [[ "${SECONDS}" -lt "${send_confirmation_deadline}" ]] || { printf '%s\n' 'original member send was not accepted by PG within 30 seconds.' >&2; exit 1; }
      sleep 0.25
    done
    send_container="$(xcrun simctl get_app_container "${sender_simulator_id}" "${app_bundle_id}" data)"
    while true; do
      /usr/bin/python3 "${repo_root}/scripts/v2_app_work_state_snapshot.py" "${send_container}" "${result_directory}/pre-cold-send-work.json"
      if jq --exit-status '[.[].work[] | select(.operation_kind == "sendMessage")] | length == 1 and all(.[]; .execution_state == "committed" and .scheduling_state == "finished")' "${result_directory}/pre-cold-send-work.json" >/dev/null; then break; fi
      [[ "${SECONDS}" -lt "${send_confirmation_deadline}" ]] || { printf '%s\n' 'original member send local work was not committed within 30 seconds.' >&2; exit 1; }
      sleep 0.25
    done
    launch_fixture "${sender_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${sender_scope}"
    run_stage "${sender_simulator_id}" testApplicantColdRestoresCanonicalApprovedMemberMessage
  else
    run_stage "${sender_simulator_id}" testApplicantRestoresApprovedGroupAndSendsMessage
  fi
  join_facts joined-message
  jq --exit-status '.approved == 1 and .members == 2 and .messages == 1' "${result_directory}/joined-message-join-facts.json" >/dev/null
  if [[ "${audit_failure_count}" -gt 0 ]]; then
    printf '%s\n' 'group join approval functional stages complete; retained accessibility failure.' >&2
    exit 1
  fi
  printf '%s\n' 'local group join approval E2E: pass'
  exit 0
fi

if [[ "${IMAPP_LOCAL_TWO_INSTALL_ACCOUNT_SWITCH_ONLY:-false}" == true ]]; then
  export TEST_RUNNER_IMAPP_ACCOUNT_SWITCH_SCOPE="${receiver_scope}"
  export TEST_RUNNER_IMAPP_ACCOUNT_SWITCH_FIRST_HANDLE="${receiver_account_handle}"
  export TEST_RUNNER_IMAPP_ACCOUNT_SWITCH_FIRST_GROUP="${receiver_self_group_title}"
  export TEST_RUNNER_IMAPP_ACCOUNT_SWITCH_SECOND_HANDLE="${IMAPP_LOCAL_TWO_INSTALL_SWITCH_SECOND_HANDLE:?registered account B required}"
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testAccountSwitchAndColdRestoreKeepProjectionsIsolated
  if [[ "${audit_failure_count}" -gt 0 ]]; then
    printf '%s\n' 'account-switch functional stages complete; retained accessibility failure.' >&2
    exit 1
  fi
  printf '%s\n' 'local account-switch isolation E2E: pass'
  exit 0
fi

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

if [[ "${IMAPP_LOCAL_TWO_INSTALL_DIRECT_EDIT_ONLY:-false}" == true ]]; then
  : "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT:?owned PG port required}"
  for attempt in {1..120}; do
    /opt/homebrew/opt/postgresql@16/bin/psql -X -A -t -h 127.0.0.1 -p "${IMAPP_LOCAL_TWO_INSTALL_PG_PORT}" -U imv2_e2e -d imv2_e2e -c "SELECT json_build_object('count',count(*),'messageID',min(message_id::text),'revision',max(content_revision),'withdrawn',coalesce(bool_or(withdrawn_at IS NOT NULL),false),'editedEvents',(SELECT count(*) FROM im_v2.room_events WHERE event_type='message.edited'))::text FROM im_v2.messages" > "${result_directory}/edited-message-facts.json"
    if jq --exit-status '.count == 1 and .revision == 2 and .withdrawn == false and .editedEvents == 1' "${result_directory}/edited-message-facts.json" >/dev/null; then break; fi
    sleep 0.25
  done
  jq --exit-status '.count == 1 and .revision == 2 and .withdrawn == false and .editedEvents == 1' "${result_directory}/edited-message-facts.json" >/dev/null
  export TEST_RUNNER_IMAPP_DIRECT_EDIT_MESSAGE_ID="$(jq --raw-output '.messageID' "${result_directory}/edited-message-facts.json")"
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testReceiverColdRestoreProjectsIndependentEditBeforeWithdrawal
  if [[ "${audit_failure_count}" -gt 0 ]]; then
    printf '%s\n' 'direct edit stages complete; retained accessibility failure.' >&2
    exit 1
  fi
  printf '%s\n' 'local direct edit cold restoration E2E: pass'
  exit 0
fi

if [[ "${IMAPP_LOCAL_TWO_INSTALL_READ_RECEIPT_ONLY:-false}" == true ]]; then
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testReceiverProjectsDirectMessageAndReportsRead
  launch_fixture "${sender_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${sender_scope}"
  run_stage "${sender_simulator_id}" testSenderColdRestoreProjectsPeerRead
  if [[ "${audit_failure_count}" -gt 0 ]]; then
    printf '%s\n' 'direct peer-read functional stages complete; retained accessibility failure.' >&2
    exit 1
  fi
  printf '%s\n' 'local direct peer-read E2E: pass'
  exit 0
fi

launch_fixture "${receiver_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-restore-local-account \
  -v2-ui-testing-e2e-scope "${receiver_scope}" \
  -v2-ui-testing-group-title "${receiver_group_title}" \
  -v2-ui-testing-group-members "@${sender_public_handle}" \
  -v2-ui-testing-message "${group_message}" \
  -v2-ui-testing-message-mentions "${group_message_mentions}"
if [[ "${IMAPP_LOCAL_TWO_INSTALL_GROUP_READ_ONLY:-false}" == true ]]; then
  run_stage "${receiver_simulator_id}" testReceiverProjectsDirectMessageAndReportsRead
else
  run_stage "${receiver_simulator_id}" testReceiverRestoresScopedInstallationAndProjectsOfflineMessageThenSendsGroupMessage
fi

launch_fixture "${receiver_simulator_id}" \
  -v2-ui-testing-live-local-account \
  -v2-ui-testing-restore-local-account \
  -v2-ui-testing-e2e-scope "${receiver_scope}" \
  -v2-ui-testing-group-title "${receiver_group_title}" \
  -v2-ui-testing-group-members "@${sender_public_handle}" \
  -v2-ui-testing-message "${group_message}" \
  -v2-ui-testing-message-mentions "${group_message_mentions}"
run_stage "${receiver_simulator_id}" testReceiverCreatesIndependentGroupAndSendsMessage

if [[ "${IMAPP_LOCAL_TWO_INSTALL_GROUP_READ_ONLY:-false}" == true ]]; then
  launch_fixture "${sender_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${sender_scope}"
  run_stage "${sender_simulator_id}" testSenderRestoresIndependentGroupAndProjectsMessage
  launch_fixture "${receiver_simulator_id}" -v2-ui-testing-live-local-account -v2-ui-testing-restore-local-account -v2-ui-testing-e2e-scope "${receiver_scope}"
  run_stage "${receiver_simulator_id}" testGroupOwnerProjectsActualMemberReadReceipts
  if [[ "${audit_failure_count}" -gt 0 || "${withdrawal_failure_count}" -gt 0 ]]; then
    printf '%s\n' 'group readers functional stages complete; retained acceptance failures.' >&2
    exit 1
  fi
  printf '%s\n' 'local group readers E2E: pass'
  exit 0
fi

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
