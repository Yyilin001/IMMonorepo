#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-18080}"
COMMAND_API_PORT="${COMMAND_API_PORT:-8081}"
QUERY_API_PORT="${QUERY_API_PORT:-8082}"
TCP_PORT="${TCP_PORT:-9000}"
LOCAL_HOST="${LOCAL_HOST:-127.0.0.1}"
LOCAL_BASE_URL="${LOCAL_BASE_URL:-http://${LOCAL_HOST}:${HTTP_PORT}}"
GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://127.0.0.1:${GATEWAY_HTTP_PORT}}"
COMMAND_API_BASE_URL="${COMMAND_API_BASE_URL:-http://127.0.0.1:${COMMAND_API_PORT}}"
QUERY_API_BASE_URL="${QUERY_API_BASE_URL:-http://127.0.0.1:${QUERY_API_PORT}}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
PUBLIC_PROTOCOL_PORTS="${PUBLIC_PROTOCOL_PORTS:-22 ${HTTP_PORT} ${TCP_PORT}}"
CURL_TIMEOUT_SECONDS="${CURL_TIMEOUT_SECONDS:-5}"
JOURNAL_LINES="${JOURNAL_LINES:-80}"
ENTRYPOINT_DIAGNOSE_SELF_TEST="${ENTRYPOINT_DIAGNOSE_SELF_TEST:-false}"

local_health_status=""
local_health_body_bytes=""
local_nginx_health_status=""
local_nginx_health_body_bytes=""
public_health_status=""
public_health_body_bytes=""
public_nginx_health_status=""
public_nginx_health_body_bytes=""
local_auth_status=""
local_auth_body_bytes=""
public_auth_status=""
public_auth_body_bytes=""
gateway_health_status=""
command_health_status=""
query_health_status=""
public_protocol_probe_count=0
public_protocol_http_403_count=0
public_edge_intercept=""

section() {
  printf '\n==> %s\n' "$1"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_optional() {
  local title="$1"
  shift
  printf '\n-- %s\n' "${title}"
  "$@" 2>&1 || true
}

first_header() {
  local file="$1"
  local name="$2"
  awk -v wanted="${name}" '
    index(tolower($0), tolower(wanted) ":") == 1 {
      sub("\r$", "")
      sub("^[^:]*:[[:space:]]*", "")
      print
      exit
    }
  ' "${file}" 2>/dev/null || true
}

probe_url() {
  local label="$1"
  local method="$2"
  local url="$3"
  local body="${4:-}"
  local header_file
  local body_file
  local status
  local exit_code
  local body_bytes
  local content_type
  local server_header
  local via_header
  local location_header
  local request_id

  header_file="$(mktemp)"
  body_file="$(mktemp)"

  set +e
  if [[ "${method}" == "POST" ]]; then
    status="$(curl -sS -m "${CURL_TIMEOUT_SECONDS}" -o "${body_file}" -D "${header_file}" -w '%{http_code}' -X "${method}" -H 'content-type: application/json' --data "${body}" "${url}" 2>/dev/null)"
  else
    status="$(curl -sS -m "${CURL_TIMEOUT_SECONDS}" -o "${body_file}" -D "${header_file}" -w '%{http_code}' -X "${method}" "${url}" 2>/dev/null)"
  fi
  exit_code=$?
  set -e

  body_bytes="$(wc -c < "${body_file}" | tr -d ' ')"
  content_type="$(first_header "${header_file}" "content-type")"
  server_header="$(first_header "${header_file}" "server")"
  via_header="$(first_header "${header_file}" "via")"
  location_header="$(first_header "${header_file}" "location")"
  request_id="$(first_header "${header_file}" "x-request-id")"

  printf 'probe=%s method=%s url=%s status=%s curlExit=%s bodyBytes=%s contentType=%s server=%s via=%s location=%s requestID=%s\n' \
    "${label}" \
    "${method}" \
    "${url}" \
    "${status:-000}" \
    "${exit_code}" \
    "${body_bytes}" \
    "${content_type:-<none>}" \
    "${server_header:-<none>}" \
    "${via_header:-<none>}" \
    "${location_header:-<none>}" \
    "${request_id:-<none>}"

  if [[ "${body_bytes}" != "0" ]]; then
    printf 'probe=%s bodyPreview=' "${label}"
    LC_ALL=C tr '\r\n' '  ' < "${body_file}" | cut -c 1-240
    printf '\n'
  fi

  case "${label}" in
    local-health)
      local_health_status="${status:-000}"
      local_health_body_bytes="${body_bytes}"
      ;;
    local-nginx-health)
      local_nginx_health_status="${status:-000}"
      local_nginx_health_body_bytes="${body_bytes}"
      ;;
    public-health)
      public_health_status="${status:-000}"
      public_health_body_bytes="${body_bytes}"
      ;;
    public-nginx-health)
      public_nginx_health_status="${status:-000}"
      public_nginx_health_body_bytes="${body_bytes}"
      ;;
    local-auth-login-get)
      local_auth_status="${status:-000}"
      local_auth_body_bytes="${body_bytes}"
      ;;
    public-auth-login-get)
      public_auth_status="${status:-000}"
      public_auth_body_bytes="${body_bytes}"
      ;;
    gateway-health)
      gateway_health_status="${status:-000}"
      ;;
    command-api-health)
      command_health_status="${status:-000}"
      ;;
    query-api-health)
      query_health_status="${status:-000}"
      ;;
  esac

  rm -f "${header_file}" "${body_file}"
}

print_tcp_probe() {
  local host="$1"
  local port="$2"
  local label="$3"

  if have_cmd nc; then
    if nc -z -w "${CURL_TIMEOUT_SECONDS}" "${host}" "${port}" >/dev/null 2>&1; then
      printf 'tcpProbe=%s host=%s port=%s status=open\n' "${label}" "${host}" "${port}"
    else
      printf 'tcpProbe=%s host=%s port=%s status=closed_or_filtered\n' "${label}" "${host}" "${port}"
    fi
  elif have_cmd timeout; then
    if timeout "${CURL_TIMEOUT_SECONDS}" bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      printf 'tcpProbe=%s host=%s port=%s status=open\n' "${label}" "${host}" "${port}"
    else
      printf 'tcpProbe=%s host=%s port=%s status=closed_or_filtered\n' "${label}" "${host}" "${port}"
    fi
  else
    printf 'tcpProbe=%s host=%s port=%s status=unknown reason=no_nc_or_timeout\n' "${label}" "${host}" "${port}"
  fi
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
  if ! have_cmd nc; then
    printf 'skipped_nc_missing\n'
    return 0
  fi
  raw="$(printf '' | nc -w "${CURL_TIMEOUT_SECONDS}" "${host}" "${port}" 2>/dev/null | LC_ALL=C head -c 160 || true)"
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

print_public_protocol_probes() {
  local host port protocol seen_ports=""
  if [[ -z "${PUBLIC_BASE_URL}" ]]; then
    return 0
  fi
  host="$(url_host "${PUBLIC_BASE_URL}")"
  if [[ -z "${host}" ]]; then
    printf 'protocolProbe=public host=<none> status=skipped_missing_host\n'
    return 0
  fi
  for port in ${PUBLIC_PROTOCOL_PORTS}; do
    if [[ -z "${port}" || " ${seen_ports} " == *" ${port} "* ]]; then
      continue
    fi
    seen_ports="${seen_ports} ${port}"
    protocol="$(probe_port_protocol "${host}" "${port}")"
    printf 'protocolProbe=public host=%s port=%s protocol=%s\n' "${host}" "${port}" "${protocol}"
    public_protocol_probe_count=$((public_protocol_probe_count + 1))
    if [[ "${protocol}" == "http_403_intercepted" ]]; then
      public_protocol_http_403_count=$((public_protocol_http_403_count + 1))
    fi
  done
  if (( public_protocol_probe_count >= 2 && public_protocol_probe_count == public_protocol_http_403_count )); then
    public_edge_intercept="http_403_all_sampled_ports"
  elif (( public_protocol_http_403_count >= 2 )); then
    public_edge_intercept="http_403_multiple_sampled_ports"
  fi
  printf 'protocolProbeSummary=public sampled=%s http403=%s edgeIntercept=%s\n' \
    "${public_protocol_probe_count}" \
    "${public_protocol_http_403_count}" \
    "${public_edge_intercept:-<none>}"
}

run_self_test() {
  local self_test_dir fake_bin output_log
  self_test_dir="$(mktemp -d)"
  fake_bin="${self_test_dir}/bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/curl" <<'SH'
#!/usr/bin/env bash
body_file=""
header_file=""
url=""
while (($#)); do
  case "$1" in
    -o)
      body_file="$2"
      shift 2
      ;;
    -D)
      header_file="$2"
      shift 2
      ;;
    -w|-m|--connect-timeout|--max-time|-X|-H|--data)
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
  *public-bad*)
    code=403
    body=""
    ;;
esac
if [[ -n "${body_file}" ]]; then
  printf '%s' "${body}" >"${body_file}"
fi
if [[ -n "${header_file}" ]]; then
  printf 'HTTP/1.1 %s Test\r\n\r\n' "${code}" >"${header_file}"
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
  *)
    printf ''
    ;;
esac
exit 0
SH
  chmod +x "${fake_bin}/curl" "${fake_bin}/nc"

  output_log="${self_test_dir}/diagnose.log"
  PATH="${fake_bin}:${PATH}" \
  ENTRYPOINT_DIAGNOSE_SELF_TEST=false \
  PUBLIC_BASE_URL=http://public-bad:8080 \
  HTTP_PORT=8080 \
  TCP_PORT=9000 \
  GATEWAY_HTTP_PORT=18080 \
  COMMAND_API_PORT=8081 \
  QUERY_API_PORT=8082 \
  CURL_TIMEOUT_SECONDS=1 \
  JOURNAL_LINES=1 \
    bash "${BASH_SOURCE[0]}" >"${output_log}" 2>&1

  grep -q 'protocolProbeSummary=public sampled=3 http403=3 edgeIntercept=http_403_all_sampled_ports' "${output_log}" || {
    printf 'entrypoint_diagnose_self_test result=fail reason=missing_protocol_summary\n' >&2
    cat "${output_log}" >&2
    rm -rf "${self_test_dir}"
    return 1
  }
  grep -q 'diagnosis=cloud_edge_http_403_intercept' "${output_log}" || {
    printf 'entrypoint_diagnose_self_test result=fail reason=missing_cloud_edge_diagnosis\n' >&2
    cat "${output_log}" >&2
    rm -rf "${self_test_dir}"
    return 1
  }
  if grep -q 'PRIVATE KEY' "${output_log}"; then
    printf 'entrypoint_diagnose_self_test result=fail reason=secret_marker_in_output\n' >&2
    rm -rf "${self_test_dir}"
    return 1
  fi
  rm -rf "${self_test_dir}"
  printf 'entrypoint_diagnose_self_test result=pass\n'
}

if [[ "${ENTRYPOINT_DIAGNOSE_SELF_TEST}" == "true" || "${ENTRYPOINT_DIAGNOSE_SELF_TEST}" == "1" ]]; then
  run_self_test
  exit 0
fi

section "Host"
printf 'date=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
printf 'hostname=%s\n' "$(hostname)"
printf 'user=%s uid=%s\n' "$(id -un)" "$(id -u)"
printf 'localBaseURL=%s gatewayBaseURL=%s commandAPIBaseURL=%s queryAPIBaseURL=%s publicBaseURL=%s\n' \
  "${LOCAL_BASE_URL}" "${GATEWAY_BASE_URL}" "${COMMAND_API_BASE_URL}" "${QUERY_API_BASE_URL}" "${PUBLIC_BASE_URL:-<unset>}"

section "Listeners"
if have_cmd ss; then
  run_optional "ss selected ports" bash -c "ss -ltnp | awk 'NR == 1 || /:(${HTTP_PORT}|${GATEWAY_HTTP_PORT}|${COMMAND_API_PORT}|${QUERY_API_PORT}|${TCP_PORT})[[:space:]]/'"
else
  printf 'ss not found\n'
fi

section "TCP Probes"
print_tcp_probe "${LOCAL_HOST}" "${HTTP_PORT}" "local-http"
print_tcp_probe "127.0.0.1" "${GATEWAY_HTTP_PORT}" "gateway-http"
print_tcp_probe "127.0.0.1" "${COMMAND_API_PORT}" "command-api"
print_tcp_probe "127.0.0.1" "${QUERY_API_PORT}" "query-api"
print_tcp_probe "${LOCAL_HOST}" "${TCP_PORT}" "local-tcp"

section "HTTP Probes"
probe_url "local-nginx-health" "GET" "${LOCAL_BASE_URL}/nginx-health"
probe_url "local-health" "GET" "${LOCAL_BASE_URL}/health"
probe_url "local-root" "GET" "${LOCAL_BASE_URL}/"
probe_url "local-auth-login-get" "GET" "${LOCAL_BASE_URL}/api/auth/login"
probe_url "gateway-health" "GET" "${GATEWAY_BASE_URL}/health"
probe_url "command-api-health" "GET" "${COMMAND_API_BASE_URL}/health"
probe_url "query-api-health" "GET" "${QUERY_API_BASE_URL}/health"

if [[ -n "${PUBLIC_BASE_URL}" ]]; then
  section "Public HTTP Probes"
  probe_url "public-nginx-health" "GET" "${PUBLIC_BASE_URL}/nginx-health"
  probe_url "public-health" "GET" "${PUBLIC_BASE_URL}/health"
  probe_url "public-root" "GET" "${PUBLIC_BASE_URL}/"
  probe_url "public-auth-login-get" "GET" "${PUBLIC_BASE_URL}/api/auth/login"

  section "Public Protocol Probes"
  print_public_protocol_probes
fi

section "systemd"
if have_cmd systemctl; then
  run_optional "service states" systemctl --no-pager --plain --type=service --state=running,failed list-units 'imserver-*' nginx postgresql redis-server kafka
  for unit in imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer nginx; do
    if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
      run_optional "status ${unit}" systemctl --no-pager --lines=20 status "${unit}"
    fi
  done
else
  printf 'systemctl not found\n'
fi

section "Recent Logs"
if have_cmd journalctl; then
  run_optional "imserver logs" journalctl -u imserver-gateway -u imserver-command-api -u imserver-query-api -u imserver-outbox-relay -u imserver-stream-consumer -u imserver-domain-delivery-consumer -n "${JOURNAL_LINES}" --no-pager
  run_optional "nginx logs" journalctl -u nginx -n "${JOURNAL_LINES}" --no-pager
else
  printf 'journalctl not found\n'
fi

section "Nginx"
if have_cmd nginx; then
  run_optional "nginx config summary" bash -c "nginx -T 2>/dev/null | awk '/server \\{|listen |server_name |location |proxy_pass |allow |deny / {print}' | head -n 160"
else
  printf 'nginx not found\n'
fi

section "Docker"
if have_cmd docker; then
  run_optional "docker ps" docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  if docker compose version >/dev/null 2>&1; then
    run_optional "docker compose ps" docker compose ps
  fi
else
  printf 'docker not found\n'
fi

section "Firewall"
if have_cmd ufw; then
  run_optional "ufw status" ufw status verbose
fi
if have_cmd nft; then
  run_optional "nft ruleset head" bash -c "nft list ruleset 2>/dev/null | head -n 120"
fi
if have_cmd iptables; then
  run_optional "iptables head" bash -c "iptables -S 2>/dev/null | head -n 120"
fi

section "Diagnosis"
if [[ "${public_edge_intercept}" == "http_403_all_sampled_ports" ]]; then
  printf 'diagnosis=cloud_edge_http_403_intercept detail=Public HTTP and sampled protocol ports all returned empty HTTP 403. Public traffic is intercepted before this IMServer instance; fix cloud security policy, WAF, NAT/public IP routing, or provider edge rules from the cloud console before running deploy or performance tests.\n'
elif [[ "${public_edge_intercept}" == "http_403_multiple_sampled_ports" ]]; then
  printf 'diagnosis=cloud_edge_partial_http_403_intercept detail=Multiple sampled public protocol ports returned empty HTTP 403. TCP connect/open is not valid evidence; inspect cloud security policy, WAF, NAT/public IP routing, or provider edge rules.\n'
elif [[ "${local_nginx_health_status}" == "200" && "${local_health_status}" != "200" ]]; then
  printf 'diagnosis=upstream_entrypoint_unhealthy detail=Nginx health is OK, but /health through gateway is not. Check imserver-gateway health, upstream ports, and Nginx proxy_pass settings.\n'
elif [[ "${local_health_status}" == "200" && -n "${PUBLIC_BASE_URL}" && "${public_nginx_health_status}" == "403" && "${public_nginx_health_body_bytes}" == "0" ]]; then
  printf 'diagnosis=public_listener_not_nginx detail=Local IM health is OK, but public /nginx-health is empty 403. Public traffic is not reaching this Nginx server block; check cloud security policy, WAF, external proxy, NAT, or wrong public IP/port.\n'
elif [[ "${local_health_status}" == "200" && -n "${PUBLIC_BASE_URL}" && "${public_health_status}" == "403" && "${public_health_body_bytes}" == "0" ]]; then
  printf 'diagnosis=public_entrypoint_blocked detail=Local IM health is OK, but public health is empty 403. Check cloud security policy, WAF, external reverse proxy, nginx server block, or allowlist before running performance tests.\n'
elif [[ "${local_health_status}" == "403" && "${local_health_body_bytes}" == "0" && "${local_auth_status}" == "403" && "${local_auth_body_bytes}" == "0" ]]; then
  printf 'diagnosis=local_uniform_empty_403 detail=Local 8080 returns empty 403 for multiple paths. Check nginx access rules, wrong listener process, or an upstream/proxy intercepting requests before the IM API.\n'
elif [[ "${local_health_status}" == "000" || -z "${local_health_status}" ]]; then
  printf 'diagnosis=local_http_unreachable detail=Local HTTP entrypoint did not respond. Check listener on port %s and imserver/nginx service status.\n' "${HTTP_PORT}"
elif [[ "${gateway_health_status}" == "200" && "${local_health_status}" != "200" ]]; then
  printf 'diagnosis=nginx_or_entrypoint_routing detail=Gateway health is reachable directly, but public HTTP entrypoint is not healthy. Check nginx listen/proxy_pass/access rules on port %s.\n' "${HTTP_PORT}"
elif [[ "${local_health_status}" == "200" ]]; then
  printf 'diagnosis=entrypoint_healthy detail=Local HTTP entrypoint is healthy. If external probe still fails, focus on cloud security group, WAF, public listener, or client network path.\n'
else
  printf 'diagnosis=needs_manual_review detail=Health status localNginx=%s local=%s gateway=%s command=%s query=%s publicNginx=%s public=%s. Review sections above for the first failing hop.\n' \
    "${local_nginx_health_status:-<unset>}" \
    "${local_health_status:-<unset>}" \
    "${gateway_health_status:-<unset>}" \
    "${command_health_status:-<unset>}" \
    "${query_health_status:-<unset>}" \
    "${public_nginx_health_status:-<unset>}" \
    "${public_health_status:-<unset>}"
fi
