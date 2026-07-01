#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENTRYPOINT_REPAIR_SELF_TEST="${ENTRYPOINT_REPAIR_SELF_TEST:-false}"
ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${IM_PUBLIC_BASE_URL:-}}"
PUBLIC_PROTOCOL_PORTS="${PUBLIC_PROTOCOL_PORTS:-22 ${HTTP_PORT} ${IM_TCP_PORT:-9000}}"
LOCAL_BASE_URL="${LOCAL_BASE_URL:-http://127.0.0.1:${HTTP_PORT}}"
GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-${IM_GATEWAY_HTTP_PORT:-18080}}"
COMMAND_API_PORT="${COMMAND_API_PORT:-${IM_COMMAND_API_PORT:-8081}}"
QUERY_API_PORT="${QUERY_API_PORT:-${IM_QUERY_API_PORT:-8082}}"
ENTRYPOINT_REPAIR_INSTALL_NGINX="${ENTRYPOINT_REPAIR_INSTALL_NGINX:-true}"
ENTRYPOINT_REPAIR_VERIFY_PUBLIC="${ENTRYPOINT_REPAIR_VERIFY_PUBLIC:-true}"
ENTRYPOINT_REPAIR_TIMEOUT_SECONDS="${ENTRYPOINT_REPAIR_TIMEOUT_SECONDS:-5}"
ENTRYPOINT_REPAIR_RETRIES="${ENTRYPOINT_REPAIR_RETRIES:-12}"
ENTRYPOINT_REPAIR_RETRY_INTERVAL_SECONDS="${ENTRYPOINT_REPAIR_RETRY_INTERVAL_SECONDS:-2}"
ENTRYPOINT_REPAIR_REPORT="${ENTRYPOINT_REPAIR_REPORT:-/var/log/imserver/http-entrypoint-repair.log}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

http_status_and_size() {
  local url="$1"
  local body_file status rc=0 size
  body_file="$(mktemp)"
  status="$(curl -sS --connect-timeout "${ENTRYPOINT_REPAIR_TIMEOUT_SECONDS}" --max-time "${ENTRYPOINT_REPAIR_TIMEOUT_SECONDS}" -o "${body_file}" -w '%{http_code}' "${url}" 2>/dev/null)" || rc=$?
  size="$(wc -c <"${body_file}" 2>/dev/null | tr -d ' ' || printf '0')"
  rm -f "${body_file}"
  if [[ "${rc}" != "0" ]]; then
    printf 'curl-error:%s %s\n' "${rc}" "${size:-0}"
  else
    printf '%s %s\n' "${status:-000}" "${size:-0}"
  fi
}

http_status_with_retry() {
  local label="$1"
  local url="$2"
  local expected_status="${3:-200}"
  local attempt result status size
  result="000 0"
  for attempt in $(seq 1 "${ENTRYPOINT_REPAIR_RETRIES}"); do
    result="$(http_status_and_size "${url}")"
    status="${result% *}"
    size="${result#* }"
    printf 'wait=%s url=%s attempt=%s/%s status=%s bodyBytes=%s expected=%s\n' \
      "${label}" \
      "${url}" \
      "${attempt}" \
      "${ENTRYPOINT_REPAIR_RETRIES}" \
      "${status}" \
      "${size}" \
      "${expected_status}" >>"${ENTRYPOINT_REPAIR_REPORT}"
    if [[ "${status}" == "${expected_status}" ]]; then
      printf '%s\n' "${result}"
      return 0
    fi
    sleep "${ENTRYPOINT_REPAIR_RETRY_INTERVAL_SECONDS}"
  done
  printf '%s\n' "${result}"
  return 1
}

tcp_listener_summary() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | awk -v port=":${HTTP_PORT}" 'NR == 1 || index($4, port) > 0'
  else
    printf 'ss unavailable\n'
  fi
}

write_report_header() {
  install -d -m 0755 "$(dirname "${ENTRYPOINT_REPAIR_REPORT}")"
  {
    printf 'http_entrypoint_repair startedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'localBaseURL=%s publicBaseURL=%s httpPort=%s gatewayPort=%s commandPort=%s queryPort=%s\n' \
      "${LOCAL_BASE_URL}" \
      "${PUBLIC_BASE_URL:-<unset>}" \
      "${HTTP_PORT}" \
      "${GATEWAY_HTTP_PORT}" \
      "${COMMAND_API_PORT}" \
      "${QUERY_API_PORT}"
  } | tee "${ENTRYPOINT_REPAIR_REPORT}"
}

append_report() {
  tee -a "${ENTRYPOINT_REPAIR_REPORT}"
}

probe_pair() {
  local label="$1"
  local base_url="$2"
  local nginx_result health_result nginx_status nginx_size health_status health_size
  nginx_result="$(http_status_and_size "${base_url%/}/nginx-health")"
  health_result="$(http_status_and_size "${base_url%/}/health")"
  nginx_status="${nginx_result% *}"
  nginx_size="${nginx_result#* }"
  health_status="${health_result% *}"
  health_size="${health_result#* }"
  printf 'probe=%s path=/nginx-health status=%s bodyBytes=%s\n' "${label}" "${nginx_status}" "${nginx_size}"
  printf 'probe=%s path=/health status=%s bodyBytes=%s\n' "${label}" "${health_status}" "${health_size}"
}

url_host() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse
import sys

print(urlparse(sys.argv[1]).hostname or "")
PY
}

probe_port_protocol() {
  local host="$1"
  local port="$2"
  local raw compact
  if [[ -z "${host}" || -z "${port}" ]]; then
    printf 'skipped_missing_target\n'
    return 0
  fi
  if ! command -v nc >/dev/null 2>&1; then
    printf 'skipped_nc_missing\n'
    return 0
  fi
  raw="$(printf '' | nc -w "${ENTRYPOINT_REPAIR_TIMEOUT_SECONDS}" "${host}" "${port}" 2>/dev/null | LC_ALL=C head -c 160 || true)"
  compact="$(printf '%s' "${raw}" | LC_ALL=C tr '\r\n\t ' '____' | sed 's/__*/_/g; s/^_//; s/_$//' | cut -c 1-120)"
  if [[ -z "${compact}" ]]; then
    printf 'no_banner\n'
  elif [[ "${compact}" == SSH-* ]]; then
    printf 'ssh_banner\n'
  elif [[ "${compact}" == HTTP/1.1_403* || "${compact}" == HTTP/1.0_403* || "${compact}" == HTTP/2_403* ]]; then
    printf 'http_403_intercepted\n'
  elif [[ "${compact}" == HTTP/* ]]; then
    printf 'http_intercepted\n'
  else
    printf 'unexpected_banner:%s\n' "${compact}"
  fi
}

public_protocol_summary() {
  local host port protocol seen_ports="" sampled=0 http403=0 edge="<none>"
  if [[ -z "${PUBLIC_BASE_URL}" ]]; then
    printf 'sampled=0 http403=0 edgeIntercept=<none>\n'
    return 0
  fi
  host="$(url_host "${PUBLIC_BASE_URL}")"
  if [[ -z "${host}" ]]; then
    printf 'sampled=0 http403=0 edgeIntercept=skipped_missing_host\n'
    return 0
  fi
  for port in ${PUBLIC_PROTOCOL_PORTS}; do
    if [[ -z "${port}" || " ${seen_ports} " == *" ${port} "* ]]; then
      continue
    fi
    seen_ports="${seen_ports} ${port}"
    protocol="$(probe_port_protocol "${host}" "${port}")"
    printf 'protocolProbe=public host=%s port=%s protocol=%s\n' "${host}" "${port}" "${protocol}" >>"${ENTRYPOINT_REPAIR_REPORT}"
    sampled=$((sampled + 1))
    if [[ "${protocol}" == "http_403_intercepted" ]]; then
      http403=$((http403 + 1))
    fi
  done
  if (( sampled >= 2 && sampled == http403 )); then
    edge="http_403_all_sampled_ports"
  elif (( http403 >= 2 )); then
    edge="http_403_multiple_sampled_ports"
  fi
  printf 'sampled=%s http403=%s edgeIntercept=%s\n' "${sampled}" "${http403}" "${edge}"
}

run_self_test() {
  local self_test_dir fake_bin old_path old_report old_retries old_interval local_result public_result public_protocol_result
  self_test_dir="$(mktemp -d)"
  fake_bin="${self_test_dir}/bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/curl" <<'SH'
#!/usr/bin/env bash
body_file=""
url=""
while (($#)); do
  case "$1" in
    -o)
      body_file="$2"
      shift 2
      ;;
    -w|--connect-timeout|--max-time)
      shift 2
      ;;
    -sS)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
code=200
body="ok"
case "${url}" in
  *public-bad*/nginx-health|*public-bad*/health)
    code=403
    body=""
    ;;
  *curl-error*)
    exit 7
    ;;
esac
if [[ -n "${body_file}" ]]; then
  printf '%s' "${body}" >"${body_file}"
fi
printf '%s' "${code}"
SH
  cat >"${fake_bin}/nc" <<'SH'
#!/usr/bin/env bash
zero_check=false
host=""
port=""
while (($#)); do
  case "$1" in
    -z)
      zero_check=true
      shift
      ;;
    -w)
      shift 2
      ;;
    *)
      if [[ -z "${host}" ]]; then
        host="$1"
      else
        port="$1"
      fi
      shift
      ;;
  esac
done
if [[ "${zero_check}" == true ]]; then
  exit 0
fi
case "${host}" in
  public-bad)
    printf 'HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'
    ;;
esac
exit 0
SH
  chmod +x "${fake_bin}/curl" "${fake_bin}/nc"
  old_path="${PATH}"
  old_report="${ENTRYPOINT_REPAIR_REPORT}"
  old_retries="${ENTRYPOINT_REPAIR_RETRIES}"
  old_interval="${ENTRYPOINT_REPAIR_RETRY_INTERVAL_SECONDS}"
  PATH="${fake_bin}:${PATH}"
  ENTRYPOINT_REPAIR_REPORT="${self_test_dir}/repair.log"
  ENTRYPOINT_REPAIR_RETRIES=1
  ENTRYPOINT_REPAIR_RETRY_INTERVAL_SECONDS=0
  write_report_header >/dev/null
  local_result="$(http_status_with_retry local-nginx http://local/nginx-health 200)"
  if [[ "${local_result% *}" != "200" ]]; then
    printf 'http_entrypoint_repair_self_test result=fail reason=local_expected_200 actual=%s\n' "${local_result% *}" >&2
    return 1
  fi
  if public_result="$(http_status_with_retry public-nginx http://public-bad/nginx-health 200)"; then
    printf 'http_entrypoint_repair_self_test result=fail reason=public_bad_unexpected_pass\n' >&2
    return 1
  fi
  if [[ "${public_result% *}" != "403" ]]; then
    printf 'http_entrypoint_repair_self_test result=fail reason=public_expected_403 actual=%s\n' "${public_result% *}" >&2
    return 1
  fi
  public_protocol_result="$(
    PUBLIC_BASE_URL=http://public-bad:8080 \
    PUBLIC_PROTOCOL_PORTS="22 8080 9000" \
      public_protocol_summary
  )"
  if [[ "${public_protocol_result}" != "sampled=3 http403=3 edgeIntercept=http_403_all_sampled_ports" ]]; then
    printf 'http_entrypoint_repair_self_test result=fail reason=public_protocol_summary_unexpected actual=%s\n' "${public_protocol_result}" >&2
    return 1
  fi
  PATH="${old_path}"
  ENTRYPOINT_REPAIR_REPORT="${old_report}"
  ENTRYPOINT_REPAIR_RETRIES="${old_retries}"
  ENTRYPOINT_REPAIR_RETRY_INTERVAL_SECONDS="${old_interval}"
  if ! grep -q 'wait=public-nginx' "${self_test_dir}/repair.log"; then
    printf 'http_entrypoint_repair_self_test result=fail reason=missing_wait_log\n' >&2
    rm -rf "${self_test_dir}"
    return 1
  fi
  rm -rf "${self_test_dir}"
  printf 'http_entrypoint_repair_self_test result=pass\n'
}

if bool_enabled "${ENTRYPOINT_REPAIR_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root

write_report_header

if bool_enabled "${ENTRYPOINT_REPAIR_INSTALL_NGINX}"; then
  {
    printf '\n==> reinstall-nginx-server-block\n'
    env \
      IM_PUBLIC_HTTP_PORT="${HTTP_PORT}" \
      IM_GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT}" \
      IM_COMMAND_API_PORT="${COMMAND_API_PORT}" \
      IM_QUERY_API_PORT="${QUERY_API_PORT}" \
      NGINX_DISABLE_DEFAULT_SITE=true \
      bash "${SCRIPT_DIR}/60_install_nginx.sh"
  } 2>&1 | append_report
else
  printf '\n==> reinstall-nginx-server-block skipped\n' | append_report
fi

{
  printf '\n==> listener-summary\n'
  tcp_listener_summary
  printf '\n==> local-probes\n'
  probe_pair "local" "${LOCAL_BASE_URL}"
} 2>&1 | append_report

local_nginx_result="$(http_status_with_retry "local-nginx-health" "${LOCAL_BASE_URL%/}/nginx-health" 200 || true)"
local_health_result="$(http_status_with_retry "local-health" "${LOCAL_BASE_URL%/}/health" 200 || true)"
local_nginx_status="${local_nginx_result% *}"
local_health_status="${local_health_result% *}"

if [[ "${local_nginx_status}" != "200" ]]; then
  {
    printf '\nhttp_entrypoint_repair result=fail reason=local_nginx_health_failed localNginxStatus=%s localHealthStatus=%s\n' \
      "${local_nginx_status}" \
      "${local_health_status}"
    printf 'Next: inspect nginx -T, journalctl -u nginx, and listener-summary above.\n'
  } | append_report
  exit 1
fi

if [[ "${local_health_status}" != "200" ]]; then
  {
    printf '\nhttp_entrypoint_repair result=fail reason=local_upstream_health_failed localNginxStatus=%s localHealthStatus=%s\n' \
      "${local_nginx_status}" \
      "${local_health_status}"
    printf 'Next: inspect imserver-gateway on 127.0.0.1:%s and run deploy/ubuntu/75_entrypoint_diagnose.sh.\n' \
      "${GATEWAY_HTTP_PORT}"
  } | append_report
  exit 1
fi

if bool_enabled "${ENTRYPOINT_REPAIR_VERIFY_PUBLIC}" && [[ -n "${PUBLIC_BASE_URL}" ]]; then
  {
    printf '\n==> public-probes\n'
    probe_pair "public" "${PUBLIC_BASE_URL}"
  } 2>&1 | append_report

  public_nginx_result="$(http_status_with_retry "public-nginx-health" "${PUBLIC_BASE_URL%/}/nginx-health" 200 || true)"
  public_health_result="$(http_status_with_retry "public-health" "${PUBLIC_BASE_URL%/}/health" 200 || true)"
  public_nginx_status="${public_nginx_result% *}"
  public_nginx_size="${public_nginx_result#* }"
  public_health_status="${public_health_result% *}"
  public_health_size="${public_health_result#* }"

  if [[ "${public_nginx_status}" != "200" ]]; then
    public_protocol_result="$(public_protocol_summary)"
    public_edge_intercept="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^edgeIntercept=/) { sub(/^edgeIntercept=/, "", $i); print $i; exit } }' <<<"${public_protocol_result}")"
    {
      if [[ "${public_edge_intercept}" == "http_403_all_sampled_ports" ]]; then
        printf '\nhttp_entrypoint_repair result=fail reason=cloud_edge_http_403_intercept publicNginxStatus=%s publicNginxBodyBytes=%s publicHealthStatus=%s publicHealthBodyBytes=%s %s\n' \
          "${public_nginx_status}" \
          "${public_nginx_size}" \
          "${public_health_status}" \
          "${public_health_size}" \
          "${public_protocol_result}"
        printf 'Public HTTP and sampled protocol ports all return empty HTTP 403. Fix cloud security policy, WAF, NAT/public IP routing, or provider edge rules from the cloud console before running performance tests.\n'
      else
        printf '\nhttp_entrypoint_repair result=fail reason=public_listener_not_this_nginx publicNginxStatus=%s publicNginxBodyBytes=%s publicHealthStatus=%s publicHealthBodyBytes=%s %s\n' \
          "${public_nginx_status}" \
          "${public_nginx_size}" \
          "${public_health_status}" \
          "${public_health_size}" \
          "${public_protocol_result}"
        printf 'Local Nginx is healthy, but public /nginx-health is not. Fix cloud security group, WAF, external proxy, NAT, wrong public IP, or another listener before running performance tests.\n'
      fi
    } | append_report
    exit 1
  fi

  if [[ "${public_health_status}" != "200" ]]; then
    {
      printf '\nhttp_entrypoint_repair result=fail reason=public_health_failed publicNginxStatus=%s publicHealthStatus=%s publicHealthBodyBytes=%s\n' \
        "${public_nginx_status}" \
        "${public_health_status}" \
        "${public_health_size}"
      printf 'Public traffic reaches this Nginx server block, but upstream health is not OK through the public path. Check host/proxy headers and gateway upstream health.\n'
    } | append_report
    exit 1
  fi
fi

printf '\nhttp_entrypoint_repair result=pass report=%s\n' "${ENTRYPOINT_REPAIR_REPORT}" | append_report
