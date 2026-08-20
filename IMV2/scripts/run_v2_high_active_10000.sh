#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 6 ]]; then
  printf 'usage: %s <host> <ca-path> <credentials-a-jsonl> <credentials-b-jsonl> <report-directory> <revision>\n' "$0" >&2
  exit 64
fi

host="$1"
ca_path="$2"
credentials_a="$3"
credentials_b="$4"
report_directory="$5"
revision="$6"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_directory}/../.." && pwd)"
scenario_path="${repo_root}/IMV2/load-scenarios/high-active-10000.json"
runner="${script_directory}/run_v2_gateway_load_guarded.sh"
summarizer="${script_directory}/summarize_v2_high_active_10000.sh"
ramp_per_second="${IM_V2_HIGH_ACTIVE_RAMP_PER_SECOND:-150}"

[[ "${ramp_per_second}" =~ ^[1-9][0-9]*$ ]] && (( ramp_per_second <= 1000 )) || {
  printf 'IM_V2_HIGH_ACTIVE_RAMP_PER_SECOND must be an integer from 1 through 1000\n' >&2
  exit 64
}

[[ -f "${ca_path}" && -f "${credentials_a}" && -f "${credentials_b}" && -f "${scenario_path}" ]] || {
  printf 'missing CA, credential, or scenario file\n' >&2
  exit 66
}
[[ -d "${report_directory}" && -z "$(find "${report_directory}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || {
  printf 'report directory must exist and be empty: %s\n' "${report_directory}" >&2
  exit 65
}

open_files="$(ulimit -n)"
[[ "${open_files}" =~ ^[0-9]+$ ]] && (( open_files >= 65536 )) || {
  printf 'ulimit -n must be at least 65536 for two 5000-connection workers; found %s\n' "${open_files}" >&2
  exit 69
}

run_worker() {
  local credentials="$1"
  local worker="$2"
  IM_V2_LOAD_LOCAL_MAX_RSS_MB=4096 \
  IM_V2_LOAD_LOCAL_MAX_CPU_PERCENT=700 \
  IM_V2_LOAD_LOCAL_MAX_CPU_SAMPLES=5 \
  "${runner}" \
    --host "${host}" \
    --port 443 \
    --server-name localhost \
    --ca-path "${ca_path}" \
    --credentials "${credentials}" \
    --report "${report_directory}/worker-${worker}.json" \
    --revision "${revision}-worker-${worker}" \
    --connections 5000 \
    --ramp-per-second "${ramp_per_second}" \
    --ramp-batch-size 50 \
    --workload-ramp-per-second 100 \
    --hold-seconds 60 \
    --event-loops 4 \
    --messages-per-second 0 \
    --max-inflight-messages-per-connection 1 \
    --message-bytes 128 \
    --targets-per-connection 4 \
    --target-offset 1 \
    --sync-reads 0 \
    --room-log-reads 0 \
    --scenario "${scenario_path}" \
    --scenario-rate-scale 0.5 \
    --max-rss-mb 4096 \
    --max-failure-percent 0.1
}

run_worker "${credentials_a}" a &
worker_a_pid="$!"
run_worker "${credentials_b}" b &
worker_b_pid="$!"

cleanup() {
  kill -INT "${worker_a_pid}" "${worker_b_pid}" >/dev/null 2>&1 || true
}
trap cleanup INT TERM

wait "${worker_a_pid}"
wait "${worker_b_pid}"
"${summarizer}" "${report_directory}" "${report_directory}/summary.json"
printf 'high-active 10000 scenario completed; reports: %s\n' "${report_directory}"
