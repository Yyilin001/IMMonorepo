#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-${PUBLIC_BASE_URL:-${IM_PUBLIC_BASE_URL:-http://127.0.0.1:8080}}}"
ACCOUNT_FILE="${ACCOUNT_FILE:-${IM_ACCOUNT_FILE:-}}"
IM_EMAIL="${IM_EMAIL:-demo@example.com}"
IM_PASSWORD="${IM_PASSWORD:-password1234}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-10}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-5}"
PROBE_PATHS="${PROBE_PATHS:-/nginx-health / /health /api/auth/login /api/me}"
PROBE_FAIL_ON_ENTRYPOINT_ERROR="${PROBE_FAIL_ON_ENTRYPOINT_ERROR:-false}"
PROBE_TCP="${PROBE_TCP:-true}"
PROBE_PROTOCOL_PORTS="${PROBE_PROTOCOL_PORTS:-22 9000}"
PROBE_ADDITIONAL_PROTOCOL_HOSTS="${PROBE_ADDITIONAL_PROTOCOL_HOSTS:-${PROBE_ADDITIONAL_HOSTS:-}}"
PROBE_REQUIRE_PUBLIC_PORT_POLICY="${PROBE_REQUIRE_PUBLIC_PORT_POLICY:-false}"
PROBE_PUBLIC_EXPECT_OPEN_PORTS="${PROBE_PUBLIC_EXPECT_OPEN_PORTS:-80 443 9000}"
PROBE_PUBLIC_DENY_PORTS="${PROBE_PUBLIC_DENY_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
PROBE_PUBLIC_PORT_POLICY_ALLOW_LOCAL_PROXY="${PROBE_PUBLIC_PORT_POLICY_ALLOW_LOCAL_PROXY:-false}"
PROBE_LOCAL_NETWORK_CHECK="${PROBE_LOCAL_NETWORK_CHECK:-true}"
PROBE_FAIL_ON_LOCAL_NETWORK="${PROBE_FAIL_ON_LOCAL_NETWORK:-false}"
PROBE_JSON_OUTPUT="${PROBE_JSON_OUTPUT:-}"
PROBE_REDACTION_SELF_TEST="${PROBE_REDACTION_SELF_TEST:-false}"
PROBE_PROTOCOL_HOSTS_SELF_TEST="${PROBE_PROTOCOL_HOSTS_SELF_TEST:-false}"

usage() {
  cat <<'EOF'
Usage:
  BASE_URL=http://host:8080 ACCOUNT_FILE=accounts/load-1000.csv ./http_entrypoint_probe.sh

Env:
  BASE_URL=http://127.0.0.1:8080
  PUBLIC_BASE_URL=http://host:8080
  IM_PUBLIC_BASE_URL=http://host:8080
  ACCOUNT_FILE=/path/email-password.csv
  IM_EMAIL=demo@example.com
  IM_PASSWORD=password1234
  PROBE_PATHS="/nginx-health / /health /api/auth/login /api/me"
  CONNECT_TIMEOUT_SECONDS=5
  REQUEST_TIMEOUT_SECONDS=10
  PROBE_FAIL_ON_ENTRYPOINT_ERROR=true|false
  PROBE_TCP=true|false
  PROBE_PROTOCOL_PORTS="22 9000"
  PROBE_ADDITIONAL_PROTOCOL_HOSTS="tcp-host-1 tcp-host-2"
  PROBE_REQUIRE_PUBLIC_PORT_POLICY=false
  PROBE_PUBLIC_EXPECT_OPEN_PORTS="80 443 9000"
  PROBE_PUBLIC_DENY_PORTS="3389 5432 6379 9092 8081 8082 18080 8080"
  PROBE_PUBLIC_PORT_POLICY_ALLOW_LOCAL_PROXY=false
  PROBE_LOCAL_NETWORK_CHECK=true|false
  PROBE_FAIL_ON_LOCAL_NETWORK=false|true
  PROBE_JSON_OUTPUT=/path/probe.json
  PROBE_REDACTION_SELF_TEST=true|false
  PROBE_PROTOCOL_HOSTS_SELF_TEST=true|false

The script prints compact HTTP probes and performs one login POST using the same
nested `device` payload shape as the k6/TCP load-test clients. It also prints a
single diagnosis line that classifies common entrypoint failures. Successful
login response bodies are never printed because they can contain tokens.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

first_account_email() {
  if [[ -n "${ACCOUNT_FILE}" && -f "${ACCOUNT_FILE}" ]]; then
    awk -F',' 'NF >= 2 && $1 !~ /^#/ { print $1; exit }' "${ACCOUNT_FILE}"
  else
    printf '%s\n' "${IM_EMAIL}"
  fi
}

first_account_password() {
  if [[ -n "${ACCOUNT_FILE}" && -f "${ACCOUNT_FILE}" ]]; then
    awk -F',' 'NF >= 2 && $1 !~ /^#/ { print $2; exit }' "${ACCOUNT_FILE}"
  else
    printf '%s\n' "${IM_PASSWORD}"
  fi
}

mask_account() {
  python3 - "$1" <<'PY'
import hashlib
import sys

value = sys.argv[1]
if "@" not in value:
    print(f"sha256:{hashlib.sha256(value.encode()).hexdigest()[:12]}")
    raise SystemExit(0)
local, domain = value.rsplit("@", 1)
if not local:
    masked = "***"
elif len(local) <= 2:
    masked = local[0] + "***"
else:
    masked = local[:2] + "***" + local[-1:]
print(f"{masked}@{domain}")
PY
}

sanitize_header_value() {
  python3 - "$1" <<'PY'
import re
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

value = sys.argv[1]
if not value or value == "<none>":
    print(value or "<none>")
    raise SystemExit(0)

sensitive = re.compile(r"(token|secret|password|authorization|access[_-]?key|jwt)", re.I)

try:
    parts = urlsplit(value)
except Exception:
    parts = None

if parts and parts.query:
    query = []
    for key, item in parse_qsl(parts.query, keep_blank_values=True):
        query.append((key, "<redacted>" if sensitive.search(key) else item))
    value = urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))

value = re.sub(
    r"((?:accessToken|refreshToken|token|password|secret|jwt|authorization|access[_-]?key)=)[^&\s]+",
    r"\1<redacted>",
    value,
    flags=re.I,
)
value = re.sub(
    r"(Authorization:\s*(?:Bearer|Basic)\s+)[A-Za-z0-9._~+/=-]+",
    r"\1<redacted>",
    value,
    flags=re.I,
)
print(value[:240])
PY
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/im-http-entrypoint-probe.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

probe_total=0
probe_403=0
probe_empty_403=0
probe_health_status=""
probe_nginx_health_status=""
probe_nginx_health_body_bytes=0
probe_login_status=""
probe_login_body_bytes=0
probe_curl_errors=0
probe_server_hint=""
probe_via_hint=""
probe_tcp_status=""
probe_edge_intercept=""
probe_additional_protocol_hosts=""
probe_public_port_policy_status=""
probe_public_ports_open=""
probe_public_ports_closed=""
probe_public_expected_ports_missing=""
probe_public_denied_ports_open=""
probe_local_network_warning=""
probe_local_route_interface=""
probe_local_route_gateway=""
probe_local_proxy_env_names=""

header_value() {
  local name="$1"
  local file="$2"
  awk -v target="${name}" '
    BEGIN { IGNORECASE = 1 }
    index($0, target ":") == 1 {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/\r$/, "")
      print
      exit
    }
  ' "${file}"
}

remember_header_hints() {
  local headers_file="$1"
  local server via
  server="$(header_value "server" "${headers_file}")"
  via="$(header_value "via" "${headers_file}")"
  if [[ -z "${probe_server_hint}" && -n "${server}" ]]; then
    probe_server_hint="${server}"
  fi
  if [[ -z "${probe_via_hint}" && -n "${via}" ]]; then
    probe_via_hint="${via}"
  fi
}

summarize_response_body() {
  local status="$1"
  local body_file="$2"
  python3 - "${status}" "${body_file}" <<'PY'
import json
import pathlib
import re
import sys

status, body_path = sys.argv[1:3]
text = pathlib.Path(body_path).read_text(errors="replace")
if not text.strip():
    print("<empty>")
    raise SystemExit(0)
if status.startswith("2"):
    print("<redacted_success_body>")
    raise SystemExit(0)

sensitive_key = re.compile(r"(token|secret|password|authorization|access[_-]?key|jwt)", re.I)

def redact_json(value):
    if isinstance(value, dict):
        return {
            key: "<redacted>" if sensitive_key.search(str(key)) else redact_json(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact_json(item) for item in value]
    return value

try:
    payload = json.loads(text)
except Exception:
    compact = re.sub(r"\s+", " ", text).strip()
    compact = re.sub(
        r'((accessToken|refreshToken|token|password|secret|secrets|jwtSecrets|authorization|access[_-]?key)["\']?\s*[:=]\s*["\']?)[^"\'\s,}]+',
        r"\1<redacted>",
        compact,
        flags=re.I,
    )
    compact = re.sub(
        r"(Authorization:\s*(Bearer|Basic)\s+)[A-Za-z0-9._~+/=-]+",
        r"\1<redacted>",
        compact,
        flags=re.I,
    )
else:
    compact = json.dumps(redact_json(payload), ensure_ascii=False, separators=(",", ":"))
print(compact[:240] if compact else "<empty>")
PY
}

run_redaction_self_test() {
  local sample_file output success_output account_output header_output
  sample_file="${tmp_dir}/redaction-sample.json"
  cat >"${sample_file}" <<'JSON'
{"accessToken":"access-token-value","refreshToken":"refresh-token-value","nested":{"password":"password-value","secret":"secret-value"},"message":"bad request"}
JSON
  output="$(summarize_response_body 400 "${sample_file}")"
  success_output="$(summarize_response_body 200 "${sample_file}")"
  account_output="$(mask_account "load-00001@example.com")"
  header_output="$(sanitize_header_value "https://example.com/callback?accessToken=access-token-value&next=/ok")"
  for forbidden in access-token-value refresh-token-value password-value secret-value; do
    if grep -q "${forbidden}" <<<"${output}${success_output}${header_output}"; then
      printf 'entrypoint probe redaction self-test result=fail leaked=%s\n' "${forbidden}" >&2
      return 1
    fi
  done
  if grep -q "load-00001@example.com" <<<"${account_output}" || grep -q "load-00001" <<<"${account_output}"; then
    printf 'entrypoint probe redaction self-test result=fail reason=account_not_masked output=%s\n' "${account_output}" >&2
    return 1
  fi
  if ! grep -q 'bad request' <<<"${output}"; then
    printf 'entrypoint probe redaction self-test result=fail reason=non_secret_message_missing\n' >&2
    return 1
  fi
  if [[ "${success_output}" != "<redacted_success_body>" ]]; then
    printf 'entrypoint probe redaction self-test result=fail reason=success_body_not_redacted\n' >&2
    return 1
  fi
  printf 'entrypoint probe redaction self-test result=pass\n'
}

run_protocol_hosts_self_test() {
  local fake_bin old_path output_json
  fake_bin="${tmp_dir}/fake-bin"
  output_json="${tmp_dir}/protocol-hosts.json"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/nc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
host="${@: -2:1}"
port="${@: -1}"
case "${host}:${port}" in
  api.example.test:80|api.example.test:3389)
    if [[ "${1:-}" == "-z" ]]; then
      exit 0
    fi
    ;;
  api.example.test:8080)
    printf 'HTTP/1.1 403 Forbidden\r\n\r\n'
    ;;
  tcp.example.test:9000)
    printf 'SSH-2.0-self-test\r\n'
    ;;
  *)
    ;;
esac
SH
  cat >"${fake_bin}/route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'OUT'
   route to: api.example.test
destination: api.example.test
    gateway: 198.18.0.1
  interface: utun99
OUT
SH
  chmod +x "${fake_bin}/nc"
  chmod +x "${fake_bin}/route"
  old_path="${PATH}"
  PATH="${fake_bin}:${PATH}"
  BASE_URL="http://api.example.test:8080"
  PROBE_PROTOCOL_PORTS="9000"
  PROBE_ADDITIONAL_PROTOCOL_HOSTS="tcp.example.test"
  PROBE_REQUIRE_PUBLIC_PORT_POLICY=true
  PROBE_PUBLIC_EXPECT_OPEN_PORTS="80"
  PROBE_PUBLIC_DENY_PORTS="3389"
  PROBE_PUBLIC_PORT_POLICY_ALLOW_LOCAL_PROXY=true
  PROBE_JSON_OUTPUT="${output_json}"
  probe_tcp_status=""
  probe_edge_intercept=""
  probe_additional_protocol_hosts=""
  probe_local_network_warning=""
  probe_local_route_interface=""
  probe_local_route_gateway=""
  probe_local_proxy_env_names=""
  detect_local_network_path >"${tmp_dir}/protocol-hosts-local-network.log"
  tcp_probe >"${tmp_dir}/protocol-hosts.log"
  public_port_policy_probe >"${tmp_dir}/protocol-hosts-port-policy.log"
  probe_login_status="200"
  write_probe_json "public_denied_ports_open" "self-test denied port open" "true"
  PROBE_JSON_OUTPUT="${tmp_dir}/protocol-hosts-failed.json"
  write_probe_json "cloud_edge_http_403_intercept" "self-test failed" "true"
  PROBE_JSON_OUTPUT="${tmp_dir}/protocol-hosts-local-network.json"
  write_probe_json "local_network_proxy_http_403_intercept" "self-test local network failed" "true"
  PATH="${old_path}"
  python3 - "${output_json}" "${tmp_dir}/protocol-hosts-failed.json" "${tmp_dir}/protocol-hosts-local-network.json" "${tmp_dir}/protocol-hosts.log" "${tmp_dir}/protocol-hosts-local-network.log" "${tmp_dir}/protocol-hosts-port-policy.log" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
failed_payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
local_payload = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
log = Path(sys.argv[4]).read_text(encoding="utf-8")
local_log = Path(sys.argv[5]).read_text(encoding="utf-8")
signals = payload.get("signals") or {}
hosts = signals.get("additionalProtocolHosts") or []
ports = signals.get("portProtocols") or []
blocker = payload.get("blocker") or {}
failed_blocker = failed_payload.get("blocker") or {}
local_blocker = local_payload.get("blocker") or {}
if payload.get("tcpStatus") != signals.get("tcpStatus"):
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=top_level_tcp_status_mismatch")
if payload.get("edgeIntercept") != signals.get("edgeIntercept"):
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=top_level_edge_intercept_mismatch")
if payload.get("additionalProtocolHosts") != hosts:
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=top_level_hosts_mismatch")
if payload.get("portProtocols") != ports:
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=top_level_ports_mismatch")
if hosts != ["tcp.example.test"]:
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=hosts_mismatch hosts={hosts}")
if not any(row.get("label") == "base-http:api.example.test" and row.get("protocol") == "http_403_intercepted" for row in ports):
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=base_host_protocol_missing")
if not any(row.get("label") == "extra-tcp.example.test-port-9000" and row.get("protocol") == "ssh_banner" for row in ports):
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=extra_host_protocol_missing ports={ports}")
if blocker.get("preventsPerformanceEvidence"):
    if blocker.get("action") != "repair_cloud_security_group":
        raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=port_policy_blocker_action_invalid blocker={blocker}")
if signals.get("publicPortPolicyStatus") != "denied_ports_open":
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=public_port_policy_status_missing payload={payload}")
if signals.get("publicDeniedPortsOpen") != ["3389"]:
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=public_denied_ports_open_missing payload={payload}")
if "Public port policy host=api.example.test port=3389 status=open expected=closed" not in Path(sys.argv[6]).read_text(encoding="utf-8"):
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=public_port_policy_log_missing")
if failed_blocker.get("type") != "entrypoint" or failed_blocker.get("severity") != "P0":
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=failed_blocker_invalid blocker={failed_blocker}")
if failed_blocker.get("action") != "cloud_console_rescue_required":
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=failed_blocker_action_invalid blocker={failed_blocker}")
if failed_blocker.get("preventsPerformanceEvidence") is not True:
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=failed_blocker_not_preventing_performance")
if "Protocol probe host=tcp.example.test port=9000 protocol=ssh_banner" not in log:
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=extra_host_log_missing")
if local_payload.get("localNetworkWarning") != "tun_route":
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=local_warning_missing payload={local_payload}")
if local_payload.get("localRouteInterface") != "utun99" or local_payload.get("localRouteGateway") != "198.18.0.1":
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=local_route_missing payload={local_payload}")
if local_blocker.get("action") != "disable_local_proxy_or_test_from_clean_network":
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=local_blocker_action_invalid blocker={local_blocker}")
if "Local network warning=tun_route" not in local_log:
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=local_network_log_missing")
PY
  probe_public_port_policy_status=""
  probe_login_status="200"
  probe_login_body_bytes=32
  probe_nginx_health_status="200"
  probe_nginx_health_body_bytes=2
  probe_health_status="200"
  probe_tcp_status="open"
  probe_edge_intercept=""
  probe_local_network_warning="tun_route"
  probe_local_route_interface="utun99"
  probe_local_route_gateway="198.18.0.1"
  PROBE_FAIL_ON_LOCAL_NETWORK=true
  PROBE_JSON_OUTPUT="${tmp_dir}/strict-local-network.json"
  diagnose_probe >"${tmp_dir}/strict-local-network.log"
  python3 - "${tmp_dir}/strict-local-network.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
blocker = payload.get("blocker") or {}
if payload.get("diagnosis") != "local_operator_network_blocked":
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=strict_local_network_diagnosis_invalid payload={payload}")
if payload.get("failed") is not True:
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=strict_local_network_not_failed")
if blocker.get("action") != "disable_local_proxy_or_test_from_clean_network":
    raise SystemExit(f"entrypoint probe protocol-hosts self-test result=fail reason=strict_local_network_blocker_invalid blocker={blocker}")
if payload.get("signals", {}).get("localRouteInterface") != "utun99":
    raise SystemExit("entrypoint probe protocol-hosts self-test result=fail reason=strict_local_network_route_missing")
PY
  printf 'entrypoint probe protocol-hosts self-test result=pass\n'
}

base_url_host() {
  python3 - "${BASE_URL}" <<'PY'
from urllib.parse import urlparse
import sys

print(urlparse(sys.argv[1]).hostname or "")
PY
}

detect_local_network_path() {
  if ! bool_enabled "${PROBE_LOCAL_NETWORK_CHECK}"; then
    return 0
  fi

  local host route_output proxy_names
  host="$(base_url_host)"
  if [[ -z "${host}" ]]; then
    return 0
  fi

  proxy_names="$(
    env | awk -F= '
      BEGIN { count = 0 }
      tolower($1) ~ /^(http|https|all)_proxy$/ {
        if (count > 0) {
          printf " "
        }
        printf "%s", $1
        count += 1
      }
    '
  )"
  probe_local_proxy_env_names="${proxy_names}"

  route_output=""
  if command -v route >/dev/null 2>&1; then
    route_output="$(route -n get "${host}" 2>/dev/null || true)"
    if [[ -n "${route_output}" ]]; then
      probe_local_route_gateway="$(awk -F: '/gateway:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' <<<"${route_output}")"
      probe_local_route_interface="$(awk -F: '/interface:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' <<<"${route_output}")"
    fi
  fi
  if [[ -z "${route_output}" && -z "${probe_local_route_interface}" ]] && command -v ip >/dev/null 2>&1; then
    route_output="$(ip route get "${host}" 2>/dev/null | head -n 1 || true)"
    if [[ -n "${route_output}" ]]; then
      probe_local_route_gateway="$(awk '{ for (i = 1; i <= NF; i += 1) if ($i == "via") { print $(i + 1); exit } }' <<<"${route_output}")"
      probe_local_route_interface="$(awk '{ for (i = 1; i <= NF; i += 1) if ($i == "dev") { print $(i + 1); exit } }' <<<"${route_output}")"
    fi
  fi

  if [[ -n "${probe_local_route_interface}" && "${probe_local_route_interface}" =~ ^(utun|tun|tap|ppp|wg|tailscale) ]]; then
    probe_local_network_warning="tun_route"
  elif [[ -n "${probe_local_route_gateway}" && "${probe_local_route_gateway}" =~ ^198\.(18|19)\. ]]; then
    probe_local_network_warning="reserved_proxy_gateway"
  elif [[ -n "${probe_local_proxy_env_names}" ]]; then
    probe_local_network_warning="proxy_env"
  fi

  if [[ -n "${probe_local_network_warning}" ]]; then
    printf 'Local network warning=%s routeInterface=%s routeGateway=%s proxyEnv=%s\n' \
      "${probe_local_network_warning}" \
      "${probe_local_route_interface:-<none>}" \
      "${probe_local_route_gateway:-<none>}" \
      "${probe_local_proxy_env_names:-<none>}"
  fi
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
  raw="$(printf '' | nc -w "${CONNECT_TIMEOUT_SECONDS}" "${host}" "${port}" 2>/dev/null | LC_ALL=C head -c 160 || true)"
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

tcp_probe() {
  if ! bool_enabled "${PROBE_TCP}"; then
    return 0
  fi
  local parsed host port rc=0 base_protocol protocol_port protocol checked_protocols http_403_protocols extra_host label
  parsed="$(
    python3 - "${BASE_URL}" <<'PY'
from urllib.parse import urlparse
import sys
url = urlparse(sys.argv[1])
host = url.hostname or ""
port = url.port or (443 if url.scheme == "https" else 80)
print(f"{host} {port}")
PY
  )"
  host="${parsed% *}"
  port="${parsed#* }"
  if [[ -z "${host}" || -z "${port}" ]]; then
    probe_tcp_status="parse_failed"
    printf 'TCP probe host=%s port=%s status=parse_failed\n' "${host:-<none>}" "${port:-<none>}"
    return 0
  fi
  : >"${tmp_dir}/port-protocols.tsv"
  base_protocol="$(probe_port_protocol "${host}" "${port}")"
  printf 'base-http:%s\t%s\t%s\n' "${host}" "${port}" "${base_protocol}" >>"${tmp_dir}/port-protocols.tsv"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w "${CONNECT_TIMEOUT_SECONDS}" "${host}" "${port}" >/dev/null 2>&1 || rc=$?
    if [[ "${base_protocol}" == "http_403_intercepted" || "${base_protocol}" == "http_intercepted" ]]; then
      probe_tcp_status="${base_protocol}"
    elif [[ "${rc}" == "0" ]]; then
      probe_tcp_status="open"
    else
      probe_tcp_status="closed_or_filtered"
    fi
    printf 'TCP probe host=%s port=%s status=%s protocol=%s\n' "${host}" "${port}" "${probe_tcp_status}" "${base_protocol}"
  else
    probe_tcp_status="skipped_nc_missing"
    printf 'TCP probe host=%s port=%s status=skipped_nc_missing\n' "${host}" "${port}"
  fi

  for protocol_port in ${PROBE_PROTOCOL_PORTS}; do
    if [[ "${protocol_port}" == "${port}" ]]; then
      continue
    fi
    protocol="$(probe_port_protocol "${host}" "${protocol_port}")"
    printf 'port-%s:%s\t%s\t%s\n' "${protocol_port}" "${host}" "${protocol_port}" "${protocol}" >>"${tmp_dir}/port-protocols.tsv"
    printf 'Protocol probe host=%s port=%s protocol=%s\n' "${host}" "${protocol_port}" "${protocol}"
  done

  for extra_host in ${PROBE_ADDITIONAL_PROTOCOL_HOSTS}; do
    if [[ -z "${extra_host}" || "${extra_host}" == "${host}" ]]; then
      continue
    fi
    probe_additional_protocol_hosts="${probe_additional_protocol_hosts}${probe_additional_protocol_hosts:+ }${extra_host}"
    for protocol_port in ${PROBE_PROTOCOL_PORTS}; do
      label="$(printf '%s' "${extra_host}" | tr -c 'A-Za-z0-9_.-' '-')"
      protocol="$(probe_port_protocol "${extra_host}" "${protocol_port}")"
      printf 'extra-%s-port-%s\t%s\t%s\n' "${label}" "${protocol_port}" "${protocol_port}" "${protocol}" >>"${tmp_dir}/port-protocols.tsv"
      printf 'Protocol probe host=%s port=%s protocol=%s\n' "${extra_host}" "${protocol_port}" "${protocol}"
    done
  done

  checked_protocols="$(awk 'NF >= 3 { count += 1 } END { print count + 0 }' "${tmp_dir}/port-protocols.tsv")"
  http_403_protocols="$(awk 'NF >= 3 && $3 == "http_403_intercepted" { count += 1 } END { print count + 0 }' "${tmp_dir}/port-protocols.tsv")"
  if (( checked_protocols >= 2 && checked_protocols == http_403_protocols )); then
    probe_edge_intercept="http_403_all_sampled_ports"
  elif (( http_403_protocols >= 2 )); then
    probe_edge_intercept="http_403_multiple_sampled_ports"
  fi
}

public_port_open() {
  local host="$1"
  local port="$2"
  command -v nc >/dev/null 2>&1 || return 2
  nc -z -w "${CONNECT_TIMEOUT_SECONDS}" "${host}" "${port}" >/dev/null 2>&1
}

public_port_policy_probe() {
  if ! bool_enabled "${PROBE_REQUIRE_PUBLIC_PORT_POLICY}"; then
    return 0
  fi

  local host port open_rc expected_missing=0 denied_open=0
  if [[ -n "${probe_local_network_warning}" ]] && ! bool_enabled "${PROBE_PUBLIC_PORT_POLICY_ALLOW_LOCAL_PROXY}"; then
    probe_public_port_policy_status="blocked_by_local_network"
    printf 'Public port policy status=blocked_by_local_network localNetworkWarning=%s action=rerun_from_clean_network_or_set_PROBE_PUBLIC_PORT_POLICY_ALLOW_LOCAL_PROXY\n' \
      "${probe_local_network_warning}"
    return 0
  fi

  host="$(base_url_host)"
  if [[ -z "${host}" ]]; then
    probe_public_port_policy_status="parse_failed"
    printf 'Public port policy host=<none> status=parse_failed\n'
    return 0
  fi
  if ! command -v nc >/dev/null 2>&1; then
    probe_public_port_policy_status="skipped_nc_missing"
    printf 'Public port policy host=%s status=skipped_nc_missing\n' "${host}"
    return 0
  fi

  for port in ${PROBE_PUBLIC_EXPECT_OPEN_PORTS}; do
    [[ -n "${port}" ]] || continue
    open_rc=0
    public_port_open "${host}" "${port}" || open_rc=$?
    if [[ "${open_rc}" == "0" ]]; then
      probe_public_ports_open="${probe_public_ports_open}${probe_public_ports_open:+ }${port}"
      printf 'Public port policy host=%s port=%s status=open expected=open\n' "${host}" "${port}"
    else
      expected_missing=$((expected_missing + 1))
      probe_public_ports_closed="${probe_public_ports_closed}${probe_public_ports_closed:+ }${port}"
      probe_public_expected_ports_missing="${probe_public_expected_ports_missing}${probe_public_expected_ports_missing:+ }${port}"
      printf 'Public port policy host=%s port=%s status=closed_or_filtered expected=open\n' "${host}" "${port}"
    fi
  done

  for port in ${PROBE_PUBLIC_DENY_PORTS}; do
    [[ -n "${port}" ]] || continue
    open_rc=0
    public_port_open "${host}" "${port}" || open_rc=$?
    if [[ "${open_rc}" == "0" ]]; then
      denied_open=$((denied_open + 1))
      probe_public_ports_open="${probe_public_ports_open}${probe_public_ports_open:+ }${port}"
      probe_public_denied_ports_open="${probe_public_denied_ports_open}${probe_public_denied_ports_open:+ }${port}"
      printf 'Public port policy host=%s port=%s status=open expected=closed\n' "${host}" "${port}"
    else
      probe_public_ports_closed="${probe_public_ports_closed}${probe_public_ports_closed:+ }${port}"
      printf 'Public port policy host=%s port=%s status=closed_or_filtered expected=closed\n' "${host}" "${port}"
    fi
  done

  if (( denied_open > 0 )); then
    probe_public_port_policy_status="denied_ports_open"
  elif (( expected_missing > 0 )); then
    probe_public_port_policy_status="expected_ports_missing"
  else
    probe_public_port_policy_status="pass"
  fi
}

probe_get() {
  local endpoint="$1"
  local body_file="${tmp_dir}/get-${endpoint//\//_}.body"
  local headers_file="${tmp_dir}/get-${endpoint//\//_}.headers"
  local rc=0 status size cache_control server via content_type location request_id
  : >"${body_file}"
  : >"${headers_file}"
  status="$(
    curl -sS \
      --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" \
      --max-time "${REQUEST_TIMEOUT_SECONDS}" \
      -D "${headers_file}" \
      -o "${body_file}" \
      -w '%{http_code}' \
      "${BASE_URL%/}${endpoint}"
  )" || rc=$?
  size="$(wc -c <"${body_file}" 2>/dev/null | tr -d ' ' || printf '0')"
  cache_control="$(header_value "cache-control" "${headers_file}")"
  server="$(header_value "server" "${headers_file}")"
  via="$(header_value "via" "${headers_file}")"
  content_type="$(header_value "content-type" "${headers_file}")"
  location="$(sanitize_header_value "$(header_value "location" "${headers_file}")")"
  request_id="$(header_value "x-request-id" "${headers_file}")"
  remember_header_hints "${headers_file}"
  printf 'GET %s status=%s curlExit=%s bodyBytes=%s contentType=%s cacheControl=%s server=%s via=%s location=%s requestID=%s\n' \
    "${endpoint}" \
    "${status:-curl-error-${rc}}" \
    "${rc}" \
    "${size:-0}" \
    "${content_type:-<none>}" \
    "${cache_control:-<none>}" \
    "${server:-<none>}" \
    "${via:-<none>}" \
    "${location:-<none>}" \
    "${request_id:-<none>}"
  probe_total=$((probe_total + 1))
  if [[ "${rc}" != "0" ]]; then
    probe_curl_errors=$((probe_curl_errors + 1))
  fi
  if [[ "${status}" == "403" ]]; then
    probe_403=$((probe_403 + 1))
    if [[ "${size:-0}" == "0" ]]; then
      probe_empty_403=$((probe_empty_403 + 1))
    fi
  fi
  if [[ "${endpoint}" == "/health" ]]; then
    probe_health_status="${status:-curl-error-${rc}}"
  fi
  if [[ "${endpoint}" == "/nginx-health" ]]; then
    probe_nginx_health_status="${status:-curl-error-${rc}}"
    probe_nginx_health_body_bytes="${size:-0}"
  fi
}

probe_login() {
  local email masked_email password payload_file body_file headers_file rc=0 status size cache_control server via content_type location request_id body_summary
  email="$(first_account_email)"
  masked_email="$(mask_account "${email}")"
  password="$(first_account_password)"
  payload_file="${tmp_dir}/login-payload.json"
  body_file="${tmp_dir}/login.body"
  headers_file="${tmp_dir}/login.headers"
  : >"${body_file}"
  : >"${headers_file}"
  python3 - "${email}" "${password}" >"${payload_file}" <<'PY'
import json
import sys

email, password = sys.argv[1:3]
print(json.dumps({
    "email": email,
    "password": password,
    "device": {
        "deviceID": "http-entrypoint-probe",
        "deviceName": "http-entrypoint-probe",
        "platform": "load-test",
        "appVersion": "load-test",
    },
}, separators=(",", ":")))
PY
  status="$(
    curl -sS \
      --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" \
      --max-time "${REQUEST_TIMEOUT_SECONDS}" \
      -D "${headers_file}" \
      -o "${body_file}" \
      -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data-binary "@${payload_file}" \
      "${BASE_URL%/}/api/auth/login"
  )" || rc=$?
  size="$(wc -c <"${body_file}" 2>/dev/null | tr -d ' ' || printf '0')"
  cache_control="$(header_value "cache-control" "${headers_file}")"
  server="$(header_value "server" "${headers_file}")"
  via="$(header_value "via" "${headers_file}")"
  content_type="$(header_value "content-type" "${headers_file}")"
  location="$(sanitize_header_value "$(header_value "location" "${headers_file}")")"
  request_id="$(header_value "x-request-id" "${headers_file}")"
  remember_header_hints "${headers_file}"
  body_summary="$(summarize_response_body "${status:-curl-error-${rc}}" "${body_file}")"
  printf 'POST /api/auth/login account=%s status=%s curlExit=%s bodyBytes=%s contentType=%s cacheControl=%s server=%s via=%s location=%s requestID=%s body=%s\n' \
    "${masked_email}" \
    "${status:-curl-error-${rc}}" \
    "${rc}" \
    "${size:-0}" \
    "${content_type:-<none>}" \
    "${cache_control:-<none>}" \
    "${server:-<none>}" \
    "${via:-<none>}" \
    "${location:-<none>}" \
    "${request_id:-<none>}" \
    "${body_summary}"
  probe_total=$((probe_total + 1))
  probe_login_status="${status:-curl-error-${rc}}"
  probe_login_body_bytes="${size:-0}"
  if [[ "${rc}" != "0" ]]; then
    probe_curl_errors=$((probe_curl_errors + 1))
  fi
  if [[ "${status}" == "403" ]]; then
    probe_403=$((probe_403 + 1))
    if [[ "${size:-0}" == "0" ]]; then
      probe_empty_403=$((probe_empty_403 + 1))
    fi
  fi
}

write_probe_json() {
  local diagnosis="$1"
  local detail="$2"
  local failed="$3"
  if [[ -z "${PROBE_JSON_OUTPUT}" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "${PROBE_JSON_OUTPUT}")"
  python3 - \
    "${PROBE_JSON_OUTPUT}" \
    "${BASE_URL%/}" \
    "$(mask_account "$(first_account_email)")" \
    "${diagnosis}" \
    "${detail}" \
    "${failed}" \
    "${probe_total}" \
    "${probe_403}" \
    "${probe_empty_403}" \
    "${probe_curl_errors}" \
    "${probe_nginx_health_status:-}" \
    "${probe_nginx_health_body_bytes}" \
    "${probe_health_status:-}" \
    "${probe_login_status:-}" \
    "${probe_login_body_bytes}" \
    "${probe_tcp_status:-}" \
    "${probe_edge_intercept:-}" \
    "${probe_additional_protocol_hosts:-}" \
    "${probe_public_port_policy_status:-}" \
    "${probe_public_ports_open:-}" \
    "${probe_public_ports_closed:-}" \
    "${probe_public_expected_ports_missing:-}" \
    "${probe_public_denied_ports_open:-}" \
    "${probe_local_network_warning:-}" \
    "${probe_local_route_interface:-}" \
    "${probe_local_route_gateway:-}" \
    "${probe_local_proxy_env_names:-}" \
    "${tmp_dir}/port-protocols.tsv" \
    "${probe_server_hint:-}" \
    "${probe_via_hint:-}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    output_path,
    base_url,
    account,
    diagnosis,
    detail,
    failed,
    total,
    forbidden,
    empty_forbidden,
    curl_errors,
    nginx_health_status,
    nginx_health_body_bytes,
    health_status,
    login_status,
    login_body_bytes,
    tcp_status,
    edge_intercept,
    additional_protocol_hosts,
    public_port_policy_status,
    public_ports_open,
    public_ports_closed,
    public_expected_ports_missing,
    public_denied_ports_open,
    local_network_warning,
    local_route_interface,
    local_route_gateway,
    local_proxy_env_names,
    port_protocols_path,
    server_hint,
    via_hint,
) = sys.argv[1:31]

port_protocols = []
path = Path(port_protocols_path)
if path.exists():
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = raw.split("\t")
        if len(parts) != 3:
            continue
        label, port, protocol = parts
        port_protocols.append({
            "label": label,
            "port": port,
            "protocol": protocol,
        })

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "baseURL": base_url,
    "account": account,
    "diagnosis": diagnosis,
    "failed": failed.lower() == "true",
    "detail": detail,
    "tcpStatus": tcp_status,
    "edgeIntercept": edge_intercept,
    "additionalProtocolHosts": additional_protocol_hosts.split() if additional_protocol_hosts else [],
    "publicPortPolicyStatus": public_port_policy_status,
    "publicPortsOpen": public_ports_open.split() if public_ports_open else [],
    "publicPortsClosed": public_ports_closed.split() if public_ports_closed else [],
    "publicExpectedPortsMissing": public_expected_ports_missing.split() if public_expected_ports_missing else [],
    "publicDeniedPortsOpen": public_denied_ports_open.split() if public_denied_ports_open else [],
    "localNetworkWarning": local_network_warning,
    "localRouteInterface": local_route_interface,
    "localRouteGateway": local_route_gateway,
    "localProxyEnvNames": local_proxy_env_names.split() if local_proxy_env_names else [],
    "portProtocols": port_protocols,
    "summary": {
        "probeTotal": int(total),
        "forbidden": int(forbidden),
        "emptyForbidden": int(empty_forbidden),
        "curlErrors": int(curl_errors),
    },
    "signals": {
        "nginxHealthStatus": nginx_health_status,
        "nginxHealthBodyBytes": int(nginx_health_body_bytes),
        "healthStatus": health_status,
        "loginStatus": login_status,
        "loginBodyBytes": int(login_body_bytes),
        "tcpStatus": tcp_status,
        "edgeIntercept": edge_intercept,
        "additionalProtocolHosts": additional_protocol_hosts.split() if additional_protocol_hosts else [],
        "publicPortPolicyStatus": public_port_policy_status,
        "publicPortsOpen": public_ports_open.split() if public_ports_open else [],
        "publicPortsClosed": public_ports_closed.split() if public_ports_closed else [],
        "publicExpectedPortsMissing": public_expected_ports_missing.split() if public_expected_ports_missing else [],
        "publicDeniedPortsOpen": public_denied_ports_open.split() if public_denied_ports_open else [],
        "localNetworkWarning": local_network_warning,
        "localRouteInterface": local_route_interface,
        "localRouteGateway": local_route_gateway,
        "localProxyEnvNames": local_proxy_env_names.split() if local_proxy_env_names else [],
        "portProtocols": port_protocols,
        "serverHint": server_hint,
        "viaHint": via_hint,
    },
}
failed_bool = failed.lower() == "true"
blocker = {
    "type": "",
    "severity": "",
    "preventsPerformanceEvidence": False,
    "action": "",
    "reason": "",
}
if failed_bool:
    blocker = {
        "type": "entrypoint",
        "severity": "P0",
        "preventsPerformanceEvidence": True,
        "action": "repair_entrypoint",
        "reason": detail,
    }
    if diagnosis in {"cloud_edge_http_403_intercept", "cloud_edge_partial_http_403_intercept"}:
        blocker["action"] = "cloud_console_rescue_required"
    elif diagnosis in {"local_operator_network_blocked", "local_network_proxy_http_403_intercept", "public_port_policy_blocked_by_local_network"}:
        blocker["action"] = "disable_local_proxy_or_test_from_clean_network"
    elif diagnosis == "network_or_timeout":
        blocker["action"] = "repair_network_path"
    elif diagnosis == "api_reachable_login_rejected":
        blocker["action"] = "repair_load_account"
    elif diagnosis == "login_forbidden":
        blocker["action"] = "repair_auth_access_control"
    elif diagnosis in {"public_denied_ports_open", "public_expected_ports_missing"}:
        blocker["action"] = "repair_cloud_security_group"
payload["blocker"] = blocker
Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

diagnose_probe() {
  local diagnosis="unknown"
  local detail="Inspect BASE_URL, route exposure, reverse proxy, and service logs."
  local failed=false

  if [[ "${probe_public_port_policy_status}" == "blocked_by_local_network" ]]; then
    diagnosis="public_port_policy_blocked_by_local_network"
    detail="The local route or proxy environment prevents trustworthy public port policy validation. Rerun from a clean network before accepting production evidence."
    failed=true
  elif [[ -n "${probe_local_network_warning}" ]] && bool_enabled "${PROBE_FAIL_ON_LOCAL_NETWORK}"; then
    diagnosis="local_operator_network_blocked"
    detail="The local route or proxy environment prevents trustworthy production entrypoint evidence. Disable the local TUN/proxy or rerun from a clean network before deployment, rescue, or performance validation."
    failed=true
  elif [[ "${probe_public_port_policy_status}" == "denied_ports_open" ]]; then
    diagnosis="public_denied_ports_open"
    detail="One or more production-denied public ports are reachable. Close these cloud security group or edge firewall ports before accepting production evidence."
    failed=true
  elif [[ "${probe_public_port_policy_status}" == "expected_ports_missing" ]]; then
    diagnosis="public_expected_ports_missing"
    detail="One or more required public client ports are closed or filtered. Open the expected HTTP/HTTPS/TCP ports before production acceptance."
    failed=true
  elif [[ "${probe_login_status}" == "200" ]]; then
    diagnosis="ok"
    detail="HTTP entrypoint reaches IM API and login succeeded."
  elif (( probe_curl_errors > 0 )); then
    diagnosis="network_or_timeout"
    detail="curl failed for one or more probes; check DNS, security group, firewall, service bind address, or proxy."
    failed=true
  elif [[ -n "${probe_local_network_warning}" && "${probe_edge_intercept}" == "http_403_all_sampled_ports" ]]; then
    diagnosis="local_network_proxy_http_403_intercept"
    detail="The local route or proxy environment can intercept traffic before it reaches the server, and all sampled ports returned empty HTTP 403. Disable the local TUN/proxy or rerun from a clean network before changing server-side cloud routing."
    failed=true
  elif [[ "${probe_edge_intercept}" == "http_403_all_sampled_ports" ]]; then
    diagnosis="cloud_edge_http_403_intercept"
    detail="The HTTP entrypoint and sampled protocol ports all returned empty HTTP 403. Public traffic is being intercepted before it reaches the IMServer instance; fix cloud security/WAF/NAT/public IP routing before deployment or performance tests."
    failed=true
  elif [[ "${probe_edge_intercept}" == "http_403_multiple_sampled_ports" ]]; then
    diagnosis="cloud_edge_partial_http_403_intercept"
    detail="Multiple sampled protocol ports returned empty HTTP 403. TCP connect success is not valid evidence; check cloud security/WAF/NAT/public IP routing."
    failed=true
  elif [[ "${probe_nginx_health_status}" == "403" && "${probe_nginx_health_body_bytes}" == "0" ]]; then
    diagnosis="public_listener_not_imserver_nginx"
    detail="/nginx-health returned empty 403. Public traffic is not reaching the expected IMServer Nginx server block; check cloud security policy, WAF, external proxy, NAT, wrong public IP/port, or deploy the updated Nginx config."
    failed=true
  elif (( probe_total > 0 && probe_403 == probe_total && probe_empty_403 == probe_total )); then
    diagnosis="uniform_empty_403"
    detail="Every probe returned empty 403; this is usually reverse proxy, WAF, firewall, IP allowlist, or wrong process on the port before the IM API."
    failed=true
  elif [[ "${probe_health_status}" != "200" ]]; then
    diagnosis="health_unavailable"
    detail="/health is not 200; fix service exposure before running performance scenarios."
    failed=true
  elif [[ "${probe_login_status}" == "401" || "${probe_login_status}" == "400" ]]; then
    diagnosis="api_reachable_login_rejected"
    detail="IM API appears reachable; check account credentials, seed data, or login payload."
    failed=true
  elif [[ "${probe_login_status}" == "403" ]]; then
    diagnosis="login_forbidden"
    detail="Health may be reachable but login is forbidden; check auth middleware, rate limits, account state, or access-control rules."
    failed=true
  fi

  printf 'diagnosis=%s nginxHealthStatus=%s healthStatus=%s loginStatus=%s loginBodyBytes=%s tcpStatus=%s edgeIntercept=%s additionalProtocolHosts=%s publicPortPolicy=%s publicDeniedPortsOpen=%s publicExpectedPortsMissing=%s localNetworkWarning=%s localRouteInterface=%s localRouteGateway=%s proxyEnv=%s serverHint=%s viaHint=%s detail=%s\n' \
    "${diagnosis}" \
    "${probe_nginx_health_status:-<none>}" \
    "${probe_health_status:-<none>}" \
    "${probe_login_status:-<none>}" \
    "${probe_login_body_bytes}" \
    "${probe_tcp_status:-<none>}" \
    "${probe_edge_intercept:-<none>}" \
    "${probe_additional_protocol_hosts:-<none>}" \
    "${probe_public_port_policy_status:-<none>}" \
    "${probe_public_denied_ports_open:-<none>}" \
    "${probe_public_expected_ports_missing:-<none>}" \
    "${probe_local_network_warning:-<none>}" \
    "${probe_local_route_interface:-<none>}" \
    "${probe_local_route_gateway:-<none>}" \
    "${probe_local_proxy_env_names:-<none>}" \
    "${probe_server_hint:-<none>}" \
    "${probe_via_hint:-<none>}" \
    "${detail}"

  write_probe_json "${diagnosis}" "${detail}" "${failed}"

  if [[ "${failed}" == true ]] && bool_enabled "${PROBE_FAIL_ON_ENTRYPOINT_ERROR}"; then
    return 1
  fi
  return 0
}

echo "HTTP entrypoint probe:"
echo "  baseURL=${BASE_URL%/}"
echo "  account=$(mask_account "$(first_account_email)")"

if bool_enabled "${PROBE_REDACTION_SELF_TEST}"; then
  run_redaction_self_test
  exit 0
fi

if bool_enabled "${PROBE_PROTOCOL_HOSTS_SELF_TEST}"; then
  run_protocol_hosts_self_test
  exit 0
fi

detect_local_network_path
tcp_probe
public_port_policy_probe
for endpoint in ${PROBE_PATHS}; do
  probe_get "${endpoint}"
done
probe_login
diagnose_probe
