#!/usr/bin/env bash
set -Eeuo pipefail

# Keep deployment examples aligned with the strict runtime configuration
# constructors. This validates variable declarations only: real credentials
# are supplied by the deployment secret manager and must never enter CI.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_assignment() {
  local example_path="$1"
  local key="$2"
  if ! grep -Eq "^${key}=" "${example_path}"; then
    printf 'missing required deployment variable %s in %s\n' "${key}" "${example_path}" >&2
    exit 1
  fi
}

check_example() {
  local example_path="$1"
  shift
  test -f "${example_path}" || {
    printf 'missing deployment example: %s\n' "${example_path}" >&2
    exit 1
  }
  local key
  for key in "$@"; do
    require_assignment "${example_path}" "${key}"
  done
}

check_example "${repo_root}/IMV2Server/.env.example" \
  IM_V2_DATABASE_URL \
  IM_V2_TLS_HOST \
  IM_V2_TLS_PORT \
  IM_V2_TLS_CERTIFICATE_CHAIN_PATH \
  IM_V2_TLS_PRIVATE_KEY_PATH \
  IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64 \
  IM_V2_CAPABILITY_PROFILE \
  IM_V2_MAX_MESSAGE_UTF8_BYTES \
  IM_V2_MAX_FRAME_BYTES \
  IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH \
  IM_V2_MAX_IN_FLIGHT_REQUESTS \
  IM_V2_MAX_QUEUED_INBOUND_BYTES \
  IM_V2_IDLE_TIMEOUT_MS \
  IM_V2_WORKER_BATCH_SIZE \
  IM_V2_WORKER_POLL_INTERVAL_MS \
  IM_V2_DURABLE_RETRY_INITIAL_DELAY_MS \
  IM_V2_DURABLE_RETRY_MAX_DELAY_MS \
  IM_V2_DURABLE_RETRY_MAX_ATTEMPTS \
  IM_V2_DURABLE_RETRY_JITTER_PERCENT \
  IM_V2_MAINTENANCE_POLL_INTERVAL_MS \
  IM_V2_MEDIA_WITHDRAWN_RETENTION_SECONDS \
  IM_V2_METRICS_HOST \
  IM_V2_METRICS_PORT \
  IM_V2_GATEWAY_NODE_ID \
  IM_V2_USER_SHARD_BUCKET \
  IM_V2_USER_SHARD_ROUTER_EPOCH \
  IM_V2_DIRECT_ROOM_SHARD_ID \
  IM_V2_GROUP_ROOM_SHARD_ID \
  IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW \
  IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS \
  IM_V2_CAPACITY_PROFILE_ID \
  IM_V2_MAX_ELIGIBLE_MEMBERS \
  IM_V2_MAX_COMMANDS_PER_WINDOW \
  IM_V2_MAX_FANOUT_UNITS_PER_WINDOW \
  IM_V2_MAX_OUTSTANDING_FANOUT_UNITS \
  IM_V2_MAX_OUTSTANDING_PLANS \
  IM_V2_MAX_ENUMERATION_PAGE_SIZE \
  IM_V2_MAX_PLANNER_CONCURRENCY \
  IM_V2_MAX_DELIVERY_CONCURRENCY \
  IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS

check_example "${repo_root}/IMV2Server/account.env.example" \
  IM_V2_DATABASE_URL \
  IM_V2_ACCOUNT_LISTEN_HOST \
  IM_V2_ACCOUNT_LISTEN_PORT \
  IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64 \
  IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64 \
  IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64 \
  IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64 \
  IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64 \
  IM_V2_PASSWORD_DUMMY_BCRYPT_HASH \
  IM_V2_PASSWORD_LOGIN_MAX_FAILURES \
  IM_V2_PASSWORD_LOGIN_WINDOW_SECONDS \
  IM_V2_PASSWORD_LOGIN_LOCKOUT_SECONDS

check_example "${repo_root}/IMV2Server/operator-replay.env.example" \
  IM_V2_DATABASE_URL \
  IM_V2_OPERATOR_REPLAY_LISTEN_HOST \
  IM_V2_OPERATOR_REPLAY_LISTEN_PORT \
  IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64 \
  IM_V2_OPERATOR_REPLAY_PRINCIPAL \
  IM_V2_USER_SHARD_STORES_JSON

printf 'V2 runtime environment examples declare every required variable.\n'
