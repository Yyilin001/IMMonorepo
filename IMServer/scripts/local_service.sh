#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION="${IMSERVER_LOCAL_SCREEN_SESSION:-imserver-local}"
HTTP_PORT="${PORT:-8080}"
HTTP_HOST="${HTTP_HOST:-0.0.0.0}"
HEALTH_URL="${IMSERVER_LOCAL_HEALTH_URL:-http://127.0.0.1:${HTTP_PORT}/health}"

usage() {
  cat <<EOF
Usage: $0 start|stop|restart|status|health|logs

Environment:
  IMSERVER_LOCAL_SCREEN_SESSION  screen session name, default: imserver-local
  PORT                           HTTP port, default: 8080
  HTTP_HOST                      HTTP bind host, default: 0.0.0.0
  IMSERVER_LOCAL_HEALTH_URL      health probe URL, default: http://127.0.0.1:\${PORT}/health
EOF
}

screen_available() {
  command -v screen >/dev/null 2>&1
}

session_exists() {
  local sessions
  sessions="$(screen -ls 2>/dev/null || true)"
  grep -Fq ".${SESSION}" <<<"$sessions"
}

local_imserver_pids_on_port() {
  local port="$1"
  local pid command
  for pid in $(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == *".build/debug/IMServer serve --env development"* ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

stop_local_imserver_processes() {
  local pids=()
  local pid
  for pid in $(local_imserver_pids_on_port "$HTTP_PORT") $(local_imserver_pids_on_port 9000); do
    if [[ -n "$pid" && ! " ${pids[*]} " =~ " ${pid} " ]]; then
      pids+=("$pid")
    fi
  done

  if [[ "${#pids[@]}" -eq 0 ]]; then
    return
  fi

  echo "Stopping local IMServer process(es): ${pids[*]}"
  kill "${pids[@]}" 2>/dev/null || true
  sleep 1

  local alive=()
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      alive+=("$pid")
    fi
  done
  if [[ "${#alive[@]}" -gt 0 ]]; then
    echo "Force stopping local IMServer process(es): ${alive[*]}"
    kill -9 "${alive[@]}" 2>/dev/null || true
  fi
}

build_server() {
  (cd "$PROJECT_ROOT" && swift build --product IMServer)
}

start_service() {
  if ! screen_available; then
    echo "screen is required to run the local service in the background." >&2
    exit 1
  fi

  if session_exists; then
    echo "IMServer local service already running in screen session ${SESSION}."
    status_service
    return
  fi

  stop_local_imserver_processes
  build_server

  local command
  command="cd \"$PROJECT_ROOT\" && IMSERVER_RUN_LOCAL_BINARY=\".build/debug/IMServer\" ./scripts/run_local.sh serve --env development --hostname \"$HTTP_HOST\" --port \"$HTTP_PORT\""
  screen -dmS "$SESSION" zsh -lc "$command"
  echo "Started IMServer local service in screen session ${SESSION}."
  sleep 2
  status_service
}

stop_service() {
  if session_exists; then
    screen -S "$SESSION" -X quit
    echo "Stopped IMServer local service screen session ${SESSION}."
  else
    echo "IMServer local service screen session ${SESSION} is not running."
  fi
  stop_local_imserver_processes
}

status_service() {
  (screen -ls 2>/dev/null || true) | sed -n '1,80p'
  lsof -nP -iTCP:"$HTTP_PORT" -sTCP:LISTEN || true
  lsof -nP -iTCP:9000 -sTCP:LISTEN || true
}

health_service() {
  curl -fsS "$HEALTH_URL"
  printf '\n'
}

logs_service() {
  if ! session_exists; then
    echo "IMServer local service screen session ${SESSION} is not running." >&2
    exit 1
  fi

  local log_file="${TMPDIR:-/tmp}/imserver-local-${SESSION}.screen.txt"
  screen -S "$SESSION" -X hardcopy "$log_file"
  tail -n 120 "$log_file"
}

command_name="${1:-status}"
case "$command_name" in
  start)
    start_service
    ;;
  stop)
    stop_service
    ;;
  restart)
    stop_service
    start_service
    ;;
  status)
    status_service
    ;;
  health)
    health_service
    ;;
  logs)
    logs_service
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
