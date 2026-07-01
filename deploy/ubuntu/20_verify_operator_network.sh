#!/usr/bin/env bash
set -euo pipefail

OPERATOR_NETWORK_SELF_TEST="${OPERATOR_NETWORK_SELF_TEST:-false}"
OPERATOR_NETWORK_TARGETS="${OPERATOR_NETWORK_TARGETS:-}"
OPERATOR_NETWORK_ALLOW_TUN="${OPERATOR_NETWORK_ALLOW_TUN:-false}"
OPERATOR_NETWORK_FAIL_ON_PROXY_ENV="${OPERATOR_NETWORK_FAIL_ON_PROXY_ENV:-false}"
OPERATOR_NETWORK_ALLOW_ROUTE_LOOKUP_MISSING="${OPERATOR_NETWORK_ALLOW_ROUTE_LOOKUP_MISSING:-false}"
OPERATOR_NETWORK_JSON_OUTPUT="${OPERATOR_NETWORK_JSON_OUTPUT:-}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'USAGE'
Usage: 20_verify_operator_network.sh [target ...]

Checks the operator workstation route before deployment, rescue, or production
probes. It fails when the route to a target goes through common local TUN/proxy
interfaces or a 198.18.0.0/15 reserved proxy gateway.

Targets can be hostnames, IPs, URLs, host:port, or ssh-style user@host values.

Environment:
  OPERATOR_NETWORK_TARGETS                Space-separated targets when no args are provided.
  OPERATOR_NETWORK_ALLOW_TUN=false        Allow TUN/proxy routes and return success.
  OPERATOR_NETWORK_FAIL_ON_PROXY_ENV=false
                                           Fail when HTTP_PROXY/HTTPS_PROXY/ALL_PROXY are set.
  OPERATOR_NETWORK_ALLOW_ROUTE_LOOKUP_MISSING=false
                                           Allow missing route lookup commands or no route result.
  OPERATOR_NETWORK_JSON_OUTPUT             Optional path for structured JSON evidence.
USAGE
}

proxy_env_names() {
  env | awk -F= '
    $1 ~ /^(http_proxy|https_proxy|all_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|no_proxy|NO_PROXY)$/ {
      names[$1] = 1
    }
    END {
      first = 1
      for (name in names) {
        if (!first) {
          printf ","
        }
        printf "%s", name
        first = 0
      }
    }
  '
}

target_host() {
  python3 - "$1" <<'PY'
import re
import sys
from urllib.parse import urlparse

raw = sys.argv[1].strip()
if not raw:
    print("")
    raise SystemExit(0)

if "://" in raw:
    parsed = urlparse(raw)
    print(parsed.hostname or "")
    raise SystemExit(0)

if "@" in raw:
    raw = raw.rsplit("@", 1)[1]

if raw.startswith("["):
    end = raw.find("]")
    print(raw[1:end] if end >= 0 else raw.strip("[]"))
    raise SystemExit(0)

if raw.count(":") == 1:
    host, maybe_port = raw.rsplit(":", 1)
    if re.fullmatch(r"\d+", maybe_port):
        print(host)
        raise SystemExit(0)

print(raw)
PY
}

parse_route_output() {
  python3 -c '
import re
import sys

text = sys.stdin.read()
interface = ""
gateway = ""

for line in text.splitlines():
    stripped = line.strip()
    lower = stripped.lower()
    if lower.startswith("interface:"):
        interface = stripped.split(":", 1)[1].strip()
    elif lower.startswith("gateway:"):
        gateway = stripped.split(":", 1)[1].strip()

tokens = text.replace("\n", " ").split()
for index, token in enumerate(tokens):
    if token == "dev" and index + 1 < len(tokens) and not interface:
        interface = tokens[index + 1]
    elif token == "via" and index + 1 < len(tokens) and not gateway:
        gateway = tokens[index + 1]
    elif token == "gateway:" and index + 1 < len(tokens) and not gateway:
        gateway = tokens[index + 1]
    elif token == "interface:" and index + 1 < len(tokens) and not interface:
        interface = tokens[index + 1]

interface = re.sub(r"[^A-Za-z0-9_.:-].*$", "", interface)
gateway = re.sub(r"[^A-Za-z0-9_.:-].*$", "", gateway)
print(f"{interface}\t{gateway}")
'
}

classify_route() {
  local route_interface="$1"
  local route_gateway="$2"
  local proxy_names="$3"

  if [[ -n "${route_interface}" && "${route_interface}" =~ ^(utun|tun|tap|ppp|wg|tailscale) ]]; then
    printf 'tun_route\n'
  elif [[ -n "${route_gateway}" && "${route_gateway}" =~ ^198\.(18|19)\. ]]; then
    printf 'reserved_proxy_gateway\n'
  elif [[ -n "${proxy_names}" ]]; then
    printf 'proxy_env\n'
  else
    printf 'clean\n'
  fi
}

lookup_route() {
  local host="$1"
  if command -v route >/dev/null 2>&1; then
    route -n get "${host}" 2>/dev/null || true
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip route get "${host}" 2>/dev/null | head -n 1 || true
    return 0
  fi
  return 127
}

check_route_text() {
  local label="$1"
  local host="$2"
  local route_output="$3"
  local proxy_names="$4"
  local parsed route_interface route_gateway warning status fail_reason

  parsed="$(printf '%s' "${route_output}" | parse_route_output)"
  route_interface="${parsed%%$'\t'*}"
  route_gateway="${parsed#*$'\t'}"
  [[ "${route_gateway}" != "${route_interface}" ]] || route_gateway=""

  warning="$(classify_route "${route_interface}" "${route_gateway}" "${proxy_names}")"
  status="pass"
  fail_reason=""

  case "${warning}" in
    tun_route|reserved_proxy_gateway)
      if ! bool_enabled "${OPERATOR_NETWORK_ALLOW_TUN}"; then
        status="fail"
        fail_reason="${warning}"
      fi
      ;;
    proxy_env)
      if bool_enabled "${OPERATOR_NETWORK_FAIL_ON_PROXY_ENV}"; then
        status="fail"
        fail_reason="${warning}"
      else
        status="warn"
      fi
      ;;
  esac

  printf 'operator-network target=%s host=%s status=%s warning=%s routeInterface=%s routeGateway=%s proxyEnv=%s\n' \
    "${label}" \
    "${host:-<none>}" \
    "${status}" \
    "${warning}" \
    "${route_interface:-<none>}" \
    "${route_gateway:-<none>}" \
    "${proxy_names:-<none>}"

  [[ -z "${fail_reason}" ]]
}

write_json_output() {
  local output_path="$1"
  local status="$2"
  local failures="$3"
  local records_file="$4"
  [[ -n "${output_path}" ]] || return 0
  mkdir -p "$(dirname "${output_path}")"
  python3 - "${output_path}" "${status}" "${failures}" "${records_file}" <<'PY'
import json
import sys
import time
from pathlib import Path

output_path, status, failures_raw, records_file = sys.argv[1:5]
targets = []
warning_counts = {}
route_interfaces = set()
route_gateways = set()
failed_targets = []

for raw in Path(records_file).read_text(encoding="utf-8", errors="replace").splitlines():
    fields = {}
    for token in raw.split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        fields[key] = value
    if not fields or "target" not in fields:
        continue
    warning = fields.get("warning") or ""
    route_interface = fields.get("routeInterface") or ""
    route_gateway = fields.get("routeGateway") or ""
    row = {
        "target": fields.get("target") or "",
        "host": fields.get("host") or "",
        "status": fields.get("status") or "",
        "warning": warning,
        "routeInterface": route_interface,
        "routeGateway": route_gateway,
        "proxyEnv": fields.get("proxyEnv") or "",
    }
    targets.append(row)
    if warning and warning not in {"clean", "<none>"}:
        warning_counts[warning] = warning_counts.get(warning, 0) + 1
    if row["status"] == "fail":
        failed_targets.append(row["target"])
    if route_interface and route_interface != "<none>":
        route_interfaces.add(route_interface)
    if route_gateway and route_gateway != "<none>":
        route_gateways.add(route_gateway)

try:
    failures = int(failures_raw)
except Exception:
    failures = len(failed_targets)

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": status,
    "failed": status == "fail",
    "failureCount": failures,
    "targetCount": len(targets),
    "warnings": sorted(warning_counts),
    "warningCounts": dict(sorted(warning_counts.items())),
    "routeInterfaces": sorted(route_interfaces),
    "routeGateways": sorted(route_gateways),
    "failedTargets": failed_targets,
    "targets": targets,
    "action": "disconnect_local_tun_or_use_clean_network" if status == "fail" else "",
}
Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

run_check() {
  local failures=0 target host route_output route_rc parsed_targets proxy_names records_file line status
  records_file="$(mktemp "${TMPDIR:-/tmp}/im-operator-network-records.XXXXXX")"
  trap 'rm -f "${records_file}"' RETURN
  proxy_names="$(proxy_env_names)"
  parsed_targets=("$@")
  if ((${#parsed_targets[@]} == 0)); then
    if [[ -n "${OPERATOR_NETWORK_TARGETS}" ]]; then
      # shellcheck disable=SC2206
      parsed_targets=(${OPERATOR_NETWORK_TARGETS})
    else
      for target in "${PUBLIC_BASE_URL:-}" "${BASE_URL:-}" "${IM_PUBLIC_BASE_URL:-}" "${TCP_HOST:-}" "${SSH_HOST:-}"; do
        [[ -n "${target}" ]] && parsed_targets+=("${target}")
      done
    fi
  fi

  if ((${#parsed_targets[@]} == 0)); then
    printf 'operator-network result=fail reason=target_required action=set_OPERATOR_NETWORK_TARGETS_or_pass_targets\n' >&2
    write_json_output "${OPERATOR_NETWORK_JSON_OUTPUT}" "fail" "1" "${records_file}"
    return 2
  fi

  for target in "${parsed_targets[@]}"; do
    host="$(target_host "${target}")"
    if [[ -z "${host}" ]]; then
      line="$(printf 'operator-network target=%s host=<none> status=fail warning=parse_failed routeInterface=<none> routeGateway=<none> proxyEnv=%s' \
        "${target}" \
        "${proxy_names:-<none>}")"
      printf '%s\n' "${line}" >&2
      printf '%s\n' "${line}" >>"${records_file}"
      failures=$((failures + 1))
      continue
    fi

    route_rc=0
    route_output="$(lookup_route "${host}")" || route_rc=$?
    if [[ "${route_rc}" == "127" || -z "${route_output}" ]]; then
      if bool_enabled "${OPERATOR_NETWORK_ALLOW_ROUTE_LOOKUP_MISSING}"; then
        line="$(printf 'operator-network target=%s host=%s status=warn warning=route_lookup_missing routeInterface=<none> routeGateway=<none> proxyEnv=%s' \
          "${target}" \
          "${host}" \
          "${proxy_names:-<none>}")"
        printf '%s\n' "${line}"
        printf '%s\n' "${line}" >>"${records_file}"
      else
        line="$(printf 'operator-network target=%s host=%s status=fail warning=route_lookup_missing routeInterface=<none> routeGateway=<none> proxyEnv=%s' \
          "${target}" \
          "${host}" \
          "${proxy_names:-<none>}")"
        printf '%s\n' "${line}" >&2
        printf '%s\n' "${line}" >>"${records_file}"
        failures=$((failures + 1))
      fi
      continue
    fi

    if line="$(check_route_text "${target}" "${host}" "${route_output}" "${proxy_names}")"; then
      printf '%s\n' "${line}"
      printf '%s\n' "${line}" >>"${records_file}"
    else
      printf '%s\n' "${line}"
      printf '%s\n' "${line}" >>"${records_file}"
      failures=$((failures + 1))
    fi
  done

  if ((failures > 0)); then
    write_json_output "${OPERATOR_NETWORK_JSON_OUTPUT}" "fail" "${failures}" "${records_file}"
    printf 'operator-network result=fail failures=%s action=disconnect_local_tun_or_use_clean_network\n' "${failures}" >&2
    return 1
  fi
  write_json_output "${OPERATOR_NETWORK_JSON_OUTPUT}" "pass" "0" "${records_file}"
  printf 'operator-network result=pass targets=%s\n' "${#parsed_targets[@]}"
}

run_self_test() {
  local mac_clean mac_tun linux_clean linux_reserved parsed records_file json_file
  mac_clean=$'   route to: 203.0.113.10\n    gateway: 192.168.1.1\n  interface: en0\n'
  mac_tun=$'   route to: 47.106.103.10\n    gateway: 198.18.0.1\n  interface: utun8\n'
  linux_clean='203.0.113.10 via 192.168.1.1 dev eth0 src 192.168.1.10 uid 501'
  linux_reserved='47.106.103.10 via 198.19.0.1 dev en0 src 198.19.0.2 uid 501'

  check_route_text "mac-clean" "203.0.113.10" "${mac_clean}" "" >/tmp/im-operator-network-self-test.log
  grep -q 'status=pass warning=clean routeInterface=en0 routeGateway=192.168.1.1' /tmp/im-operator-network-self-test.log

  if check_route_text "mac-tun" "47.106.103.10" "${mac_tun}" "" >/tmp/im-operator-network-self-test.log 2>&1; then
    printf 'operator-network-self-test result=fail reason=tun_route_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'status=fail warning=tun_route routeInterface=utun8 routeGateway=198.18.0.1' /tmp/im-operator-network-self-test.log
  records_file="/tmp/im-operator-network-self-test-records.txt"
  json_file="/tmp/im-operator-network-self-test.json"
  cp /tmp/im-operator-network-self-test.log "${records_file}"
  write_json_output "${json_file}" "fail" "1" "${records_file}"
  python3 - "${json_file}" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("operator-network-self-test result=fail reason=json_schema_missing")
if payload.get("failed") is not True or payload.get("status") != "fail":
    raise SystemExit("operator-network-self-test result=fail reason=json_failed_status_invalid")
if payload.get("failureCount") != 1:
    raise SystemExit("operator-network-self-test result=fail reason=json_failure_count_invalid")
if "tun_route" not in (payload.get("warnings") or []):
    raise SystemExit("operator-network-self-test result=fail reason=json_warning_missing")
if "utun8" not in (payload.get("routeInterfaces") or []):
    raise SystemExit("operator-network-self-test result=fail reason=json_interface_missing")
if "198.18.0.1" not in (payload.get("routeGateways") or []):
    raise SystemExit("operator-network-self-test result=fail reason=json_gateway_missing")
PY

  OPERATOR_NETWORK_ALLOW_TUN=true check_route_text "mac-tun-allowed" "47.106.103.10" "${mac_tun}" "" >/tmp/im-operator-network-self-test.log
  grep -q 'status=pass warning=tun_route' /tmp/im-operator-network-self-test.log

  check_route_text "linux-clean" "203.0.113.10" "${linux_clean}" "" >/tmp/im-operator-network-self-test.log
  grep -q 'status=pass warning=clean routeInterface=eth0 routeGateway=192.168.1.1' /tmp/im-operator-network-self-test.log

  if check_route_text "linux-reserved" "47.106.103.10" "${linux_reserved}" "" >/tmp/im-operator-network-self-test.log 2>&1; then
    printf 'operator-network-self-test result=fail reason=reserved_gateway_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'status=fail warning=reserved_proxy_gateway routeInterface=en0 routeGateway=198.19.0.1' /tmp/im-operator-network-self-test.log

  if OPERATOR_NETWORK_FAIL_ON_PROXY_ENV=true check_route_text "proxy-env" "203.0.113.10" "${mac_clean}" "HTTPS_PROXY" >/tmp/im-operator-network-self-test.log 2>&1; then
    printf 'operator-network-self-test result=fail reason=proxy_env_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'status=fail warning=proxy_env' /tmp/im-operator-network-self-test.log

  parsed="$(target_host "ssh://root@47.106.103.10:22")"
  [[ "${parsed}" == "47.106.103.10" ]] || {
    printf 'operator-network-self-test result=fail reason=url_target_parse parsed=%s\n' "${parsed}" >&2
    return 1
  }
  parsed="$(target_host "root@47.106.103.10")"
  [[ "${parsed}" == "47.106.103.10" ]] || {
    printf 'operator-network-self-test result=fail reason=ssh_target_parse parsed=%s\n' "${parsed}" >&2
    return 1
  }
  parsed="$(target_host "47.106.103.10:9000")"
  [[ "${parsed}" == "47.106.103.10" ]] || {
    printf 'operator-network-self-test result=fail reason=host_port_target_parse parsed=%s\n' "${parsed}" >&2
    return 1
  }

  rm -f /tmp/im-operator-network-self-test.log "${records_file}" "${json_file}"
  printf 'operator-network-self-test result=pass\n'
}

if bool_enabled "${OPERATOR_NETWORK_SELF_TEST}"; then
  run_self_test
  exit 0
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

run_check "$@"
