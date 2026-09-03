#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFO_PLIST="${INFO_PLIST:-${PROJECT_DIR}/Config/IMAppInfo.plist}"
VALIDATION_MODE="${IMAPP_NETWORK_CONFIG_MODE:-${CONFIGURATION:-development}}"
USE_ENV_OVERRIDES="${IMAPP_NETWORK_CONFIG_USE_ENV_OVERRIDES:-true}"

if [[ "${IMAPP_NETWORK_CONFIG_SELF_TEST:-false}" == "true" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  test_plist="${tmpdir}/IMAppInfo.plist"
  python3 - "${test_plist}" <<'PY'
import plistlib
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "IMV2AccountBaseURL": "$(IM_V2_ACCOUNT_BASE_URL)",
    "IMV2GatewayHost": "$(IM_V2_GATEWAY_HOST)",
    "IMV2GatewayPort": "$(IM_V2_GATEWAY_PORT)",
    "IMV2PushEnvironment": "$(IM_V2_PUSH_ENVIRONMENT)",
}))
PY

  INFO_PLIST="${test_plist}" \
    IMAPP_NETWORK_CONFIG_SELF_TEST=false \
    IMAPP_NETWORK_CONFIG_MODE=production \
    IM_V2_ACCOUNT_BASE_URL=https://account.prod-domain.com \
    IM_V2_GATEWAY_HOST=gateway.prod-domain.com \
    IM_V2_GATEWAY_PORT=7443 \
    IM_V2_PUSH_ENVIRONMENT=production \
      bash "${BASH_SOURCE[0]}" >/dev/null

  expect_failure() {
    local expected_reason="$1"
    shift
    local log_file="${tmpdir}/${expected_reason}.log"
    if INFO_PLIST="${test_plist}" \
      IMAPP_NETWORK_CONFIG_SELF_TEST=false \
      IMAPP_NETWORK_CONFIG_MODE=production \
      "$@" bash "${BASH_SOURCE[0]}" >"${log_file}" 2>&1; then
      printf 'network-config-self-test result=fail reason=expected_failure_missing expected=%s\n' "${expected_reason}" >&2
      return 1
    fi
    grep -q "${expected_reason}" "${log_file}" || {
      printf 'network-config-self-test result=fail reason=expected_reason_missing expected=%s\n' "${expected_reason}" >&2
      sed -n '1,20p' "${log_file}" >&2 || true
      return 1
    }
  }

  expect_failure production_v2_account_requires_https \
    env IM_V2_ACCOUNT_BASE_URL=http://account.prod-domain.com IM_V2_GATEWAY_HOST=gateway.prod-domain.com IM_V2_GATEWAY_PORT=7443 IM_V2_PUSH_ENVIRONMENT=production
  expect_failure production_v2_account_host_requires_domain \
    env IM_V2_ACCOUNT_BASE_URL=https://127.0.0.1 IM_V2_GATEWAY_HOST=127.0.0.1 IM_V2_GATEWAY_PORT=7443 IM_V2_PUSH_ENVIRONMENT=production
  expect_failure production_v2_gateway_host_requires_domain \
    env IM_V2_ACCOUNT_BASE_URL=https://account.prod-domain.com IM_V2_GATEWAY_HOST=127.0.0.1 IM_V2_GATEWAY_PORT=7443 IM_V2_PUSH_ENVIRONMENT=production
  expect_failure production_v2_push_environment_requires_production \
    env IM_V2_ACCOUNT_BASE_URL=https://account.prod-domain.com IM_V2_GATEWAY_HOST=gateway.prod-domain.com IM_V2_GATEWAY_PORT=7443 IM_V2_PUSH_ENVIRONMENT=development

  printf 'network-config-self-test result=pass\n'
  exit 0
fi

python3 - "${INFO_PLIST}" "${VALIDATION_MODE}" "${USE_ENV_OVERRIDES}" <<'PY'
import ipaddress
import os
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit

info_plist = Path(sys.argv[1])
mode = (sys.argv[2] or "development").strip().lower()
use_env_overrides = (sys.argv[3] or "true").strip().lower() in {"1", "true", "yes", "on"}
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

def config_value(env_key, plist_key):
    env_value = os.environ.get(env_key) if use_env_overrides else None
    if env_value is not None and env_value.strip():
        return env_value.strip(), f"env:{env_key}"
    return str(payload.get(plist_key) or "").strip(), f"plist:{plist_key}"

account_base_url, account_base_url_source = config_value("IM_V2_ACCOUNT_BASE_URL", "IMV2AccountBaseURL")
gateway_host, gateway_host_source = config_value("IM_V2_GATEWAY_HOST", "IMV2GatewayHost")
gateway_port_raw, gateway_port_source = config_value("IM_V2_GATEWAY_PORT", "IMV2GatewayPort")
push_environment, push_environment_source = config_value("IM_V2_PUSH_ENVIRONMENT", "IMV2PushEnvironment")
errors = []

if not account_base_url:
    errors.append("missing_IMV2AccountBaseURL")
if not gateway_host:
    errors.append("missing_IMV2GatewayHost")
if not gateway_port_raw:
    errors.append("missing_IMV2GatewayPort")
if not push_environment:
    errors.append("missing_IMV2PushEnvironment")
if "$(" in account_base_url or ")" in account_base_url:
    errors.append(f"unresolved_IMV2AccountBaseURL:{account_base_url}")
if "$(" in gateway_host or ")" in gateway_host:
    errors.append(f"unresolved_IMV2GatewayHost:{gateway_host}")
if "$(" in gateway_port_raw or ")" in gateway_port_raw:
    errors.append(f"unresolved_IMV2GatewayPort:{gateway_port_raw}")
if "$(" in push_environment or ")" in push_environment:
    errors.append(f"unresolved_IMV2PushEnvironment:{push_environment}")

push_environment = push_environment.lower()
if push_environment and push_environment not in {"development", "production"}:
    errors.append(f"invalid_IMV2PushEnvironment:{push_environment}")
if mode in production_modes and push_environment != "production":
    errors.append(f"production_v2_push_environment_requires_production:{push_environment or '<missing>'}")

account_url = urlsplit(account_base_url) if account_base_url else None
if account_url is not None:
    if not account_url.scheme or not account_url.hostname:
        errors.append(f"invalid_IMV2AccountBaseURL:{account_base_url}")
    if mode in production_modes and account_url.scheme != "https":
        errors.append(f"production_v2_account_requires_https:{account_base_url}")
    if mode in production_modes and account_url.scheme == "https" and account_url.port not in (None, 443):
        errors.append(f"production_v2_account_requires_default_https_port:{account_base_url}")
    if mode in production_modes and account_url.hostname:
        host_reason = public_host_policy_reason(account_url.hostname)
        if host_reason != "ok":
            errors.append(f"production_v2_account_host_requires_domain:{account_url.hostname}:{host_reason}")

try:
    gateway_port = int(gateway_port_raw)
except ValueError:
    errors.append(f"invalid_IMV2GatewayPort:{gateway_port_raw}")
else:
    if gateway_port < 1 or gateway_port > 65535:
        errors.append(f"invalid_IMV2GatewayPort:{gateway_port_raw}")
if mode in production_modes:
    gateway_reason = public_host_policy_reason(gateway_host)
    if gateway_reason != "ok":
        errors.append(f"production_v2_gateway_host_requires_domain:{gateway_host}:{gateway_reason}")
if errors:
    print(
        "network-config result=fail "
        f"mode={mode} path={info_plist} "
        f"v2AccountBaseURL={account_base_url or '<missing>'} "
        f"v2AccountBaseURLSource={account_base_url_source} "
        f"v2GatewayHost={gateway_host or '<missing>'} "
        f"v2GatewayHostSource={gateway_host_source} "
        f"v2GatewayPort={gateway_port_raw or '<missing>'} "
        f"v2GatewayPortSource={gateway_port_source} "
        f"v2PushEnvironment={push_environment or '<missing>'} "
        f"v2PushEnvironmentSource={push_environment_source} "
        f"errors={','.join(errors)}",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    "network-config result=pass "
    f"mode={mode} path={info_plist} "
    f"v2AccountBaseURL={account_base_url} v2AccountBaseURLSource={account_base_url_source} "
    f"v2GatewayHost={gateway_host} v2GatewayHostSource={gateway_host_source} "
    f"v2GatewayPort={gateway_port_raw} v2GatewayPortSource={gateway_port_source} "
    f"v2PushEnvironment={push_environment} v2PushEnvironmentSource={push_environment_source}"
)
PY
