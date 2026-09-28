#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 6 )); then
  printf 'usage: %s <stage> <start-epoch> <binary> <credential-directory> <scenario> <event-loops-per-partition>\n' "$0" >&2
  exit 64
fi

readonly stage="$1"
readonly start_epoch="$2"
readonly binary="$3"
readonly credential_directory="$4"
readonly scenario="$5"
readonly event_loops="$6"
readonly base="${IM_V2_LOAD_BASE:-/opt/imv2-loadtest}"
readonly ramp_per_partition="${IM_V2_LOAD_PARTITION_RAMP_PER_SECOND:-200}"
readonly preflight_script="${IM_V2_LOAD_PREFLIGHT_SCRIPT:-${base}/preflight_v2_postgres_load_test.sh}"
readonly capacity_profile_id="${IM_V2_LOAD_CAPACITY_PROFILE_ID:-}"

[[ "${stage}" =~ ^[A-Za-z0-9._-]+$ ]] || exit 64
[[ "${start_epoch}" =~ ^[0-9]+$ ]] || exit 64
[[ "${event_loops}" =~ ^[0-9]+$ ]] && (( event_loops >= 1 && event_loops <= 16 )) || exit 64
[[ "${ramp_per_partition}" =~ ^[0-9]+$ ]] && (( ramp_per_partition >= 1 )) || exit 64
[[ -x "${binary}" && -s "${scenario}" && -s "${base}/root.crt" ]] || exit 66
[[ -x "${preflight_script}" ]] || {
  printf 'partitioned load preflight is missing or not executable: %s\n' "${preflight_script}" >&2
  exit 66
}
[[ -n "${IM_V2_PROFILE_DATABASE_URL:-}" ]] || {
  printf 'IM_V2_PROFILE_DATABASE_URL is required for the aggregate preflight\n' >&2
  exit 64
}
[[ "${capacity_profile_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  printf 'IM_V2_LOAD_CAPACITY_PROFILE_ID is required and must be valid\n' >&2
  exit 64
}

mapfile -t credentials < <(find "${credential_directory}" -maxdepth 1 -type f -name 'part-*.jsonl' -print | sort)
(( ${#credentials[@]} > 0 )) || exit 65
readonly scenario_rate_scale="$(awk -v count="${#credentials[@]}" 'BEGIN { printf "%.12g", 1 / count }')"

# Capacity is global even though the traffic generator is partitioned. Run
# every credential partition through the authoritative target validation, but
# give each invocation the full scenario command count. Passing only the
# partition-local count would allow N independent generators to collectively
# overrun one durable shard window while every local preflight still passes.
readonly expected_messages="$(jq -er '
  [.phases[] | (.durationSeconds * .messagesPerSecond)] | add // 0
' "${scenario}")"
readonly scenario_seconds="$(jq -er '
  ([.phases[].durationSeconds] | add // 0)
  + (.roomWarmupTimeoutSeconds // 0)
  + (.completionDrainSeconds // 0)
  + (.postDrainHoldSeconds // 0)
' "${scenario}")"
[[ "${expected_messages}" =~ ^[0-9]+$ && "${scenario_seconds}" =~ ^[0-9]+$ ]] || exit 65

maximum_partition_connections=0
for credential_file in "${credentials[@]}"; do
  connections="$(awk 'NF { n += 1 } END { print n + 0 }' "${credential_file}")"
  (( connections > maximum_partition_connections )) && maximum_partition_connections="${connections}"
done
ramp_seconds="$((
  (maximum_partition_connections + ramp_per_partition - 1) / ramp_per_partition
))"
now="$(date +%s)"
start_delay_seconds=0
(( now < start_epoch )) && start_delay_seconds="$((start_epoch - now))"
readonly preflight_duration_seconds="$((
  start_delay_seconds + ramp_seconds + scenario_seconds
))"

for credential_file in "${credentials[@]}"; do
  IM_V2_LOAD_CAPACITY_PROFILE_ID="${capacity_profile_id}" \
    "${preflight_script}" \
      "${credential_file}" \
      "${preflight_duration_seconds}" \
      "${expected_messages}"
done
printf 'partitioned preflight ok partitions=%s expected_messages=%s duration_seconds=%s profile=%s\n' \
  "${#credentials[@]}" "${expected_messages}" "${preflight_duration_seconds}" \
  "${capacity_profile_id}"

install -d -m 700 "${base}/reports/${stage}" "${base}/logs/${stage}"
ulimit -n 131072

now="$(date +%s)"
if (( now < start_epoch )); then sleep "$((start_epoch - now))"; fi

declare -a pids=()
declare -a labels=()
for index in "${!credentials[@]}"; do
  credential_file="${credentials[$index]}"
  connections="$(awk 'NF { n += 1 } END { print n + 0 }' "${credential_file}")"
  (( connections > 0 )) || exit 65
  label="$(printf '%02d' "${index}")"
  LD_LIBRARY_PATH="${base}/swift-runtime/linux" "${binary}" \
    --host 172.17.22.48 --port 443 --server-name localhost \
    --account-base-url "${IM_V2_LOAD_ACCOUNT_BASE_URL:-https://localhost:8443}" \
    --ca-path "${base}/root.crt" --credentials "${credential_file}" \
    --report "${base}/reports/${stage}/partition-${label}.json" \
    --revision "${stage}-${HOSTNAME}-${label}" \
    --connections "${connections}" \
    --ramp-per-second "${ramp_per_partition}" --ramp-batch-size "${ramp_per_partition}" \
    --workload-ramp-per-second 100 --hold-seconds 60 --event-loops "${event_loops}" \
    --scenario "${scenario}" --scenario-rate-scale "${scenario_rate_scale}" \
    --messages-per-second 0 --max-inflight-messages-per-connection 8 \
    --message-bytes 128 --targets-per-connection 2 --target-offset 1 \
    --sync-reads 1 --room-log-reads 1 --room-log-initial-cursor tail \
    --room-log-read-trigger availability_hint --peer-topology ring \
    --max-rss-mb 1200 --max-failure-percent 0.1 \
    >"${base}/logs/${stage}/partition-${label}.log" 2>&1 &
  pids+=("$!")
  labels+=("${label}")
done

telemetry="${base}/logs/${stage}/loadgen-system.log"
: > "${telemetry}"
while true; do
  live=0
  rss_kb=0
  cpu_pct=0
  for pid in "${pids[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      live=$((live + 1))
      read -r process_rss process_cpu < <(ps -p "${pid}" -o rss=,pcpu= | awk '{print $1+0,$2+0}')
      rss_kb=$((rss_kb + process_rss))
      cpu_pct="$(awk -v a="${cpu_pct}" -v b="${process_cpu}" 'BEGIN { printf "%.1f", a+b }')"
    fi
  done
  established="$(ss -Htn state established dst 172.17.22.48:443 | wc -l | tr -d ' ')"
  read -r mem_available swap_used < <(free -b | awk 'NR==2{available=$7} NR==3{print available,$3}')
  read -r load1 load5 _ < /proc/loadavg
  printf '%s live=%s rss_kb=%s cpu_pct=%s established=%s mem_available=%s swap_used=%s load1=%s load5=%s\n' \
    "$(date -u '+%FT%TZ')" "${live}" "${rss_kb}" "${cpu_pct}" "${established}" \
    "${mem_available}" "${swap_used}" "${load1}" "${load5}" >> "${telemetry}"
  (( live > 0 )) || break
  sleep 5
done

failed=0
for index in "${!pids[@]}"; do
  if wait "${pids[$index]}"; then result=0; else result=$?; failed=1; fi
  printf 'partition=%s exit=%s\n' "${labels[$index]}" "${result}"
done
printf 'stage=%s failed=%s\n' "${stage}" "${failed}"
(( failed == 0 ))
