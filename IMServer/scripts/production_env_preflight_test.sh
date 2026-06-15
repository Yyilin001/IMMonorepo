#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="${ROOT_DIR}/scripts/production_env_preflight.sh"
RELEASE_GATE="${ROOT_DIR}/scripts/production_release_gate.sh"
ENV_DIR="${ROOT_DIR}/config/env"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

log() {
  echo "==> $1"
}

replace_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^${key}=" "${file}"; then
    perl -0pi -e "s/^${key}=.*$/${key}=${value}/m" "${file}"
  else
    printf '\n%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

delete_env_key() {
  local file="$1"
  local key="$2"
  perl -0pi -e "s/^${key}=.*\\n//m" "${file}"
}

sanitize_template_placeholders() {
  local dir="$1"
  local file
  for file in "${dir}"/*.env; do
    perl -0pi -e 's/replace-me/prod-secret-value/g; s/user:pass/prod-user:prod-pass/g; s/\.example/.internal/g' "${file}"
  done
}

copy_templates() {
  local name="$1"
  local dir="${TMP_DIR}/${name}"
  mkdir -p "${dir}"

  cp "${ENV_DIR}/command-api.production.env.example" "${dir}/command-api.env"
  cp "${ENV_DIR}/gateway.production.env.example" "${dir}/gateway.env"
  cp "${ENV_DIR}/query-api.production.env.example" "${dir}/query-api.env"
  cp "${ENV_DIR}/outbox-relay.production.env.example" "${dir}/outbox-relay.env"
  cp "${ENV_DIR}/ops.production.env.example" "${dir}/ops.env"
  cp "${ENV_DIR}/stream-consumer.production.env.example" "${dir}/stream-summary.env"
  cp "${ENV_DIR}/stream-consumer.production.env.example" "${dir}/stream-domain.env"
  cp "${ENV_DIR}/stream-consumer.production.env.example" "${dir}/stream-realtime.env"
  cp "${ENV_DIR}/stream-consumer.production.env.example" "${dir}/stream-notification.env"

  replace_env_value "${dir}/stream-summary.env" "IM_NODE_ID" "stream-summary"
  replace_env_value "${dir}/stream-summary.env" "IM_STREAM_CONSUMER_GROUPS" "summary-projection-consumer"
  replace_env_value "${dir}/stream-domain.env" "IM_NODE_ID" "stream-domain"
  replace_env_value "${dir}/stream-domain.env" "IM_STREAM_CONSUMER_GROUPS" "domain-delivery-consumer"
  replace_env_value "${dir}/stream-domain.env" "IM_GATEWAY_RELAY_MODE" "http"
  replace_env_value "${dir}/stream-domain.env" "IM_GATEWAY_INTERNAL_BASE_URL" "http://gateway.internal:8080"
  replace_env_value "${dir}/stream-domain.env" "IM_INTERNAL_SHARED_SECRET" "replace-me"
  replace_env_value "${dir}/stream-realtime.env" "IM_NODE_ID" "stream-realtime"
  replace_env_value "${dir}/stream-realtime.env" "IM_STREAM_CONSUMER_GROUPS" "realtime-delivery-consumer"
  replace_env_value "${dir}/stream-realtime.env" "IM_GATEWAY_RELAY_MODE" "http"
  replace_env_value "${dir}/stream-realtime.env" "IM_GATEWAY_INTERNAL_BASE_URL" "http://gateway.internal:8080"
  replace_env_value "${dir}/stream-realtime.env" "IM_INTERNAL_SHARED_SECRET" "replace-me"
  replace_env_value "${dir}/stream-notification.env" "IM_NODE_ID" "stream-notification"
  replace_env_value "${dir}/stream-notification.env" "IM_STREAM_CONSUMER_GROUPS" "notification-consumer"

  printf '%s\n' "${dir}"
}

preflight_args() {
  local dir="$1"
  printf '%s\0' \
    --command-api "${dir}/command-api.env" \
    --gateway "${dir}/gateway.env" \
    --query-api "${dir}/query-api.env" \
    --outbox-relay "${dir}/outbox-relay.env" \
    --ops "${dir}/ops.env" \
    --stream-consumer "${dir}/stream-summary.env" \
    --stream-consumer "${dir}/stream-domain.env" \
    --stream-consumer "${dir}/stream-realtime.env" \
    --stream-consumer "${dir}/stream-notification.env"
}

run_preflight() {
  local dir="$1"
  shift
  local args=()
  while IFS= read -r -d '' arg; do
    args+=("${arg}")
  done < <(preflight_args "${dir}")
  "${PREFLIGHT}" "${args[@]}" "$@"
}

run_should_pass() {
  local name="$1"
  shift
  log "${name}"
  local output
  if ! output="$("$@" 2>&1)"; then
    echo "${output}" >&2
    fail "${name} should pass"
  fi
  echo "${output}"
}

run_should_fail() {
  local name="$1"
  local expected="$2"
  shift 2
  log "${name}"
  local output rc
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )); then
    echo "${output}" >&2
    fail "${name} should fail"
  fi
  if [[ "${output}" != *"${expected}"* ]]; then
    echo "${output}" >&2
    fail "${name} failure should include: ${expected}"
  fi
  echo "${output}"
}

bash -n "${PREFLIGHT}"
bash -n "${RELEASE_GATE}"

run_should_pass "default templates pass" "${PREFLIGHT}"

run_should_fail "strict secrets rejects template placeholders" "strict secrets requires JWT_SECRET to not use placeholder value" \
  "${PREFLIGHT}" --strict-secrets

run_should_fail "release gate real env requires complete role args" "Real env preflight requires --command-api, --gateway, --query-api, --outbox-relay, --ops, and at least one --stream-consumer." \
  "${RELEASE_GATE}" --command-api /tmp/command-api.env --strict-secrets

run_should_fail "release gate real env requires strict secrets" "Real env preflight requires --strict-secrets." \
  "${RELEASE_GATE}" \
    --command-api /tmp/command-api.env \
    --gateway /tmp/gateway.env \
    --query-api /tmp/query-api.env \
    --outbox-relay /tmp/outbox-relay.env \
    --ops /tmp/ops.env \
    --stream-consumer /tmp/stream.env

full_dir="$(copy_templates full)"
run_should_pass "four stream-consumer topology passes" run_preflight "${full_dir}" \
  --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,notification-consumer

private_tcp_dir="$(copy_templates private-tcp)"
replace_env_value "${private_tcp_dir}/gateway.env" "IM_TCP_HOST" "10.0.0.10"
replace_env_value "${private_tcp_dir}/gateway.env" "IM_TCP_REQUIRES_TLS_TERMINATION" "false"
run_should_pass "private gateway tcp bind can omit tls termination marker" run_preflight "${private_tcp_dir}"

minimal_split_dir="$(copy_templates minimal-split)"
delete_env_key "${minimal_split_dir}/stream-domain.env" "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD"
delete_env_key "${minimal_split_dir}/stream-domain.env" "IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS"
delete_env_key "${minimal_split_dir}/stream-domain.env" "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
delete_env_key "${minimal_split_dir}/stream-domain.env" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
delete_env_key "${minimal_split_dir}/stream-domain.env" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT"
delete_env_key "${minimal_split_dir}/stream-domain.env" "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD"
run_should_pass "minimal split stream domain env passes without unrelated thresholds" run_preflight "${minimal_split_dir}" \
  --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,notification-consumer

strict_full_dir="$(copy_templates strict-full)"
sanitize_template_placeholders "${strict_full_dir}"
run_should_pass "strict secrets accepts sanitized four stream-consumer topology" run_preflight "${strict_full_dir}" \
  --strict-secrets \
  --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,notification-consumer

missing_group_dir="$(copy_templates missing-group)"
run_should_fail "required group mismatch fails" "stream-consumer deployment requires missing group: domain-delivery-consumer" \
  run_preflight "${missing_group_dir}" --require-groups domain-delivery-consumer-missing

stream_limit_dir="$(copy_templates stream-limit)"
replace_env_value "${stream_limit_dir}/stream-domain.env" "IM_GROUP_MEMBER_LIMIT" "999"
run_should_fail "stream member limit mismatch fails" "requires IM_GROUP_MEMBER_LIMIT (999) to match IM_GROUP_MEMBER_LIMIT (1000)" \
  run_preflight "${stream_limit_dir}"

gateway_threshold_dir="$(copy_templates gateway-threshold)"
replace_env_value "${gateway_threshold_dir}/gateway.env" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" "1001"
run_should_fail "gateway fanout threshold above group limit fails" "requires IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD <= 1000" \
  run_preflight "${gateway_threshold_dir}"

gateway_public_tcp_tls_dir="$(copy_templates gateway-public-tcp-tls)"
delete_env_key "${gateway_public_tcp_tls_dir}/gateway.env" "IM_TCP_REQUIRES_TLS_TERMINATION"
run_should_fail "gateway public tcp bind without tls termination marker fails" "gateway requires IM_TCP_REQUIRES_TLS_TERMINATION=true when IM_TCP_HOST binds a public address" \
  run_preflight "${gateway_public_tcp_tls_dir}"

gateway_payload_budget_dir="$(copy_templates gateway-payload-budget)"
delete_env_key "${gateway_payload_budget_dir}/gateway.env" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_PAYLOAD_BYTE_BUDGET"
run_should_fail "gateway missing full fanout payload budget fails" "requires IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_PAYLOAD_BYTE_BUDGET >= 65536" \
  run_preflight "${gateway_payload_budget_dir}"

gateway_full_fanout_hard_cap_dir="$(copy_templates gateway-full-fanout-hard-cap)"
replace_env_value "${gateway_full_fanout_hard_cap_dir}/gateway.env" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" "256"
run_should_fail "gateway full fanout above hard cap fails" "gateway requires IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT <= 128" \
  run_preflight "${gateway_full_fanout_hard_cap_dir}"

gateway_full_fanout_above_threshold_dir="$(copy_templates gateway-full-fanout-above-threshold)"
replace_env_value "${gateway_full_fanout_above_threshold_dir}/gateway.env" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" "64"
replace_env_value "${gateway_full_fanout_above_threshold_dir}/gateway.env" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" "128"
run_should_fail "gateway full fanout above active threshold fails" "gateway requires IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT <= IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" \
  run_preflight "${gateway_full_fanout_above_threshold_dir}"

gateway_full_fanout_mode_dir="$(copy_templates gateway-full-fanout-mode)"
replace_env_value "${gateway_full_fanout_mode_dir}/gateway.env" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE" "bounded"
run_should_fail "gateway bounded full fanout mode fails" "gateway requires IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE=compact-only" \
  run_preflight "${gateway_full_fanout_mode_dir}"

gateway_inactive_hint_mode_dir="$(copy_templates gateway-inactive-hint-mode)"
replace_env_value "${gateway_inactive_hint_mode_dir}/gateway.env" "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE" "relay"
run_should_fail "gateway inactive hint relay mode fails" "gateway requires IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only" \
  run_preflight "${gateway_inactive_hint_mode_dir}"

gateway_local_fanout_batch_dir="$(copy_templates gateway-local-fanout-batch)"
replace_env_value "${gateway_local_fanout_batch_dir}/gateway.env" "IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE" "1025"
run_should_fail "gateway local fanout batch above cap fails" "gateway requires IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE <= 1024" \
  run_preflight "${gateway_local_fanout_batch_dir}"

gateway_local_fanout_yield_dir="$(copy_templates gateway-local-fanout-yield)"
replace_env_value "${gateway_local_fanout_yield_dir}/gateway.env" "IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS" "257"
run_should_fail "gateway local fanout yield chunks above cap fails" "gateway requires IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS <= 256" \
  run_preflight "${gateway_local_fanout_yield_dir}"

gateway_remote_dispatch_inflight_dir="$(copy_templates gateway-remote-dispatch-inflight)"
replace_env_value "${gateway_remote_dispatch_inflight_dir}/gateway.env" "IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT" "65"
run_should_fail "gateway remote dispatch max in flight above cap fails" "gateway requires IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT <= 64" \
  run_preflight "${gateway_remote_dispatch_inflight_dir}"

gateway_remote_dispatch_batch_dir="$(copy_templates gateway-remote-dispatch-batch)"
replace_env_value "${gateway_remote_dispatch_batch_dir}/gateway.env" "IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE" "2049"
run_should_fail "gateway remote dispatch user batch above cap fails" "gateway requires IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE <= 2048" \
  run_preflight "${gateway_remote_dispatch_batch_dir}"

gateway_relay_body_max_dir="$(copy_templates gateway-relay-body-max)"
replace_env_value "${gateway_relay_body_max_dir}/gateway.env" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES" "16777217"
run_should_fail "gateway relay body above cap fails" "gateway requires IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES <= 16777216" \
  run_preflight "${gateway_relay_body_max_dir}"

gateway_relay_binary_body_max_dir="$(copy_templates gateway-relay-binary-body-max)"
replace_env_value "${gateway_relay_binary_body_max_dir}/gateway.env" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES" "16777217"
run_should_fail "gateway relay binary body above cap fails" "gateway requires IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES <= 16777216" \
  run_preflight "${gateway_relay_binary_body_max_dir}"

gateway_relay_batch_body_max_dir="$(copy_templates gateway-relay-batch-body-max)"
replace_env_value "${gateway_relay_batch_body_max_dir}/gateway.env" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKETS_MAX_BODY_BYTES" "16777217"
run_should_fail "gateway relay batch body above cap fails" "gateway requires IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKETS_MAX_BODY_BYTES <= 16777216" \
  run_preflight "${gateway_relay_batch_body_max_dir}"

command_relay_body_override_dir="$(copy_templates command-relay-body-override)"
replace_env_value "${command_relay_body_override_dir}/command-api.env" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES" "16777217"
run_should_fail "command-api relay body override above cap fails" "command-api requires IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES between 65536 and 16777216 when set" \
  run_preflight "${command_relay_body_override_dir}"

stream_relay_body_override_dir="$(copy_templates stream-relay-body-override)"
replace_env_value "${stream_relay_body_override_dir}/stream-realtime.env" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES" "1024"
run_should_fail "stream relay body override below minimum fails" "stream-consumer:${stream_relay_body_override_dir}/stream-realtime.env requires IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES between 65536 and 16777216 when set" \
  run_preflight "${stream_relay_body_override_dir}"

query_legacy_dir="$(copy_templates query-legacy)"
replace_env_value "${query_legacy_dir}/query-api.env" "IM_SUMMARY_QUERY_READ_SOURCE" "legacy"
run_should_fail "query-api legacy summary read fails" "query-api requires IM_SUMMARY_QUERY_READ_SOURCE=sharded" \
  run_preflight "${query_legacy_dir}"

query_summary_member_limit_dir="$(copy_templates query-summary-member-limit)"
replace_env_value "${query_summary_member_limit_dir}/query-api.env" "IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT" "0"
run_should_fail "query-api summary member ids limit disabled fails" "query-api requires IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT >= 1" \
  run_preflight "${query_summary_member_limit_dir}"

ops_summary_member_limit_dir="$(copy_templates ops-summary-member-limit)"
replace_env_value "${ops_summary_member_limit_dir}/ops.env" "IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT" "0"
run_should_fail "ops summary member ids limit disabled fails" "ops requires IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT >= 1" \
  run_preflight "${ops_summary_member_limit_dir}"

kafka_mismatch_dir="$(copy_templates kafka-mismatch)"
replace_env_value "${kafka_mismatch_dir}/outbox-relay.env" "IM_KAFKA_TOPIC" "conversation-domain-events-mismatch"
run_should_fail "Kafka topic mismatch fails" "outbox-relay/command-api Kafka requires IM_KAFKA_TOPIC" \
  run_preflight "${kafka_mismatch_dir}"

kafka_plaintext_dir="$(copy_templates kafka-plaintext)"
replace_env_value "${kafka_plaintext_dir}/command-api.env" "IM_KAFKA_SECURITY_PROTOCOL" "plaintext"
run_should_fail "Kafka plaintext security protocol fails" "command-api requires IM_KAFKA_SECURITY_PROTOCOL=sasl_tls" \
  run_preflight "${kafka_plaintext_dir}"

kafka_missing_sasl_dir="$(copy_templates kafka-missing-sasl)"
delete_env_key "${kafka_missing_sasl_dir}/outbox-relay.env" "IM_KAFKA_SASL_PASSWORD"
run_should_fail "Kafka missing SASL password fails" "outbox-relay requires IM_KAFKA_SASL_PASSWORD" \
  run_preflight "${kafka_missing_sasl_dir}"

kafka_acks_dir="$(copy_templates kafka-acks)"
replace_env_value "${kafka_acks_dir}/stream-realtime.env" "IM_KAFKA_REQUIRED_ACKS" "1"
run_should_fail "Kafka non-all required acknowledgements fails" "stream-consumer:${kafka_acks_dir}/stream-realtime.env requires IM_KAFKA_REQUIRED_ACKS=all" \
  run_preflight "${kafka_acks_dir}"

stream_domain_relay_mode_dir="$(copy_templates stream-domain-relay-mode)"
delete_env_key "${stream_domain_relay_mode_dir}/stream-domain.env" "IM_GATEWAY_RELAY_MODE"
run_should_fail "domain stream missing gateway relay mode fails" "stream-consumer:${stream_domain_relay_mode_dir}/stream-domain.env requires IM_GATEWAY_RELAY_MODE=http" \
  run_preflight "${stream_domain_relay_mode_dir}"

stream_domain_relay_secret_dir="$(copy_templates stream-domain-relay-secret)"
delete_env_key "${stream_domain_relay_secret_dir}/stream-domain.env" "IM_INTERNAL_SHARED_SECRET"
run_should_fail "domain stream missing gateway relay secret fails" "stream-consumer:${stream_domain_relay_secret_dir}/stream-domain.env requires IM_INTERNAL_SHARED_SECRET" \
  run_preflight "${stream_domain_relay_secret_dir}"

stream_realtime_relay_url_dir="$(copy_templates stream-realtime-relay-url)"
delete_env_key "${stream_realtime_relay_url_dir}/stream-realtime.env" "IM_GATEWAY_INTERNAL_BASE_URL"
run_should_fail "realtime stream missing gateway relay url fails" "stream-consumer:${stream_realtime_relay_url_dir}/stream-realtime.env requires IM_GATEWAY_INTERNAL_BASE_URL" \
  run_preflight "${stream_realtime_relay_url_dir}"

media_local_dir="$(copy_templates media-local)"
replace_env_value "${media_local_dir}/command-api.env" "MEDIA_STORAGE_PROVIDER" "local"
run_should_fail "command-api local media storage fails" "command-api requires MEDIA_STORAGE_PROVIDER=s3compatible" \
  run_preflight "${media_local_dir}"

media_missing_secret_dir="$(copy_templates media-missing-secret)"
delete_env_key "${media_missing_secret_dir}/command-api.env" "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY"
run_should_fail "command-api missing S3 media secret fails" "command-api requires MEDIA_STORAGE_S3_SECRET_ACCESS_KEY" \
  run_preflight "${media_missing_secret_dir}"

hot_limit_dir="$(copy_templates hot-limit)"
delete_env_key "${hot_limit_dir}/command-api.env" "IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT"
run_should_fail "command-api missing hot conversation limit fails" "command-api requires IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT >= 1" \
  run_preflight "${hot_limit_dir}"

sequence_mode_dir="$(copy_templates sequence-mode)"
replace_env_value "${sequence_mode_dir}/command-api.env" "IM_SEQUENCE_ALLOCATION_MODE" "single"
run_should_fail "command-api non-block sequence allocation fails" "command-api requires IM_SEQUENCE_ALLOCATION_MODE=block" \
  run_preflight "${sequence_mode_dir}"

command_node_dir="$(copy_templates command-node)"
replace_env_value "${command_node_dir}/command-api.env" "IM_COMMAND_NODE_ID" "node-missing"
run_should_fail "command-api node id must exist in command node urls" "command-api requires IM_COMMAND_NODE_ID to match an entry in IM_COMMAND_NODE_URLS" \
  run_preflight "${command_node_dir}"

write_batch_dir="$(copy_templates write-batch)"
replace_env_value "${write_batch_dir}/command-api.env" "IM_MESSAGE_WRITE_BATCH_ENABLED" "false"
run_should_fail "command-api disabled message write batching fails" "command-api requires IM_MESSAGE_WRITE_BATCH_ENABLED=true" \
  run_preflight "${write_batch_dir}"

gateway_relay_secret_dir="$(copy_templates gateway-relay-secret)"
delete_env_key "${gateway_relay_secret_dir}/command-api.env" "IM_INTERNAL_SHARED_SECRET"
run_should_fail "command-api missing gateway relay secret fails" "command-api requires IM_INTERNAL_SHARED_SECRET" \
  run_preflight "${gateway_relay_secret_dir}"

gateway_command_ingress_dir="$(copy_templates gateway-command-ingress)"
delete_env_key "${gateway_command_ingress_dir}/gateway.env" "IM_COMMAND_API_INTERNAL_BASE_URL"
run_should_fail "gateway missing command-api ingress fails" "gateway requires IM_COMMAND_API_INTERNAL_BASE_URL" \
  run_preflight "${gateway_command_ingress_dir}"

timeline_invalidation_dir="$(copy_templates timeline-invalidation)"
delete_env_key "${timeline_invalidation_dir}/query-api.env" "IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE"
run_should_fail "query-api missing timeline cache invalidation fails" "query-api requires IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE=redis" \
  run_preflight "${timeline_invalidation_dir}"

timeline_recent_cache_dir="$(copy_templates timeline-recent-cache)"
delete_env_key "${timeline_recent_cache_dir}/query-api.env" "IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS"
run_should_fail "query-api missing timeline recent cache ttl fails" "query-api requires IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS >= 1000" \
  run_preflight "${timeline_recent_cache_dir}"

timeline_hot_cache_disabled_dir="$(copy_templates timeline-hot-cache-disabled)"
replace_env_value "${timeline_hot_cache_disabled_dir}/query-api.env" "IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS" "0"
run_should_fail "query-api disabled timeline hot cache fails" "query-api requires IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS >= 50" \
  run_preflight "${timeline_hot_cache_disabled_dir}"

timeline_recent_cache_disabled_dir="$(copy_templates timeline-recent-cache-disabled)"
replace_env_value "${timeline_recent_cache_disabled_dir}/query-api.env" "IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION" "0"
run_should_fail "query-api disabled timeline recent cache fails" "query-api requires IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION >= 128" \
  run_preflight "${timeline_recent_cache_disabled_dir}"

timeline_target_window_dir="$(copy_templates timeline-target-window)"
replace_env_value "${timeline_target_window_dir}/query-api.env" "IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS" "100"
run_should_fail "query-api oversized target sequence coalescing window fails" "query-api requires IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS <= 50" \
  run_preflight "${timeline_target_window_dir}"

gateway_internal_secret_dir="$(copy_templates gateway-internal-secret)"
delete_env_key "${gateway_internal_secret_dir}/gateway.env" "IM_INTERNAL_SHARED_SECRET"
run_should_fail "gateway missing internal shared secret fails" "gateway requires IM_INTERNAL_SHARED_SECRET" \
  run_preflight "${gateway_internal_secret_dir}"

multi_group_dir="$(copy_templates multi-group)"
replace_env_value "${multi_group_dir}/stream-summary.env" "IM_STREAM_CONSUMER_GROUPS" "summary-projection-consumer,domain-delivery-consumer"
run_should_fail "multi-group stream env without override fails" "requires exactly one IM_STREAM_CONSUMER_GROUPS entry per env file" \
  run_preflight "${multi_group_dir}"

stream_batch_fill_wait_dir="$(copy_templates stream-batch-fill-wait)"
delete_env_key "${stream_batch_fill_wait_dir}/stream-summary.env" "IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS"
run_should_fail "stream batch fill wait missing fails" "stream-consumer:${stream_batch_fill_wait_dir}/stream-summary.env requires IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS >= 1" \
  run_preflight "${stream_batch_fill_wait_dir}"

summary_coalesce_dir="$(copy_templates summary-coalesce)"
delete_env_key "${summary_coalesce_dir}/stream-summary.env" "IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS"
run_should_fail "summary stream missing activity coalescing window fails" "stream-consumer:${summary_coalesce_dir}/stream-summary.env requires IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS >= 50" \
  run_preflight "${summary_coalesce_dir}"

summary_coalesce_high_dir="$(copy_templates summary-coalesce-high)"
replace_env_value "${summary_coalesce_high_dir}/stream-summary.env" "IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS" "5000"
run_should_fail "summary stream high activity coalescing window fails" "stream-consumer:${summary_coalesce_high_dir}/stream-summary.env requires IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS <= 1000" \
  run_preflight "${summary_coalesce_high_dir}"

command_inline_dir="$(copy_templates command-inline)"
replace_env_value "${command_inline_dir}/command-api.env" "IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD" "1001"
run_should_fail "command-api inline recipient threshold above group limit fails" "command-api requires IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD <= IM_GROUP_MEMBER_LIMIT" \
  run_preflight "${command_inline_dir}"

command_dedup_dir="$(copy_templates command-dedup)"
replace_env_value "${command_dedup_dir}/command-api.env" "IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD" "1001"
run_should_fail "command-api dedup threshold above inline threshold fails" "command-api requires IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD <= IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD" \
  run_preflight "${command_dedup_dir}"

relay_conflict_dir="$(copy_templates relay-conflict)"
replace_env_value "${relay_conflict_dir}/stream-domain.env" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" "true"
run_should_fail "relay-after-record conflicts with realtime consumer" "stream-consumer deployment must not combine realtime-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true" \
  run_preflight "${relay_conflict_dir}"

missing_realtime_path_dir="$(copy_templates missing-realtime-path)"
replace_env_value "${missing_realtime_path_dir}/stream-realtime.env" "IM_STREAM_CONSUMER_GROUPS" "search-index-consumer"
run_should_fail "owner delivery skip requires realtime path" "stream-consumer deployment with large-group owner delivery skip requires realtime-delivery-consumer or IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true" \
  run_preflight "${missing_realtime_path_dir}"

timeline_pull_mode_dir="$(copy_templates timeline-pull-mode)"
replace_env_value "${timeline_pull_mode_dir}/stream-domain.env" "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE" "owner-delivery"
run_should_fail "owner-delivery mode with large-group skip threshold fails" "stream-consumer:${timeline_pull_mode_dir}/stream-domain.env requires IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE=timeline-pull" \
  run_preflight "${timeline_pull_mode_dir}"

owner_record_batch_min_dir="$(copy_templates owner-record-batch-min)"
replace_env_value "${owner_record_batch_min_dir}/stream-domain.env" "IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS" "1"
run_should_fail "owner record batch below production minimum fails" "stream-consumer:${owner_record_batch_min_dir}/stream-domain.env requires IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS >= 100" \
  run_preflight "${owner_record_batch_min_dir}"

summary_threshold_dir="$(copy_templates summary-threshold)"
replace_env_value "${summary_threshold_dir}/stream-summary.env" "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD" "600"
run_should_fail "summary activity threshold above owner delivery skip threshold fails" "stream-consumer:${summary_threshold_dir}/stream-summary.env requires IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD <= IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD" \
  run_preflight "${summary_threshold_dir}"

realtime_threshold_dir="$(copy_templates realtime-threshold)"
replace_env_value "${realtime_threshold_dir}/stream-realtime.env" "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD" "600"
run_should_fail "realtime lightweight threshold above owner delivery skip threshold fails" "stream-consumer:${realtime_threshold_dir}/stream-realtime.env requires IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD <= IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD" \
  run_preflight "${realtime_threshold_dir}"

realtime_full_fanout_hard_cap_dir="$(copy_templates realtime-full-fanout-hard-cap)"
replace_env_value "${realtime_full_fanout_hard_cap_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" "256"
run_should_fail "realtime full fanout above hard cap fails" "stream-consumer:${realtime_full_fanout_hard_cap_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT <= 128" \
  run_preflight "${realtime_full_fanout_hard_cap_dir}"

realtime_full_fanout_above_threshold_dir="$(copy_templates realtime-full-fanout-above-threshold)"
replace_env_value "${realtime_full_fanout_above_threshold_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" "64"
replace_env_value "${realtime_full_fanout_above_threshold_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" "128"
run_should_fail "realtime full fanout above active threshold fails" "stream-consumer:${realtime_full_fanout_above_threshold_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT <= IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" \
  run_preflight "${realtime_full_fanout_above_threshold_dir}"

realtime_full_fanout_mode_dir="$(copy_templates realtime-full-fanout-mode)"
replace_env_value "${realtime_full_fanout_mode_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE" "bounded"
run_should_fail "realtime bounded full fanout mode fails" "stream-consumer:${realtime_full_fanout_mode_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE=compact-only" \
  run_preflight "${realtime_full_fanout_mode_dir}"

realtime_inactive_hint_mode_dir="$(copy_templates realtime-inactive-hint-mode)"
replace_env_value "${realtime_inactive_hint_mode_dir}/stream-realtime.env" "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE" "relay"
run_should_fail "realtime inactive hint relay mode fails" "stream-consumer:${realtime_inactive_hint_mode_dir}/stream-realtime.env requires IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only" \
  run_preflight "${realtime_inactive_hint_mode_dir}"

notification_threshold_dir="$(copy_templates notification-threshold)"
replace_env_value "${notification_threshold_dir}/stream-notification.env" "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD" "600"
run_should_fail "notification threshold above owner delivery skip threshold fails" "stream-consumer:${notification_threshold_dir}/stream-notification.env requires IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD <= IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD" \
  run_preflight "${notification_threshold_dir}"

relay_after_record_coalesce_dir="$(copy_templates relay-after-record-coalesce)"
replace_env_value "${relay_after_record_coalesce_dir}/stream-realtime.env" "IM_STREAM_CONSUMER_GROUPS" "search-index-consumer"
replace_env_value "${relay_after_record_coalesce_dir}/stream-domain.env" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" "true"
replace_env_value "${relay_after_record_coalesce_dir}/stream-domain.env" "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS" "0"
run_should_fail "relay-after-record missing coalescing window fails" "stream-consumer:${relay_after_record_coalesce_dir}/stream-domain.env requires IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS >= 1" \
  run_preflight "${relay_after_record_coalesce_dir}"

realtime_active_compact_missing_coalesce_dir="$(copy_templates realtime-active-compact-missing-coalesce)"
replace_env_value "${realtime_active_compact_missing_coalesce_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS" "0"
run_should_fail "realtime active compact coalescing missing fails" "stream-consumer:${realtime_active_compact_missing_coalesce_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS >= 1" \
  run_preflight "${realtime_active_compact_missing_coalesce_dir}"

realtime_active_compact_coalesce_dir="$(copy_templates realtime-active-compact-coalesce)"
replace_env_value "${realtime_active_compact_coalesce_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS" "1000"
run_should_fail "realtime active compact coalescing above cap fails" "stream-consumer:${realtime_active_compact_coalesce_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS <= 100" \
  run_preflight "${realtime_active_compact_coalesce_dir}"

realtime_active_compact_body_dir="$(copy_templates realtime-active-compact-body)"
replace_env_value "${realtime_active_compact_body_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_COMPACT_HINT_BODY" "timeline-gap"
run_should_fail "realtime active compact body timeline-gap fails" "stream-consumer:${realtime_active_compact_body_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_COMPACT_HINT_BODY=conversation-activity" \
  run_preflight "${realtime_active_compact_body_dir}"

realtime_active_compact_preview_dir="$(copy_templates realtime-active-compact-preview)"
replace_env_value "${realtime_active_compact_preview_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS" "0"
run_should_fail "realtime active compact preview empty fails" "stream-consumer:${realtime_active_compact_preview_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS >= 1" \
  run_preflight "${realtime_active_compact_preview_dir}"

realtime_active_compact_preview_high_dir="$(copy_templates realtime-active-compact-preview-high)"
replace_env_value "${realtime_active_compact_preview_high_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS" "121"
run_should_fail "realtime active compact preview above cap fails" "stream-consumer:${realtime_active_compact_preview_high_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS <= 120" \
  run_preflight "${realtime_active_compact_preview_high_dir}"

relay_after_record_route_cache_dir="$(copy_templates relay-after-record-route-cache)"
replace_env_value "${relay_after_record_route_cache_dir}/stream-realtime.env" "IM_STREAM_CONSUMER_GROUPS" "search-index-consumer"
replace_env_value "${relay_after_record_route_cache_dir}/stream-domain.env" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" "true"
replace_env_value "${relay_after_record_route_cache_dir}/stream-domain.env" "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS" "0"
run_should_fail "relay-after-record missing active route cache fails" "stream-consumer:${relay_after_record_route_cache_dir}/stream-domain.env requires IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS >= 1" \
  run_preflight "${relay_after_record_route_cache_dir}"

relay_after_record_route_cache_bound_dir="$(copy_templates relay-after-record-route-cache-bound)"
replace_env_value "${relay_after_record_route_cache_bound_dir}/stream-realtime.env" "IM_STREAM_CONSUMER_GROUPS" "search-index-consumer"
replace_env_value "${relay_after_record_route_cache_bound_dir}/stream-domain.env" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" "true"
replace_env_value "${relay_after_record_route_cache_bound_dir}/stream-domain.env" "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES" "0"
run_should_fail "relay-after-record unbounded active route cache fails" "stream-consumer:${relay_after_record_route_cache_bound_dir}/stream-domain.env requires IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES >= 1" \
  run_preflight "${relay_after_record_route_cache_bound_dir}"

gateway_unsplit_fallback_dir="$(copy_templates gateway-unsplit-fallback)"
replace_env_value "${gateway_unsplit_fallback_dir}/gateway.env" "IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED" "true"
run_should_fail "gateway unsplit fallback enabled fails" "gateway requires IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED=false" \
  run_preflight "${gateway_unsplit_fallback_dir}"

gateway_active_compact_body_dir="$(copy_templates gateway-active-compact-body)"
replace_env_value "${gateway_active_compact_body_dir}/gateway.env" "IM_REALTIME_ACTIVE_COMPACT_HINT_BODY" "timeline-gap"
run_should_fail "gateway active compact body timeline-gap fails" "gateway requires IM_REALTIME_ACTIVE_COMPACT_HINT_BODY=conversation-activity" \
  run_preflight "${gateway_active_compact_body_dir}"

gateway_active_compact_preview_dir="$(copy_templates gateway-active-compact-preview)"
replace_env_value "${gateway_active_compact_preview_dir}/gateway.env" "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS" "0"
run_should_fail "gateway active compact preview empty fails" "gateway requires IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS >= 1" \
  run_preflight "${gateway_active_compact_preview_dir}"

gateway_active_compact_preview_high_dir="$(copy_templates gateway-active-compact-preview-high)"
replace_env_value "${gateway_active_compact_preview_high_dir}/gateway.env" "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS" "121"
run_should_fail "gateway active compact preview above cap fails" "gateway requires IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS <= 120" \
  run_preflight "${gateway_active_compact_preview_high_dir}"

realtime_preview_lookup_dir="$(copy_templates realtime-preview-lookup)"
replace_env_value "${realtime_preview_lookup_dir}/stream-realtime.env" "IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED" "true"
run_should_fail "realtime stream preview lookup enabled fails" "stream-consumer:${realtime_preview_lookup_dir}/stream-realtime.env requires IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED=false" \
  run_preflight "${realtime_preview_lookup_dir}"

realtime_summary_member_limit_dir="$(copy_templates realtime-summary-member-limit)"
replace_env_value "${realtime_summary_member_limit_dir}/stream-realtime.env" "IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT" "0"
run_should_fail "realtime stream summary member ids limit disabled fails" "stream-consumer:${realtime_summary_member_limit_dir}/stream-realtime.env requires IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT >= 1" \
  run_preflight "${realtime_summary_member_limit_dir}"

realtime_unsplit_fallback_dir="$(copy_templates realtime-unsplit-fallback)"
replace_env_value "${realtime_unsplit_fallback_dir}/stream-realtime.env" "IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED" "true"
run_should_fail "realtime stream unsplit fallback enabled fails" "stream-consumer:${realtime_unsplit_fallback_dir}/stream-realtime.env requires IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED=false" \
  run_preflight "${realtime_unsplit_fallback_dir}"

relay_after_record_unsplit_fallback_dir="$(copy_templates relay-after-record-unsplit-fallback)"
replace_env_value "${relay_after_record_unsplit_fallback_dir}/stream-realtime.env" "IM_STREAM_CONSUMER_GROUPS" "search-index-consumer"
replace_env_value "${relay_after_record_unsplit_fallback_dir}/stream-domain.env" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" "true"
replace_env_value "${relay_after_record_unsplit_fallback_dir}/stream-domain.env" "IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED" "true"
run_should_fail "relay-after-record unsplit fallback enabled fails" "stream-consumer:${relay_after_record_unsplit_fallback_dir}/stream-domain.env requires IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED=false" \
  run_preflight "${relay_after_record_unsplit_fallback_dir}"

relay_after_record_inactive_hint_mode_dir="$(copy_templates relay-after-record-inactive-hint-mode)"
replace_env_value "${relay_after_record_inactive_hint_mode_dir}/stream-realtime.env" "IM_STREAM_CONSUMER_GROUPS" "search-index-consumer"
replace_env_value "${relay_after_record_inactive_hint_mode_dir}/stream-domain.env" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" "true"
replace_env_value "${relay_after_record_inactive_hint_mode_dir}/stream-domain.env" "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE" "relay"
run_should_fail "relay-after-record inactive hint relay mode fails" "stream-consumer:${relay_after_record_inactive_hint_mode_dir}/stream-domain.env requires IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only" \
  run_preflight "${relay_after_record_inactive_hint_mode_dir}"

conversation_shard_dir="$(copy_templates conversation-shard)"
delete_env_key "${conversation_shard_dir}/command-api.env" "DATABASE_CONVERSATION_SHARD_0_PASSWORD"
run_should_fail "conversation shard database config must be complete" "command-api conversation shard shard-0 requires DATABASE_CONVERSATION_SHARD_0_PASSWORD" \
  run_preflight "${conversation_shard_dir}"

summary_shard_dir="$(copy_templates summary-shard)"
delete_env_key "${summary_shard_dir}/query-api.env" "DATABASE_SUMMARY_SUMMARY_B_HOST"
run_should_fail "summary shard database config must be complete" "query-api summary shard summary-b requires DATABASE_SUMMARY_SUMMARY_B_HOST" \
  run_preflight "${summary_shard_dir}"

echo "production_env_preflight_test passed."
