#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LADDER_SCRIPT="${SCRIPT_DIR}/tcp_capacity_ladder.sh"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

log() {
  echo "==> $1"
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

write_timeline_histogram_pair() {
  local before_file="$1"
  local after_file="$2"
  cat >"${before_file}" <<'METRICS'
im_timeline_read_latency_millis_bucket{kind="since",le="5"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="10"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="25"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="50"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="100"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="250"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="500"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="1000"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="2500"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="5000"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="10000"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="30000"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="+Inf"} 0
im_timeline_read_latency_millis_count{kind="since"} 0
METRICS
  cat >"${after_file}" <<'METRICS'
im_timeline_read_latency_millis_bucket{kind="since",le="5"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="10"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="25"} 0
im_timeline_read_latency_millis_bucket{kind="since",le="50"} 5
im_timeline_read_latency_millis_bucket{kind="since",le="100"} 10
im_timeline_read_latency_millis_bucket{kind="since",le="250"} 20
im_timeline_read_latency_millis_bucket{kind="since",le="500"} 50
im_timeline_read_latency_millis_bucket{kind="since",le="1000"} 95
im_timeline_read_latency_millis_bucket{kind="since",le="2500"} 99
im_timeline_read_latency_millis_bucket{kind="since",le="5000"} 100
im_timeline_read_latency_millis_bucket{kind="since",le="10000"} 100
im_timeline_read_latency_millis_bucket{kind="since",le="30000"} 100
im_timeline_read_latency_millis_bucket{kind="since",le="+Inf"} 100
im_timeline_read_latency_millis_count{kind="since"} 100
METRICS
}

source_ladder_functions() {
  IM_TCP_CAPACITY_LADDER_SOURCE_ONLY=true source "${LADDER_SCRIPT}"
}

if [[ "${TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

bash -n "${LADDER_SCRIPT}"
bash -n "${SCRIPT_DIR}/tcp_message_send_ladder.sh"
bash -n "${SCRIPT_DIR}/tcp_capacity_local_shards.sh"
bash -n "${SCRIPT_DIR}/prewarm_login_cache_slow.sh"
bash -n "${SCRIPT_DIR}/provision_load_accounts.sh"

expected_protocol_version="$(tr -d '[:space:]' <"${SCRIPT_DIR}/../../Protocol/im_realtime/v1/protocol_version.txt")"
driver_default_protocol_version="$(sed -nE 's/.*protocolVersion = .* \?\? ([0-9]+).*/\1/p' "${SCRIPT_DIR}/TCPDriver/Sources/IMTCPLoadDriver/main.swift" | head -n 1)"
[[ "${driver_default_protocol_version}" == "${expected_protocol_version}" ]] \
  || fail "TCPDriver default protocol version ${driver_default_protocol_version:-missing} should match ${expected_protocol_version}"

run_should_pass "message-send ladder defaults to production gate settings" env \
  IM_CONVERSATION_ID="conversation-1" \
  ACCOUNT_FILE="${TMP_DIR}/accounts.csv" \
  ONLINE_LADDER="10" \
  MESSAGE_RATES="5" \
  MESSAGE_HOLD_SECONDS="1" \
  MESSAGE_CONNECT_RAMP_SECONDS="1" \
  MESSAGE_SEND_LADDER_DRY_RUN="true" \
  "${SCRIPT_DIR}/tcp_message_send_ladder.sh"
message_dry_run_output="$(IM_CONVERSATION_ID="conversation-1" \
  ACCOUNT_FILE="${TMP_DIR}/accounts.csv" \
  ONLINE_LADDER="10" \
  MESSAGE_RATES="5" \
  MESSAGE_HOLD_SECONDS="1" \
  MESSAGE_CONNECT_RAMP_SECONDS="1" \
  MESSAGE_SEND_LADDER_DRY_RUN="true" \
  "${SCRIPT_DIR}/tcp_message_send_ladder.sh")"
[[ "${message_dry_run_output}" == *"MESSAGE_PROFILE=pair-delivery"* ]] || fail "message-send dry-run should use pair-delivery"
[[ "${message_dry_run_output}" == *"PREWARM_LOGIN_CACHE=true"* ]] || fail "message-send dry-run should prewarm login cache"
[[ "${message_dry_run_output}" == *"REQUIRE_LOGIN_CACHE=true"* ]] || fail "message-send dry-run should require login cache"
[[ "${message_dry_run_output}" == *"IM_METRICS_GATE_MODE=fail"* ]] || fail "message-send dry-run should fail on metrics gate violations"
[[ "${message_dry_run_output}" == *"COLLECT_REMOTE_METRICS=true"* ]] || fail "message-send dry-run should collect remote metrics"
[[ "${message_dry_run_output}" == *"COLLECT_IM_METRICS_DELTA=true"* ]] || fail "message-send dry-run should collect IM metrics deltas"

local_shards_accounts="${TMP_DIR}/local-shards-accounts.csv"
cat >"${local_shards_accounts}" <<'ACCOUNTS'
load-00001@example.com,password1234
load-00002@example.com,password1234
load-00003@example.com,password1234
load-00004@example.com,password1234
ACCOUNTS
local_shards_dry_run_output="$(IM_CONVERSATION_ID="conversation-1" \
  ACCOUNT_FILE="${local_shards_accounts}" \
  CONNECTIONS="4" \
  LOCAL_DRIVER_SHARDS="2" \
  ACTIVE_CONVERSATION_USERS="3" \
  GLOBAL_HOLD_BARRIER_MIN_RATIO="0.75" \
  LOCAL_SHARDS_DRY_RUN="true" \
  "${SCRIPT_DIR}/tcp_capacity_local_shards.sh")"
[[ "${local_shards_dry_run_output}" == *"dry-run local-shard 1/2"* ]] || fail "local shards dry-run should print shard 1"
[[ "${local_shards_dry_run_output}" == *"--active-conversation-users"* ]] || fail "local shards dry-run should pass active conversation users"
[[ "${local_shards_dry_run_output}" == *"  3"* ]] || fail "local shards dry-run should pass active conversation user count"
[[ "${local_shards_dry_run_output}" == *"--global-hold-barrier-min-ratio"* ]] || fail "local shards dry-run should pass hold barrier ratio"
[[ "${local_shards_dry_run_output}" == *"  0.75"* ]] || fail "local shards dry-run should pass hold barrier ratio value"

run_should_fail "local shards rejects more shards than connections" "LOCAL_DRIVER_SHARDS must be <= CONNECTIONS" env \
  IM_CONVERSATION_ID="conversation-1" \
  ACCOUNT_FILE="${local_shards_accounts}" \
  CONNECTIONS="2" \
  LOCAL_DRIVER_SHARDS="3" \
  LOCAL_SHARDS_DRY_RUN="true" \
  "${SCRIPT_DIR}/tcp_capacity_local_shards.sh"

run_should_fail "local shards fail gate rejects missing remote metrics config before build" "mode=fail requires SSH_HOST" env \
  IM_CONVERSATION_ID="conversation-1" \
  ACCOUNT_FILE="${local_shards_accounts}" \
  CONNECTIONS="2" \
  LOCAL_DRIVER_SHARDS="2" \
  IM_METRICS_GATE_MODE="fail" \
  COLLECT_REMOTE_METRICS="true" \
  COLLECT_IM_METRICS="true" \
  COLLECT_IM_METRICS_DELTA="true" \
  SSH_HOST="" \
  "${SCRIPT_DIR}/tcp_capacity_local_shards.sh"

run_should_pass "source-only loads ladder functions without required runtime args" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  type evaluate_im_metrics_gate >/dev/null
  type validate_im_metrics_gate_runtime_config >/dev/null
  [[ \"\${PROTOCOL_VERSION}\" == \"\$(tr -d '[:space:]' < '${SCRIPT_DIR}/../../Protocol/im_realtime/v1/protocol_version.txt')\" ]]
"

run_should_pass "source-only execution exits before required runtime args" bash -c "
  set -Eeuo pipefail
  IM_TCP_CAPACITY_LADDER_SOURCE_ONLY=true '${LADDER_SCRIPT}'
"

run_should_fail "fail gate preflight rejects missing remote metrics config before build" "mode=fail requires SSH_HOST" bash -c "
  set -Eeuo pipefail
  IM_CONVERSATION_ID=conversation-1 \
  IM_METRICS_GATE_MODE=fail \
  COLLECT_REMOTE_METRICS=true \
  COLLECT_IM_METRICS=true \
  COLLECT_IM_METRICS_DELTA=true \
  SSH_HOST= \
  '${LADDER_SCRIPT}'
"

run_should_pass "timeline histogram delta quantiles are step-local" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/hist-before.prom'
  after='${TMP_DIR}/hist-after.prom'
  write_timeline_histogram_pair \"\${before}\" \"\${after}\"
  p95=\"\$(histogram_quantile_delta_upper_bound \"\${before}\" \"\${after}\" im_timeline_read_latency_millis since 0.95)\"
  p99=\"\$(histogram_quantile_delta_upper_bound \"\${before}\" \"\${after}\" im_timeline_read_latency_millis since 0.99)\"
  [[ \"\${p95}\" == '1000' ]]
  [[ \"\${p99}\" == '2500' ]]
"

run_should_pass "fail gate passes with complete metrics inside thresholds" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/passing-before.prom'
  after='${TMP_DIR}/passing-after.prom'
  write_timeline_histogram_pair \"\${before}\" \"\${after}\"
  printf '%s\n' 'im_timeline_read_visibility_scan_limit_exceeded_total 0' >>\"\${before}\"
  printf '%s\n' 'im_timeline_read_visibility_scan_limit_exceeded_total 0' >>\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS=2000
  IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS=5000
  IM_GATE_TIMELINE_VISIBILITY_SCAN_LIMIT_EXCEEDED_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step passing'
"

run_should_pass "target sequence catch-up summary reports coalesced fallback" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/target-summary-before.prom'
  after='${TMP_DIR}/target-summary-after.prom'
  cat >\"\${before}\" <<'METRICS'
im_timeline_since_target_sequence_requests_total 0
im_timeline_since_target_sequence_eventual_satisfied_total 0
im_timeline_since_target_sequence_strong_fallbacks_total 0
im_timeline_since_target_sequence_strong_satisfied_total 0
im_timeline_since_target_sequence_strong_misses_total 0
im_timeline_since_target_sequence_errors_total 0
im_timeline_since_response_singleflight_joined_total 0
im_timeline_since_response_singleflight_notice_bypasses_total 0
im_timeline_since_target_sequence_singleflight_joined_total 0
im_timeline_since_target_sequence_window_joined_total 0
im_timeline_since_hot_cache_target_sequence_bypasses_total 0
im_timeline_since_recent_cache_target_sequence_bypasses_total 0
METRICS
  cat >\"\${after}\" <<'METRICS'
im_timeline_since_target_sequence_requests_total 100
im_timeline_since_target_sequence_eventual_satisfied_total 40
im_timeline_since_target_sequence_strong_fallbacks_total 60
im_timeline_since_target_sequence_strong_satisfied_total 60
im_timeline_since_target_sequence_strong_misses_total 0
im_timeline_since_target_sequence_errors_total 0
im_timeline_since_response_singleflight_joined_total 55
im_timeline_since_response_singleflight_notice_bypasses_total 3
im_timeline_since_target_sequence_singleflight_joined_total 55
im_timeline_since_target_sequence_window_joined_total 50
im_timeline_since_hot_cache_target_sequence_bypasses_total 10
im_timeline_since_recent_cache_target_sequence_bypasses_total 5
METRICS
  output=\"\$(print_target_sequence_catchup_summary \"\${before}\" \"\${after}\" 'step target-summary')\"
  [[ \"\${output}\" == *'targetRequestsDelta=100'* ]]
  [[ \"\${output}\" == *'strongFallbackDelta=60'* ]]
  [[ \"\${output}\" == *'targetSingleflightJoinedDelta=55'* ]]
  [[ \"\${output}\" == *'targetWindowJoinedDelta=50'* ]]
  [[ \"\${output}\" == *'noticeBypassDelta=3'* ]]
  [[ \"\${output}\" == *'targetSequenceEffect=shared-catch-up'* ]]
  [[ \"\${output}\" == *'targetSequenceCache=stale-for-target'* ]]
  [[ \"\${output}\" == *'targetSequenceNotice=isolated'* ]]
"

run_should_fail "fail gate rejects uncoalesced target sequence fallback" "targeted strong catch-up is not coalescing" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/target-singleflight-before.prom'
  after='${TMP_DIR}/target-singleflight-after.prom'
  printf '%s\n' \
    'im_timeline_since_target_sequence_strong_fallbacks_total 0' \
    'im_timeline_since_target_sequence_singleflight_joined_total 0' >\"\${before}\"
  printf '%s\n' \
    'im_timeline_since_target_sequence_strong_fallbacks_total 10' \
    'im_timeline_since_target_sequence_singleflight_joined_total 0' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_TARGET_SEQUENCE_SINGLEFLIGHT_MIN_FALLBACKS=10
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step target-singleflight'
"

run_should_fail "fail gate rejects high target sequence strong fallback rate" "fallbackRate=60.00% exceeds max=25%" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/target-fallback-rate-before.prom'
  after='${TMP_DIR}/target-fallback-rate-after.prom'
  printf '%s\n' \
    'im_timeline_since_target_sequence_requests_total 0' \
    'im_timeline_since_target_sequence_strong_fallbacks_total 0' \
    'im_timeline_since_target_sequence_singleflight_joined_total 0' >\"\${before}\"
  printf '%s\n' \
    'im_timeline_since_target_sequence_requests_total 100' \
    'im_timeline_since_target_sequence_strong_fallbacks_total 60' \
    'im_timeline_since_target_sequence_singleflight_joined_total 60' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT=25
  IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS=20
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step target-fallback-rate'
"

run_should_fail "fail gate rejects target sequence notice bypasses" "im_timeline_since_response_singleflight_notice_bypasses_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/notice-bypass-before.prom'
  after='${TMP_DIR}/notice-bypass-after.prom'
  printf '%s\n' 'im_timeline_since_response_singleflight_notice_bypasses_total 0' >\"\${before}\"
  printf '%s\n' 'im_timeline_since_response_singleflight_notice_bypasses_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step notice-bypass'
"

run_should_fail "fail gate rejects timeline since visibility notice bypasses" "im_timeline_since_visibility_notice_bypasses_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/visibility-notice-bypass-before.prom'
  after='${TMP_DIR}/visibility-notice-bypass-after.prom'
  printf '%s\n' 'im_timeline_since_visibility_notice_bypasses_total 0' >\"\${before}\"
  printf '%s\n' 'im_timeline_since_visibility_notice_bypasses_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step visibility-notice-bypass'
"

run_should_fail "fail gate requires remote metrics configuration" "mode=fail requires SSH_HOST" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/missing-config-before.prom'
  after='${TMP_DIR}/missing-config-after.prom'
  : >\"\${before}\"
  : >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step missing-config'
"

run_should_fail "fail gate rejects missing metrics snapshots" "missing before/after /internal/metrics snapshots" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/missing-snapshot-before.prom'
  after='${TMP_DIR}/missing-snapshot-after.prom'
  : >\"\${before}\"
  : >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step missing-snapshot'
"

run_should_pass "warn gate skips missing metrics snapshots" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/warn-missing-before.prom'
  after='${TMP_DIR}/warn-missing-after.prom'
  : >\"\${before}\"
  : >\"\${after}\"
  IM_METRICS_GATE_MODE=warn
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step warn-missing'
"

run_should_fail "fail gate rejects timeline since p95 violations" "p0.95=1000ms exceeds max=500ms" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/p95-before.prom'
  after='${TMP_DIR}/p95-after.prom'
  write_timeline_histogram_pair \"\${before}\" \"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS=500
  IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS=5000
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step p95'
"

run_should_fail "fail gate rejects timeline since p99 violations" "p0.99=2500ms exceeds max=2000ms" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/p99-before.prom'
  after='${TMP_DIR}/p99-after.prom'
  write_timeline_histogram_pair \"\${before}\" \"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS=2000
  IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS=2000
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step p99'
"

run_should_fail "fail gate rejects timeline visibility scan limit hits" "im_timeline_read_visibility_scan_limit_exceeded_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/scan-before.prom'
  after='${TMP_DIR}/scan-after.prom'
  printf '%s\n' 'im_timeline_read_visibility_scan_limit_exceeded_total 0' >\"\${before}\"
  printf '%s\n' 'im_timeline_read_visibility_scan_limit_exceeded_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_TIMELINE_VISIBILITY_SCAN_LIMIT_EXCEEDED_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step scan-limit'
"

run_should_fail "fail gate rejects active fanout dropped fallback" "im_realtime_active_conversation_fanout_dropped_fallbacks_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/active-dropped-before.prom'
  after='${TMP_DIR}/active-dropped-after.prom'
  printf '%s\n' 'im_realtime_active_conversation_fanout_dropped_fallbacks_total 0' >\"\${before}\"
  printf '%s\n' 'im_realtime_active_conversation_fanout_dropped_fallbacks_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_ACTIVE_FANOUT_DROPPED_FALLBACKS_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step active-dropped'
"

run_should_fail "fail gate rejects active fanout unsplit fallback" "im_realtime_active_conversation_fanout_unsplit_fallbacks_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/active-unsplit-before.prom'
  after='${TMP_DIR}/active-unsplit-after.prom'
  printf '%s\n' 'im_realtime_active_conversation_fanout_unsplit_fallbacks_total 0' >\"\${before}\"
  printf '%s\n' 'im_realtime_active_conversation_fanout_unsplit_fallbacks_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_ACTIVE_FANOUT_UNSPLIT_FALLBACKS_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step active-unsplit'
"

run_should_fail "fail gate rejects active fanout hint fallback recipients" "im_realtime_active_conversation_fanout_hint_fallback_recipients_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/active-hint-fallback-before.prom'
  after='${TMP_DIR}/active-hint-fallback-after.prom'
  printf '%s\n' 'im_realtime_active_conversation_fanout_hint_fallback_recipients_total 0' >\"\${before}\"
  printf '%s\n' 'im_realtime_active_conversation_fanout_hint_fallback_recipients_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_ACTIVE_FANOUT_HINT_FALLBACK_RECIPIENTS_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step active-hint-fallback'
"

run_should_fail "fail gate rejects remote active fanout fallback" "im_realtime_remote_active_conversation_fanout_fallbacks_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/remote-fallback-before.prom'
  after='${TMP_DIR}/remote-fallback-after.prom'
  printf '%s\n' 'im_realtime_remote_active_conversation_fanout_fallbacks_total 0' >\"\${before}\"
  printf '%s\n' 'im_realtime_remote_active_conversation_fanout_fallbacks_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_REMOTE_ACTIVE_FANOUT_FALLBACKS_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step remote-fallback'
"

run_should_fail "fail gate rejects remote active fanout dropped fallback" "im_realtime_remote_active_conversation_fanout_dropped_fallbacks_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/remote-dropped-before.prom'
  after='${TMP_DIR}/remote-dropped-after.prom'
  printf '%s\n' 'im_realtime_remote_active_conversation_fanout_dropped_fallbacks_total 0' >\"\${before}\"
  printf '%s\n' 'im_realtime_remote_active_conversation_fanout_dropped_fallbacks_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_REMOTE_ACTIVE_FANOUT_DROPPED_FALLBACKS_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step remote-dropped'
"

run_should_fail "fail gate rejects realtime async relay dropped dispatch" "im_realtime_async_relay_dropped_dispatches_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/async-relay-dropped-dispatch-before.prom'
  after='${TMP_DIR}/async-relay-dropped-dispatch-after.prom'
  printf '%s\n' 'im_realtime_async_relay_dropped_dispatches_total 0' >\"\${before}\"
  printf '%s\n' 'im_realtime_async_relay_dropped_dispatches_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_DISPATCHES_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step async-relay-dropped-dispatch'
"

run_should_fail "fail gate rejects realtime async relay dropped recipient delivery" "im_realtime_async_relay_dropped_recipient_deliveries_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/async-relay-dropped-recipient-before.prom'
  after='${TMP_DIR}/async-relay-dropped-recipient-after.prom'
  printf '%s\n' 'im_realtime_async_relay_dropped_recipient_deliveries_total 0' >\"\${before}\"
  printf '%s\n' 'im_realtime_async_relay_dropped_recipient_deliveries_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_RECIPIENT_DELIVERIES_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step async-relay-dropped-recipient'
"

run_should_fail "fail gate rejects gateway relay skipped recipients" "im_gateway_http_relay_skipped_recipients_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/gateway-relay-skipped-before.prom'
  after='${TMP_DIR}/gateway-relay-skipped-after.prom'
  printf '%s\n' 'im_gateway_http_relay_skipped_recipients_total 0' >\"\${before}\"
  printf '%s\n' 'im_gateway_http_relay_skipped_recipients_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_GATEWAY_HTTP_RELAY_SKIPPED_RECIPIENTS_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step gateway-relay-skipped'
"

run_should_fail "fail gate rejects gateway relay request failures" "im_gateway_http_relay_request_failures_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/gateway-relay-failure-before.prom'
  after='${TMP_DIR}/gateway-relay-failure-after.prom'
  printf '%s\n' 'im_gateway_http_relay_request_failures_total 0' >\"\${before}\"
  printf '%s\n' 'im_gateway_http_relay_request_failures_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_FAILURES_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step gateway-relay-failure'
"

run_should_fail "fail gate rejects gateway relay binary fallback" "im_gateway_http_relay_binary_fallbacks_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/gateway-relay-binary-fallback-before.prom'
  after='${TMP_DIR}/gateway-relay-binary-fallback-after.prom'
  printf '%s\n' 'im_gateway_http_relay_binary_fallbacks_total 0' >\"\${before}\"
  printf '%s\n' 'im_gateway_http_relay_binary_fallbacks_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_GATEWAY_HTTP_RELAY_BINARY_FALLBACKS_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step gateway-relay-binary-fallback'
"

run_should_fail "fail gate rejects gateway relay inbound failures" "im_gateway_http_relay_inbound_failures_total delta=1 exceeds max=0" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/gateway-relay-inbound-failure-before.prom'
  after='${TMP_DIR}/gateway-relay-inbound-failure-after.prom'
  printf '%s\n' 'im_gateway_http_relay_inbound_failures_total 0' >\"\${before}\"
  printf '%s\n' 'im_gateway_http_relay_inbound_failures_total 1' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_FAILURES_MAX=0
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step gateway-relay-inbound-failure'
"

run_should_fail "fail gate rejects gateway relay request body above cap" "im_gateway_http_relay_request_max_body_bytes value=2048 exceeds max=1024" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/gateway-relay-request-body-before.prom'
  after='${TMP_DIR}/gateway-relay-request-body-after.prom'
  printf '%s\n' 'im_gateway_http_relay_request_max_body_bytes 0' >\"\${before}\"
  printf '%s\n' 'im_gateway_http_relay_request_max_body_bytes 2048' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_MAX_BODY_BYTES=1024
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step gateway-relay-request-body'
"

run_should_fail "fail gate rejects gateway relay inbound body above cap" "im_gateway_http_relay_inbound_max_body_bytes value=2048 exceeds max=1024" bash -c "
  set -Eeuo pipefail
  TCP_CAPACITY_LADDER_TEST_SOURCE_ONLY=true source '${BASH_SOURCE[0]}'
  source_ladder_functions
  before='${TMP_DIR}/gateway-relay-inbound-body-before.prom'
  after='${TMP_DIR}/gateway-relay-inbound-body-after.prom'
  printf '%s\n' 'im_gateway_http_relay_inbound_max_body_bytes 0' >\"\${before}\"
  printf '%s\n' 'im_gateway_http_relay_inbound_max_body_bytes 2048' >\"\${after}\"
  IM_METRICS_GATE_MODE=fail
  COLLECT_REMOTE_METRICS=true
  COLLECT_IM_METRICS=true
  COLLECT_IM_METRICS_DELTA=true
  SSH_HOST=metrics-host
  IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_MAX_BODY_BYTES=1024
  evaluate_im_metrics_gate \"\${before}\" \"\${after}\" 'step gateway-relay-inbound-body'
"

echo "tcp_capacity_ladder_test passed."
