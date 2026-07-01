#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SERVICE_NAME="${1:-imserver-operational-audit.service}"
AUDIT_ALERT_SELF_TEST="${AUDIT_ALERT_SELF_TEST:-false}"
AUDIT_ALERT_WEBHOOK_URL="${AUDIT_ALERT_WEBHOOK_URL:-}"
AUDIT_ALERT_WEBHOOK_HEADER="${AUDIT_ALERT_WEBHOOK_HEADER:-}"
AUDIT_ALERT_ALLOW_INSECURE_HTTP="${AUDIT_ALERT_ALLOW_INSECURE_HTTP:-false}"
AUDIT_ALERT_REDACT_LOG_TAIL="${AUDIT_ALERT_REDACT_LOG_TAIL:-true}"
AUDIT_ALERT_LOG_FILE="${AUDIT_ALERT_LOG_FILE:-${IMSERVER_LOG_DIR}/operational-audit.log}"
AUDIT_ALERT_LOG_LINES="${AUDIT_ALERT_LOG_LINES:-120}"
AUDIT_ALERT_TIMEOUT_SECONDS="${AUDIT_ALERT_TIMEOUT_SECONDS:-10}"
AUDIT_ALERT_HOST="${AUDIT_ALERT_HOST:-$(hostname)}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

alert_webhook_url_policy_reason() {
  python3 - "${1:-}" "${AUDIT_ALERT_ALLOW_INSECURE_HTTP}" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit

url = (sys.argv[1] or "").strip()
allow_insecure_http = (sys.argv[2] or "").lower() in {"1", "true", "yes", "on"}
parsed = urlsplit(url)
scheme = (parsed.scheme or "").lower()
host = (parsed.hostname or "").strip().strip("[]").lower()
if scheme not in {"http", "https"}:
    print("invalid_scheme")
    raise SystemExit(0)
if not host:
    print("missing_host")
    raise SystemExit(0)
if host in {"localhost", "ip6-localhost"} or host.endswith(".local"):
    print("local_host")
    raise SystemExit(0)
try:
    ipaddress.ip_address(host)
except ValueError:
    pass
else:
    print("ip_literal")
    raise SystemExit(0)
if "." not in host:
    print("single_label")
    raise SystemExit(0)
placeholder_hosts = {"example.com", "example.net", "example.org", "yourdomain.com"}
placeholder_suffixes = (
    ".example.com",
    ".example.net",
    ".example.org",
    ".yourdomain.com",
    ".test",
    ".invalid",
)
if host in placeholder_hosts or any(host.endswith(suffix) for suffix in placeholder_suffixes):
    print("placeholder_domain")
    raise SystemExit(0)
if scheme == "http":
    print("ok" if allow_insecure_http else "insecure_http")
    raise SystemExit(0)
print("ok")
PY
}

validate_alert_config() {
  if [[ ! "${AUDIT_ALERT_LOG_LINES}" =~ ^[0-9]+$ ]] || (( AUDIT_ALERT_LOG_LINES < 1 )); then
    printf 'operational-alert result=failed reason=invalid_log_lines value=%s service=%s\n' \
      "${AUDIT_ALERT_LOG_LINES}" \
      "${SERVICE_NAME}" >&2
    return 1
  fi
  if [[ ! "${AUDIT_ALERT_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( AUDIT_ALERT_TIMEOUT_SECONDS < 1 )); then
    printf 'operational-alert result=failed reason=invalid_timeout value=%s service=%s\n' \
      "${AUDIT_ALERT_TIMEOUT_SECONDS}" \
      "${SERVICE_NAME}" >&2
    return 1
  fi
  if [[ -n "${AUDIT_ALERT_WEBHOOK_URL}" ]]; then
    local url_reason
    url_reason="$(alert_webhook_url_policy_reason "${AUDIT_ALERT_WEBHOOK_URL}")"
    if [[ "${url_reason}" != "ok" ]]; then
      printf 'operational-alert result=failed reason=invalid_webhook_url urlReason=%s service=%s hint=use_https_webhook_or_set_AUDIT_ALERT_ALLOW_INSECURE_HTTP_true_for_bootstrap\n' \
        "${url_reason}" \
        "${SERVICE_NAME}" >&2
      return 1
    fi
  fi
}

if bool_enabled "${AUDIT_ALERT_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  mkdir -p "${self_test_dir}/bin"
  cat >"${self_test_dir}/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${AUDIT_ALERT_SELF_TEST_CURL_ARGS}"
for arg in "$@"; do
  case "${arg}" in
    @*)
      cat "${arg#@}" >"${AUDIT_ALERT_SELF_TEST_PAYLOAD}"
      ;;
  esac
done
exit 0
SH
  chmod +x "${self_test_dir}/bin/curl"
  printf 'first line\nAuthorization: Bearer should-not-leak\nJWT_SECRETS=active:should-not-leak\npassword=should-not-leak\nsecond line\n' >"${self_test_dir}/alert.log"
  AUDIT_ALERT_SELF_TEST=false \
  AUDIT_ALERT_WEBHOOK_URL="https://alerts.myim-prod.com/imserver" \
  AUDIT_ALERT_WEBHOOK_HEADER="Authorization: Bearer self-test-token" \
  AUDIT_ALERT_LOG_FILE="${self_test_dir}/alert.log" \
  AUDIT_ALERT_LOG_LINES=2 \
  AUDIT_ALERT_TIMEOUT_SECONDS=3 \
  AUDIT_ALERT_HOST="self-test-host" \
  AUDIT_ALERT_SELF_TEST_CURL_ARGS="${self_test_dir}/curl.args" \
  AUDIT_ALERT_SELF_TEST_PAYLOAD="${self_test_dir}/payload.json" \
  PATH="${self_test_dir}/bin:${PATH}" \
    bash "${BASH_SOURCE[0]}" "imserver-self-test.service" >"${self_test_dir}/send.log"
  grep -Fq 'operational-alert result=sent service=imserver-self-test.service' "${self_test_dir}/send.log" || {
    printf 'operational_alert_self_test result=fail reason=send_output_missing\n' >&2
    exit 1
  }
  grep -Fq 'Authorization: Bearer self-test-token' "${self_test_dir}/curl.args" || {
    printf 'operational_alert_self_test result=fail reason=header_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/payload.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
expected = {
    "source": "imserver-operational-alert",
    "severity": "critical",
    "service": "imserver-self-test.service",
    "host": "self-test-host",
    "logFile": None,
}
for key, value in expected.items():
    if key == "logFile":
        if not str(payload.get(key) or "").endswith("/alert.log"):
            raise SystemExit(f"operational_alert_self_test result=fail reason={key}_mismatch")
    elif payload.get(key) != value:
        raise SystemExit(f"operational_alert_self_test result=fail reason={key}_mismatch")
log_tail = str(payload.get("logTail") or "")
if "second line" not in log_tail:
    raise SystemExit("operational_alert_self_test result=fail reason=log_tail_missing")
for forbidden in ("Bearer should-not-leak", "active:should-not-leak", "password=should-not-leak"):
    if forbidden in log_tail:
        raise SystemExit("operational_alert_self_test result=fail reason=secret_not_redacted")
if "[REDACTED]" not in log_tail:
    raise SystemExit("operational_alert_self_test result=fail reason=redaction_marker_missing")
if payload.get("logTailRedacted") is not True:
    raise SystemExit("operational_alert_self_test result=fail reason=redaction_flag_missing")
if "timestamp" not in payload:
    raise SystemExit("operational_alert_self_test result=fail reason=timestamp_missing")
PY
  if AUDIT_ALERT_SELF_TEST=false \
    AUDIT_ALERT_WEBHOOK_URL="http://alerts.myim-prod.com/imserver" \
    AUDIT_ALERT_LOG_FILE="${self_test_dir}/alert.log" \
    AUDIT_ALERT_SELF_TEST_CURL_ARGS="${self_test_dir}/curl-insecure.args" \
    AUDIT_ALERT_SELF_TEST_PAYLOAD="${self_test_dir}/payload-insecure.json" \
    PATH="${self_test_dir}/bin:${PATH}" \
      bash "${BASH_SOURCE[0]}" "imserver-insecure-alert.service" >"${self_test_dir}/insecure-send.log" 2>&1; then
    printf 'operational_alert_self_test result=fail reason=insecure_http_webhook_accepted\n' >&2
    exit 1
  fi
  grep -Fq 'urlReason=insecure_http' "${self_test_dir}/insecure-send.log" || {
    printf 'operational_alert_self_test result=fail reason=insecure_http_reason_missing\n' >&2
    exit 1
  }
  if AUDIT_ALERT_SELF_TEST=false \
    AUDIT_ALERT_WEBHOOK_URL="https://alerts.example.test/imserver" \
    AUDIT_ALERT_LOG_FILE="${self_test_dir}/alert.log" \
    AUDIT_ALERT_SELF_TEST_CURL_ARGS="${self_test_dir}/curl-placeholder.args" \
    AUDIT_ALERT_SELF_TEST_PAYLOAD="${self_test_dir}/payload-placeholder.json" \
    PATH="${self_test_dir}/bin:${PATH}" \
      bash "${BASH_SOURCE[0]}" "imserver-placeholder-alert.service" >"${self_test_dir}/placeholder-send.log" 2>&1; then
    printf 'operational_alert_self_test result=fail reason=placeholder_https_webhook_accepted\n' >&2
    exit 1
  fi
  grep -Fq 'urlReason=placeholder_domain' "${self_test_dir}/placeholder-send.log" || {
    printf 'operational_alert_self_test result=fail reason=placeholder_https_reason_missing\n' >&2
    exit 1
  }
  AUDIT_ALERT_SELF_TEST=false \
  AUDIT_ALERT_WEBHOOK_URL="http://alerts.myim-prod.com/imserver" \
  AUDIT_ALERT_ALLOW_INSECURE_HTTP=true \
  AUDIT_ALERT_LOG_FILE="${self_test_dir}/alert.log" \
  AUDIT_ALERT_LOG_LINES=1 \
  AUDIT_ALERT_SELF_TEST_CURL_ARGS="${self_test_dir}/curl-insecure-allowed.args" \
  AUDIT_ALERT_SELF_TEST_PAYLOAD="${self_test_dir}/payload-insecure-allowed.json" \
  PATH="${self_test_dir}/bin:${PATH}" \
    bash "${BASH_SOURCE[0]}" "imserver-insecure-allowed-alert.service" >"${self_test_dir}/insecure-allowed-send.log"
  grep -Fq 'operational-alert result=sent service=imserver-insecure-allowed-alert.service' "${self_test_dir}/insecure-allowed-send.log" || {
    printf 'operational_alert_self_test result=fail reason=insecure_http_override_rejected\n' >&2
    exit 1
  }
  if AUDIT_ALERT_SELF_TEST=false \
    AUDIT_ALERT_WEBHOOK_URL="http://alerts.example.test/imserver" \
    AUDIT_ALERT_ALLOW_INSECURE_HTTP=true \
    AUDIT_ALERT_LOG_FILE="${self_test_dir}/alert.log" \
    AUDIT_ALERT_SELF_TEST_CURL_ARGS="${self_test_dir}/curl-insecure-placeholder.args" \
    AUDIT_ALERT_SELF_TEST_PAYLOAD="${self_test_dir}/payload-insecure-placeholder.json" \
    PATH="${self_test_dir}/bin:${PATH}" \
      bash "${BASH_SOURCE[0]}" "imserver-insecure-placeholder-alert.service" >"${self_test_dir}/insecure-placeholder-send.log" 2>&1; then
    printf 'operational_alert_self_test result=fail reason=insecure_placeholder_webhook_accepted\n' >&2
    exit 1
  fi
  grep -Fq 'urlReason=placeholder_domain' "${self_test_dir}/insecure-placeholder-send.log" || {
    printf 'operational_alert_self_test result=fail reason=insecure_placeholder_reason_missing\n' >&2
    exit 1
  }
  printf 'operational_alert_self_test result=pass\n'
  exit 0
fi

validate_alert_config

if [[ -z "${AUDIT_ALERT_WEBHOOK_URL}" ]]; then
  printf 'operational-alert result=skipped reason=missing_webhook service=%s\n' "${SERVICE_NAME}"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  printf 'operational-alert result=skipped reason=curl_missing service=%s\n' "${SERVICE_NAME}" >&2
  exit 0
fi

log_tail="$(
  if [[ -f "${AUDIT_ALERT_LOG_FILE}" ]]; then
    tail -n "${AUDIT_ALERT_LOG_LINES}" "${AUDIT_ALERT_LOG_FILE}" 2>/dev/null || true
  else
    printf 'log file missing: %s\n' "${AUDIT_ALERT_LOG_FILE}"
  fi
)"

payload_file="$(mktemp)"
trap 'rm -f "${payload_file}"' EXIT

python3 - "${SERVICE_NAME}" "${AUDIT_ALERT_HOST}" "${AUDIT_ALERT_LOG_FILE}" "${AUDIT_ALERT_REDACT_LOG_TAIL}" "${log_tail}" >"${payload_file}" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

service, host, log_file, redact_log_tail, log_tail = sys.argv[1:6]

def redact(text: str) -> str:
    patterns = [
        (re.compile(r"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+"), r"\1[REDACTED]"),
        (re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{12,}"), r"\1[REDACTED]"),
        (re.compile(r"(?i)\b((?:jwt_)?secrets?|(?:access_?|refresh_?)?tokens?|passwords?|passphrases?|api[_-]?keys?|secret[_-]?keys?)\s*[:=]\s*([^,\s]+)"), r"\1=[REDACTED]"),
        (re.compile(r"(?i)\b((?:database|redis|kafka|s3|opensearch)[_-]?(?:url|password|secret|token|key))\s*[:=]\s*([^,\s]+)"), r"\1=[REDACTED]"),
    ]
    redacted = text
    for pattern, replacement in patterns:
        redacted = pattern.sub(replacement, redacted)
    return redacted

safe_log_tail = redact(log_tail) if redact_log_tail.lower() in {"1", "true", "yes", "on"} else log_tail
print(json.dumps({
    "source": "imserver-operational-alert",
    "severity": "critical",
    "service": service,
    "host": host,
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "message": f"{service} failed on {host}",
    "logFile": log_file,
    "logTail": safe_log_tail[-12000:],
    "logTailRedacted": redact_log_tail.lower() in {"1", "true", "yes", "on"},
}, separators=(",", ":")))
PY

curl_args=(
  -fsS
  --connect-timeout "${AUDIT_ALERT_TIMEOUT_SECONDS}"
  --max-time "${AUDIT_ALERT_TIMEOUT_SECONDS}"
  -H "Content-Type: application/json"
  --data-binary "@${payload_file}"
  "${AUDIT_ALERT_WEBHOOK_URL}"
)
if [[ -n "${AUDIT_ALERT_WEBHOOK_HEADER}" ]]; then
  curl_args=(-H "${AUDIT_ALERT_WEBHOOK_HEADER}" "${curl_args[@]}")
fi

if curl "${curl_args[@]}" >/dev/null; then
  printf 'operational-alert result=sent service=%s\n' "${SERVICE_NAME}"
else
  printf 'operational-alert result=failed service=%s\n' "${SERVICE_NAME}" >&2
  exit 1
fi
