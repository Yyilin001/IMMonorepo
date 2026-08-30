#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 1 || $# > 4 )); then
  printf 'usage: %s <output-prefix> [accepted-threshold] [duration-seconds] [timeout-seconds]\n' "$0" >&2
  exit 64
fi

readonly output_prefix="$1"
readonly accepted_threshold="${2:-1000}"
readonly duration_seconds="${3:-30}"
readonly timeout_seconds="${4:-300}"
readonly container="${IM_V2_GATEWAY_CONTAINER:-imv2gateway2_gateway_1}"
readonly metrics_url="${IM_V2_GATEWAY_METRICS_URL:-http://127.0.0.1:9464/metrics}"
readonly append_pending_threshold="${IM_V2_GATEWAY_APPEND_PENDING_THRESHOLD:-}"

[[ "${accepted_threshold}" =~ ^[0-9]+$ ]] || exit 64
[[ "${duration_seconds}" =~ ^[0-9]+$ ]] && (( duration_seconds >= 1 )) || exit 64
[[ "${timeout_seconds}" =~ ^[0-9]+$ ]] && (( timeout_seconds >= 1 )) || exit 64
if [[ -n "${append_pending_threshold}" ]]; then
  [[ "${append_pending_threshold}" =~ ^[0-9]+$ ]] \
    && (( append_pending_threshold >= 1 )) \
    || exit 64
fi

deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
  read -r accepted append_pending < <({
    curl --fail --silent --show-error --max-time 3 "${metrics_url}" || true
  } | awk '
    /^im_v2_gateway_commands_total\{command="send_message",outcome="accepted"/ {
      if (!accepted_found) { accepted = int($2); accepted_found = 1 }
    }
    /^im_v2_direct_room_log_append_batch_pending_requests / {
      append_pending = int($2)
      append_pending_found = 1
    }
    END {
      if (!accepted_found) accepted = 0
      if (!append_pending_found) append_pending = 0
      print accepted, append_pending
    }
  ')
  if [[ -n "${append_pending_threshold}" ]] \
      && (( append_pending >= append_pending_threshold )); then
    break
  fi
  if [[ -z "${append_pending_threshold}" ]] \
      && (( accepted >= accepted_threshold )); then
    break
  fi
  sleep 1
done

if [[ -n "${append_pending_threshold}" ]]; then
  if (( append_pending < append_pending_threshold )); then
    printf 'append-pending threshold not reached: pending=%s threshold=%s\n' \
      "${append_pending}" "${append_pending_threshold}" >&2
    exit 1
  fi
else
  if (( accepted < accepted_threshold )); then
    printf 'accepted-message threshold not reached: accepted=%s threshold=%s\n' \
      "${accepted}" "${accepted_threshold}" >&2
    exit 1
  fi
fi

readonly host_pid="$(docker inspect "${container}" --format '{{.State.Pid}}')"
[[ "${host_pid}" =~ ^[0-9]+$ ]] && (( host_pid > 0 )) || exit 1

perf record \
  --quiet \
  --event cpu-clock \
  --freq 99 \
  --pid "${host_pid}" \
  --call-graph fp \
  --output "${output_prefix}.perf.data" \
  -- sleep "${duration_seconds}"

perf report \
  --stdio \
  --no-children \
  --percent-limit 0.25 \
  --input "${output_prefix}.perf.data" \
  > "${output_prefix}.perf-report.txt"

perf report \
  --stdio \
  --children \
  --percent-limit 0.25 \
  --input "${output_prefix}.perf.data" \
  > "${output_prefix}.perf-report-children.txt"
