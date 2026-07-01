#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFO_PLIST="${INFO_PLIST:-${PROJECT_DIR}/Config/IMAppInfo.plist}"
VALIDATION_MODE="${IMAPP_NETWORK_CONFIG_MODE:-${CONFIGURATION:-development}}"
STALE_PUBLIC_IPS="${STALE_PUBLIC_IPS:-47.106.103.10 120.25.106.200}"
USE_ENV_OVERRIDES="${IMAPP_NETWORK_CONFIG_USE_ENV_OVERRIDES:-true}"
EXPECTED_PRODUCTION_TCP_PORT="${IMAPP_PRODUCTION_TCP_PORT:-9000}"

if [[ "${IMAPP_NETWORK_CONFIG_SELF_TEST:-false}" == "true" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  test_plist="${tmpdir}/IMAppInfo.plist"
  python3 - "${test_plist}" <<'PY'
import plistlib
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "IMAPIBaseURL": "$(IM_API_BASE_URL)",
    "IMTCPHost": "$(IM_TCP_HOST)",
    "IMTCPPort": "$(IM_TCP_PORT)",
}))
PY

  INFO_PLIST="${test_plist}" \
    IMAPP_NETWORK_CONFIG_SELF_TEST=false \
    IMAPP_NETWORK_CONFIG_MODE=production \
    IM_API_BASE_URL=https://chat.prod-domain.com \
    IM_TCP_HOST=tcp.prod-domain.com \
    IM_TCP_PORT=9000 \
      "${BASH_SOURCE[0]}" >/dev/null

  expect_failure() {
    local expected_reason="$1"
    shift
    local log_file="${tmpdir}/${expected_reason}.log"
    if INFO_PLIST="${test_plist}" \
      IMAPP_NETWORK_CONFIG_SELF_TEST=false \
      IMAPP_NETWORK_CONFIG_MODE=production \
      "$@" "${BASH_SOURCE[0]}" >"${log_file}" 2>&1; then
      printf 'network-config-self-test result=fail reason=expected_failure_missing expected=%s\n' "${expected_reason}" >&2
      return 1
    fi
    if ! grep -q "${expected_reason}" "${log_file}"; then
      printf 'network-config-self-test result=fail reason=expected_reason_missing expected=%s log=%s\n' "${expected_reason}" "${log_file}" >&2
      sed -n '1,20p' "${log_file}" >&2 || true
      return 1
    fi
  }

  expect_failure production_api_requires_default_https_port \
    env IM_API_BASE_URL=https://chat.prod-domain.com:8443 IM_TCP_HOST=tcp.prod-domain.com IM_TCP_PORT=9000
  expect_failure production_tcp_port_unexpected \
    env IM_API_BASE_URL=https://chat.prod-domain.com IM_TCP_HOST=tcp.prod-domain.com IM_TCP_PORT=9443
  expect_failure placeholder_api_host \
    env IM_API_BASE_URL=https://im.example.com IM_TCP_HOST=tcp.prod-domain.com IM_TCP_PORT=9000
  expect_failure production_tcp_host_requires_domain \
    env IM_API_BASE_URL=https://chat.prod-domain.com IM_TCP_HOST=47.106.103.10 IM_TCP_PORT=9000

  printf 'network-config-self-test result=pass\n'
  exit 0
fi

python3 - "${INFO_PLIST}" "${VALIDATION_MODE}" "${STALE_PUBLIC_IPS}" "${USE_ENV_OVERRIDES}" "${EXPECTED_PRODUCTION_TCP_PORT}" <<'PY'
import ipaddress
import os
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit

info_plist = Path(sys.argv[1])
mode = (sys.argv[2] or "development").strip().lower()
stale_public_ips = {item for item in sys.argv[3].split() if item}
use_env_overrides = (sys.argv[4] or "true").strip().lower() in {"1", "true", "yes", "on"}
expected_production_tcp_port_raw = (sys.argv[5] or "9000").strip()
production_modes = {"release", "production", "appstore", "app-store"}
placeholder_hosts = {"im.example.com", "example.com", "example.net", "example.org"}
placeholder_suffixes = (".example.com", ".example.net", ".example.org", ".test", ".invalid", ".localhost")
local_hosts = {"127.0.0.1", "localhost", "::1"}

def public_host_policy_reason(host):
    normalized = (host or "").strip().strip("[]").lower()
    if not normalized:
        return "missing_host"
    if normalized in local_hosts or normalized.endswith(".local"):
        return "local_host"
    try:
        ipaddress.ip_address(normalized)
    except ValueError:
        pass
    else:
        return "ip_literal"
    if "." not in normalized:
        return "single_label"
    if normalized in placeholder_hosts or normalized.endswith(placeholder_suffixes):
        return "placeholder_domain"
    return "ok"

try:
    payload = plistlib.loads(info_plist.read_bytes())
except Exception as exc:
    print(f"network-config result=fail reason=invalid_plist path={info_plist} detail={exc}", file=sys.stderr)
    raise SystemExit(2)

def config_value(env_key: str, plist_key: str) -> tuple[str, str]:
    env_value = os.environ.get(env_key) if use_env_overrides else None
    if env_value is not None and env_value.strip():
        return env_value.strip(), f"env:{env_key}"
    return str(payload.get(plist_key) or "").strip(), f"plist:{plist_key}"

api_base_url, api_base_url_source = config_value("IM_API_BASE_URL", "IMAPIBaseURL")
tcp_host, tcp_host_source = config_value("IM_TCP_HOST", "IMTCPHost")
tcp_port_raw, tcp_port_source = config_value("IM_TCP_PORT", "IMTCPPort")
errors: list[str] = []

if not api_base_url:
    errors.append("missing_IMAPIBaseURL")
if not tcp_host:
    errors.append("missing_IMTCPHost")
if not tcp_port_raw:
    errors.append("missing_IMTCPPort")
if "$(" in api_base_url or ")" in api_base_url:
    errors.append(f"unresolved_IMAPIBaseURL:{api_base_url}")
if "$(" in tcp_host or ")" in tcp_host:
    errors.append(f"unresolved_IMTCPHost:{tcp_host}")
if "$(" in tcp_port_raw or ")" in tcp_port_raw:
    errors.append(f"unresolved_IMTCPPort:{tcp_port_raw}")

url = urlsplit(api_base_url) if api_base_url else None
if url is not None:
    if not url.scheme or not url.hostname:
        errors.append(f"invalid_IMAPIBaseURL:{api_base_url}")
    if url.hostname in stale_public_ips:
        errors.append(f"stale_api_host:{url.hostname}")
    if mode in production_modes and (url.hostname in placeholder_hosts or url.hostname.endswith(placeholder_suffixes)):
        errors.append(f"placeholder_api_host:{url.hostname}")
    if mode in production_modes and url.scheme != "https":
        errors.append(f"production_api_requires_https:{api_base_url}")
    if mode in production_modes and url.scheme == "https" and url.port not in (None, 443):
        errors.append(f"production_api_requires_default_https_port:{api_base_url}")
    if mode in production_modes:
        host_reason = public_host_policy_reason(url.hostname)
        if host_reason != "ok":
            errors.append(f"production_api_host_requires_domain:{url.hostname}:{host_reason}")

if tcp_host in stale_public_ips:
    errors.append(f"stale_tcp_host:{tcp_host}")
if mode in production_modes and (tcp_host in placeholder_hosts or tcp_host.endswith(placeholder_suffixes)):
    errors.append(f"placeholder_tcp_host:{tcp_host}")
if mode in production_modes:
    host_reason = public_host_policy_reason(tcp_host)
    if host_reason != "ok":
        errors.append(f"production_tcp_host_requires_domain:{tcp_host}:{host_reason}")

try:
    tcp_port = int(tcp_port_raw)
except ValueError:
    errors.append(f"invalid_IMTCPPort:{tcp_port_raw}")
else:
    if tcp_port < 1 or tcp_port > 65535:
        errors.append(f"invalid_IMTCPPort:{tcp_port_raw}")
    if mode in production_modes:
        try:
            expected_production_tcp_port = int(expected_production_tcp_port_raw)
        except ValueError:
            errors.append(f"invalid_IMAPP_PRODUCTION_TCP_PORT:{expected_production_tcp_port_raw}")
        else:
            if tcp_port != expected_production_tcp_port:
                errors.append(
                    f"production_tcp_port_unexpected:{tcp_port_raw}:expected_{expected_production_tcp_port}"
                )

if errors:
    print(
        "network-config result=fail "
        f"mode={mode} path={info_plist} "
        f"apiBaseURL={api_base_url or '<missing>'} "
        f"apiBaseURLSource={api_base_url_source} "
        f"tcpHost={tcp_host or '<missing>'} "
        f"tcpHostSource={tcp_host_source} "
        f"tcpPort={tcp_port_raw or '<missing>'} "
        f"tcpPortSource={tcp_port_source} "
        f"errors={','.join(errors)}",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    "network-config result=pass "
    f"mode={mode} path={info_plist} "
    f"apiBaseURL={api_base_url} apiBaseURLSource={api_base_url_source} "
    f"tcpHost={tcp_host} tcpHostSource={tcp_host_source} "
    f"tcpPort={tcp_port_raw} tcpPortSource={tcp_port_source}"
)
PY
