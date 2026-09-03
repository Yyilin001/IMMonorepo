#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${PROJECT_FILE:-${PROJECT_DIR}/IMApp.xcodeproj}"
SCHEME="${SCHEME:-IMApp}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"
EXPECTED_ACCOUNT_URL="${EXPECTED_DEBUG_V2_ACCOUNT_BASE_URL:-https://localhost:8443}"
EXPECTED_GATEWAY_HOST="${EXPECTED_DEBUG_V2_GATEWAY_HOST:-localhost}"
EXPECTED_GATEWAY_PORT="${EXPECTED_DEBUG_V2_GATEWAY_PORT:-7443}"

if [[ "${IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST:-false}" == "true" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  fake_xcodebuild="${tmpdir}/xcodebuild"
  cat >"${fake_xcodebuild}" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_XCODEBUILD_CASE:-local}" in
  local) printf '%s\n' '    IM_V2_ACCOUNT_BASE_URL = https://localhost:8443' '    IM_V2_GATEWAY_HOST = localhost' '    IM_V2_GATEWAY_PORT = 7443' ;;
  public) printf '%s\n' '    IM_V2_ACCOUNT_BASE_URL = https://im.example.com' '    IM_V2_GATEWAY_HOST = gateway.im.example.com' '    IM_V2_GATEWAY_PORT = 7443' ;;
  unresolved) printf '%s\n' '    IM_V2_ACCOUNT_BASE_URL = $(IM_V2_ACCOUNT_BASE_URL)' '    IM_V2_GATEWAY_HOST = $(IM_V2_GATEWAY_HOST)' '    IM_V2_GATEWAY_PORT = $(IM_V2_GATEWAY_PORT)' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "${fake_xcodebuild}"
  PATH="${tmpdir}:${PATH}" IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST=false bash "${BASH_SOURCE[0]}" >/dev/null
  for test_case in public unresolved; do
    if PATH="${tmpdir}:${PATH}" FAKE_XCODEBUILD_CASE="${test_case}" IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST=false bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
      printf 'debug-network-defaults-self-test result=fail reason=%s_not_rejected\n' "${test_case}" >&2
      exit 1
    fi
  done
  printf 'debug-network-defaults-self-test result=pass\n'
  exit 0
fi

build_settings_file="$(mktemp)"
trap 'rm -f "${build_settings_file}"' EXIT
xcodebuild -project "${PROJECT_FILE}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" -showBuildSettings >"${build_settings_file}"

python3 - "${build_settings_file}" "${EXPECTED_ACCOUNT_URL}" "${EXPECTED_GATEWAY_HOST}" "${EXPECTED_GATEWAY_PORT}" <<'PY'
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

settings_file, expected_url, expected_gateway_host, expected_gateway_port = sys.argv[1:]
settings = {}
for line in Path(settings_file).read_text(encoding="utf-8").splitlines():
    match = re.match(r"\s*(IM_V2_ACCOUNT_BASE_URL|IM_V2_GATEWAY_HOST|IM_V2_GATEWAY_PORT)\s*=\s*(.*?)\s*$", line)
    if match:
        settings[match.group(1)] = match.group(2)

errors = []
for key in ("IM_V2_ACCOUNT_BASE_URL", "IM_V2_GATEWAY_HOST", "IM_V2_GATEWAY_PORT"):
    value = settings.get(key, "")
    if not value:
        errors.append(f"missing_{key}")
    elif "$(" in value or ")" in value:
        errors.append(f"unresolved_{key}:{value}")

url = settings.get("IM_V2_ACCOUNT_BASE_URL", "")
gateway_host = settings.get("IM_V2_GATEWAY_HOST", "")
gateway_port = settings.get("IM_V2_GATEWAY_PORT", "")
if url and url != expected_url:
    errors.append(f"unexpected_IM_V2_ACCOUNT_BASE_URL:{url}:expected_{expected_url}")
if gateway_host and gateway_host != expected_gateway_host:
    errors.append(f"unexpected_IM_V2_GATEWAY_HOST:{gateway_host}:expected_{expected_gateway_host}")
if gateway_port and gateway_port != expected_gateway_port:
    errors.append(f"unexpected_IM_V2_GATEWAY_PORT:{gateway_port}:expected_{expected_gateway_port}")
parsed = urlsplit(url) if url else None
if parsed and (parsed.scheme != "https" or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}):
    errors.append(f"debug_v2_account_must_be_local_https:{url}")
if gateway_host not in {"localhost", "127.0.0.1", "::1"}:
    errors.append(f"debug_v2_gateway_must_be_local:{gateway_host}")
if gateway_port != "7443":
    errors.append(f"debug_v2_gateway_port_unexpected:{gateway_port}")
if errors:
    print(f"debug-network-defaults result=fail configuration={settings!r} errors={','.join(errors)}", file=sys.stderr)
    raise SystemExit(1)
print(f"debug-network-defaults result=pass v2AccountBaseURL={url} v2GatewayHost={gateway_host} v2GatewayPort={gateway_port}")
PY
