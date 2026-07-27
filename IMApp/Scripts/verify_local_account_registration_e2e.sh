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
scheme="${IMAPP_LOCAL_ACCOUNT_E2E_SCHEME:-IMAppLocalAccountE2E}"
destination_id="${IMAPP_LOCAL_ACCOUNT_E2E_SIMULATOR_ID:-}"
expected_test_count="${IMAPP_LOCAL_ACCOUNT_E2E_EXPECTED_TESTS:-9}"

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

require_command xcrun
require_command xcodebuild
require_command curl
require_command docker
require_command jq

if ! [[ "${expected_test_count}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'IMAPP_LOCAL_ACCOUNT_E2E_EXPECTED_TESTS must be a positive integer, got: %s\n' "${expected_test_count}" >&2
  exit 2
fi

if [[ -z "${destination_id}" ]]; then
  printf '%s\n' 'missing IMAPP_LOCAL_ACCOUNT_E2E_SIMULATOR_ID; choose an iOS 26.2+ simulator explicitly so this script never shuts down or restarts an unrelated simulator.' >&2
  exit 2
fi

if ! xcrun simctl list devices | grep -Fq "(${destination_id}) (Booted)"; then
  printf '%s\n' "selected simulator is not booted: ${destination_id}; boot and manually unlock that exact simulator first. This script will not boot, restart, erase, or shut down a simulator." >&2
  exit 2
fi

# Keychain items use `AfterFirstUnlockThisDeviceOnly`.  A simulator started by
# `simctl boot` stays protected until a person unlocks it once, even if XCTest
# can interact with the app UI.  There is no supported non-interactive API for
# bypassing that security boundary, so make the prerequisite explicit rather
# than turning its failure into a misleading account-service diagnosis.
printf '%s\n' 'preflight: ensure the selected simulator has been manually unlocked at least once since it was last booted, and that the Mac is unlocked.' >&2

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
  "https://localhost:8443/v2/account-auth/password/assertion")"
# The service deliberately rejects the malformed request with 400. This still
# proves that the simulator-facing local HTTPS edge and CA are usable.
[[ "${status}" == "400" ]] || { printf 'local HTTPS readiness returned %s, expected 400\n' "${status}" >&2; exit 1; }

# This alters only the explicitly selected simulator's trust store. It does
# not reset, shut down, erase, or otherwise touch any simulator lifecycle.
xcrun simctl keychain "${destination_id}" add-root-cert "${local_ca}"

result_directory="$(mktemp -d "${TMPDIR:-/tmp}/im-v2-local-account-e2e.XXXXXX")"
result_bundle="${result_directory}/result.xcresult"
trap 'rm -rf -- "${result_directory}"' EXIT

xcodebuild test \
  -project "${project_file}" \
  -scheme "${scheme}" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${destination_id}" \
  -only-testing:IMAppLocalAccountE2ETests/IMAppLocalAccountUITests \
  -resultBundlePath "${result_bundle}"

test_summary="$(xcrun xcresulttool get test-results summary --path "${result_bundle}" --compact)"
test_result="$(jq --raw-output '.result' <<<"${test_summary}")"
failed_test_count="$(jq --raw-output '.failedTests' <<<"${test_summary}")"
passed_test_count="$(jq --raw-output '.passedTests' <<<"${test_summary}")"
total_test_count="$(jq --raw-output '.totalTestCount' <<<"${test_summary}")"

if [[ "${test_result}" != "Passed" || "${failed_test_count}" != "0" || "${passed_test_count}" != "${expected_test_count}" || "${total_test_count}" != "${expected_test_count}" ]]; then
  printf 'local iOS account-and-delivery E2E result mismatch: result=%s passed=%s failed=%s total=%s expected=%s\n' \
    "${test_result}" "${passed_test_count}" "${failed_test_count}" "${total_test_count}" "${expected_test_count}" >&2
  exit 1
fi

printf 'local iOS account-and-delivery E2E: pass simulator=%s tests=%s\n' "${destination_id}" "${total_test_count}"
