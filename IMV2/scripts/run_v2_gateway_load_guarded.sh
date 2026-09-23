#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
binary_directory="$(swift build --disable-automatic-resolution -c release --package-path "${repo_root}/IMV2Server" --show-bin-path)"
binary="${binary_directory}/IMV2GatewayLoadGenerator"
maximum_rss_mb="${IM_V2_LOAD_LOCAL_MAX_RSS_MB:-2048}"
maximum_cpu_percent="${IM_V2_LOAD_LOCAL_MAX_CPU_PERCENT:-500}"
maximum_cpu_samples="${IM_V2_LOAD_LOCAL_MAX_CPU_SAMPLES:-5}"

[[ -x "${binary}" ]] || {
  printf 'missing release load generator; run: swift build -c release --package-path IMV2Server --product IMV2GatewayLoadGenerator\n' >&2
  exit 66
}

nice -n 10 "${binary}" "$@" &
load_pid="$!"
caffeinate -dimsu -w "${load_pid}" &
caffeinate_pid="$!"
high_cpu_samples=0

cleanup() {
  kill "${caffeinate_pid}" >/dev/null 2>&1 || true
  if kill -0 "${load_pid}" >/dev/null 2>&1; then
    kill -INT "${load_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

while kill -0 "${load_pid}" >/dev/null 2>&1; do
  rss_kb="$(ps -o rss= -p "${load_pid}" | tr -d '[:space:]')"
  cpu_percent="$(ps -o %cpu= -p "${load_pid}" | tr -d '[:space:]')"
  [[ -n "${rss_kb}" ]] || break
  rss_mb=$((rss_kb / 1024))
  if (( rss_mb > maximum_rss_mb )); then
    printf 'watchdog: RSS limit exceeded (%d MB > %d MB); stopping load generator\n' "${rss_mb}" "${maximum_rss_mb}" >&2
    kill -INT "${load_pid}" >/dev/null 2>&1 || true
    break
  fi
  if awk -v current="${cpu_percent:-0}" -v limit="${maximum_cpu_percent}" 'BEGIN { exit !(current > limit) }'; then
    high_cpu_samples=$((high_cpu_samples + 1))
  else
    high_cpu_samples=0
  fi
  if (( high_cpu_samples >= maximum_cpu_samples )); then
    printf 'watchdog: CPU limit exceeded for %d samples; stopping load generator\n' "${high_cpu_samples}" >&2
    kill -INT "${load_pid}" >/dev/null 2>&1 || true
    break
  fi
  sleep 2
done

set +e
wait "${load_pid}"
exit_status="$?"
set -e
kill "${caffeinate_pid}" >/dev/null 2>&1 || true
wait "${caffeinate_pid}" >/dev/null 2>&1 || true
exit "${exit_status}"
