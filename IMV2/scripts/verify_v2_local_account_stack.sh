#!/usr/bin/env bash
set -Eeuo pipefail

# Non-destructive smoke test for the local-only V2 account stack. It proves
# that the Caddy HTTPS edge, password fallback and device credential issuer
# are connected without printing an assertion, access token or refresh token.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${v2_dir}/.." && pwd)"
ca_path="${V2_LOCAL_CA_PATH:-${v2_dir}/local-ca/root.crt}"
compose_file="${V2_LOCAL_COMPOSE_FILE:-${v2_dir}/docker-compose.local-account.yml}"
env_file="${V2_LOCAL_ENV_FILE:-${v2_dir}/.env.local}"
compose_project="${V2_LOCAL_COMPOSE_PROJECT:-imv2localaccount}"
account_base_url="${V2_LOCAL_HTTP_BASE_URL:-https://localhost:8443}"
gateway_probe_account_base_url="${V2_LOCAL_GATEWAY_PROBE_ACCOUNT_BASE_URL:-${account_base_url}}"
gateway_tls_address="${V2_LOCAL_GATEWAY_TLS_ADDRESS:-localhost:7443}"
registration_recovery_directory="${V2_LOCAL_REGISTRATION_RECOVERY_DIRECTORY:-${v2_dir}/local-ca/registration-recovery}"
busy_term_fixture="${V2_LOCAL_BUSY_TERM_FIXTURE_PATH:-}"
busy_term_release="${V2_LOCAL_BUSY_TERM_RELEASE_PATH:-}"
cross_entry_fixture="${V2_LOCAL_CROSS_ENTRY_FIXTURE_PATH:-}"
cross_entry_warm_release="${V2_LOCAL_CROSS_ENTRY_WARM_RELEASE_PATH:-}"
cross_entry_disable_ready="${V2_LOCAL_CROSS_ENTRY_DISABLE_READY_PATH:-}"
cross_entry_disable_release="${V2_LOCAL_CROSS_ENTRY_DISABLE_RELEASE_PATH:-}"
cross_entry_disabled="${V2_LOCAL_CROSS_ENTRY_DISABLED_PATH:-}"
remote_batch_fixture="${V2_LOCAL_REMOTE_BATCH_FIXTURE_PATH:-}"
remote_batch_release="${V2_LOCAL_REMOTE_BATCH_RELEASE_PATH:-}"
phase="preflight"

source "${script_dir}/local_compose.sh"

compose() {
  v2_local_compose "${env_file}" --project-name "${compose_project}" --file "${compose_file}" "$@"
}

report_failure() {
  local exit_status="$?"
  # Do not print BASH_COMMAND here: registration, credential exchange, and
  # Push requests may contain short-lived secrets in their command arguments.
  printf 'local account stack verification failed during %s (exit %s)\n' "${phase}" "${exit_status}" >&2
}
trap report_failure ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for command in curl jq openssl uuidgen docker python3; do
  require_command "${command}"
done

test -f "${ca_path}" || {
  printf 'missing local CA: start the stack first with %s\n' "${script_dir}/run_v2_local_account_stack.sh" >&2
  exit 1
}

# Caddy's internal development leaves are short-lived. The long-running native
# gateway reads its PEM files only at process startup, so Caddy can renew the
# file while the gateway continues presenting the expired in-memory leaf.
# Validate the actual public gateway handshake first; on this local-only
# Compose stack, refresh only Caddy and the gateway, never PostgreSQL or the
# account service. This keeps a long-lived developer stack usable without
# concealing a certificate failure from the black-box probe.
gateway_tls_is_usable() {
  compose exec -T gateway sh -c '
    openssl s_client \
      -connect 127.0.0.1:7443 \
      -servername localhost \
      -CAfile /caddy/caddy/pki/authorities/local/root.crt \
      -verify_return_error \
      </dev/null >/dev/null 2>&1
  '
}

refresh_local_gateway_tls() {
  compose up -d --force-recreate caddy
  for _ in {1..30}; do
    if compose cp caddy:/data/caddy/pki/authorities/local/root.crt "${ca_path}" >/dev/null 2>&1 &&
      compose exec -T gateway test -s /caddy/caddy/certificates/local/localhost/localhost.crt &&
      compose exec -T gateway test -s /caddy/caddy/certificates/local/localhost/localhost.key; then
      break
    fi
    sleep 1
  done
  test -s "${ca_path}" || {
    printf 'local Caddy did not expose its CA while refreshing the gateway certificate\n' >&2
    exit 1
  }
  compose up -d --wait --force-recreate gateway
}

phase="gateway TLS readiness"
if ! gateway_tls_is_usable; then
  phase="gateway TLS certificate refresh"
  refresh_local_gateway_tls
  phase="gateway TLS readiness after refresh"
  gateway_tls_is_usable || {
    printf 'local gateway TLS verification still fails after refreshing its Caddy certificate\n' >&2
    exit 1
  }
fi

phase="invalid-request rejection"
invalid_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{}' \
  "${account_base_url}/v2/account-auth/password/assertion")"
test "${invalid_status}" = '400' || {
  printf 'unexpected invalid account request status: %s\n' "${invalid_status}" >&2
  exit 1
}

suffix="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
account_handle="smoke-${suffix:0:20}"
public_handle="smoke${suffix:0:20}"
device_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

phase="password registration"
assertion="$(curl --silent --show-error --fail \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountHandle\":\"${account_handle}\",\"password\":\"v2-local-smoke-password\",\"deviceID\":\"${device_id}\",\"publicHandle\":\"${public_handle}\",\"displayName\":\"Local Smoke\"}" \
  "${account_base_url}/v2/account-auth/password/register" | jq -er '.accountAssertion')"

# Exercise the real HTTPS route, PostgreSQL persistence and configured policy as
# one path. The rate-limited account is separate from the credential smoke
# account so the subsequent trusted-device flow remains independent.
rate_limit_handle="rate-${suffix:0:20}"
rate_limit_public_handle="rate${suffix:0:20}"
rate_limit_device_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
rate_limit_password="v2-local-rate-limit-password"
wrong_rate_limit_password="v2-local-wrong-password"

phase="password rate-limit registration"
rate_limit_registration_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountHandle\":\"${rate_limit_handle}\",\"password\":\"${rate_limit_password}\",\"deviceID\":\"${rate_limit_device_id}\",\"publicHandle\":\"${rate_limit_public_handle}\",\"displayName\":\"Local Rate Limit\"}" \
  "${account_base_url}/v2/account-auth/password/register")"
test "${rate_limit_registration_status}" = '200' || {
  printf 'unexpected password rate-limit registration status: %s\n' "${rate_limit_registration_status}" >&2
  exit 1
}

for _ in {1..5}; do
  phase="password rate-limit rejection"
  rejected_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "${ca_path}" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "{\"accountHandle\":\"${rate_limit_handle}\",\"password\":\"${wrong_rate_limit_password}\",\"deviceID\":\"${rate_limit_device_id}\"}" \
    "${account_base_url}/v2/account-auth/password/assertion")"
  test "${rejected_status}" = '401' || {
    printf 'unexpected password rejection status before lockout: %s\n' "${rejected_status}" >&2
    exit 1
  }
done

rate_limit_headers="$(mktemp)"
trap 'rm -f -- "${rate_limit_headers}"' EXIT
phase="password rate-limit lockout"
rate_limit_status="$(curl --silent --show-error --output /dev/null --dump-header "${rate_limit_headers}" --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountHandle\":\"${rate_limit_handle}\",\"password\":\"${wrong_rate_limit_password}\",\"deviceID\":\"${rate_limit_device_id}\"}" \
  "${account_base_url}/v2/account-auth/password/assertion")"
test "${rate_limit_status}" = '429' || {
  printf 'unexpected password rate-limit status: %s\n' "${rate_limit_status}" >&2
  exit 1
}
grep -Eiq '^cache-control:.*no-store' "${rate_limit_headers}" || {
  printf 'password rate-limit response omitted no-store cache control\n' >&2
  exit 1
}
grep -Eiq '^pragma:.*no-cache' "${rate_limit_headers}" || {
  printf 'password rate-limit response omitted no-cache pragma\n' >&2
  exit 1
}
grep -Eiq '^retry-after:[[:space:]]*[1-9][0-9]*' "${rate_limit_headers}" || {
  printf 'password rate-limit response omitted a positive Retry-After value\n' >&2
  exit 1
}

phase="device credential issuance"
cancellation="$(python3 "${script_dir}/prepare_v2_registration_cancellation.py" \
  "${device_id}" "${operation_id}" "${registration_recovery_directory}")"
issued_credentials="$(curl --silent --show-error --fail \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountAssertion\":\"${assertion}\",\"deviceID\":\"${device_id}\",\"operationID\":\"${operation_id}\",\"cancellation\":${cancellation}}" \
  "${account_base_url}/v2/device-credentials")"
access_token="$(printf '%s' "${issued_credentials}" | jq -er '.accessToken')"
refresh_credential="$(printf '%s' "${issued_credentials}" | jq -er '.refreshCredential')"
revocation_credential="$(printf '%s' "${issued_credentials}" | jq -er '.revocationCredential')"
printf '%s' "${issued_credentials}" | jq -e --argjson expected "${cancellation}" '.registrationCancellation == $expected' > /dev/null
user_id="$(printf '%s' "${issued_credentials}" | jq -er '.userID')"

# Register an independent recipient. It gives the gateway probe a real direct
# room target and keeps the later account-disable assertions scoped to the
# original smoke account.
peer_account_handle="peer-${suffix:0:20}"
peer_public_handle="peer${suffix:0:20}"
peer_device_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
peer_operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

phase="peer password registration"
peer_assertion="$(curl --silent --show-error --fail \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountHandle\":\"${peer_account_handle}\",\"password\":\"v2-local-peer-password\",\"deviceID\":\"${peer_device_id}\",\"publicHandle\":\"${peer_public_handle}\",\"displayName\":\"Local Peer\"}" \
  "${account_base_url}/v2/account-auth/password/register" | jq -er '.accountAssertion')"

phase="peer device credential issuance"
peer_cancellation="$(python3 "${script_dir}/prepare_v2_registration_cancellation.py" \
  "${peer_device_id}" "${peer_operation_id}" "${registration_recovery_directory}")"
peer_issued_credentials="$(curl --silent --show-error --fail \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountAssertion\":\"${peer_assertion}\",\"deviceID\":\"${peer_device_id}\",\"operationID\":\"${peer_operation_id}\",\"cancellation\":${peer_cancellation}}" \
  "${account_base_url}/v2/device-credentials")"
peer_access_token="$(printf '%s' "${peer_issued_credentials}" | jq -er '.accessToken')"
printf '%s' "${peer_issued_credentials}" | jq -e --argjson expected "${peer_cancellation}" '.registrationCancellation == $expected' > /dev/null
peer_user_id="$(printf '%s' "${peer_issued_credentials}" | jq -er '.userID')"

# Exercise the real framed gateway protocol after the HTTPS account issuer has
# produced two independent device credentials. The sender-side probe opens the
# unique direct room and accepts a message; the recipient-side probe reads
# that same room-log event and checks its message ID. Both run in the gateway container
# so they trust only the local Caddy root, and neither prints credentials or
# identities or becomes a gateway debug endpoint.
phase="authenticated V2 direct-message send"
gateway_send_result="$(compose \
  exec -T \
  --env "IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL=${gateway_probe_account_base_url}" \
  --env 'IM_V2_GATEWAY_PROBE_MODE=sendDirectMessage' \
  --env "IM_V2_GATEWAY_PROBE_ACCESS_TOKEN=${access_token}" \
  --env "IM_V2_GATEWAY_PROBE_DEVICE_ID=${device_id}" \
  --env "IM_V2_GATEWAY_PROBE_TARGET_USER_ID=${peer_user_id}" \
  gateway /workspace/IMV2Server/.build/release/IMV2LocalGatewayProbe)"
read -r gateway_room_id gateway_message_id gateway_send_extra <<<"${gateway_send_result}"
test -n "${gateway_room_id}" && test -n "${gateway_message_id}" && test -z "${gateway_send_extra}" || {
  printf 'local V2 gateway send probe returned an unexpected result\n' >&2
  exit 1
}

phase="authenticated V2 recipient room-log delivery"
gateway_receive_output="$(compose \
  exec -T \
  --env "IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL=${gateway_probe_account_base_url}" \
  --env 'IM_V2_GATEWAY_PROBE_MODE=receiveDirectMessage' \
  --env "IM_V2_GATEWAY_PROBE_ACCESS_TOKEN=${peer_access_token}" \
  --env "IM_V2_GATEWAY_PROBE_DEVICE_ID=${peer_device_id}" \
  --env "IM_V2_GATEWAY_PROBE_EXPECTED_ROOM_ID=${gateway_room_id}" \
  --env "IM_V2_GATEWAY_PROBE_EXPECTED_MESSAGE_ID=${gateway_message_id}" \
  gateway /workspace/IMV2Server/.build/release/IMV2LocalGatewayProbe)"
test "${gateway_receive_output}" = 'local V2 gateway direct room-log delivery: verified' || {
  printf 'local V2 gateway recipient room-log probe returned an unexpected result\n' >&2
  exit 1
}

# Opt-in G3 fixture: B belongs to both warmed direct rooms A-B and B-C, while
# C is a genuine non-member of A-B. Distinct direct rooms are required because
# the direct atomic append advances each room cursor once per batch wave.
if [[ -n "${remote_batch_fixture}" || -n "${remote_batch_release}" ]]; then
  phase="remote-batch private fixture paths"
  [[ "${remote_batch_fixture}" == /* && "${remote_batch_release}" == /* &&
     "${remote_batch_fixture}" != "${remote_batch_release}" &&
     -d "$(dirname "${remote_batch_fixture}")" &&
     -d "$(dirname "${remote_batch_release}")" &&
     ! -e "${remote_batch_fixture}" && ! -e "${remote_batch_release}" ]] || {
    printf 'invalid private remote-batch fixture/barrier paths\n' >&2
    exit 1
  }
  batch_account_handle="batch-${suffix:0:20}"
  batch_public_handle="batch${suffix:0:20}"
  batch_device_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  batch_operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  phase="remote-batch third account registration"
  batch_assertion="$(curl --silent --show-error --fail --cacert "${ca_path}" \
    --request POST --header 'Content-Type: application/json' \
    --data "{\"accountHandle\":\"${batch_account_handle}\",\"password\":\"v2-local-batch-password\",\"deviceID\":\"${batch_device_id}\",\"publicHandle\":\"${batch_public_handle}\",\"displayName\":\"Local Batch\"}" \
    "${account_base_url}/v2/account-auth/password/register" | jq -er '.accountAssertion')"
  phase="remote-batch third device credential issuance"
  batch_cancellation="$(python3 "${script_dir}/prepare_v2_registration_cancellation.py" \
    "${batch_device_id}" "${batch_operation_id}" "${registration_recovery_directory}")"
  batch_credentials="$(curl --silent --show-error --fail --cacert "${ca_path}" \
    --request POST --header 'Content-Type: application/json' \
    --data "{\"accountAssertion\":\"${batch_assertion}\",\"deviceID\":\"${batch_device_id}\",\"operationID\":\"${batch_operation_id}\",\"cancellation\":${batch_cancellation}}" \
    "${account_base_url}/v2/device-credentials")"
  batch_access_token="$(printf '%s' "${batch_credentials}" | jq -er '.accessToken')"
  batch_user_id="$(printf '%s' "${batch_credentials}" | jq -er '.userID')"

  remote_batch_warm_send() {
    compose exec -T \
      --env "IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL=${gateway_probe_account_base_url}" \
  --env 'IM_V2_GATEWAY_PROBE_MODE=sendDirectMessage' \
      --env "IM_V2_GATEWAY_PROBE_ACCESS_TOKEN=$1" \
      --env "IM_V2_GATEWAY_PROBE_DEVICE_ID=$2" \
      --env "IM_V2_GATEWAY_PROBE_TARGET_USER_ID=$3" \
      gateway /workspace/IMV2Server/.build/release/IMV2LocalGatewayProbe
  }
  remote_batch_relationship() {
    compose exec -T \
      --env "IM_V2_GATEWAY_PROBE_MODE=$1" \
      --env "IM_V2_GATEWAY_PROBE_ACCESS_TOKEN=$2" \
      --env "IM_V2_GATEWAY_PROBE_DEVICE_ID=$3" \
      --env "IM_V2_GATEWAY_PROBE_TARGET_USER_ID=$4" \
      gateway /workspace/IMV2Server/.build/release/IMV2LocalGatewayProbe
  }
  phase="remote-batch accepted relationships"
  test "$(remote_batch_relationship relationshipRequest "${peer_access_token}" "${peer_device_id}" "${user_id}")" = \
    'local V2 relationship accepted or requested'
  test "$(remote_batch_relationship relationshipAccept "${access_token}" "${device_id}" "${peer_user_id}")" = \
    'local V2 relationship accepted or requested'
  test "$(remote_batch_relationship relationshipRequest "${peer_access_token}" "${peer_device_id}" "${batch_user_id}")" = \
    'local V2 relationship accepted or requested'
  test "$(remote_batch_relationship relationshipAccept "${batch_access_token}" "${batch_device_id}" "${peer_user_id}")" = \
    'local V2 relationship accepted or requested'
  phase="remote-batch A-B and B-C room warmup"
  for _ in {1..4}; do
    read -r warm_ab_room _ <<<"$(remote_batch_warm_send "${peer_access_token}" "${peer_device_id}" "${user_id}")"
    test "${warm_ab_room}" = "${gateway_room_id}" || {
      printf 'remote-batch A-B warmup changed room identity\n' >&2; exit 1;
    }
  done
  read -r warm_bc_room _ <<<"$(remote_batch_warm_send "${peer_access_token}" "${peer_device_id}" "${batch_user_id}")"
  read -r warm_bc_reply_room _ <<<"$(remote_batch_warm_send "${batch_access_token}" "${batch_device_id}" "${peer_user_id}")"
  test "${warm_bc_room}" = "${warm_bc_reply_room}" && test "${warm_bc_room}" != "${gateway_room_id}" || {
    printf 'remote-batch B-C warmup changed room identity\n' >&2; exit 1;
  }
  for _ in {1..3}; do
    read -r warm_bc_final_room _ <<<"$(remote_batch_warm_send "${peer_access_token}" "${peer_device_id}" "${batch_user_id}")"
    test "${warm_bc_final_room}" = "${warm_bc_room}" || {
      printf 'remote-batch B-C final warmup changed room identity\n' >&2; exit 1;
    }
  done
  ( umask 077; set -C; printf '%s\n' "${gateway_room_id}" "${warm_bc_room}" \
      "${peer_access_token}" "${peer_device_id}" "${peer_user_id}" \
      "${batch_access_token}" "${batch_device_id}" "${batch_user_id}" \
      "${user_id}" > "${remote_batch_fixture}" )
  phase="remote-batch runner handoff"
  batch_deadline=$(( $(date +%s) + 150 ))
  while [[ ! -f "${remote_batch_release}" ]]; do
    (( $(date +%s) < batch_deadline )) || {
      printf 'remote-batch runner barrier was not released\n' >&2; exit 1;
    }
    sleep 0.05
  done
fi

# Opt-in test-only handoff. The recipient is still active here; the operator
# disable below applies to the original sender. Keep the access credential in
# the runner's private directory, never in stdout, service logs, or a command
# argument to another process. A file barrier lets the runner stage a real
# room transaction before the ordinary smoke continues unchanged.
if [[ -n "${busy_term_fixture}" || -n "${busy_term_release}" ]]; then
  phase="busy-TERM fixture handoff"
  [[ "${busy_term_fixture}" == /* && "${busy_term_release}" == /* &&
     "${busy_term_fixture}" != "${busy_term_release}" &&
     -d "$(dirname "${busy_term_fixture}")" &&
     -d "$(dirname "${busy_term_release}")" &&
     ! -e "${busy_term_fixture}" && ! -e "${busy_term_release}" ]] || {
    printf 'invalid private busy-TERM fixture/barrier paths\n' >&2
    exit 1
  }
  ( umask 077; set -C; printf '%s\n' "${gateway_room_id}" "${peer_access_token}" \
      "${peer_device_id}" "${user_id}" "${peer_user_id}" > "${busy_term_fixture}" )
  phase="busy-TERM runner barrier"
  busy_term_timeout="${V2_LOCAL_BUSY_TERM_BARRIER_TIMEOUT_SECONDS:-45}"
  [[ "${busy_term_timeout}" =~ ^[1-9][0-9]*$ ]] && (( busy_term_timeout <= 180 )) || {
    printf 'invalid busy-TERM barrier timeout\n' >&2
    exit 1
  }
  busy_term_deadline=$(( $(date +%s) + busy_term_timeout ))
  while [[ ! -f "${busy_term_release}" ]]; do
    (( $(date +%s) < busy_term_deadline )) || {
      printf 'busy-TERM runner barrier was not released\n' >&2
      exit 1
    }
    sleep 0.05
  done
fi

# Opt-in G5/#20 handoff. The direct room has been accepted and read through
# Gateway already. The runner now holds two authenticated sessions for this
# sender before allowing the ordinary Account/Operator HTTP checks to proceed.
# Only the runner's 0700 private directory receives the short-lived credential.
if [[ -n "${cross_entry_fixture}" || -n "${cross_entry_warm_release}" ||
      -n "${cross_entry_disable_ready}" || -n "${cross_entry_disable_release}" ||
      -n "${cross_entry_disabled}" ]]; then
  phase="cross-entry warm-room handoff"
  [[ "${cross_entry_fixture}" == /* && "${cross_entry_warm_release}" == /* &&
     "${cross_entry_disable_ready}" == /* && "${cross_entry_disable_release}" == /* &&
     "${cross_entry_disabled}" == /* &&
     "${cross_entry_fixture}" != "${cross_entry_warm_release}" &&
     "${cross_entry_fixture}" != "${cross_entry_disable_ready}" &&
     "${cross_entry_fixture}" != "${cross_entry_disable_release}" &&
     "${cross_entry_fixture}" != "${cross_entry_disabled}" &&
     "${cross_entry_warm_release}" != "${cross_entry_disable_ready}" &&
     "${cross_entry_warm_release}" != "${cross_entry_disable_release}" &&
     "${cross_entry_warm_release}" != "${cross_entry_disabled}" &&
     "${cross_entry_disable_ready}" != "${cross_entry_disable_release}" &&
     "${cross_entry_disable_ready}" != "${cross_entry_disabled}" &&
     "${cross_entry_disable_release}" != "${cross_entry_disabled}" &&
     -d "$(dirname "${cross_entry_fixture}")" &&
     -d "$(dirname "${cross_entry_warm_release}")" &&
     -d "$(dirname "${cross_entry_disable_ready}")" &&
     -d "$(dirname "${cross_entry_disable_release}")" &&
     -d "$(dirname "${cross_entry_disabled}")" &&
     ! -e "${cross_entry_fixture}" && ! -e "${cross_entry_warm_release}" &&
     ! -e "${cross_entry_disable_ready}" && ! -e "${cross_entry_disable_release}" &&
     ! -e "${cross_entry_disabled}" ]] || {
    printf 'invalid private cross-entry fixture/barrier paths\n' >&2
    exit 1
  }
  ( umask 077; set -C; printf '%s\n' "${gateway_room_id}" "${access_token}" \
      "${device_id}" "${user_id}" "${gateway_message_id}" > "${cross_entry_fixture}" )
  phase="cross-entry pre-disable barrier"
  cross_entry_timeout="${V2_LOCAL_CROSS_ENTRY_BARRIER_TIMEOUT_SECONDS:-150}"
  [[ "${cross_entry_timeout}" =~ ^[1-9][0-9]*$ ]] && (( cross_entry_timeout <= 180 )) || {
    printf 'invalid cross-entry barrier timeout\n' >&2
    exit 1
  }
  cross_entry_deadline=$(( $(date +%s) + cross_entry_timeout ))
  while [[ ! -f "${cross_entry_warm_release}" ]]; do
    (( $(date +%s) < cross_entry_deadline )) || {
      printf 'cross-entry pre-disable barrier was not released\n' >&2
      exit 1
    }
    sleep 0.05
  done
fi

# Capture a second, short-lived device-bound assertion before disabling the
# account. It remains intentionally unexchanged until after the operator
# action, where the credential issuer must fence it even though its HMAC is
# otherwise syntactically valid and still within its lifetime.
pre_disable_device_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
phase="pre-disable account assertion"
pre_disable_assertion="$(curl --silent --show-error --fail \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountHandle\":\"${account_handle}\",\"password\":\"v2-local-smoke-password\",\"deviceID\":\"${pre_disable_device_id}\"}" \
  "${account_base_url}/v2/account-auth/password/assertion" | jq -er '.accountAssertion')"

# This exercises the authenticated endpoint route without printing or
# persisting either credential. The opaque smoke token is deliberately not a
# real APNs token and is removed immediately after the no-store response.
push_headers="$(mktemp)"
trap 'rm -f -- "${push_headers}" "${rate_limit_headers}"' EXIT
phase="Push endpoint registration"
push_status="$(curl --silent --show-error --output /dev/null --dump-header "${push_headers}" --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request PUT \
  --header "Authorization: Bearer ${access_token}" \
  --header "X-IM-Device-ID: ${device_id}" \
  --header 'Content-Type: application/json' \
  --header 'Cache-Control: no-store' \
  --data "{\"provider\":\"apns\",\"environment\":\"development\",\"token\":\"local-smoke-push-token-${suffix}\"}" \
  "${account_base_url}/v2/push-endpoint")"
test "${push_status}" = '204' || {
  printf 'unexpected Push endpoint registration status: %s\n' "${push_status}" >&2
  exit 1
}
grep -Eiq '^cache-control:.*no-store' "${push_headers}" || {
  printf 'Push endpoint registration omitted no-store cache control\n' >&2
  exit 1
}

phase="Push endpoint removal"
push_delete_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request DELETE \
  --header "Authorization: Bearer ${access_token}" \
  --header "X-IM-Device-ID: ${device_id}" \
  --header 'Cache-Control: no-store' \
  "${account_base_url}/v2/push-endpoint")"
test "${push_delete_status}" = '204' || {
  printf 'unexpected Push endpoint removal status: %s\n' "${push_delete_status}" >&2
  exit 1
}

# The operator listener has no host-published port and is not connected to
# Caddy. Probe it only from its own container namespace, preserving the
# production invariant that this destructive API is loopback-only. The bearer
# comes from that container's local environment and is never printed.
if [[ -n "${cross_entry_fixture}" ]]; then
  # The runner checks that neither old Gateway socket closed during the
  # ordinary pre-disable HTTP work before acknowledging this second barrier.
  phase="cross-entry before-operator barrier"
  ( umask 077; set -C; printf 'ready\n' > "${cross_entry_disable_ready}" )
  cross_entry_deadline=$(( $(date +%s) + cross_entry_timeout ))
  while [[ ! -f "${cross_entry_disable_release}" ]]; do
    (( $(date +%s) < cross_entry_deadline )) || {
      printf 'cross-entry before-operator barrier was not released\n' >&2
      exit 1
    }
    sleep 0.05
  done
fi
disable_operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
disable_body="{\"operationID\":\"${disable_operation_id}\",\"userID\":\"${user_id}\",\"reason\":\"credential_compromise\"}"
phase="operator account disable"
operator_response="$(compose \
  exec -T operator bash -c '
    body="$1"
    exec 3<>/dev/tcp/127.0.0.1/9445
    printf "POST /internal/v2/accounts/disable HTTP/1.1\\r\\nHost: localhost\\r\\nAuthorization: Bearer %s\\r\\nContent-Type: application/json\\r\\nContent-Length: %s\\r\\nConnection: close\\r\\n\\r\\n%s" "$IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64" "${#body}" "$body" >&3
    cat <&3
  ' operator-disable "${disable_body}")"
printf '%s' "${operator_response}" | grep -Eq '^HTTP/1\.[01] 200 ' || {
  printf 'operator account-disable request did not return HTTP 200\n' >&2
  exit 1
}
printf '%s' "${operator_response}" | grep -Eiq $'\r?\ncache-control:.*no-store' || {
  printf 'operator account-disable response omitted no-store cache control\n' >&2
  exit 1
}
printf '%s' "${operator_response}" | grep -Fq '"outcome":"disabled"' || {
  printf 'operator account-disable response did not report a new disable\n' >&2
  exit 1
}
if [[ -n "${cross_entry_fixture}" ]]; then
  ( umask 077; set -C; printf 'disabled\n' > "${cross_entry_disabled}" )
fi

phase="disabled access credential rejection"
disabled_access_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request PUT \
  --header "Authorization: Bearer ${access_token}" \
  --header "X-IM-Device-ID: ${device_id}" \
  --header 'Content-Type: application/json' \
  --data "{\"provider\":\"apns\",\"environment\":\"development\",\"token\":\"disabled-smoke-push-token-${suffix}\"}" \
  "${account_base_url}/v2/push-endpoint")"
test "${disabled_access_status}" = '401' || {
  printf 'disabled access credential was unexpectedly accepted: %s\n' "${disabled_access_status}" >&2
  exit 1
}

phase="disabled refresh credential rejection"
disabled_refresh_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"userID\":\"${user_id}\",\"deviceID\":\"${device_id}\",\"refreshCredential\":\"${refresh_credential}\",\"revocationCredential\":\"${revocation_credential}\",\"operationID\":\"$(uuidgen | tr '[:upper:]' '[:lower:]')\"}" \
  "${account_base_url}/v2/device-credentials/refresh")"
test "${disabled_refresh_status}" = '401' || {
  printf 'disabled refresh credential was unexpectedly accepted: %s\n' "${disabled_refresh_status}" >&2
  exit 1
}

phase="disabled account assertion rejection"
pre_disable_operation_id="$(uuidgen)"
pre_disable_cancellation="$(python3 "${script_dir}/prepare_v2_registration_cancellation.py" \
  "${pre_disable_device_id}" "${pre_disable_operation_id}" "${registration_recovery_directory}")"
disabled_assertion_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountAssertion\":\"${pre_disable_assertion}\",\"deviceID\":\"${pre_disable_device_id}\",\"operationID\":\"${pre_disable_operation_id}\",\"cancellation\":${pre_disable_cancellation}}" \
  "${account_base_url}/v2/device-credentials")"
test "${disabled_assertion_status}" = '403' || {
  printf 'disabled account assertion was unexpectedly allowed to issue a credential: %s\n' "${disabled_assertion_status}" >&2
  exit 1
}

phase="TLS gateway handshake"
gateway_probe="$(openssl s_client \
  -connect "${gateway_tls_address}" \
  -servername localhost \
  -tls1_3 \
  -CAfile "${ca_path}" \
  -verify_return_error \
  -brief </dev/null 2>&1 || true)"
if printf '%s\n' "${gateway_probe}" | grep -Fq 'certificate has expired'; then
  printf 'V2 TLS gateway development certificate has expired; rerun %s to refresh the local TLS edge.\n' "${script_dir}/run_v2_local_account_stack.sh" >&2
  exit 1
fi
printf '%s\n' "${gateway_probe}" | grep -Fq 'Protocol version: TLSv1.3' || {
  printf 'V2 TLS gateway did not negotiate TLS 1.3\n' >&2
  exit 1
}
printf '%s\n' "${gateway_probe}" | grep -Fq 'Verification: OK' || {
  printf 'V2 TLS gateway certificate was not verified by the local CA\n' >&2
  exit 1
}

# Metrics must remain private to the gateway container. Probe its loopback
# listener from inside the Compose service rather than publishing a second
# host port merely for smoke testing. This also rejects a stale image that
# predates the durable retry/pause metric vocabulary.
if compose \
  port gateway 9464 >/dev/null 2>&1; then
  printf 'V2 metrics listener must not publish port 9464 to the host\n' >&2
  exit 1
fi

phase="private metrics probe"
metrics_response="$(compose \
  exec -T gateway bash -lc 'exec 3<>/dev/tcp/127.0.0.1/9464; printf "GET /metrics HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n" >&3; cat <&3')"
grep -Fq 'HTTP/1.1 200 OK' <<< "${metrics_response}" || {
  printf 'V2 private metrics listener did not return HTTP 200\n' >&2
  exit 1
}
grep -Fiq 'cache-control: no-store, no-cache' <<< "${metrics_response}" || {
  printf 'V2 private metrics listener omitted no-store cache control\n' >&2
  exit 1
}
for metric in \
  'im_v2_durable_work_metrics_available ' \
  'im_v2_user_state_event_backlog{state="ready"}' \
  'im_v2_user_state_event_backlog{state="leased"}' \
  'im_v2_user_state_event_backlog{state="scheduled"}' \
  'im_v2_user_state_event_backlog{state="paused"}' \
  'im_v2_profile_security_invalidation_backlog{state="ready"}' \
  'im_v2_profile_security_invalidation_backlog{state="leased"}' \
  'im_v2_read_receipt_preference_propagation_backlog{state="ready"}' \
  'im_v2_read_receipt_preference_propagation_backlog{state="leased"}' \
  'im_v2_read_receipt_preference_propagation_backlog{state="scheduled"}' \
  'im_v2_read_receipt_preference_propagation_backlog{state="paused"}' \
  'im_v2_content_review_backlog{state="ready"}' \
  'im_v2_content_review_backlog{state="leased"}' \
  'im_v2_content_review_backlog{state="scheduled"}' \
  'im_v2_content_review_backlog{state="paused"}' \
  'im_v2_media_scan_backlog{state="ready"}' \
  'im_v2_media_purge_backlog{state="ready"}' \
  'im_v2_user_sync_log_estimated_rows ' \
  'im_v2_user_sync_log_relation_bytes ' \
  'im_v2_push_wake_backlog{state="ready"}' \
  'im_v2_push_wake_backlog{state="leased"}' \
  'im_v2_push_wake_backlog{state="suppressed"}'; do
  grep -Fq "${metric}" <<< "${metrics_response}" || {
    printf 'V2 private metrics listener omitted required metric: %s\n' "${metric}" >&2
    exit 1
  }
done

# The per-gateway revocation backlog is intentionally identified by the
# scrape target, never a Prometheus node/device/user label. A label here
# would disclose topology or identity and create cardinality pressure.
if ! grep -Eq '^im_v2_device_revocation_events_pending [0-9]+$' <<< "${metrics_response}"; then
  printf 'V2 private metrics listener omitted the device-revocation backlog sample\n' >&2
  exit 1
fi
if grep -Fq 'im_v2_device_revocation_events_pending{' <<< "${metrics_response}"; then
  printf 'V2 private metrics listener exposed a label on device-revocation backlog\n' >&2
  exit 1
fi
if ! grep -Eq '^im_v2_revoked_device_projection_cleanup_events_pending [0-9]+$' <<< "${metrics_response}"; then
  printf 'V2 private metrics listener omitted the revoked-device projection cleanup sample\n' >&2
  exit 1
fi
if grep -Fq 'im_v2_revoked_device_projection_cleanup_events_pending{' <<< "${metrics_response}"; then
  printf 'V2 private metrics listener exposed a label on revoked-device projection cleanup\n' >&2
  exit 1
fi

printf 'local account HTTPS validation: 400\n'
printf 'local password registration and device credential issuance: 200\n'
printf 'local V2 gateway direct chat: auth, open, accept, recipient room-log delivery verified\n'
printf 'local password failure limit: 5 x 401, then 429 no-store with Retry-After\n'
printf 'local Push endpoint register/remove: 204, no-store\n'
printf 'local loopback operator account disable: 200 no-store, then access/refresh 401 and prior assertion 403\n'
printf 'local V2 TLS gateway: TLS 1.3 verified\n'
printf 'local V2 private metrics: HTTP 200, no-store, durable-work and revocation metric vocabulary verified\n'
