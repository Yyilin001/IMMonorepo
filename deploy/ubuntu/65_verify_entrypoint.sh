#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-${IM_GATEWAY_HTTP_PORT:-18080}}"
COMMAND_API_PORT="${COMMAND_API_PORT:-${IM_COMMAND_API_PORT:-8081}}"
QUERY_API_PORT="${QUERY_API_PORT:-${IM_QUERY_API_PORT:-8082}}"
TCP_PORT="${TCP_PORT:-9000}"
LOCAL_BASE_URL="${LOCAL_BASE_URL:-http://127.0.0.1:${HTTP_PORT}}"
GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://127.0.0.1:${GATEWAY_HTTP_PORT}}"
COMMAND_API_BASE_URL="${COMMAND_API_BASE_URL:-http://127.0.0.1:${COMMAND_API_PORT}}"
QUERY_API_BASE_URL="${QUERY_API_BASE_URL:-http://127.0.0.1:${QUERY_API_PORT}}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
PUBLIC_PROTOCOL_PORTS="${PUBLIC_PROTOCOL_PORTS:-22 ${HTTP_PORT} ${TCP_PORT}}"
VERIFY_TIMEOUT_SECONDS="${VERIFY_TIMEOUT_SECONDS:-5}"
VERIFY_RETRIES="${VERIFY_RETRIES:-12}"
VERIFY_RETRY_INTERVAL_SECONDS="${VERIFY_RETRY_INTERVAL_SECONDS:-2}"
VERIFY_REQUIRE_PUBLIC="${VERIFY_REQUIRE_PUBLIC:-false}"
VERIFY_ENTRYPOINT_SELF_TEST="${VERIFY_ENTRYPOINT_SELF_TEST:-false}"

failures=0
public_protocol_probe_count=0
public_protocol_http_403_count=0
public_edge_intercept=""

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

run_self_test() {
  local self_test_dir fake_bin ok_log blocked_log
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
    -w|--connect-timeout|--max-time|-m)
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
  ssh-good)
    printf 'SSH-2.0-OpenSSH_9.6\r\n'
    ;;
esac
exit 0
SH
  chmod +x "${fake_bin}/curl" "${fake_bin}/nc"

  ok_log="${self_test_dir}/ok.log"
  if ! PATH="${fake_bin}:${PATH}" \
    VERIFY_ENTRYPOINT_SELF_TEST=false \
    VERIFY_RETRIES=1 \
    VERIFY_RETRY_INTERVAL_SECONDS=0 \
    HTTP_PORT=8080 \
    GATEWAY_HTTP_PORT=18080 \
    COMMAND_API_PORT=8081 \
    QUERY_API_PORT=8082 \
    TCP_PORT=9000 \
    PUBLIC_BASE_URL=http://public-ok:8080 \
      bash "${BASH_SOURCE[0]}" >"${ok_log}" 2>&1; then
    printf 'entrypoint_verify_self_test result=fail reason=ok_case_failed\n' >&2
    cat "${ok_log}" >&2
    rm -rf "${self_test_dir}"
    return 1
  fi
  grep -q 'entrypoint verification passed' "${ok_log}" || {
    printf 'entrypoint_verify_self_test result=fail reason=ok_case_missing_pass\n' >&2
    rm -rf "${self_test_dir}"
    return 1
  }

  blocked_log="${self_test_dir}/blocked.log"
  if PATH="${fake_bin}:${PATH}" \
    VERIFY_ENTRYPOINT_SELF_TEST=false \
    VERIFY_RETRIES=1 \
    VERIFY_RETRY_INTERVAL_SECONDS=0 \
    HTTP_PORT=8080 \
    GATEWAY_HTTP_PORT=18080 \
    COMMAND_API_PORT=8081 \
    QUERY_API_PORT=8082 \
    TCP_PORT=9000 \
    PUBLIC_BASE_URL=http://public-bad:8080 \
      bash "${BASH_SOURCE[0]}" >"${blocked_log}" 2>&1; then
    printf 'entrypoint_verify_self_test result=fail reason=blocked_case_unexpected_pass\n' >&2
    rm -rf "${self_test_dir}"
    return 1
  fi
  grep -q 'reason=cloud_edge_http_403_intercept' "${blocked_log}" || {
    printf 'entrypoint_verify_self_test result=fail reason=blocked_case_missing_cloud_edge_reason\n' >&2
    cat "${blocked_log}" >&2
    rm -rf "${self_test_dir}"
    return 1
  }
  grep -q 'verify=public-protocol-summary sampled=3 http403=3 edgeIntercept=http_403_all_sampled_ports' "${blocked_log}" || {
    printf 'entrypoint_verify_self_test result=fail reason=blocked_case_missing_protocol_summary\n' >&2
    rm -rf "${self_test_dir}"
    return 1
  }

  rm -rf "${self_test_dir}"
  printf 'entrypoint_verify_self_test result=pass\n'
}

http_status_and_size() {
  local url="$1"
  local body_file
  local status
  body_file="$(mktemp)"
  set +e
  status="$(curl -sS -m "${VERIFY_TIMEOUT_SECONDS}" -o "${body_file}" -w '%{http_code}' "${url}" 2>/dev/null)"
  local rc=$?
  set -e
  local size
  size="$(wc -c < "${body_file}" | tr -d ' ')"
  rm -f "${body_file}"
  if [[ "${rc}" != "0" ]]; then
    printf 'curl-error:%s %s\n' "${rc}" "${size:-0}"
    return 0
  fi
  printf '%s %s\n' "${status:-000}" "${size:-0}"
}

require_http_200() {
  local label="$1"
  local url="$2"
  local result status size attempt
  for attempt in $(seq 1 "${VERIFY_RETRIES}"); do
    result="$(http_status_and_size "${url}")"
    status="${result% *}"
    size="${result#* }"
    printf 'verify=%s url=%s attempt=%s/%s status=%s bodyBytes=%s\n' \
      "${label}" "${url}" "${attempt}" "${VERIFY_RETRIES}" "${status}" "${size}"
    if [[ "${status}" == "200" ]]; then
      return 0
    fi
    sleep "${VERIFY_RETRY_INTERVAL_SECONDS}"
  done
  failures=$((failures + 1))
}

require_tcp_open() {
  local label="$1"
  local host="$2"
  local port="$3"
  local rc=0 attempt
  for attempt in $(seq 1 "${VERIFY_RETRIES}"); do
    rc=0
    if command -v nc >/dev/null 2>&1; then
      if nc -z -w "${VERIFY_TIMEOUT_SECONDS}" "${host}" "${port}" >/dev/null 2>&1; then
        printf 'verify=%s host=%s port=%s attempt=%s/%s status=open\n' \
          "${label}" "${host}" "${port}" "${attempt}" "${VERIFY_RETRIES}"
        return 0
      fi
      printf 'verify=%s host=%s port=%s attempt=%s/%s status=closed_or_filtered\n' \
        "${label}" "${host}" "${port}" "${attempt}" "${VERIFY_RETRIES}"
    elif command -v timeout >/dev/null 2>&1; then
      timeout "${VERIFY_TIMEOUT_SECONDS}" bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1 || rc=$?
      if [[ "${rc}" == "0" ]]; then
        printf 'verify=%s host=%s port=%s attempt=%s/%s status=open method=dev-tcp\n' \
          "${label}" "${host}" "${port}" "${attempt}" "${VERIFY_RETRIES}"
        return 0
      fi
      printf 'verify=%s host=%s port=%s attempt=%s/%s status=closed_or_filtered method=dev-tcp\n' \
        "${label}" "${host}" "${port}" "${attempt}" "${VERIFY_RETRIES}"
    else
      printf 'verify=%s host=%s port=%s status=failed reason=no_nc_or_timeout\n' "${label}" "${host}" "${port}"
      failures=$((failures + 1))
      return 0
    fi
    sleep "${VERIFY_RETRY_INTERVAL_SECONDS}"
  done
  failures=$((failures + 1))
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
  raw="$(printf '' | nc -w "${VERIFY_TIMEOUT_SECONDS}" "${host}" "${port}" 2>/dev/null | LC_ALL=C head -c 160 || true)"
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

probe_public_protocols() {
  local host port protocol seen_ports=""
  if [[ -z "${PUBLIC_BASE_URL}" ]]; then
    return 0
  fi
  host="$(url_host "${PUBLIC_BASE_URL}")"
  if [[ -z "${host}" ]]; then
    printf 'verify=public-protocol status=skipped_missing_host publicBaseURL=%s\n' "${PUBLIC_BASE_URL}"
    return 0
  fi
  for port in ${PUBLIC_PROTOCOL_PORTS}; do
    if [[ -z "${port}" || " ${seen_ports} " == *" ${port} "* ]]; then
      continue
    fi
    seen_ports="${seen_ports} ${port}"
    protocol="$(probe_port_protocol "${host}" "${port}")"
    printf 'verify=public-protocol host=%s port=%s protocol=%s\n' "${host}" "${port}" "${protocol}"
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
  printf 'verify=public-protocol-summary sampled=%s http403=%s edgeIntercept=%s\n' \
    "${public_protocol_probe_count}" \
    "${public_protocol_http_403_count}" \
    "${public_edge_intercept:-<none>}"
}

if bool_enabled "${VERIFY_ENTRYPOINT_SELF_TEST}"; then
  run_self_test
  exit 0
fi

printf 'IMServer entrypoint verification\n'
printf 'localBaseURL=%s gatewayBaseURL=%s commandAPIBaseURL=%s queryAPIBaseURL=%s publicBaseURL=%s\n' \
  "${LOCAL_BASE_URL}" \
  "${GATEWAY_BASE_URL}" \
  "${COMMAND_API_BASE_URL}" \
  "${QUERY_API_BASE_URL}" \
  "${PUBLIC_BASE_URL:-<unset>}"

require_tcp_open "public-http-listener" "127.0.0.1" "${HTTP_PORT}"
require_tcp_open "gateway-http-listener" "127.0.0.1" "${GATEWAY_HTTP_PORT}"
require_tcp_open "command-api-listener" "127.0.0.1" "${COMMAND_API_PORT}"
require_tcp_open "query-api-listener" "127.0.0.1" "${QUERY_API_PORT}"
require_tcp_open "tcp-gateway-listener" "127.0.0.1" "${TCP_PORT}"

require_http_200 "nginx-health" "${LOCAL_BASE_URL}/nginx-health"
require_http_200 "entrypoint-health" "${LOCAL_BASE_URL}/health"
require_http_200 "gateway-health" "${GATEWAY_BASE_URL}/health"
require_http_200 "command-api-health" "${COMMAND_API_BASE_URL}/health"
require_http_200 "query-api-health" "${QUERY_API_BASE_URL}/health"

if [[ -n "${PUBLIC_BASE_URL}" ]]; then
  probe_public_protocols
  require_http_200 "public-nginx-health" "${PUBLIC_BASE_URL%/}/nginx-health"
  require_http_200 "public-health" "${PUBLIC_BASE_URL%/}/health"
elif bool_enabled "${VERIFY_REQUIRE_PUBLIC}"; then
  printf 'verify=public-health status=missing_public_base_url\n'
  failures=$((failures + 1))
fi

if [[ "${failures}" != "0" ]]; then
  printf 'entrypoint verification failed failures=%s\n' "${failures}" >&2
  if [[ "${public_edge_intercept}" == "http_403_all_sampled_ports" ]]; then
    printf 'entrypoint verification failed reason=cloud_edge_http_403_intercept detail=Public HTTP and sampled protocol ports all returned empty HTTP 403. Fix cloud security policy, WAF, NAT/public IP routing, or provider edge rules before running deploy or performance tests.\n' >&2
  elif [[ "${public_edge_intercept}" == "http_403_multiple_sampled_ports" ]]; then
    printf 'entrypoint verification failed reason=cloud_edge_partial_http_403_intercept detail=Multiple sampled public protocol ports returned empty HTTP 403. TCP connect/open is not valid IM evidence.\n' >&2
  fi
  printf 'Run diagnosis:\n' >&2
  printf '  sudo HTTP_PORT=%s PUBLIC_BASE_URL=%s bash deploy/ubuntu/75_entrypoint_diagnose.sh\n' \
    "${HTTP_PORT}" \
    "${PUBLIC_BASE_URL:-http://<server-public-ip>:${HTTP_PORT}}" >&2
  exit 1
fi

printf 'entrypoint verification passed\n'
