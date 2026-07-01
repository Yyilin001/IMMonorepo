#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
BASE_URL="${BASE_URL:-}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${IM_PUBLIC_BASE_URL:-}}"
METRICS_BASE_URL="${METRICS_BASE_URL:-}"
ACCOUNT_FILE="${ACCOUNT_FILE:-${IM_ACCOUNT_FILE:-}}"
explicit_smoke_email="${IM_EMAIL:-${IM_SMOKE_EMAIL:-}}"
explicit_smoke_password="${IM_PASSWORD:-${IM_SMOKE_PASSWORD:-}}"
IM_EMAIL="${IM_EMAIL:-${IM_SMOKE_EMAIL:-demo@example.com}}"
IM_PASSWORD="${IM_PASSWORD:-${IM_SMOKE_PASSWORD:-password1234}}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-10}"
INTERNAL_SECRET="${IM_INTERNAL_SHARED_SECRET:-}"
ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
SMOKE_ENTRYPOINT_SELF_TEST="${SMOKE_ENTRYPOINT_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_smoke_base_url() {
  if [[ -n "${BASE_URL}" ]]; then
    printf '%s\n' "${BASE_URL}"
  elif [[ -n "${PUBLIC_BASE_URL}" ]]; then
    printf '%s\n' "${PUBLIC_BASE_URL}"
  else
    printf 'http://127.0.0.1:%s\n' "${HTTP_PORT}"
  fi
}

resolve_metrics_base_url() {
  if [[ -n "${METRICS_BASE_URL}" ]]; then
    printf '%s\n' "${METRICS_BASE_URL}"
  else
    printf 'http://127.0.0.1:%s\n' "${HTTP_PORT}"
  fi
}

app_env="${APP_ENV:-}"
if [[ -z "${app_env}" && -f "${ENV_FILE}" ]]; then
  app_env="$(awk -F= '$1 == "APP_ENV" { print $2; exit }' "${ENV_FILE}")"
fi
app_env="${app_env:-development}"
BASE_URL="$(resolve_smoke_base_url)"
METRICS_BASE_URL="$(resolve_metrics_base_url)"

if bool_enabled "${SMOKE_ENTRYPOINT_SELF_TEST}"; then
  actual="$(BASE_URL= PUBLIC_BASE_URL=http://smoke-public.example.test:8080 HTTP_PORT=18080 resolve_smoke_base_url)"
  [[ "${actual}" == "http://smoke-public.example.test:8080" ]] || {
    printf 'entrypoint-smoke-self-test result=fail reason=public_base_url_resolution expected=http://smoke-public.example.test:8080 actual=%s\n' "${actual}" >&2
    exit 1
  }
  actual="$(BASE_URL=http://explicit-smoke.example.test:8080 PUBLIC_BASE_URL=http://smoke-public.example.test:8080 HTTP_PORT=18080 resolve_smoke_base_url)"
  [[ "${actual}" == "http://explicit-smoke.example.test:8080" ]] || {
    printf 'entrypoint-smoke-self-test result=fail reason=explicit_base_url_precedence expected=http://explicit-smoke.example.test:8080 actual=%s\n' "${actual}" >&2
    exit 1
  }
  actual="$(BASE_URL= PUBLIC_BASE_URL= HTTP_PORT=18080 resolve_smoke_base_url)"
  [[ "${actual}" == "http://127.0.0.1:18080" ]] || {
    printf 'entrypoint-smoke-self-test result=fail reason=loopback_fallback expected=http://127.0.0.1:18080 actual=%s\n' "${actual}" >&2
    exit 1
  }
  actual="$(METRICS_BASE_URL= HTTP_PORT=18080 resolve_metrics_base_url)"
  [[ "${actual}" == "http://127.0.0.1:18080" ]] || {
    printf 'entrypoint-smoke-self-test result=fail reason=metrics_loopback_default expected=http://127.0.0.1:18080 actual=%s\n' "${actual}" >&2
    exit 1
  }
  actual="$(METRICS_BASE_URL=http://metrics-local.example.test:8080 HTTP_PORT=18080 resolve_metrics_base_url)"
  [[ "${actual}" == "http://metrics-local.example.test:8080" ]] || {
    printf 'entrypoint-smoke-self-test result=fail reason=metrics_base_url_override expected=http://metrics-local.example.test:8080 actual=%s\n' "${actual}" >&2
    exit 1
  }
  printf 'entrypoint-smoke-self-test result=pass\n'
  exit 0
fi

if [[ "${app_env}" == "production" && -z "${ACCOUNT_FILE}" ]]; then
  if [[ -z "${explicit_smoke_email//[[:space:]]/}" || -z "${explicit_smoke_password//[[:space:]]/}" ]]; then
    printf 'entrypoint-smoke result=fail reason=production_requires_explicit_smoke_account\n' >&2
    printf 'Set IM_SMOKE_EMAIL and IM_SMOKE_PASSWORD, or pass ACCOUNT_FILE with a dedicated smoke account.\n' >&2
    exit 1
  fi
fi

if [[ -z "${INTERNAL_SECRET}" && -f "${ENV_FILE}" ]]; then
  INTERNAL_SECRET="$(awk -F= '$1 == "IM_INTERNAL_SHARED_SECRET" { print $2; exit }' "${ENV_FILE}")"
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

request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local token="${4:-}"
  local secret="${5:-}"
  local body_file headers_file status rc=0
  body_file="$(mktemp)"
  headers_file="$(mktemp)"
  local args=(-sS --max-time "${REQUEST_TIMEOUT_SECONDS}" -D "${headers_file}" -o "${body_file}" -w "%{http_code}" -X "${method}")
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "${body}")
  fi
  if [[ -n "${token}" ]]; then
    args+=(-H "Authorization: Bearer ${token}")
  fi
  if [[ -n "${secret}" ]]; then
    args+=(-H "X-IM-Internal-Secret: ${secret}")
  fi
  status="$(curl "${args[@]}" "${url}")" || rc=$?
  printf '%s %s %s\n' "${status:-000}" "${rc}" "${body_file}"
  rm -f "${headers_file}"
}

email="$(first_account_email)"
password="$(first_account_password)"
login_payload="$(
  python3 - "${email}" "${password}" <<'PY'
import json
import sys

email, password = sys.argv[1:3]
print(json.dumps({
    "email": email,
    "password": password,
    "device": {
        "deviceID": "ubuntu-entrypoint-smoke",
        "deviceName": "ubuntu-entrypoint-smoke",
        "platform": "deploy-smoke",
        "appVersion": "deploy-smoke",
    },
}, separators=(",", ":")))
PY
)"

printf 'entrypoint-smoke baseURL=%s metricsBaseURL=%s account=%s\n' "${BASE_URL%/}" "${METRICS_BASE_URL%/}" "${email}"

read -r login_status login_rc login_body < <(request POST "${BASE_URL%/}/api/auth/login" "${login_payload}")
printf 'entrypoint-smoke step=login status=%s curlExit=%s\n' "${login_status}" "${login_rc}"
if [[ "${login_rc}" != "0" || "${login_status}" != "200" ]]; then
  printf 'entrypoint-smoke step=login body=' >&2
  tr '\r\n' '  ' < "${login_body}" | cut -c 1-240 >&2 || true
  printf '\n' >&2
  rm -f "${login_body}"
  exit 1
fi

access_token="$(
  python3 - "${login_body}" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(data.get("accessToken", ""))
PY
)"
rm -f "${login_body}"
if [[ -z "${access_token}" ]]; then
  printf 'entrypoint-smoke step=login reason=missing_access_token\n' >&2
  exit 1
fi

read -r me_status me_rc me_body < <(request GET "${BASE_URL%/}/api/me" "" "${access_token}")
printf 'entrypoint-smoke step=me status=%s curlExit=%s\n' "${me_status}" "${me_rc}"
rm -f "${me_body}"
if [[ "${me_rc}" != "0" || "${me_status}" != "200" ]]; then
  exit 1
fi

if [[ -n "${INTERNAL_SECRET}" ]]; then
  read -r metrics_status metrics_rc metrics_body < <(request GET "${METRICS_BASE_URL%/}/internal/metrics" "" "" "${INTERNAL_SECRET}")
  printf 'entrypoint-smoke step=metrics status=%s curlExit=%s\n' "${metrics_status}" "${metrics_rc}"
  rm -f "${metrics_body}"
  if [[ "${metrics_rc}" != "0" || "${metrics_status}" != "200" ]]; then
    exit 1
  fi
else
  printf 'entrypoint-smoke step=metrics status=skipped reason=missing_internal_secret\n'
fi

printf 'entrypoint-smoke result=pass\n'
