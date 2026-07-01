#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 print|xcodebuild [xcodebuild-action...]

Print or apply local IM client network settings for Debug builds.

Environment:
  IM_LOCAL_HOST        override detected Mac LAN IP
  IM_LOCAL_API_PORT    HTTP API port, default: 8080
  IM_LOCAL_TCP_PORT    TCP IM port, default: 9000
  IM_XCODE_DESTINATION xcodebuild destination, default: generic/platform=iOS
EOF
}

detect_lan_ip() {
  if [[ -n "${IM_LOCAL_HOST:-}" ]]; then
    printf '%s\n' "$IM_LOCAL_HOST"
    return
  fi

  local candidate
  for interface in en0 en1; do
    candidate="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  candidate="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}' | xargs -I{} ipconfig getifaddr {} 2>/dev/null || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  printf 'Unable to detect a LAN IP. Set IM_LOCAL_HOST manually.\n' >&2
  exit 1
}

api_port="${IM_LOCAL_API_PORT:-8080}"
tcp_port="${IM_LOCAL_TCP_PORT:-9000}"
lan_ip="$(detect_lan_ip)"
api_base_url="http://${lan_ip}:${api_port}"

command_name="${1:-print}"
shift || true

case "$command_name" in
  print)
    cat <<EOF
Local IM client settings:
  IM_API_BASE_URL=${api_base_url}
  IM_TCP_HOST=${lan_ip}
  IM_TCP_PORT=${tcp_port}

iOS Simulator default remains:
  IM_API_BASE_URL=http://127.0.0.1:8080
  IM_TCP_HOST=127.0.0.1
  IM_TCP_PORT=9000

For a physical iPhone on the same Wi-Fi, build Debug with:
  xcodebuild -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration Debug -destination 'generic/platform=iOS' IM_API_BASE_URL=${api_base_url} IM_TCP_HOST=${lan_ip} IM_TCP_PORT=${tcp_port} build-for-testing
EOF
    ;;
  xcodebuild)
    if [[ "$#" -eq 0 ]]; then
      set -- build-for-testing
    fi
    cd "$REPO_ROOT"
    xcodebuild \
      -project IMApp/IMApp.xcodeproj \
      -scheme IMApp \
      -configuration Debug \
      -destination "${IM_XCODE_DESTINATION:-generic/platform=iOS}" \
      "IM_API_BASE_URL=${api_base_url}" \
      "IM_TCP_HOST=${lan_ip}" \
      "IM_TCP_PORT=${tcp_port}" \
      "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
