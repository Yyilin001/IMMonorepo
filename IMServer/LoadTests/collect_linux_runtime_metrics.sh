#!/usr/bin/env bash
set -Eeuo pipefail

# Emits a low-overhead, append-only host telemetry stream for capacity and
# message-delivery runs. It is designed to run on the IM host; when invoked in
# a load-generator container, the Docker section is simply omitted.

OUTPUT_FILE=""
INTERVAL_SECONDS="5"
COMPOSE_PROJECT="imserver-production-smoke"
TCP_PORT="9000"

usage() {
  echo "usage: $0 --output FILE [--interval-seconds N] [--compose-project NAME] [--tcp-port PORT]" >&2
}

while (($#)); do
  case "$1" in
    --output) OUTPUT_FILE="${2:-}"; shift 2 ;;
    --interval-seconds) INTERVAL_SECONDS="${2:-}"; shift 2 ;;
    --compose-project) COMPOSE_PROJECT="${2:-}"; shift 2 ;;
    --tcp-port) TCP_PORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "${OUTPUT_FILE}" ]] || { usage; exit 2; }
[[ "${INTERVAL_SECONDS}" =~ ^[1-9][0-9]*$ ]] || { echo "invalid interval" >&2; exit 2; }
[[ "${TCP_PORT}" =~ ^[1-9][0-9]*$ ]] || { echo "invalid TCP port" >&2; exit 2; }
mkdir -p "$(dirname "${OUTPUT_FILE}")"

read_cpu_ticks() {
  local user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  local idle_total=$((idle + iowait))
  printf '%s %s\n' "${total}" "${idle_total}"
}

read -r previous_total previous_idle < <(read_cpu_ticks)

while true; do
  read -r total idle < <(read_cpu_ticks)
  total_delta=$((total - previous_total))
  idle_delta=$((idle - previous_idle))
  host_cpu_percent="0.00"
  if ((total_delta > 0)); then
    host_cpu_percent="$(awk -v total="${total_delta}" -v idle="${idle_delta}" 'BEGIN { printf "%.2f", (total-idle)*100/total }')"
  fi
  previous_total="${total}"
  previous_idle="${idle}"

  mem_total_kib="$(awk '/MemTotal:/ { print $2 }' /proc/meminfo)"
  mem_available_kib="$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)"
  mem_used_kib=$((mem_total_kib - mem_available_kib))
  established="$(ss -tan state established "( sport = :${TCP_PORT} or dport = :${TCP_PORT} )" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  file_allocated="$(awk '{ print $1 }' /proc/sys/fs/file-nr 2>/dev/null || echo unknown)"
  load_average="$(awk '{ print $1 "," $2 "," $3 }' /proc/loadavg)"

  {
    printf 'timestamp=%s host_cpu_percent=%s mem_total_mib=%s mem_used_mib=%s mem_available_mib=%s tcp_established=%s open_files=%s load_average=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${host_cpu_percent}" \
      "$((mem_total_kib / 1024))" "$((mem_used_kib / 1024))" "$((mem_available_kib / 1024))" \
      "${established}" "${file_allocated}" "${load_average}"
    if command -v docker >/dev/null 2>&1; then
      docker stats --no-stream --format 'container={{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} mem_percent={{.MemPerc}} pids={{.PIDs}}' 2>/dev/null \
        | awk -v prefix="${COMPOSE_PROJECT}-" 'index($1, "container=" prefix) == 1' || true
    fi
  } >>"${OUTPUT_FILE}"
  sleep "${INTERVAL_SECONDS}"
done
