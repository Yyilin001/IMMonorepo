#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${PROJECT_FILE:-${PROJECT_DIR}/IMApp.xcodeproj}"
SCHEME="${SCHEME:-IMApp}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"

EXPECTED_API_BASE_URL="${EXPECTED_DEBUG_API_BASE_URL:-http://127.0.0.1:8080}"
EXPECTED_TCP_HOST="${EXPECTED_DEBUG_TCP_HOST:-127.0.0.1}"
EXPECTED_TCP_PORT="${EXPECTED_DEBUG_TCP_PORT:-9000}"

if [[ "${IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST:-false}" == "true" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  fake_xcodebuild="${tmpdir}/xcodebuild"
  cat >"${fake_xcodebuild}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${FAKE_XCODEBUILD_CASE:-local}" in
  local)
    cat <<'SETTINGS'
Build settings for action build and target IMApp:
    IM_API_BASE_URL = http://127.0.0.1:8080
    IM_TCP_HOST = 127.0.0.1
    IM_TCP_PORT = 9000
SETTINGS
    ;;
  public)
    cat <<'SETTINGS'
Build settings for action build and target IMApp:
    IM_API_BASE_URL = https://im.example.com
    IM_TCP_HOST = im.example.com
    IM_TCP_PORT = 9000
SETTINGS
    ;;
  unresolved)
    cat <<'SETTINGS'
Build settings for action build and target IMApp:
    IM_API_BASE_URL = $(IM_API_BASE_URL)
    IM_TCP_HOST = $(IM_TCP_HOST)
    IM_TCP_PORT = $(IM_TCP_PORT)
SETTINGS
    ;;
  *)
    printf 'unknown fake case: %s\n' "${FAKE_XCODEBUILD_CASE}" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "${fake_xcodebuild}"

  PATH="${tmpdir}:${PATH}" IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST=false "${BASH_SOURCE[0]}" >/dev/null

  public_log="${tmpdir}/public.log"
  if PATH="${tmpdir}:${PATH}" FAKE_XCODEBUILD_CASE=public IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST=false "${BASH_SOURCE[0]}" >"${public_log}" 2>&1; then
    printf 'debug-network-defaults-self-test result=fail reason=public_debug_defaults_not_rejected\n' >&2
    exit 1
  fi
  if ! grep -q "debug_api_must_be_local_http" "${public_log}"; then
    printf 'debug-network-defaults-self-test result=fail reason=public_debug_failure_reason_missing\n' >&2
    sed -n '1,20p' "${public_log}" >&2 || true
    exit 1
  fi

  unresolved_log="${tmpdir}/unresolved.log"
  if PATH="${tmpdir}:${PATH}" FAKE_XCODEBUILD_CASE=unresolved IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST=false "${BASH_SOURCE[0]}" >"${unresolved_log}" 2>&1; then
    printf 'debug-network-defaults-self-test result=fail reason=unresolved_debug_defaults_not_rejected\n' >&2
    exit 1
  fi
  if ! grep -q "unresolved_IM_API_BASE_URL" "${unresolved_log}"; then
    printf 'debug-network-defaults-self-test result=fail reason=unresolved_debug_failure_reason_missing\n' >&2
    sed -n '1,20p' "${unresolved_log}" >&2 || true
    exit 1
  fi

  printf 'debug-network-defaults-self-test result=pass\n'
  exit 0
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  printf 'debug-network-defaults result=skip reason=xcodebuild_not_found\n' >&2
  exit 0
fi

build_settings_file="$(mktemp)"
trap 'rm -f "${build_settings_file}"' EXIT

xcodebuild \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -showBuildSettings >"${build_settings_file}"

python3 - "${build_settings_file}" "${EXPECTED_API_BASE_URL}" "${EXPECTED_TCP_HOST}" "${EXPECTED_TCP_PORT}" <<'PY'
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

settings_file, expected_api, expected_host, expected_port = sys.argv[1:5]
text = Path(settings_file).read_text(encoding="utf-8")
settings = {}
for line in text.splitlines():
    match = re.match(r"\s*(IM_API_BASE_URL|IM_TCP_HOST|IM_TCP_PORT)\s*=\s*(.*?)\s*$", line)
    if match:
        settings[match.group(1)] = match.group(2)

errors = []
for key in ("IM_API_BASE_URL", "IM_TCP_HOST", "IM_TCP_PORT"):
    if key not in settings:
        errors.append(f"missing_{key}")
    elif "$(" in settings[key] or ")" in settings[key]:
        errors.append(f"unresolved_{key}:{settings[key]}")

api = settings.get("IM_API_BASE_URL", "")
host = settings.get("IM_TCP_HOST", "")
port = settings.get("IM_TCP_PORT", "")

if api and api != expected_api:
    errors.append(f"unexpected_IM_API_BASE_URL:{api}:expected_{expected_api}")
if host and host != expected_host:
    errors.append(f"unexpected_IM_TCP_HOST:{host}:expected_{expected_host}")
if port and port != expected_port:
    errors.append(f"unexpected_IM_TCP_PORT:{port}:expected_{expected_port}")

if api:
    parsed = urlsplit(api)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost"}:
        errors.append(f"debug_api_must_be_local_http:{api}")

if host and host not in {"127.0.0.1", "localhost", "::1"}:
    errors.append(f"debug_tcp_host_must_be_local:{host}")

if errors:
    print(
        "debug-network-defaults result=fail "
        f"configuration={settings!r} errors={','.join(errors)}",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    "debug-network-defaults result=pass "
    f"apiBaseURL={api} tcpHost={host} tcpPort={port}"
)
PY
