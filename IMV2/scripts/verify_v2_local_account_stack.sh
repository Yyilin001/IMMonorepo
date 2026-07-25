#!/usr/bin/env bash
set -Eeuo pipefail

# Non-destructive smoke test for the local-only V2 account stack. It proves
# that the Caddy HTTPS edge, password fallback and device credential issuer
# are connected without printing an assertion, access token or refresh token.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${v2_dir}/.." && pwd)"
ca_path="${v2_dir}/local-ca/root.crt"
compose_file="${v2_dir}/docker-compose.local-account.yml"
env_file="${v2_dir}/.env.local"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for command in curl jq openssl uuidgen docker; do
  require_command "${command}"
done

test -f "${ca_path}" || {
  printf 'missing local CA: start the stack first with %s\n' "${script_dir}/run_v2_local_account_stack.sh" >&2
  exit 1
}

invalid_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{}' \
  https://localhost:8443/v2/account-auth/password/assertion)"
test "${invalid_status}" = '400' || {
  printf 'unexpected invalid account request status: %s\n' "${invalid_status}" >&2
  exit 1
}

suffix="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
account_handle="smoke-${suffix:0:20}"
device_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

assertion="$(curl --silent --show-error --fail \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountHandle\":\"${account_handle}\",\"password\":\"v2-local-smoke-password\",\"deviceID\":\"${device_id}\"}" \
  https://localhost:8443/v2/account-auth/password/register | jq -er '.accountAssertion')"

issued_credentials="$(curl --silent --show-error --fail \
  --cacert "${ca_path}" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data "{\"accountAssertion\":\"${assertion}\",\"deviceID\":\"${device_id}\",\"operationID\":\"${operation_id}\"}" \
  https://localhost:8443/v2/device-credentials)"
access_token="$(printf '%s' "${issued_credentials}" | jq -er '.accessToken')"

# This exercises the authenticated endpoint route without printing or
# persisting either credential. The opaque smoke token is deliberately not a
# real APNs token and is removed immediately after the no-store response.
push_headers="$(mktemp)"
trap 'rm -f -- "${push_headers}"' EXIT
push_status="$(curl --silent --show-error --output /dev/null --dump-header "${push_headers}" --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request PUT \
  --header "Authorization: Bearer ${access_token}" \
  --header "X-IM-Device-ID: ${device_id}" \
  --header 'Content-Type: application/json' \
  --header 'Cache-Control: no-store' \
  --data "{\"provider\":\"apns\",\"environment\":\"development\",\"token\":\"local-smoke-push-token-${suffix}\"}" \
  https://localhost:8443/v2/push-endpoint)"
test "${push_status}" = '204' || {
  printf 'unexpected Push endpoint registration status: %s\n' "${push_status}" >&2
  exit 1
}
grep -Eiq '^cache-control:.*no-store' "${push_headers}" || {
  printf 'Push endpoint registration omitted no-store cache control\n' >&2
  exit 1
}

push_delete_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert "${ca_path}" \
  --request DELETE \
  --header "Authorization: Bearer ${access_token}" \
  --header "X-IM-Device-ID: ${device_id}" \
  --header 'Cache-Control: no-store' \
  https://localhost:8443/v2/push-endpoint)"
test "${push_delete_status}" = '204' || {
  printf 'unexpected Push endpoint removal status: %s\n' "${push_delete_status}" >&2
  exit 1
}

gateway_probe="$(openssl s_client \
  -connect localhost:7443 \
  -servername localhost \
  -tls1_3 \
  -CAfile "${ca_path}" \
  -verify_return_error \
  -brief </dev/null 2>&1)"
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
if docker compose --project-name imv2localaccount --env-file "${env_file}" --file "${compose_file}" \
  port gateway 9464 >/dev/null 2>&1; then
  printf 'V2 metrics listener must not publish port 9464 to the host\n' >&2
  exit 1
fi

metrics_response="$(docker compose --project-name imv2localaccount --env-file "${env_file}" --file "${compose_file}" \
  exec -T gateway bash -lc 'exec 3<>/dev/tcp/127.0.0.1/9464; printf "GET /metrics HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n" >&3; cat <&3')"
printf '%s\n' "${metrics_response}" | grep -Fq 'HTTP/1.1 200 OK' || {
  printf 'V2 private metrics listener did not return HTTP 200\n' >&2
  exit 1
}
printf '%s\n' "${metrics_response}" | grep -Fq 'cache-control: no-store, no-cache' || {
  printf 'V2 private metrics listener omitted no-store cache control\n' >&2
  exit 1
}
for metric in \
  'im_v2_durable_work_metrics_available ' \
  'im_v2_room_outbox_backlog{state="ready"}' \
  'im_v2_room_outbox_backlog{state="leased"}' \
  'im_v2_room_outbox_backlog{state="scheduled"}' \
  'im_v2_room_outbox_backlog{state="paused"}' \
  'im_v2_fanout_delivery_backlog{state="ready"}' \
  'im_v2_fanout_delivery_backlog{state="leased"}' \
  'im_v2_fanout_delivery_backlog{state="scheduled"}' \
  'im_v2_fanout_delivery_backlog{state="paused"}' \
  'im_v2_push_wake_backlog{state="ready"}' \
  'im_v2_push_wake_backlog{state="leased"}' \
  'im_v2_push_wake_backlog{state="suppressed"}'; do
  printf '%s\n' "${metrics_response}" | grep -Fq "${metric}" || {
    printf 'V2 private metrics listener omitted required metric: %s\n' "${metric}" >&2
    exit 1
  }
done

printf 'local account HTTPS validation: 400\n'
printf 'local password registration and device credential issuance: 200\n'
printf 'local Push endpoint register/remove: 204, no-store\n'
printf 'local V2 TLS gateway: TLS 1.3 verified\n'
printf 'local V2 private metrics: HTTP 200, no-store, durable-work metric vocabulary verified\n'
