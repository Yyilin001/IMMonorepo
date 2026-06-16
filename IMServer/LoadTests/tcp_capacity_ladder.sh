#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCP_DRIVER_DIR="${SCRIPT_DIR}/TCPDriver"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

default_protocol_version() {
  local version_file="${REPO_ROOT}/Protocol/im_realtime/v1/protocol_version.txt"
  if [[ -f "${version_file}" ]]; then
    tr -d '[:space:]' <"${version_file}"
  else
    echo "12"
  fi
}

BASE_URL="${BASE_URL:-http://120.25.106.200:8080}"
TCP_HOST="${TCP_HOST:-120.25.106.200}"
TCP_PORT="${TCP_PORT:-9000}"
IM_EMAIL="${IM_EMAIL:-demo@example.com}"
IM_PASSWORD="${IM_PASSWORD:-password1234}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}"
LADDER="${LADDER:-100 500 1000 2000 5000 10000}"
DEVICES_PER_USER="${DEVICES_PER_USER:-}"
MESSAGES="${MESSAGES:-1}"
SEND_INTERVAL_MS="${SEND_INTERVAL_MS:-0}"
MESSAGE_PROFILE="${MESSAGE_PROFILE:-per-connection}"
MESSAGE_RATE_PER_SECOND="${MESSAGE_RATE_PER_SECOND:-0}"
MESSAGE_SENDER_EVERY="${MESSAGE_SENDER_EVERY:-1}"
MESSAGE_RECEIVER_OFFSET="${MESSAGE_RECEIVER_OFFSET:-1}"
ACTIVE_CONVERSATION_USERS="${ACTIVE_CONVERSATION_USERS:-0}"
GLOBAL_HOLD_BARRIER_MIN_RATIO="${GLOBAL_HOLD_BARRIER_MIN_RATIO:-1.0}"
HOLD_SECONDS="${HOLD_SECONDS:-0}"
CONNECT_RAMP_SECONDS="${CONNECT_RAMP_SECONDS:-0}"
LOGIN_CONCURRENCY="${LOGIN_CONCURRENCY:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-0}"
HEARTBEAT_JITTER_SECONDS="${HEARTBEAT_JITTER_SECONDS:--1}"
HEARTBEAT_LOG_MODE="${HEARTBEAT_LOG_MODE:-errors}"
HEARTBEAT_LOG_SAMPLE_RATE="${HEARTBEAT_LOG_SAMPLE_RATE:-100}"
CONNECTION_QUEUE_POOL_SIZE="${CONNECTION_QUEUE_POOL_SIZE:-256}"
MAX_RECONNECTS="${MAX_RECONNECTS:-0}"
RECONNECT_DELAY_MS="${RECONNECT_DELAY_MS:-1000}"
LOGIN_RETRIES="${LOGIN_RETRIES:-2}"
LOGIN_RETRY_DELAY_MS="${LOGIN_RETRY_DELAY_MS:-1000}"
LOGIN_MODE="${LOGIN_MODE:-upfront}"
LOGIN_CACHE_DIR="${LOGIN_CACHE_DIR:-/tmp/imtcp-login-cache}"
LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE:-}"
PREWARM_LOGIN_CACHE="${PREWARM_LOGIN_CACHE:-auto}"
REQUIRE_LOGIN_CACHE="${REQUIRE_LOGIN_CACHE:-false}"
LOGIN_CACHE_TTL_GUARD_SECONDS="${LOGIN_CACHE_TTL_GUARD_SECONDS:-60}"
LOAD_GENERATOR_ID="${LOAD_GENERATOR_ID:-1}"
LOAD_GENERATOR_COUNT="${LOAD_GENERATOR_COUNT:-1}"
ACCOUNT_SHARD_OFFSET="${ACCOUNT_SHARD_OFFSET:-}"
ACCOUNT_SHARD_LIMIT="${ACCOUNT_SHARD_LIMIT:-}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-15}"
SAMPLE_DURING_SECONDS="${SAMPLE_DURING_SECONDS:-15}"
PROTOCOL_VERSION="${PROTOCOL_VERSION:-$(default_protocol_version)}"
SSH_HOST="${SSH_HOST:-}"
CONNECTION_LOG_DIR="${CONNECTION_LOG_DIR:-}"
REMOTE_METRICS_TIMEOUT_SECONDS="${REMOTE_METRICS_TIMEOUT_SECONDS:-10}"
REMOTE_SERVICE_NAMES="${REMOTE_SERVICE_NAMES:-imserver-gateway imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer imserver-summary-projection-consumer imserver-realtime-delivery-consumer imserver-notification-consumer}"
KAFKA_BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVER:-127.0.0.1:9092}"
KAFKA_CONSUMER_GROUPS="${KAFKA_CONSUMER_GROUPS:-domain-delivery-consumer summary-projection-consumer realtime-delivery-consumer notification-consumer}"
KAFKA_CONSUMER_GROUPS_CMD="${KAFKA_CONSUMER_GROUPS_CMD:-/opt/kafka/bin/kafka-consumer-groups.sh}"
COLLECT_REMOTE_METRICS="${COLLECT_REMOTE_METRICS:-true}"
COLLECT_IM_METRICS="${COLLECT_IM_METRICS:-true}"
COLLECT_IM_METRICS_DELTA="${COLLECT_IM_METRICS_DELTA:-true}"
IM_METRICS_GATE_MODE="${IM_METRICS_GATE_MODE:-warn}"
IM_GATE_CLIENT_CATCH_UP_FAILURES_MAX="${IM_GATE_CLIENT_CATCH_UP_FAILURES_MAX:-0}"
IM_GATE_CLIENT_CATCH_UP_DEFERRED_MAX="${IM_GATE_CLIENT_CATCH_UP_DEFERRED_MAX:-0}"
IM_GATE_TIMELINE_INVALIDATION_ERRORS_MAX="${IM_GATE_TIMELINE_INVALIDATION_ERRORS_MAX:-0}"
IM_GATE_STREAM_FAILED_EVENTS_MAX="${IM_GATE_STREAM_FAILED_EVENTS_MAX:-0}"
IM_GATE_TCP_DROPPED_BACKPRESSURE_MAX="${IM_GATE_TCP_DROPPED_BACKPRESSURE_MAX:-0}"
IM_GATE_TCP_BACKPRESSURE_MAX="${IM_GATE_TCP_BACKPRESSURE_MAX:-0}"
IM_GATE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX="${IM_GATE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX:-0}"
IM_GATE_REMOTE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX="${IM_GATE_REMOTE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX:-0}"
IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_DISPATCHES_MAX="${IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_DISPATCHES_MAX:-0}"
IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_RECIPIENT_DELIVERIES_MAX="${IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_RECIPIENT_DELIVERIES_MAX:-0}"
IM_GATE_GATEWAY_HTTP_RELAY_SKIPPED_RECIPIENTS_MAX="${IM_GATE_GATEWAY_HTTP_RELAY_SKIPPED_RECIPIENTS_MAX:-0}"
IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_FAILURES_MAX="${IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_FAILURES_MAX:-0}"
IM_GATE_GATEWAY_HTTP_RELAY_BINARY_FALLBACKS_MAX="${IM_GATE_GATEWAY_HTTP_RELAY_BINARY_FALLBACKS_MAX:-0}"
IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_FAILURES_MAX="${IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_FAILURES_MAX:-0}"
IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_MAX_BODY_BYTES="${IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_MAX_BODY_BYTES:-1048576}"
IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_MAX_BODY_BYTES="${IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_MAX_BODY_BYTES:-1048576}"
IM_GATE_CATCH_UP_REQUEST_MAX_MS="${IM_GATE_CATCH_UP_REQUEST_MAX_MS:-10000}"
IM_GATE_CATCH_UP_HINT_TO_APPLY_MAX_MS="${IM_GATE_CATCH_UP_HINT_TO_APPLY_MAX_MS:-10000}"
IM_GATE_TIMELINE_READ_MAX_MS="${IM_GATE_TIMELINE_READ_MAX_MS:-10000}"
IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS="${IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS:-2000}"
IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS="${IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS:-5000}"
IM_GATE_TIMELINE_VISIBILITY_SCAN_LIMIT_EXCEEDED_MAX="${IM_GATE_TIMELINE_VISIBILITY_SCAN_LIMIT_EXCEEDED_MAX:-0}"
IM_GATE_TIMELINE_SINCE_NOTICE_BYPASSES_MAX="${IM_GATE_TIMELINE_SINCE_NOTICE_BYPASSES_MAX:-0}"
IM_GATE_TIMELINE_SINCE_VISIBILITY_NOTICE_BYPASSES_MAX="${IM_GATE_TIMELINE_SINCE_VISIBILITY_NOTICE_BYPASSES_MAX:-0}"
IM_GATE_OWNER_BATCH_WRITE_MAX_MS="${IM_GATE_OWNER_BATCH_WRITE_MAX_MS:-5000}"
IM_GATE_PROJECTION_LAG_MAX_MS="${IM_GATE_PROJECTION_LAG_MAX_MS:-60000}"
IM_GATE_TARGET_SEQUENCE_STRONG_MISSES_MAX="${IM_GATE_TARGET_SEQUENCE_STRONG_MISSES_MAX:-0}"
IM_GATE_TARGET_SEQUENCE_ERRORS_MAX="${IM_GATE_TARGET_SEQUENCE_ERRORS_MAX:-0}"
IM_GATE_TARGET_SEQUENCE_SINGLEFLIGHT_MIN_FALLBACKS="${IM_GATE_TARGET_SEQUENCE_SINGLEFLIGHT_MIN_FALLBACKS:-10}"
IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT="${IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT:-25}"
IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS="${IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS:-20}"
IM_METRICS_URL="${IM_METRICS_URL:-http://127.0.0.1:8080/internal/metrics}"
IM_METRICS_SECRET="${IM_METRICS_SECRET:-${IM_METRICS_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}}"
DEFAULT_IM_METRICS_NAMES=(
  im_tcp_connections
  im_tcp_channels
  im_tcp_write_backpressure_total
  im_tcp_write_dropped_backpressure_total
  im_tcp_write_latency_avg_millis
  im_tcp_write_latency_max_millis
  im_user_fanout_total
  im_gateway_http_relay_skipped_recipients_total
  im_gateway_http_relay_request_failures_total
  im_gateway_http_relay_request_max_body_bytes
  im_gateway_http_relay_binary_fallbacks_total
  im_gateway_http_relay_inbound_failures_total
  im_gateway_http_relay_inbound_max_body_bytes
  im_local_fanout_packets_total
  im_local_fanout_target_connections_total
  im_local_fanout_event_loop_jobs_total
  im_realtime_active_conversation_fanout_splits_total
  im_realtime_active_conversation_fanout_active_recipients_total
  im_realtime_active_conversation_fanout_compact_active_recipients_total
  im_realtime_active_conversation_fanout_inactive_hint_recipients_total
  im_realtime_active_conversation_fanout_downgraded_active_recipients_total
  im_realtime_active_conversation_fanout_backpressure_downgraded_active_recipients_total
  im_realtime_active_conversation_fanout_route_split_drops_total
  im_realtime_active_conversation_fanout_route_split_drop_recipients_total
  im_realtime_active_conversation_route_cache_hits_total
  im_realtime_active_conversation_route_cache_partial_hits_total
  im_realtime_active_conversation_route_cache_misses_total
  im_realtime_active_conversation_route_cache_cached_users_total
  im_realtime_active_conversation_route_cache_missed_users_total
  im_realtime_active_conversation_route_cache_joined_in_flight_total
  im_realtime_remote_active_conversation_fanout_route_split_drops_total
  im_realtime_remote_active_conversation_fanout_route_split_drop_recipients_total
  im_realtime_inactive_conversation_hint_flushes_total
  im_realtime_inactive_conversation_hint_payload_batches_total
  im_realtime_inactive_conversation_hint_recipients_total
  im_realtime_coalesced_dispatch_replacements_total
  im_realtime_coalesced_dropped_recipient_deliveries_total
  im_realtime_async_relay_dropped_dispatches_total
  im_realtime_async_relay_dropped_recipient_deliveries_total
  im_timeline_since_hot_cache_hits_total
  im_timeline_since_hot_cache_misses_total
  im_timeline_since_hot_cache_unsafe_bypasses_total
  im_timeline_since_hot_cache_target_sequence_bypasses_total
  im_timeline_since_recent_cache_hits_total
  im_timeline_since_recent_cache_misses_total
  im_timeline_since_recent_cache_target_sequence_bypasses_total
  im_timeline_since_recent_cache_stores_total
  im_timeline_since_recent_cache_invalidations_total
  im_timeline_since_recent_cache_invalidated_entries_total
  im_timeline_since_response_singleflight_joined_total
  im_timeline_since_response_singleflight_notice_bypasses_total
  im_timeline_since_visibility_notice_bypasses_total
  im_timeline_since_distributed_invalidations_published_total
  im_timeline_since_distributed_invalidations_received_total
  im_timeline_since_distributed_invalidation_errors_total
  im_timeline_since_target_sequence_requests_total
  im_timeline_since_target_sequence_eventual_satisfied_total
  im_timeline_since_target_sequence_strong_fallbacks_total
  im_timeline_since_target_sequence_strong_satisfied_total
  im_timeline_since_target_sequence_strong_misses_total
  im_timeline_since_target_sequence_errors_total
  im_timeline_since_target_sequence_singleflight_joined_total
  im_timeline_since_target_sequence_window_joined_total
  im_timeline_read_visibility_scan_rows_total
  im_timeline_read_visibility_scan_max_rows
  im_timeline_read_visibility_scan_pages_total
  im_timeline_read_visibility_scan_max_pages
  im_timeline_read_visibility_scan_limit_exceeded_total
  im_timeline_read_latency_millis_bucket
  im_timeline_read_latency_millis_count
  im_timeline_read_latency_millis_sum
  im_timeline_read_latency_max_millis
  im_client_health_reports_total
  im_client_health_reporting_users
  im_client_timeline_catch_up_hint_queued_total
  im_client_timeline_catch_up_since_requests_total
  im_client_timeline_catch_up_since_successes_total
  im_client_timeline_catch_up_since_failures_total
  im_client_timeline_catch_up_deferred_total
  im_client_timeline_catch_up_applied_items_total
  im_client_timeline_catch_up_hint_to_request_max_millis
  im_client_timeline_catch_up_hint_to_request_avg_millis
  im_client_timeline_catch_up_request_max_millis
  im_client_timeline_catch_up_request_avg_millis
  im_client_timeline_catch_up_hint_to_apply_max_millis
  im_client_timeline_catch_up_hint_to_apply_avg_millis
  im_client_timeline_catch_up_config_selected_hint_initial_jitter_max_millis
  im_client_timeline_catch_up_config_selected_hint_initial_jitter_avg_millis
  im_client_timeline_catch_up_config_selected_hint_min_interval_max_millis
  im_client_timeline_catch_up_config_selected_hint_min_interval_avg_millis
  im_client_timeline_catch_up_config_selected_hint_micro_batch_max_millis
  im_client_timeline_catch_up_config_selected_hint_micro_batch_avg_millis
  im_domain_event_owner_delivery_batch_write_latency_avg_millis
  im_domain_event_owner_delivery_batch_write_latency_max_millis
  im_domain_event_owner_delivery_batch_write_chunked_total
  im_domain_event_owner_delivery_batch_write_chunks_total
  im_domain_relay_after_record_active_route_cache_hits_total
  im_domain_relay_after_record_active_route_cache_partial_hits_total
  im_domain_relay_after_record_active_route_cache_misses_total
  im_domain_relay_after_record_active_route_cache_cached_users_total
  im_domain_relay_after_record_active_route_cache_missed_users_total
  im_domain_relay_after_record_active_route_cache_joined_in_flight_total
  im_projection_lag_millis
  im_stream_consumed_events_total
  im_stream_failed_events_total
  im_stream_processed_runs_total
  im_stream_message_created_runs_total
  im_stream_message_created_run_events_total
  im_stream_message_created_run_events_avg
  im_stream_message_created_run_max_events
  im_stream_processing_batches_total
  im_stream_processing_batch_events_total
  im_stream_processing_batch_events_avg
  im_stream_processing_batch_max_events
  im_stream_batch_fill_waits_total
  im_stream_batch_fill_wait_millis_total
  im_stream_batch_fill_wait_avg_millis
  im_stream_batch_fill_events_total
  im_stream_batch_fill_skipped_batches_total
  im_stream_run_events_total
  im_stream_run_max_events
  im_stream_run_event_lag_avg_millis
  im_stream_run_event_lag_max_millis
)
IM_METRICS_NAMES="${IM_METRICS_NAMES:-${DEFAULT_IM_METRICS_NAMES[*]}}"

collect_remote_metrics() {
  local label="$1"
  if ! bool_enabled "${COLLECT_REMOTE_METRICS}"; then
    return
  fi
  if [[ -z "${SSH_HOST}" ]]; then
    return
  fi

  echo "== remote metrics: ${label} =="
  ssh "${SSH_HOST}" \
    "REMOTE_METRICS_TIMEOUT_SECONDS='${REMOTE_METRICS_TIMEOUT_SECONDS}' REMOTE_SERVICE_NAMES='${REMOTE_SERVICE_NAMES}' KAFKA_BOOTSTRAP_SERVER='${KAFKA_BOOTSTRAP_SERVER}' KAFKA_CONSUMER_GROUPS='${KAFKA_CONSUMER_GROUPS}' KAFKA_CONSUMER_GROUPS_CMD='${KAFKA_CONSUMER_GROUPS_CMD}' COLLECT_IM_METRICS='${COLLECT_IM_METRICS}' IM_METRICS_URL='${IM_METRICS_URL}' IM_METRICS_SECRET='${IM_METRICS_SECRET}' IM_METRICS_NAMES='${IM_METRICS_NAMES}' bash -s" <<'REMOTE'
set -euo pipefail
run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}" "$@" || true
  else
    "$@" || true
  fi
}
bool_enabled() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}
print_selected_im_metrics() {
  if ! bool_enabled "${COLLECT_IM_METRICS:-true}"; then
    return
  fi
  if [[ -z "${IM_METRICS_URL:-}" ]]; then
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl unavailable; skipping /internal/metrics"
    return
  fi

  local metrics_file
  metrics_file="$(mktemp)"
  local curl_status=0
  if [[ -n "${IM_METRICS_SECRET:-}" ]]; then
    run_with_timeout "${REMOTE_METRICS_TIMEOUT_SECONDS}" \
      curl -fsS -H "X-IM-Metrics-Secret: ${IM_METRICS_SECRET}" "${IM_METRICS_URL}" >"${metrics_file}" || curl_status=$?
  else
    run_with_timeout "${REMOTE_METRICS_TIMEOUT_SECONDS}" \
      curl -fsS "${IM_METRICS_URL}" >"${metrics_file}" || curl_status=$?
  fi
  if [[ "${curl_status}" != "0" ]]; then
    echo "/internal/metrics unavailable from ${IM_METRICS_URL}"
    rm -f "${metrics_file}"
    return
  fi

  if [[ -n "${IM_METRICS_NAMES:-}" ]]; then
    awk -v names="${IM_METRICS_NAMES}" '
      BEGIN {
        split(names, metric_names, " ")
        for (index in metric_names) {
          wanted[metric_names[index]] = 1
        }
      }
      /^#/ { next }
      {
        metric = $1
        sub(/\{.*/, "", metric)
        if (wanted[metric]) { print }
      }
    ' "${metrics_file}"
  else
    grep -v '^#' "${metrics_file}" || true
  fi
  rm -f "${metrics_file}"
}
echo "-- memory --"
free -m
echo "-- tcp established on 9000 --"
ss -tan state established "( sport = :9000 )" | wc -l
echo "-- im metrics --"
print_selected_im_metrics
echo "-- services --"
if [[ -n "${REMOTE_SERVICE_NAMES:-}" ]]; then
  for service_name in ${REMOTE_SERVICE_NAMES}; do
    status="unknown"
    if command -v systemctl >/dev/null 2>&1; then
      status="$(systemctl is-active "${service_name}" 2>/dev/null || true)"
    else
      status="systemctl-unavailable"
    fi
    printf "%s %s\n" "${service_name}" "${status}"
  done
fi
if [[ -n "${KAFKA_CONSUMER_GROUPS:-}" ]]; then
  kafka_consumer_groups_cmd="${KAFKA_CONSUMER_GROUPS_CMD:-/opt/kafka/bin/kafka-consumer-groups.sh}"
  for consumer_group in ${KAFKA_CONSUMER_GROUPS}; do
    echo "-- kafka lag: ${consumer_group} --"
    if [[ "${kafka_consumer_groups_cmd}" == */* ]]; then
      if [[ ! -x "${kafka_consumer_groups_cmd}" ]]; then
        echo "kafka consumer groups command unavailable: ${kafka_consumer_groups_cmd}"
        continue
      fi
    elif ! command -v "${kafka_consumer_groups_cmd}" >/dev/null 2>&1; then
      echo "kafka consumer groups command unavailable: ${kafka_consumer_groups_cmd}"
      continue
    fi
    run_with_timeout "${REMOTE_METRICS_TIMEOUT_SECONDS}" \
      "${kafka_consumer_groups_cmd}" \
      --bootstrap-server "${KAFKA_BOOTSTRAP_SERVER:-127.0.0.1:9092}" \
      --describe \
      --group "${consumer_group}"
  done
fi
REMOTE
}

capture_remote_im_metrics() {
  local output_file="$1"
  if ! bool_enabled "${COLLECT_REMOTE_METRICS}"; then
    return
  fi
  if ! bool_enabled "${COLLECT_IM_METRICS}"; then
    return
  fi
  if ! bool_enabled "${COLLECT_IM_METRICS_DELTA}"; then
    return
  fi
  if [[ -z "${SSH_HOST}" ]]; then
    return
  fi

  ssh "${SSH_HOST}" \
    "REMOTE_METRICS_TIMEOUT_SECONDS='${REMOTE_METRICS_TIMEOUT_SECONDS}' IM_METRICS_URL='${IM_METRICS_URL}' IM_METRICS_SECRET='${IM_METRICS_SECRET}' IM_METRICS_NAMES='${IM_METRICS_NAMES}' bash -s" >"${output_file}" <<'REMOTE' || true
set -euo pipefail
run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}" "$@" || true
  else
    "$@" || true
  fi
}
if [[ -z "${IM_METRICS_URL:-}" ]] || ! command -v curl >/dev/null 2>&1; then
  exit 0
fi
metrics_file="$(mktemp)"
trap 'rm -f "${metrics_file}"' EXIT
curl_status=0
if [[ -n "${IM_METRICS_SECRET:-}" ]]; then
  run_with_timeout "${REMOTE_METRICS_TIMEOUT_SECONDS}" \
    curl -fsS -H "X-IM-Metrics-Secret: ${IM_METRICS_SECRET}" "${IM_METRICS_URL}" >"${metrics_file}" || curl_status=$?
else
  run_with_timeout "${REMOTE_METRICS_TIMEOUT_SECONDS}" \
    curl -fsS "${IM_METRICS_URL}" >"${metrics_file}" || curl_status=$?
fi
if [[ "${curl_status}" != "0" ]]; then
  exit 0
fi
awk -v names="${IM_METRICS_NAMES}" '
  BEGIN {
    split(names, metric_names, " ")
    for (index in metric_names) {
      wanted[metric_names[index]] = 1
    }
  }
  /^#/ { next }
  {
    metric = $1
    sub(/\{.*/, "", metric)
    if (wanted[metric]) { print $1, $2 }
  }
' "${metrics_file}"
REMOTE
}

print_im_metrics_delta() {
  local before_file="$1"
  local after_file="$2"
  local label="$3"
  if [[ ! -s "${before_file}" || ! -s "${after_file}" ]]; then
    return
  fi

  echo "== im metrics delta: ${label} =="
  awk '
    FNR == NR {
      before[$1] = $2 + 0
      next
    }
    {
      metric = $1
      after = $2 + 0
      if (!(metric in before)) {
        next
      }
      delta = after - before[metric]
      if (metric ~ /_total$/) {
        printf "%s delta=%g before=%g after=%g\n", metric, delta, before[metric], after
      } else {
        printf "%s value=%g delta=%g before=%g\n", metric, after, delta, before[metric]
      }
    }
  ' "${before_file}" "${after_file}"
}

metric_sum_or_empty() {
  local file="$1"
  local name="$2"
  awk -v name="${name}" '
    {
      metric = $1
      sub(/\{.*/, "", metric)
      if (metric == name) {
        sum += $2 + 0
        found = 1
      }
    }
    END {
      if (found) {
        print sum
      }
    }
  ' "${file}"
}

metric_max_or_empty() {
  local file="$1"
  local name="$2"
  awk -v name="${name}" '
    {
      metric = $1
      sub(/\{.*/, "", metric)
      if (metric == name) {
        value = $2 + 0
        if (!found || value > max) {
          max = value
        }
        found = 1
      }
    }
    END {
      if (found) {
        print max
      }
    }
  ' "${file}"
}

metric_value_or_empty() {
  local file="$1"
  local name="$2"
  awk -v name="${name}" '
    $1 == name {
      print $2 + 0
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 0
      }
    }
  ' "${file}"
}

metric_delta_or_empty() {
  local before_file="$1"
  local after_file="$2"
  local name="$3"
  local before after
  before="$(metric_value_or_empty "${before_file}" "${name}")"
  after="$(metric_value_or_empty "${after_file}" "${name}")"
  if [[ -z "${before}" || -z "${after}" ]]; then
    return
  fi
  awk -v before="${before}" -v after="${after}" 'BEGIN { print after - before }'
}

histogram_quantile_delta_upper_bound() {
  local before_file="$1"
  local after_file="$2"
  local metric="$3"
  local kind="$4"
  local quantile="$5"
  local deltas total target
  deltas="$(
    awk -v name="${metric}_bucket" -v kind="${kind}" '
      FNR == NR {
        metric_name = $1
        if (metric_name ~ ("^" name "\\{") && index(metric_name, "kind=\"" kind "\"") > 0) {
          le = metric_name
          sub(/^.*le="/, "", le)
          sub(/".*$/, "", le)
          before[le] = $2 + 0
        }
        next
      }
      {
        metric_name = $1
        if (metric_name ~ ("^" name "\\{") && index(metric_name, "kind=\"" kind "\"") > 0) {
          le = metric_name
          sub(/^.*le="/, "", le)
          sub(/".*$/, "", le)
          delta = ($2 + 0) - before[le]
          if (delta < 0) {
            delta = 0
          }
          print le, delta
        }
      }
    ' "${before_file}" "${after_file}"
  )"
  if [[ -z "${deltas}" ]]; then
    return
  fi
  total="$(printf '%s\n' "${deltas}" | awk '$1 == "+Inf" { print $2; found = 1 } END { if (!found) exit 0 }')"
  if [[ -z "${total}" ]]; then
    return
  fi
  if ! awk -v total="${total}" 'BEGIN { exit !(total > 0) }'; then
    return
  fi
  target="$(awk -v total="${total}" -v quantile="${quantile}" 'BEGIN { print total * quantile }')"
  printf '%s\n' "${deltas}" |
    awk '$1 != "+Inf" { print $1, $2 }' |
    sort -n |
    awk -v target="${target}" '
      {
        last = $1
        if ($2 >= target) {
          print $1
          found = 1
          exit
        }
      }
      END {
        if (!found && last != "") {
          print 1000000000
        }
      }
    '
}

print_timeline_read_latency_summary() {
  local before_file="$1"
  local after_file="$2"
  local label="$3"
  if [[ ! -s "${before_file}" || ! -s "${after_file}" ]]; then
    return
  fi

  local since_count since_p95 since_p99 history_count
  since_count="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_read_latency_millis_count{kind=\"since\"}")"
  history_count="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_read_latency_millis_count{kind=\"history\"}")"
  since_p95="$(histogram_quantile_delta_upper_bound "${before_file}" "${after_file}" "im_timeline_read_latency_millis" "since" "0.95")"
  since_p99="$(histogram_quantile_delta_upper_bound "${before_file}" "${after_file}" "im_timeline_read_latency_millis" "since" "0.99")"
  if [[ -z "${since_count}" && -z "${history_count}" && -z "${since_p95}" && -z "${since_p99}" ]]; then
    return
  fi
  echo "== timeline read latency summary: ${label} =="
  printf "sinceReadCountDelta=%s historyReadCountDelta=%s sinceReadLatencyP95Ms=%s sinceReadLatencyP99Ms=%s\n" \
    "${since_count:-0}" \
    "${history_count:-0}" \
    "${since_p95:-n/a}" \
    "${since_p99:-n/a}"
}

print_target_sequence_catchup_summary() {
  local before_file="$1"
  local after_file="$2"
  local label="$3"
  if [[ ! -s "${before_file}" || ! -s "${after_file}" ]]; then
    return
  fi

  local requests eventual fallback strong_satisfied strong_misses errors singleflight notice_bypass target_singleflight target_window hot_bypass recent_bypass
  requests="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_requests_total")"
  eventual="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_eventual_satisfied_total")"
  fallback="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_strong_fallbacks_total")"
  strong_satisfied="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_strong_satisfied_total")"
  strong_misses="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_strong_misses_total")"
  errors="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_errors_total")"
  singleflight="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_response_singleflight_joined_total")"
  notice_bypass="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_response_singleflight_notice_bypasses_total")"
  target_singleflight="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_singleflight_joined_total")"
  target_window="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_window_joined_total")"
  hot_bypass="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_hot_cache_target_sequence_bypasses_total")"
  recent_bypass="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_recent_cache_target_sequence_bypasses_total")"

  if [[ -z "${requests}" && -z "${fallback}" && -z "${target_singleflight}" && -z "${target_window}" && -z "${singleflight}" && -z "${notice_bypass}" && -z "${hot_bypass}" && -z "${recent_bypass}" ]]; then
    return
  fi

  echo "== target-sequence catch-up summary: ${label} =="
  awk \
    -v requests="${requests:-0}" \
    -v eventual="${eventual:-0}" \
    -v fallback="${fallback:-0}" \
    -v strong_satisfied="${strong_satisfied:-0}" \
    -v strong_misses="${strong_misses:-0}" \
    -v errors="${errors:-0}" \
    -v singleflight="${singleflight:-0}" \
    -v notice_bypass="${notice_bypass:-0}" \
    -v target_singleflight="${target_singleflight:-0}" \
    -v target_window="${target_window:-0}" \
    -v hot_bypass="${hot_bypass:-0}" \
    -v recent_bypass="${recent_bypass:-0}" '
    BEGIN {
      fallback_rate = requests > 0 ? (fallback / requests) * 100 : 0
      eventual_rate = requests > 0 ? (eventual / requests) * 100 : 0
      target_singleflight_per_fallback = fallback > 0 ? target_singleflight / fallback : 0
      printf "targetRequestsDelta=%g eventualSatisfiedDelta=%g strongFallbackDelta=%g strongSatisfiedDelta=%g strongMissDelta=%g errorsDelta=%g\n", requests, eventual, fallback, strong_satisfied, strong_misses, errors
      printf "eventualSatisfiedRate=%.2f%% strongFallbackRate=%.2f%% targetSingleflightJoinedDelta=%g targetWindowJoinedDelta=%g targetSingleflightJoinedPerFallback=%.2f genericSingleflightJoinedDelta=%g\n", eventual_rate, fallback_rate, target_singleflight, target_window, target_singleflight_per_fallback, singleflight
      printf "hotCacheTargetBypassDelta=%g recentCacheTargetBypassDelta=%g noticeBypassDelta=%g\n", hot_bypass, recent_bypass, notice_bypass
      if (requests == 0) {
        print "targetSequenceEffect=none; no targeted timeline/since catch-up was observed."
      } else if (fallback > 0 && target_singleflight > 0) {
        print "targetSequenceEffect=shared-catch-up; strong fallbacks were coalesced by singleflight."
      } else if (fallback > 0 && target_singleflight == 0) {
        print "targetSequenceEffect=uncoalesced-fallback; strong fallbacks did not join in-flight reads. Check cursor spread, limit, visible floor, target sequence spread, or query-api cache locality."
      } else if (eventual > 0 && fallback == 0) {
        print "targetSequenceEffect=eventual-satisfied; eventual reads reached the hinted target."
      }
      if (hot_bypass > 0 || recent_bypass > 0) {
        print "targetSequenceCache=stale-for-target; cached pages existed but did not reach the hinted target sequence."
      }
      if (notice_bypass > 0) {
        print "targetSequenceNotice=isolated; user-specific timeline notices forced joined catch-up requests to re-read independently."
      }
    }
  '
}

print_stream_batch_fill_summary() {
  local before_file="$1"
  local after_file="$2"
  local label="$3"
  if [[ ! -s "${before_file}" || ! -s "${after_file}" ]]; then
    return
  fi

  local batches batch_events fill_waits fill_wait_ms fill_events fill_skipped processed_runs run_events message_runs message_run_events
  batches="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_processing_batches_total")"
  batch_events="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_processing_batch_events_total")"
  fill_waits="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_batch_fill_waits_total")"
  fill_wait_ms="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_batch_fill_wait_millis_total")"
  fill_events="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_batch_fill_events_total")"
  fill_skipped="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_batch_fill_skipped_batches_total")"
  processed_runs="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_processed_runs_total")"
  run_events="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_run_events_total")"
  message_runs="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_message_created_runs_total")"
  message_run_events="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_stream_message_created_run_events_total")"
  if [[ -z "${batches}" && -z "${fill_waits}" && -z "${processed_runs}" ]]; then
    return
  fi

  echo "== stream batch-fill summary: ${label} =="
  awk \
    -v batches="${batches:-0}" \
    -v batch_events="${batch_events:-0}" \
    -v fill_waits="${fill_waits:-0}" \
    -v fill_wait_ms="${fill_wait_ms:-0}" \
    -v fill_events="${fill_events:-0}" \
    -v fill_skipped="${fill_skipped:-0}" \
    -v processed_runs="${processed_runs:-0}" \
    -v run_events="${run_events:-0}" \
    -v message_runs="${message_runs:-0}" \
    -v message_run_events="${message_run_events:-0}" '
    BEGIN {
      avg_batch_events = batches > 0 ? batch_events / batches : 0
      fill_events_per_wait = fill_waits > 0 ? fill_events / fill_waits : 0
      wait_ms_per_fill_event = fill_events > 0 ? fill_wait_ms / fill_events : 0
      avg_run_events = processed_runs > 0 ? run_events / processed_runs : 0
      avg_message_run_events = message_runs > 0 ? message_run_events / message_runs : 0
      printf "processingBatchesDelta=%g processingBatchEventsDelta=%g avgProcessingBatchEvents=%.2f\n", batches, batch_events, avg_batch_events
      printf "batchFillWaitsDelta=%g batchFillSkippedDelta=%g batchFillEventsDelta=%g fillEventsPerWait=%.2f batchFillWaitMsDelta=%g waitMsPerFillEvent=%.2f\n", fill_waits, fill_skipped, fill_events, fill_events_per_wait, fill_wait_ms, wait_ms_per_fill_event
      printf "processedRunsDelta=%g runEventsDelta=%g avgRunEvents=%.2f\n", processed_runs, run_events, avg_run_events
      printf "messageCreatedRunsDelta=%g messageCreatedRunEventsDelta=%g avgMessageCreatedRunEvents=%.2f\n", message_runs, message_run_events, avg_message_run_events
      if (fill_waits > 0 && fill_events == 0) {
        print "batchFillEffect=none; fill waits occurred but no events were added after waiting."
      } else if (fill_skipped > 0 && fill_waits == 0) {
        print "batchFillEffect=skipped; first events were not eligible message_created events, so the wait window was bypassed."
      } else if (message_runs > 0 && fill_events > 0 && avg_message_run_events > 1) {
        print "batchFillEffect=useful; wait window added events and message_created runs are coalescing."
      } else if (message_runs > 0 && avg_message_run_events <= 1) {
        print "batchFillEffect=weak; message_created runs are still mostly single-event."
      } else if (fill_events > 0 && avg_batch_events > 1) {
        print "batchFillEffect=generic-useful; wait window added events, but no message_created runs were observed."
      } else if (batches > 0 && avg_batch_events <= 1) {
        print "batchFillEffect=weak; processing batches are still mostly single-event and no message_created run evidence was observed."
      }
    }
  '
}

record_gate_violation() {
  local message="$1"
  case "${IM_METRICS_GATE_MODE}" in
    off|disabled|none)
      return
      ;;
    fail)
      echo "IM METRICS GATE FAILURE: ${message}" >&2
      IM_METRICS_GATE_VIOLATIONS=$((IM_METRICS_GATE_VIOLATIONS + 1))
      ;;
    warn|*)
      echo "IM METRICS GATE WARNING: ${message}" >&2
      ;;
  esac
}

check_counter_delta_max() {
  local before_file="$1"
  local after_file="$2"
  local metric="$3"
  local maximum="$4"
  local before after delta
  before="$(metric_sum_or_empty "${before_file}" "${metric}")"
  after="$(metric_sum_or_empty "${after_file}" "${metric}")"
  if [[ -z "${before}" || -z "${after}" ]]; then
    return
  fi
  delta="$(awk -v before="${before}" -v after="${after}" 'BEGIN { print after - before }')"
  awk -v delta="${delta}" -v maximum="${maximum}" 'BEGIN { exit !(delta > maximum) }' \
    && record_gate_violation "${metric} delta=${delta} exceeds max=${maximum}"
  return 0
}

check_gauge_max() {
  local after_file="$1"
  local metric="$2"
  local maximum="$3"
  local value
  value="$(metric_max_or_empty "${after_file}" "${metric}")"
  if [[ -z "${value}" ]]; then
    return
  fi
  awk -v value="${value}" -v maximum="${maximum}" 'BEGIN { exit !(value > maximum) }' \
    && record_gate_violation "${metric} value=${value} exceeds max=${maximum}"
  return 0
}

check_histogram_quantile_delta_max() {
  local before_file="$1"
  local after_file="$2"
  local metric="$3"
  local kind="$4"
  local quantile="$5"
  local maximum="$6"
  local value
  value="$(histogram_quantile_delta_upper_bound "${before_file}" "${after_file}" "${metric}" "${kind}" "${quantile}")"
  if [[ -z "${value}" ]]; then
    return
  fi
  awk -v value="${value}" -v maximum="${maximum}" 'BEGIN { exit !(value > maximum) }' \
    && record_gate_violation "${metric}{kind=\"${kind}\"} p${quantile}=${value}ms exceeds max=${maximum}ms"
  return 0
}

check_target_sequence_singleflight_joined() {
  local before_file="$1"
  local after_file="$2"
  local minimum_fallbacks="$3"
  local fallbacks joined
  fallbacks="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_strong_fallbacks_total")"
  joined="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_singleflight_joined_total")"
  fallbacks="${fallbacks:-0}"
  joined="${joined:-0}"
  awk -v fallbacks="${fallbacks}" -v joined="${joined}" -v minimum="${minimum_fallbacks}" \
    'BEGIN { exit !(fallbacks >= minimum && joined <= 0) }' \
    && record_gate_violation "im_timeline_since_target_sequence_strong_fallbacks_total delta=${fallbacks} reached singleflight minimum=${minimum_fallbacks}, but im_timeline_since_target_sequence_singleflight_joined_total delta=${joined}; targeted strong catch-up is not coalescing"
  return 0
}

check_target_sequence_strong_fallback_rate() {
  local before_file="$1"
  local after_file="$2"
  local maximum_percent="$3"
  local minimum_requests="$4"
  local requests fallbacks
  requests="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_requests_total")"
  fallbacks="$(metric_delta_or_empty "${before_file}" "${after_file}" "im_timeline_since_target_sequence_strong_fallbacks_total")"
  requests="${requests:-0}"
  fallbacks="${fallbacks:-0}"
  awk \
    -v requests="${requests}" \
    -v fallbacks="${fallbacks}" \
    -v maximum="${maximum_percent}" \
    -v minimum="${minimum_requests}" '
    BEGIN {
      rate = requests > 0 ? (fallbacks / requests) * 100 : 0
      exit !(requests >= minimum && rate > maximum)
    }' \
    && record_gate_violation "im_timeline_since_target_sequence_strong_fallbacks_total fallbackRate=$(awk -v requests="${requests}" -v fallbacks="${fallbacks}" 'BEGIN { printf "%.2f", (requests > 0 ? (fallbacks / requests) * 100 : 0) }')% exceeds max=${maximum_percent}% with targetSequenceRequestsDelta=${requests} minimum=${minimum_requests}"
  return 0
}

evaluate_im_metrics_gate() {
  local before_file="$1"
  local after_file="$2"
  local label="$3"
  if [[ "${IM_METRICS_GATE_MODE}" == "off" || "${IM_METRICS_GATE_MODE}" == "disabled" || "${IM_METRICS_GATE_MODE}" == "none" ]]; then
    return
  fi
  if [[ "${IM_METRICS_GATE_MODE}" == "fail" ]]; then
    validate_im_metrics_gate_runtime_config "${label}" || return 1
    if [[ ! -s "${before_file}" || ! -s "${after_file}" ]]; then
      echo "IM metrics gate failed for ${label}: missing before/after /internal/metrics snapshots." >&2
      return 1
    fi
  elif [[ ! -s "${before_file}" || ! -s "${after_file}" ]]; then
    if bool_enabled "${COLLECT_REMOTE_METRICS}" && bool_enabled "${COLLECT_IM_METRICS}" && bool_enabled "${COLLECT_IM_METRICS_DELTA}" && [[ -n "${SSH_HOST}" ]]; then
      echo "IM METRICS GATE WARNING: missing before/after /internal/metrics snapshots for ${label}; skipping gate." >&2
    fi
    return
  fi

  IM_METRICS_GATE_VIOLATIONS=0
  echo "== im metrics gate: ${label} mode=${IM_METRICS_GATE_MODE} =="
  check_counter_delta_max "${before_file}" "${after_file}" "im_client_timeline_catch_up_since_failures_total" "${IM_GATE_CLIENT_CATCH_UP_FAILURES_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_client_timeline_catch_up_deferred_total" "${IM_GATE_CLIENT_CATCH_UP_DEFERRED_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_timeline_since_distributed_invalidation_errors_total" "${IM_GATE_TIMELINE_INVALIDATION_ERRORS_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_stream_failed_events_total" "${IM_GATE_STREAM_FAILED_EVENTS_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_tcp_write_dropped_backpressure_total" "${IM_GATE_TCP_DROPPED_BACKPRESSURE_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_tcp_write_backpressure_total" "${IM_GATE_TCP_BACKPRESSURE_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_realtime_active_conversation_fanout_route_split_drops_total" "${IM_GATE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_realtime_remote_active_conversation_fanout_route_split_drops_total" "${IM_GATE_REMOTE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_realtime_async_relay_dropped_dispatches_total" "${IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_DISPATCHES_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_realtime_async_relay_dropped_recipient_deliveries_total" "${IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_RECIPIENT_DELIVERIES_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_gateway_http_relay_skipped_recipients_total" "${IM_GATE_GATEWAY_HTTP_RELAY_SKIPPED_RECIPIENTS_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_gateway_http_relay_request_failures_total" "${IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_FAILURES_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_gateway_http_relay_binary_fallbacks_total" "${IM_GATE_GATEWAY_HTTP_RELAY_BINARY_FALLBACKS_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_gateway_http_relay_inbound_failures_total" "${IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_FAILURES_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_timeline_since_target_sequence_strong_misses_total" "${IM_GATE_TARGET_SEQUENCE_STRONG_MISSES_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_timeline_since_target_sequence_errors_total" "${IM_GATE_TARGET_SEQUENCE_ERRORS_MAX}"
  check_target_sequence_singleflight_joined "${before_file}" "${after_file}" "${IM_GATE_TARGET_SEQUENCE_SINGLEFLIGHT_MIN_FALLBACKS}"
  check_target_sequence_strong_fallback_rate "${before_file}" "${after_file}" "${IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT}" "${IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_timeline_since_response_singleflight_notice_bypasses_total" "${IM_GATE_TIMELINE_SINCE_NOTICE_BYPASSES_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_timeline_since_visibility_notice_bypasses_total" "${IM_GATE_TIMELINE_SINCE_VISIBILITY_NOTICE_BYPASSES_MAX}"
  check_counter_delta_max "${before_file}" "${after_file}" "im_timeline_read_visibility_scan_limit_exceeded_total" "${IM_GATE_TIMELINE_VISIBILITY_SCAN_LIMIT_EXCEEDED_MAX}"
  check_gauge_max "${after_file}" "im_client_timeline_catch_up_request_max_millis" "${IM_GATE_CATCH_UP_REQUEST_MAX_MS}"
  check_gauge_max "${after_file}" "im_client_timeline_catch_up_hint_to_apply_max_millis" "${IM_GATE_CATCH_UP_HINT_TO_APPLY_MAX_MS}"
  check_gauge_max "${after_file}" "im_gateway_http_relay_request_max_body_bytes" "${IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_MAX_BODY_BYTES}"
  check_gauge_max "${after_file}" "im_gateway_http_relay_inbound_max_body_bytes" "${IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_MAX_BODY_BYTES}"
  check_histogram_quantile_delta_max "${before_file}" "${after_file}" "im_timeline_read_latency_millis" "since" "0.95" "${IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS}"
  check_histogram_quantile_delta_max "${before_file}" "${after_file}" "im_timeline_read_latency_millis" "since" "0.99" "${IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS}"
  check_gauge_max "${after_file}" "im_timeline_read_latency_max_millis" "${IM_GATE_TIMELINE_READ_MAX_MS}"
  check_gauge_max "${after_file}" "im_domain_event_owner_delivery_batch_write_latency_max_millis" "${IM_GATE_OWNER_BATCH_WRITE_MAX_MS}"
  check_gauge_max "${after_file}" "im_projection_lag_millis" "${IM_GATE_PROJECTION_LAG_MAX_MS}"

  if [[ "${IM_METRICS_GATE_MODE}" == "fail" && "${IM_METRICS_GATE_VIOLATIONS}" -gt 0 ]]; then
    echo "IM metrics gate failed for ${label}: violations=${IM_METRICS_GATE_VIOLATIONS}" >&2
    return 1
  fi
}

bool_enabled() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

validate_im_metrics_gate_runtime_config() {
  local label="$1"
  if [[ "${IM_METRICS_GATE_MODE}" != "fail" ]]; then
    return 0
  fi
  if ! bool_enabled "${COLLECT_REMOTE_METRICS}" || ! bool_enabled "${COLLECT_IM_METRICS}" || ! bool_enabled "${COLLECT_IM_METRICS_DELTA}" || [[ -z "${SSH_HOST}" ]]; then
    echo "IM metrics gate failed for ${label}: mode=fail requires SSH_HOST plus COLLECT_REMOTE_METRICS=true, COLLECT_IM_METRICS=true, and COLLECT_IM_METRICS_DELTA=true." >&2
    return 1
  fi
}

effective_prewarm_login_cache() {
  if [[ "${PREWARM_LOGIN_CACHE}" == "auto" ]]; then
    [[ "${MESSAGES}" == "0" ]]
    return
  fi
  bool_enabled "${PREWARM_LOGIN_CACHE}"
}

effective_require_login_cache() {
  bool_enabled "${REQUIRE_LOGIN_CACHE}"
}

login_cache_file_for_step() {
  local connections="$1"
  if [[ -n "${LOGIN_CACHE_FILE}" ]]; then
    echo "${LOGIN_CACHE_FILE}"
    return
  fi
  echo "${LOGIN_CACHE_DIR}/tcp-login-cache-lg${LOAD_GENERATOR_ID}-${connections}.json"
}

make_account_shard() {
  local connections="$1"
  if [[ -z "${ACCOUNT_FILE}" ]]; then
    return
  fi

  local total_accounts
  total_accounts="$(grep -v '^[[:space:]]*#' "${ACCOUNT_FILE}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [[ "${total_accounts}" -eq 0 ]]; then
    echo "ACCOUNT_FILE has no usable rows: ${ACCOUNT_FILE}" >&2
    exit 1
  fi

  local offset limit
  if [[ -n "${ACCOUNT_SHARD_OFFSET}" ]]; then
    offset="${ACCOUNT_SHARD_OFFSET}"
  else
    offset=$(( (LOAD_GENERATOR_ID - 1) * ((total_accounts + LOAD_GENERATOR_COUNT - 1) / LOAD_GENERATOR_COUNT) ))
  fi
  if [[ -n "${ACCOUNT_SHARD_LIMIT}" ]]; then
    limit="${ACCOUNT_SHARD_LIMIT}"
  else
    limit=$(( (total_accounts + LOAD_GENERATOR_COUNT - 1) / LOAD_GENERATOR_COUNT ))
  fi

  if (( offset < 0 || offset >= total_accounts )); then
    echo "Account shard offset is out of range: offset=${offset}, total=${total_accounts}" >&2
    exit 1
  fi
  if (( limit < connections )); then
    echo "Account shard limit ${limit} is smaller than connections ${connections}; increase ACCOUNT_SHARD_LIMIT or reduce this ladder step." >&2
    exit 1
  fi

  local shard_file="${TMPDIR:-/tmp}/imtcp-accounts-lg${LOAD_GENERATOR_ID}-of-${LOAD_GENERATOR_COUNT}-${offset}-${limit}.csv"
  grep -v '^[[:space:]]*#' "${ACCOUNT_FILE}" \
    | sed '/^[[:space:]]*$/d' \
    | awk -v offset="${offset}" -v limit="${limit}" 'NR > offset && NR <= offset + limit { print }' >"${shard_file}"

  local shard_count
  shard_count="$(wc -l <"${shard_file}" | tr -d ' ')"
  if (( shard_count < connections )); then
    echo "Account shard has ${shard_count} rows, smaller than connections ${connections}." >&2
    exit 1
  fi
  echo "${shard_file}"
}

jsonl_count() {
  local event="$1"
  local file="$2"
  if [[ ! -f "${file}" ]]; then
    echo 0
    return
  fi
  grep -c "\"event\":\"${event}\"" "${file}" || true
}

ensure_login_cache_hit() {
  local file="$1"
  if [[ "$(jsonl_count "login_cache_hit" "${file}")" == "0" ]]; then
    echo "Expected login_cache_hit in ${file}; TCP online capacity run is invalid without cached login tokens." >&2
    exit 1
  fi
  if [[ "$(jsonl_count "login_start" "${file}")" != "0" ]]; then
    echo "Unexpected HTTP login_start in strict TCP online capacity run: ${file}" >&2
    exit 1
  fi
}

if bool_enabled "${IM_TCP_CAPACITY_LADDER_SOURCE_ONLY:-false}"; then
  return 0 2>/dev/null || exit 0
fi

if [[ -z "${IM_CONVERSATION_ID}" ]]; then
  echo "IM_CONVERSATION_ID is required." >&2
  exit 1
fi
validate_im_metrics_gate_runtime_config "preflight"

echo "Building TCP load driver..."
swift build -c release --package-path "${TCP_DRIVER_DIR}"

for connections in ${LADDER}; do
  if [[ -n "${DEVICES_PER_USER}" ]]; then
    devices_per_user="${DEVICES_PER_USER}"
  elif [[ "${MESSAGES}" == "0" ]]; then
    devices_per_user="${connections}"
  else
    devices_per_user="1"
  fi

  echo
  echo "== TCP ladder step: connections=${connections}, devices=${devices_per_user}, messages=${MESSAGES}, hold=${HOLD_SECONDS}s, ramp=${CONNECT_RAMP_SECONDS}s =="
  step_metrics_before="$(mktemp "${TMPDIR:-/tmp}/im-metrics-before-${connections}.XXXXXX")"
  step_metrics_after="$(mktemp "${TMPDIR:-/tmp}/im-metrics-after-${connections}.XXXXXX")"
  capture_remote_im_metrics "${step_metrics_before}"
  collect_remote_metrics "before ${connections}"

  step_account_file="${ACCOUNT_FILE}"
  if [[ -n "${ACCOUNT_FILE}" ]]; then
    step_account_file="$(make_account_shard "${connections}")"
    echo "Account shard: ${step_account_file}"
  fi

  effective_connection_log_dir="${CONNECTION_LOG_DIR}"
  if { effective_prewarm_login_cache || effective_require_login_cache; } && [[ -z "${effective_connection_log_dir}" ]]; then
    effective_connection_log_dir="/tmp/imtcp-driver-logs"
  fi

  driver_args=(
    --profile custom
    --base-url "${BASE_URL}"
    --tcp-host "${TCP_HOST}"
    --tcp-port "${TCP_PORT}"
    --email "${IM_EMAIL}"
    --password "${IM_PASSWORD}"
    --conversation-id "${IM_CONVERSATION_ID}"
    --connections "${connections}"
    --devices-per-user "${devices_per_user}"
    --messages "${MESSAGES}"
    --send-interval-ms "${SEND_INTERVAL_MS}"
    --message-profile "${MESSAGE_PROFILE}"
    --message-rate-per-second "${MESSAGE_RATE_PER_SECOND}"
    --message-sender-every "${MESSAGE_SENDER_EVERY}"
    --message-receiver-offset "${MESSAGE_RECEIVER_OFFSET}"
    --active-conversation-users "${ACTIVE_CONVERSATION_USERS}"
    --global-hold-barrier-min-ratio "${GLOBAL_HOLD_BARRIER_MIN_RATIO}"
    --hold-seconds "${HOLD_SECONDS}"
    --connect-ramp-seconds "${CONNECT_RAMP_SECONDS}"
    --login-concurrency "${LOGIN_CONCURRENCY}"
    --timeout-seconds "${TIMEOUT_SECONDS}"
    --protocol-version "${PROTOCOL_VERSION}"
    --heartbeat-interval-seconds "${HEARTBEAT_INTERVAL_SECONDS}"
    --heartbeat-jitter-seconds "${HEARTBEAT_JITTER_SECONDS}"
    --heartbeat-log-mode "${HEARTBEAT_LOG_MODE}"
    --heartbeat-log-sample-rate "${HEARTBEAT_LOG_SAMPLE_RATE}"
    --connection-queue-pool-size "${CONNECTION_QUEUE_POOL_SIZE}"
    --max-reconnects "${MAX_RECONNECTS}"
    --reconnect-delay-ms "${RECONNECT_DELAY_MS}"
    --login-retries "${LOGIN_RETRIES}"
    --login-retry-delay-ms "${LOGIN_RETRY_DELAY_MS}"
    --login-mode "${LOGIN_MODE}"
    --login-cache-ttl-guard-seconds "${LOGIN_CACHE_TTL_GUARD_SECONDS}"
  )
  if [[ -n "${step_account_file}" ]]; then
    driver_args+=(--account-file "${step_account_file}")
  fi
  if [[ -n "${effective_connection_log_dir}" ]]; then
    mkdir -p "${effective_connection_log_dir}"
    connection_log_file="${effective_connection_log_dir}/tcp-driver-lg${LOAD_GENERATOR_ID}-${connections}.jsonl"
    driver_args+=(--connection-log-file "${connection_log_file}")
    echo "Connection lifecycle log: ${connection_log_file}"
  fi
  if effective_prewarm_login_cache; then
    mkdir -p "${LOGIN_CACHE_DIR}"
    login_cache_file="$(login_cache_file_for_step "${connections}")"
    prewarm_log_file="${effective_connection_log_dir:-/tmp}/tcp-driver-prewarm-lg${LOAD_GENERATOR_ID}-${connections}.jsonl"
    echo "Prewarming login cache: ${login_cache_file}"
    prewarm_args=(
      --profile custom
      --base-url "${BASE_URL}"
      --tcp-host "${TCP_HOST}"
      --tcp-port "${TCP_PORT}"
      --email "${IM_EMAIL}"
      --password "${IM_PASSWORD}"
      --conversation-id "${IM_CONVERSATION_ID}"
      --connections "${connections}"
      --devices-per-user "${devices_per_user}"
      --messages "0"
      --message-profile "per-connection"
      --message-rate-per-second "0"
      --hold-seconds "${HOLD_SECONDS}"
      --connect-ramp-seconds "${CONNECT_RAMP_SECONDS}"
      --login-concurrency "${LOGIN_CONCURRENCY}"
      --timeout-seconds "${TIMEOUT_SECONDS}"
      --protocol-version "${PROTOCOL_VERSION}"
      --login-retries "${LOGIN_RETRIES}"
      --login-retry-delay-ms "${LOGIN_RETRY_DELAY_MS}"
      --login-cache-ttl-guard-seconds "${LOGIN_CACHE_TTL_GUARD_SECONDS}"
      --login-cache-file "${login_cache_file}"
      --connection-log-file "${prewarm_log_file}"
      --login-only true
    )
    if [[ -n "${step_account_file}" ]]; then
      prewarm_args+=(--account-file "${step_account_file}")
    fi
    "${TCP_DRIVER_DIR}/.build/release/IMTCPLoadDriver" "${prewarm_args[@]}"

    driver_args+=(
      --login-cache-file "${login_cache_file}"
      --require-login-cache true
      --login-mode upfront
    )
  elif [[ -n "${LOGIN_CACHE_FILE}" ]] || effective_require_login_cache; then
    login_cache_file="$(login_cache_file_for_step "${connections}")"
    echo "Using login cache: ${login_cache_file}"
    driver_args+=(
      --login-cache-file "${login_cache_file}"
      --login-mode upfront
    )
    if effective_require_login_cache; then
      driver_args+=(--require-login-cache true)
    fi
  fi

  "${TCP_DRIVER_DIR}/.build/release/IMTCPLoadDriver" "${driver_args[@]}" &
  driver_pid="$!"

  sampler_pid=""
  if [[ -n "${SSH_HOST}" && "${SAMPLE_DURING_SECONDS}" != "0" ]]; then
    (
      while kill -0 "${driver_pid}" 2>/dev/null; do
        sleep "${SAMPLE_DURING_SECONDS}"
        if kill -0 "${driver_pid}" 2>/dev/null; then
          collect_remote_metrics "during ${connections}"
        fi
      done
    ) &
    sampler_pid="$!"
  fi

  if ! wait "${driver_pid}"; then
    if [[ -n "${sampler_pid}" ]]; then
      kill "${sampler_pid}" 2>/dev/null || true
    fi
    rm -f "${step_metrics_before}" "${step_metrics_after}"
    exit 1
  fi
  if [[ -n "${sampler_pid}" ]]; then
    kill "${sampler_pid}" 2>/dev/null || true
    wait "${sampler_pid}" 2>/dev/null || true
  fi

  if effective_prewarm_login_cache || effective_require_login_cache; then
    ensure_login_cache_hit "${connection_log_file}"
  fi

  collect_remote_metrics "after ${connections}"
  capture_remote_im_metrics "${step_metrics_after}"
  print_im_metrics_delta "${step_metrics_before}" "${step_metrics_after}" "step ${connections}"
  print_timeline_read_latency_summary "${step_metrics_before}" "${step_metrics_after}" "step ${connections}"
  print_target_sequence_catchup_summary "${step_metrics_before}" "${step_metrics_after}" "step ${connections}"
  print_stream_batch_fill_summary "${step_metrics_before}" "${step_metrics_after}" "step ${connections}"
  if ! evaluate_im_metrics_gate "${step_metrics_before}" "${step_metrics_after}" "step ${connections}"; then
    rm -f "${step_metrics_before}" "${step_metrics_after}"
    exit 1
  fi
  rm -f "${step_metrics_before}" "${step_metrics_after}"

  if [[ "${COOLDOWN_SECONDS}" != "0" ]]; then
    echo "Cooling down for ${COOLDOWN_SECONDS}s..."
    sleep "${COOLDOWN_SECONDS}"
  fi
done
