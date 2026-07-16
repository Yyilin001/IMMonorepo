#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
SSH_PORT="${SSH_PORT:-22}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/imserver}"
AUDIT_REQUIRE_BACKUP="${AUDIT_REQUIRE_BACKUP:-false}"
AUDIT_VERIFY_LATEST_BACKUP="${AUDIT_VERIFY_LATEST_BACKUP:-true}"
AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS="${AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS:-true}"
AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS="${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS:-172800}"
AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS="${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS:-300}"
AUDIT_REQUIRE_ENTRYPOINT="${AUDIT_REQUIRE_ENTRYPOINT:-true}"
AUDIT_REQUIRE_HOST_SECURITY="${AUDIT_REQUIRE_HOST_SECURITY:-true}"
AUDIT_REQUIRE_TIME_SYNC="${AUDIT_REQUIRE_TIME_SYNC:-true}"
AUDIT_REQUIRE_PRODUCTION_ENV="${AUDIT_REQUIRE_PRODUCTION_ENV:-true}"
AUDIT_REQUIRE_HTTPS_CERTIFICATE="${AUDIT_REQUIRE_HTTPS_CERTIFICATE:-true}"
AUDIT_HTTPS_CERT_MODE="${AUDIT_HTTPS_CERT_MODE:-auto}"
AUDIT_HTTPS_CERT_MIN_VALID_DAYS="${AUDIT_HTTPS_CERT_MIN_VALID_DAYS:-14}"
AUDIT_HTTPS_CERT_FILE="${AUDIT_HTTPS_CERT_FILE:-}"
AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER="${AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER:-true}"
AUDIT_REQUIRE_RESTRICTED_SSH_CIDR="${AUDIT_REQUIRE_RESTRICTED_SSH_CIDR:-true}"
AUDIT_REQUIRE_RDP_CLOSED="${AUDIT_REQUIRE_RDP_CLOSED:-true}"
AUDIT_REQUIRE_SSH_ACCESS="${AUDIT_REQUIRE_SSH_ACCESS:-true}"
AUDIT_REQUIRE_AUDIT_TIMER="${AUDIT_REQUIRE_AUDIT_TIMER:-false}"
AUDIT_REQUIRE_RESTORE_DRILL_TIMER="${AUDIT_REQUIRE_RESTORE_DRILL_TIMER:-false}"
AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS="${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS:-false}"
AUDIT_RESTORE_DRILL_RECEIPT_FILE="${AUDIT_RESTORE_DRILL_RECEIPT_FILE:-/var/lib/imserver/restore-drill/latest.json}"
AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS="${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS:-3888000}"
AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS="${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS:-300}"
AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS="${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS:-false}"
AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE:-/var/lib/imserver/offsite-backup/latest.json}"
AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS="${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS:-172800}"
AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS="${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS:-300}"
AUDIT_REQUIRE_RELEASE_MANIFEST="${AUDIT_REQUIRE_RELEASE_MANIFEST:-true}"
AUDIT_REQUIRE_PERFORMANCE_GATE="${AUDIT_REQUIRE_PERFORMANCE_GATE:-}"
AUDIT_REQUIRE_KAFKA_LAG="${AUDIT_REQUIRE_KAFKA_LAG:-}"
AUDIT_KAFKA_LAG_GROUPS="${AUDIT_KAFKA_LAG_GROUPS:-summary-projection-consumer domain-delivery-consumer}"
AUDIT_KAFKA_LAG_MAX_TOTAL="${AUDIT_KAFKA_LAG_MAX_TOTAL:-10000}"
AUDIT_KAFKA_LAG_MAX_PARTITION="${AUDIT_KAFKA_LAG_MAX_PARTITION:-5000}"
AUDIT_KAFKA_LAG_REQUIRE_GROUPS="${AUDIT_KAFKA_LAG_REQUIRE_GROUPS:-true}"
# Comma-separated instance suffixes for multi-node consumer hosts, for example
# realtime_delivery_consumer,domain_delivery_consumer. When set, the audit
# checks these templated units instead of the single-node legacy consumer units.
AUDIT_STREAM_CONSUMER_INSTANCE_UNITS="${AUDIT_STREAM_CONSUMER_INSTANCE_UNITS:-}"
AUDIT_REQUIRE_CLOUD_SECURITY_GROUP="${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP:-}"
AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE="${AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE:-${IMSERVER_ETC_DIR}/cloud-security-group.json}"
AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}"
AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-}"
AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-}"
AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}"
AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}"
AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}"
AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}"
AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}"
AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}"
AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT:-}"
AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json}"
AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-86400}"
AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${ALIYUN_SECURITY_GROUP_ID:-}}"
AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${ALIYUN_REGION_ID:-}}"
AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}}"
AUDIT_REQUIRE_TOPOLOGY_SMOKE="${AUDIT_REQUIRE_TOPOLOGY_SMOKE:-}"
AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON="${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON:-/var/lib/imserver/production-smoke/latest-production-smoke.json}"
AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS="${AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS:-86400}"
AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS="${AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS:-300}"
AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS="${AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS:-true}"
AUDIT_TOPOLOGY_SMOKE_VERIFIER="${AUDIT_TOPOLOGY_SMOKE_VERIFIER:-${SCRIPT_DIR}/../../IMServer/scripts/verify_production_smoke.py}"
AUDIT_REQUIRE_ALERT_WEBHOOK="${AUDIT_REQUIRE_ALERT_WEBHOOK:-false}"
AUDIT_REQUIRE_ALERT_LOG_REDACTION="${AUDIT_REQUIRE_ALERT_LOG_REDACTION:-}"
AUDIT_ALERT_ENV_FILE="${AUDIT_ALERT_ENV_FILE:-${IMSERVER_ETC_DIR}/operational-alert.env}"
AUDIT_ALERT_ALLOW_INSECURE_HTTP="${AUDIT_ALERT_ALLOW_INSECURE_HTTP:-}"
AUDIT_ALERT_REDACT_LOG_TAIL="${AUDIT_ALERT_REDACT_LOG_TAIL:-}"
AUDIT_DEFAULTS_SELF_TEST="${AUDIT_DEFAULTS_SELF_TEST:-false}"
AUDIT_UNIT_SELF_TEST="${AUDIT_UNIT_SELF_TEST:-false}"
AUDIT_PERFORMANCE_SUMMARY_SELF_TEST="${AUDIT_PERFORMANCE_SUMMARY_SELF_TEST:-false}"
AUDIT_SYSTEMD_DIR="${AUDIT_SYSTEMD_DIR:-/etc/systemd/system}"
AUDIT_PERFORMANCE_GATE_JSON="${AUDIT_PERFORMANCE_GATE_JSON:-/var/lib/imserver/performance/production-gate.json}"
AUDIT_PERFORMANCE_GATE_PROFILE="${AUDIT_PERFORMANCE_GATE_PROFILE:-normal-product-baseline}"
AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS="${AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS:-604800}"
AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT="${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT:-false}"
AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT="${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT:-false}"
AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL="${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL:-}"
AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST="${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST:-}"
AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT="${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT:-}"
AUDIT_PERFORMANCE_PROFILE_CATALOG="${AUDIT_PERFORMANCE_PROFILE_CATALOG:-${SCRIPT_DIR}/../../IMServer/LoadTests/perf_production_profiles.json}"
AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK="${AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK:-/var/lib/imserver/performance/current-evidence}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS:-true}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS:-}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS:-}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS:-}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP:-true}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS:-}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY:-true}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP:-}"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE:-}"
AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-86400}}"
AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-300}}"
AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}"
AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE:-}"
AUDIT_DISK_MAX_USE_PERCENT="${AUDIT_DISK_MAX_USE_PERCENT:-85}"
AUDIT_REQUIRE_DATASTORE_LOOPBACK="${AUDIT_REQUIRE_DATASTORE_LOOPBACK:-true}"
AUDIT_SS_LISTEN_FIXTURE="${AUDIT_SS_LISTEN_FIXTURE:-}"
AUDIT_REDIS_CONFIG_FILE="${AUDIT_REDIS_CONFIG_FILE:-/etc/redis/redis.conf}"
AUDIT_REQUIRE_NGINX_CONFIG="${AUDIT_REQUIRE_NGINX_CONFIG:-true}"
AUDIT_NGINX_HTTP_CONF_PATH="${AUDIT_NGINX_HTTP_CONF_PATH:-/etc/nginx/conf.d/imserver.conf}"
AUDIT_NGINX_LOCATIONS_CONF_PATH="${AUDIT_NGINX_LOCATIONS_CONF_PATH:-/etc/nginx/snippets/imserver_locations.conf}"
AUDIT_NGINX_SSL_CONF_PATH="${AUDIT_NGINX_SSL_CONF_PATH:-/etc/nginx/conf.d/imserver_ssl.conf}"
AUDIT_NGINX_REQUIRE_SSL="${AUDIT_NGINX_REQUIRE_SSL:-false}"
AUDIT_UFW_STATUS_FIXTURE="${AUDIT_UFW_STATUS_FIXTURE:-}"
AUDIT_UFW_STATUS_NUMBERED_FIXTURE="${AUDIT_UFW_STATUS_NUMBERED_FIXTURE:-}"
failures=0

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

read_env_file_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      found = value
    }
    END {
      if (found != "") {
        print found
      }
    }
  ' "${file}"
}

validate_release_checksum_file() {
  local release_dir="$1"
  local checksum_file="$2"
  python3 - "${release_dir}" "${checksum_file}" <<'PY'
import os
import posixpath
import re
import sys

release_dir, checksum_file = sys.argv[1:3]
allowed = {"bin/IMServer", "release.env", "release-manifest.json"}
digest_re = re.compile(r"^[0-9a-fA-F]{64}$")
seen = set()

with open(checksum_file, encoding="utf-8") as handle:
    for lineno, raw in enumerate(handle, start=1):
        line = raw.rstrip("\n")
        if not line:
            raise SystemExit(f"empty_line line={lineno}")
        if line.startswith("\\"):
            raise SystemExit(f"escaped_filename_syntax line={lineno}")
        if len(line) < 67 or line[64] != " " or line[65] not in (" ", "*"):
            raise SystemExit(f"invalid_line_format line={lineno}")
        digest = line[:64]
        name = line[66:]
        if not digest_re.match(digest):
            raise SystemExit(f"invalid_digest line={lineno}")
        normalized = posixpath.normpath(name)
        if not name or name.startswith("/") or normalized == ".." or normalized.startswith("../") or "/../" in name or normalized != name:
            raise SystemExit(f"unsafe_path line={lineno} file={name}")
        if name not in allowed:
            raise SystemExit(f"unexpected_file line={lineno} file={name}")
        if name in seen:
            raise SystemExit(f"duplicate_file file={name}")
        if not os.path.isfile(os.path.join(release_dir, name)):
            raise SystemExit(f"missing_file file={name}")
        seen.add(name)

missing = sorted(allowed - seen)
if missing:
    raise SystemExit(f"missing_expected_files files={','.join(missing)}")

print("audit release-checksum-safety result=pass")
PY
}

audit_env_value() {
  local key="$1"
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local value="${!key:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  read_env_file_value "${env_file}" "${key}"
}

audit_app_env() {
  if [[ -n "${AUDIT_APP_ENV:-}" ]]; then
    printf '%s\n' "${AUDIT_APP_ENV}"
    return 0
  fi
  if [[ -n "${APP_ENV:-}" ]]; then
    printf '%s\n' "${APP_ENV}"
    return 0
  fi
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local file_value
  file_value="$(read_env_file_value "${env_file}" "APP_ENV")"
  if [[ -n "${file_value}" ]]; then
    printf '%s\n' "${file_value}"
    return 0
  fi
  printf '%s\n' "${IMSERVER_RUN_ENV:-development}"
}

audit_host_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
}

audit_scheme_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).scheme or "")
PY
}

audit_public_host_policy_reason() {
  local host="$1"
  python3 - "${host}" <<'PY'
import ipaddress
import sys

host = (sys.argv[1] or "").strip().strip("[]").lower()
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
print("ok")
PY
}

audit_port_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

parsed = urlsplit(sys.argv[1])
if parsed.port:
    print(parsed.port)
elif parsed.scheme == "https":
    print("443")
elif parsed.scheme == "http":
    print("80")
else:
    print("")
PY
}

resolve_audit_public_base_url() {
  local value
  value="$(audit_env_value "PUBLIC_BASE_URL")"
  if [[ -z "${value}" ]]; then
    value="$(audit_env_value "IM_PUBLIC_BASE_URL")"
  fi
  printf '%s\n' "${value}"
}

resolve_audit_expect_base_url() {
  if [[ -n "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL}"
    return 0
  fi
  resolve_audit_public_base_url
}

resolve_audit_expect_tcp_host() {
  if [[ -n "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST}"
    return 0
  fi
  local value
  value="$(audit_env_value "TCP_HOST")"
  if [[ -z "${value}" ]]; then
    value="$(audit_env_value "IM_PUBLIC_HOST")"
  fi
  if [[ -z "${value}" ]]; then
    value="$(audit_host_from_url "$(resolve_audit_public_base_url)")"
  fi
  printf '%s\n' "${value}"
}

resolve_audit_expect_tcp_port() {
  if [[ -n "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT}"
    return 0
  fi
  local value
  value="$(audit_env_value "TCP_PORT")"
  if [[ -z "${value}" ]]; then
    value="$(audit_env_value "IM_TCP_PORT")"
  fi
  printf '%s\n' "${value:-9000}"
}

default_performance_gate_requirement() {
  local app_env
  app_env="$(audit_app_env)"
  case "${app_env}" in
    production) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

resolve_performance_gate_requirement() {
  if [[ -n "${AUDIT_REQUIRE_PERFORMANCE_GATE}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_PERFORMANCE_GATE}"
  else
    default_performance_gate_requirement
  fi
}

resolve_profile_evidence_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_product_plan_evidence_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_product_campaign_evidence_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_product_scenario_suite_evidence_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_current_readiness_evidence_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_production_acceptance_evidence_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE}"
  else
    printf 'false\n'
  fi
}

resolve_alert_webhook_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  else
    printf '%s\n' "${AUDIT_REQUIRE_ALERT_WEBHOOK}"
  fi
}

resolve_alert_log_redaction_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_ALERT_WEBHOOK_EFFECTIVE:-$(resolve_alert_webhook_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_REQUIRE_ALERT_LOG_REDACTION}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_ALERT_LOG_REDACTION}"
  else
    printf 'false\n'
  fi
}

resolve_kafka_lag_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_REQUIRE_KAFKA_LAG}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_KAFKA_LAG}"
  else
    printf 'false\n'
  fi
}

resolve_cloud_security_group_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP}"
  else
    printf 'false\n'
  fi
}

resolve_cloud_security_group_evidence_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE:-$(resolve_cloud_security_group_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}"
  else
    printf 'false\n'
  fi
}

resolve_cloud_security_group_repair_receipt_requirement() {
  if [[ -n "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}"
  elif bool_enabled "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE:-$(resolve_cloud_security_group_requirement)}"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

resolve_topology_smoke_requirement() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_REQUIRE_TOPOLOGY_SMOKE}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_TOPOLOGY_SMOKE}"
  else
    printf 'false\n'
  fi
}

configured_alert_webhook_url() {
  if [[ -n "${AUDIT_ALERT_WEBHOOK_URL:-}" ]]; then
    printf '%s\n' "${AUDIT_ALERT_WEBHOOK_URL}"
    return 0
  fi
  read_env_file_value "${AUDIT_ALERT_ENV_FILE}" "AUDIT_ALERT_WEBHOOK_URL"
}

configured_alert_allow_insecure_http() {
  local value
  if [[ -n "${AUDIT_ALERT_ALLOW_INSECURE_HTTP:-}" ]]; then
    printf '%s\n' "${AUDIT_ALERT_ALLOW_INSECURE_HTTP}"
    return 0
  fi
  value="$(read_env_file_value "${AUDIT_ALERT_ENV_FILE}" "AUDIT_ALERT_ALLOW_INSECURE_HTTP")"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
  else
    printf 'false\n'
  fi
}

configured_alert_redact_log_tail() {
  local value
  if [[ -n "${AUDIT_ALERT_REDACT_LOG_TAIL:-}" ]]; then
    printf '%s\n' "${AUDIT_ALERT_REDACT_LOG_TAIL}"
    return 0
  fi
  value="$(read_env_file_value "${AUDIT_ALERT_ENV_FILE}" "AUDIT_ALERT_REDACT_LOG_TAIL")"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
  else
    printf 'true\n'
  fi
}

alert_webhook_url_policy_reason() {
  local url="$1"
  local scheme host host_reason
  scheme="$(audit_scheme_from_url "${url}")"
  host="$(audit_host_from_url "${url}")"
  if [[ -z "${scheme}" ]]; then
    printf 'invalid_scheme\n'
    return 0
  fi
  if [[ -z "${host}" ]]; then
    printf 'missing_host\n'
    return 0
  fi
  host_reason="$(audit_public_host_policy_reason "${host}")"
  if [[ "${host_reason}" != "ok" ]]; then
    printf '%s\n' "${host_reason}"
    return 0
  fi
  case "${scheme}" in
    https)
      printf 'ok\n'
      ;;
    http)
      if bool_enabled "$(configured_alert_allow_insecure_http)"; then
        printf 'ok\n'
      else
        printf 'insecure_http\n'
      fi
      ;;
    *)
      printf 'invalid_scheme\n'
      ;;
  esac
}

valid_alert_webhook_url() {
  [[ "$(alert_webhook_url_policy_reason "$1")" == "ok" ]]
}

run_defaults_self_test() {
  local actual tmpdir env_file alert_env alert_url
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= default_performance_gate_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=production expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=development AUDIT_REQUIRE_PERFORMANCE_GATE= default_performance_gate_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=development expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false resolve_performance_gate_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=explicit_override expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=false resolve_profile_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=profile_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=false resolve_profile_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_profile_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS= resolve_product_plan_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=production_product_plan_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS= resolve_product_plan_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_product_plan_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false resolve_product_plan_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=product_plan_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS= resolve_product_campaign_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=production_product_campaign_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS= resolve_product_campaign_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_product_campaign_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=false resolve_product_campaign_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=product_campaign_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS= resolve_product_scenario_suite_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=production_product_scenario_suite_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS= resolve_product_scenario_suite_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_product_scenario_suite_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=false resolve_product_scenario_suite_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=product_scenario_suite_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS= resolve_current_readiness_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=production_current_readiness_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS= resolve_current_readiness_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_current_readiness_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=false resolve_current_readiness_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=current_readiness_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE= resolve_production_acceptance_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=production_acceptance_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE= resolve_production_acceptance_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_production_acceptance_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=false resolve_production_acceptance_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=production_acceptance_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_REQUIRE_TOPOLOGY_SMOKE=false resolve_topology_smoke_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=topology_smoke_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_REQUIRE_TOPOLOGY_SMOKE=false resolve_topology_smoke_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_topology_smoke_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_REQUIRE_ALERT_WEBHOOK=false resolve_alert_webhook_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=alert_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_REQUIRE_ALERT_WEBHOOK=false AUDIT_REQUIRE_ALERT_LOG_REDACTION=false resolve_alert_log_redaction_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=alert_log_redaction_false_ignored_when_alert_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_REQUIRE_ALERT_WEBHOOK=false resolve_alert_webhook_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_alert_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_REQUIRE_ALERT_WEBHOOK=false AUDIT_REQUIRE_ALERT_LOG_REDACTION=false resolve_alert_log_redaction_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_alert_log_redaction_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_cloud_security_group_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=cloud_security_group_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_cloud_security_group_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=performance_gate_disabled_cloud_security_group_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE= AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=false AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_cloud_security_group_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=cloud_security_group_evidence_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(AUDIT_APP_ENV=production AUDIT_REQUIRE_PERFORMANCE_GATE=false AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=false AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_cloud_security_group_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=cloud_security_group_evidence_respects_false_when_gate_disabled expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  tmpdir="$(mktemp -d)"
  env_file="${tmpdir}/common.env"
  printf 'APP_ENV=production\n' >"${env_file}"
  printf 'PUBLIC_BASE_URL=https://audit-public.myim-prod.com\n' >>"${env_file}"
  actual="$(AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL= PUBLIC_BASE_URL= ENV_FILE="${env_file}" resolve_audit_expect_base_url)"
  [[ "${actual}" == "https://audit-public.myim-prod.com" ]] || {
    printf 'audit-defaults result=fail case=expect_base_url_from_env expected=https://audit-public.myim-prod.com actual=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  actual="$(AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST= TCP_HOST= IM_PUBLIC_HOST= PUBLIC_BASE_URL= ENV_FILE="${env_file}" resolve_audit_expect_tcp_host)"
  [[ "${actual}" == "audit-public.myim-prod.com" ]] || {
    printf 'audit-defaults result=fail case=expect_tcp_host_from_public_url expected=audit-public.myim-prod.com actual=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  actual="$(AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT= TCP_PORT= IM_TCP_PORT= ENV_FILE="${env_file}" resolve_audit_expect_tcp_port)"
  [[ "${actual}" == "9000" ]] || {
    printf 'audit-defaults result=fail case=expect_tcp_port_default expected=9000 actual=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  rm -rf "${tmpdir}"
  tmpdir="$(mktemp -d)"
  env_file="${tmpdir}/common.env"
  printf 'APP_ENV=production\n' >"${env_file}"
  actual="$(AUDIT_APP_ENV= APP_ENV= ENV_FILE="${env_file}" IMSERVER_RUN_ENV=development default_performance_gate_requirement)"
  rm -rf "${tmpdir}"
  [[ "${actual}" == "true" ]] || {
    printf 'audit-defaults result=fail case=env_file_production expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  tmpdir="$(mktemp -d)"
  alert_env="${tmpdir}/operational-alert.env"
  printf 'AUDIT_ALERT_WEBHOOK_URL=https://alerts.myim-prod.com/imserver\n' >"${alert_env}"
  printf 'AUDIT_ALERT_REDACT_LOG_TAIL=false\n' >>"${alert_env}"
  alert_url="$(AUDIT_ALERT_WEBHOOK_URL= AUDIT_ALERT_ENV_FILE="${alert_env}" configured_alert_webhook_url)"
  actual="$(AUDIT_ALERT_REDACT_LOG_TAIL= AUDIT_ALERT_ENV_FILE="${alert_env}" configured_alert_redact_log_tail)"
  rm -rf "${tmpdir}"
  [[ "${alert_url}" == "https://alerts.myim-prod.com/imserver" ]] || {
    printf 'audit-defaults result=fail case=alert_env_url expected=url actual=%s\n' "${alert_url}" >&2
    return 1
  }
  [[ "${actual}" == "false" ]] || {
    printf 'audit-defaults result=fail case=alert_env_redact_log_tail expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  valid_alert_webhook_url "https://alerts.myim-prod.com/imserver" || {
    printf 'audit-defaults result=fail case=valid_alert_url_rejected\n' >&2
    return 1
  }
  if valid_alert_webhook_url "https://alerts.example.test/imserver"; then
    printf 'audit-defaults result=fail case=placeholder_alert_url_accepted\n' >&2
    return 1
  fi
  if valid_alert_webhook_url "http://alerts.myim-prod.com/imserver"; then
    printf 'audit-defaults result=fail case=insecure_alert_url_accepted\n' >&2
    return 1
  fi
  AUDIT_ALERT_ALLOW_INSECURE_HTTP=true valid_alert_webhook_url "http://alerts.myim-prod.com/imserver" || {
    printf 'audit-defaults result=fail case=insecure_alert_url_override_rejected\n' >&2
    return 1
  }
  if AUDIT_ALERT_ALLOW_INSECURE_HTTP=true valid_alert_webhook_url "http://alerts.example.test/imserver"; then
    printf 'audit-defaults result=fail case=insecure_placeholder_alert_url_accepted\n' >&2
    return 1
  fi
  tmpdir="$(mktemp -d)"
  alert_env="${tmpdir}/operational-alert.env"
  printf 'AUDIT_ALERT_ALLOW_INSECURE_HTTP=true\n' >"${alert_env}"
  AUDIT_ALERT_ALLOW_INSECURE_HTTP= AUDIT_ALERT_ENV_FILE="${alert_env}" valid_alert_webhook_url "http://alerts.myim-prod.com/imserver" || {
    printf 'audit-defaults result=fail case=insecure_alert_url_env_override_rejected\n' >&2
    rm -rf "${tmpdir}"
    return 1
  }
  rm -rf "${tmpdir}"
  if valid_alert_webhook_url "replace-me"; then
    printf 'audit-defaults result=fail case=invalid_alert_url_accepted\n' >&2
    return 1
  fi
  printf 'audit-defaults result=pass\n'
}

if bool_enabled "${AUDIT_DEFAULTS_SELF_TEST}"; then
  run_defaults_self_test
  exit 0
fi

AUDIT_APP_ENV_EFFECTIVE="$(audit_app_env)"
AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE="$(resolve_performance_gate_requirement)"
AUDIT_REQUIRE_ALERT_WEBHOOK_EFFECTIVE="$(resolve_alert_webhook_requirement)"
AUDIT_REQUIRE_ALERT_LOG_REDACTION_EFFECTIVE="$(resolve_alert_log_redaction_requirement)"
AUDIT_REQUIRE_KAFKA_LAG_EFFECTIVE="$(resolve_kafka_lag_requirement)"
AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_cloud_security_group_requirement)"
AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE="$(resolve_cloud_security_group_repair_receipt_requirement)"
AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE="$(resolve_topology_smoke_requirement)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE="$(resolve_profile_evidence_requirement)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE="$(resolve_product_plan_evidence_requirement)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE="$(resolve_product_campaign_evidence_requirement)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE="$(resolve_product_scenario_suite_evidence_requirement)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE="$(resolve_current_readiness_evidence_requirement)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_cloud_security_group_evidence_requirement)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE="$(resolve_production_acceptance_evidence_requirement)"
AUDIT_PUBLIC_BASE_URL_EFFECTIVE="$(resolve_audit_public_base_url)"
AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE="$(resolve_audit_expect_base_url)"
AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE="$(resolve_audit_expect_tcp_host)"
AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="$(resolve_audit_expect_tcp_port)"

fail() {
  printf 'audit=fail check=%s reason=%s\n' "$1" "$2"
  failures=$((failures + 1))
}

validate_performance_gate_public_targets() {
  local public_base_url_scheme public_base_url_port public_base_url_host public_base_url_host_reason
  local expect_base_url_scheme expect_base_url_port expect_base_url_host expect_base_url_host_reason
  local expect_tcp_host_reason
  if ! bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}"; then
    return 0
  fi
  if [[ -z "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}" ]]; then
    fail "performance-gate-target" "public_base_url_missing appEnv=${AUDIT_APP_ENV_EFFECTIVE} requirePerformanceGate=${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE} hint=set_PUBLIC_BASE_URL_or_IM_PUBLIC_BASE_URL"
  else
    public_base_url_scheme="$(audit_scheme_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
    if [[ "${public_base_url_scheme}" != "https" ]]; then
      fail "performance-gate-target" "public_base_url_https_required publicBaseURL=${AUDIT_PUBLIC_BASE_URL_EFFECTIVE} hint=set_PUBLIC_BASE_URL_or_IM_PUBLIC_BASE_URL_to_https_or_disable_gate_for_first_bootstrap"
    fi
    public_base_url_port="$(audit_port_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
    if [[ "${public_base_url_port}" != "443" ]]; then
      fail "performance-gate-target" "public_base_url_default_https_port_required publicBaseURL=${AUDIT_PUBLIC_BASE_URL_EFFECTIVE} port=${public_base_url_port:-<empty>} hint=use_default_https_443_for_long_term_production"
    fi
    public_base_url_host="$(audit_host_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
    public_base_url_host_reason="$(audit_public_host_policy_reason "${public_base_url_host}")"
    if [[ "${public_base_url_host_reason}" != "ok" ]]; then
      fail "performance-gate-target" "public_base_url_domain_required publicBaseURL=${AUDIT_PUBLIC_BASE_URL_EFFECTIVE} host=${public_base_url_host:-<empty>} hostReason=${public_base_url_host_reason} hint=use_a_real_production_domain_not_a_raw_ip_or_placeholder"
    fi
  fi
  if [[ -z "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}" ]]; then
    fail "performance-gate-target" "expect_base_url_missing hint=set_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_or_PUBLIC_BASE_URL"
  else
    expect_base_url_scheme="$(audit_scheme_from_url "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
    if [[ "${expect_base_url_scheme}" != "https" ]]; then
      fail "performance-gate-target" "expect_base_url_https_required expectBaseURL=${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE} hint=bind_production_performance_evidence_to_https_BASE_URL"
    fi
    expect_base_url_port="$(audit_port_from_url "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
    if [[ "${expect_base_url_port}" != "443" ]]; then
      fail "performance-gate-target" "expect_base_url_default_https_port_required expectBaseURL=${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE} port=${expect_base_url_port:-<empty>} hint=bind_production_performance_evidence_to_default_https_443"
    fi
    expect_base_url_host="$(audit_host_from_url "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
    expect_base_url_host_reason="$(audit_public_host_policy_reason "${expect_base_url_host}")"
    if [[ "${expect_base_url_host_reason}" != "ok" ]]; then
      fail "performance-gate-target" "expect_base_url_domain_required expectBaseURL=${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE} host=${expect_base_url_host:-<empty>} hostReason=${expect_base_url_host_reason} hint=bind_production_performance_evidence_to_the_real_https_domain"
    fi
  fi
  if [[ -z "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}" ]]; then
    fail "performance-gate-target" "expect_tcp_host_missing hint=set_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_or_TCP_HOST_or_IM_PUBLIC_HOST_or_PUBLIC_BASE_URL"
  else
    expect_tcp_host_reason="$(audit_public_host_policy_reason "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}")"
    if [[ "${expect_tcp_host_reason}" != "ok" ]]; then
      fail "performance-gate-target" "expect_tcp_host_domain_required tcpHost=${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE} hostReason=${expect_tcp_host_reason} hint=use_a_real_production_tcp_domain_not_a_raw_ip_or_placeholder"
    fi
  fi
  if [[ -z "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE}" ]]; then
    fail "performance-gate-target" "expect_tcp_port_missing hint=set_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_or_TCP_PORT_or_IM_TCP_PORT"
  fi
}

pass() {
  printf 'audit=pass check=%s %s\n' "$1" "${2:-}"
}

check_service() {
  local service="$1"
  if systemctl is-active --quiet "${service}"; then
    pass "service" "name=${service}"
  else
    fail "service" "name=${service}_inactive"
  fi
}

check_timer() {
  local timer="$1"
  if systemctl is-enabled --quiet "${timer}" && systemctl is-active --quiet "${timer}"; then
    pass "timer" "name=${timer}"
  else
    fail "timer" "name=${timer}_not_enabled_or_inactive"
  fi
}

check_unit_contains() {
  local unit_file="$1"
  local needle="$2"
  local check_name="$3"
  local reason="$4"
  if [[ ! -f "${unit_file}" ]]; then
    fail "${check_name}" "unit_$(basename "${unit_file}")_missing"
    return
  fi
  if grep -Fq "${needle}" "${unit_file}"; then
    pass "${check_name}" "unit=$(basename "${unit_file}") field=${reason}"
  else
    fail "${check_name}" "unit_$(basename "${unit_file}")_missing_${reason}"
  fi
}

check_operational_audit_timer_units() {
  local service_file="${AUDIT_SYSTEMD_DIR}/imserver-operational-audit.service"
  local alert_file="${AUDIT_SYSTEMD_DIR}/imserver-operational-alert@.service"
  local timer_file="${AUDIT_SYSTEMD_DIR}/imserver-operational-audit.timer"
  local production_acceptance_receipt_unit_value="${AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
  local production_acceptance_package_unit_value="${AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE}"
  if bool_enabled "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}"; then
    production_acceptance_receipt_unit_value=""
    production_acceptance_package_unit_value=""
  fi
  check_unit_contains "${service_file}" "Environment=BACKUP_ROOT=${BACKUP_ROOT}" "operational-audit-unit" "backup_root"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS=${AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS}" "operational-audit-unit" "latest_backup_freshness"
  check_unit_contains "${service_file}" "Environment=AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS=${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}" "operational-audit-unit" "latest_backup_max_age"
  check_unit_contains "${service_file}" "Environment=AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS=${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS}" "operational-audit-unit" "latest_backup_max_future_skew"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS}" "operational-audit-unit" "restore_drill_freshness"
  check_unit_contains "${service_file}" "Environment=AUDIT_RESTORE_DRILL_RECEIPT_FILE=${AUDIT_RESTORE_DRILL_RECEIPT_FILE}" "operational-audit-unit" "restore_drill_receipt"
  check_unit_contains "${service_file}" "Environment=AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS=${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}" "operational-audit-unit" "restore_drill_max_age"
  check_unit_contains "${service_file}" "Environment=AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS=${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS}" "operational-audit-unit" "restore_drill_max_future_skew"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS}" "operational-audit-unit" "offsite_backup_freshness"
  check_unit_contains "${service_file}" "Environment=AUDIT_OFFSITE_BACKUP_RECEIPT_FILE=${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE}" "operational-audit-unit" "offsite_backup_receipt"
  check_unit_contains "${service_file}" "Environment=AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS=${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}" "operational-audit-unit" "offsite_backup_max_age"
  check_unit_contains "${service_file}" "Environment=AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS=${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS}" "operational-audit-unit" "offsite_backup_max_future_skew"
  check_unit_contains "${service_file}" "Environment=PUBLIC_BASE_URL=" "operational-audit-unit" "public_base_url"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_AUDIT_TIMER=true" "operational-audit-unit" "require_audit_timer"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_TIME_SYNC=${AUDIT_REQUIRE_TIME_SYNC}" "operational-audit-unit" "require_time_sync"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_PRODUCTION_ENV=${AUDIT_REQUIRE_PRODUCTION_ENV}" "operational-audit-unit" "require_production_env"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_HTTPS_CERTIFICATE=${AUDIT_REQUIRE_HTTPS_CERTIFICATE}" "operational-audit-unit" "require_https_certificate"
  check_unit_contains "${service_file}" "Environment=AUDIT_HTTPS_CERT_MODE=${AUDIT_HTTPS_CERT_MODE}" "operational-audit-unit" "https_cert_mode"
  check_unit_contains "${service_file}" "Environment=AUDIT_HTTPS_CERT_MIN_VALID_DAYS=${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}" "operational-audit-unit" "https_cert_min_valid_days"
  check_unit_contains "${service_file}" "Environment=AUDIT_HTTPS_CERT_FILE=${AUDIT_HTTPS_CERT_FILE}" "operational-audit-unit" "https_cert_file"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER=${AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER}" "operational-audit-unit" "require_certbot_renewal_timer"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_RESTRICTED_SSH_CIDR=${AUDIT_REQUIRE_RESTRICTED_SSH_CIDR}" "operational-audit-unit" "require_restricted_ssh_cidr"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_RDP_CLOSED=${AUDIT_REQUIRE_RDP_CLOSED}" "operational-audit-unit" "require_rdp_closed"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_PERFORMANCE_GATE=${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}" "operational-audit-unit" "require_performance_gate"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_KAFKA_LAG=${AUDIT_REQUIRE_KAFKA_LAG_EFFECTIVE}" "operational-audit-unit" "require_kafka_lag"
  check_unit_contains "${service_file}" "Environment=AUDIT_KAFKA_LAG_MAX_TOTAL=${AUDIT_KAFKA_LAG_MAX_TOTAL}" "operational-audit-unit" "kafka_lag_max_total"
  check_unit_contains "${service_file}" "Environment=AUDIT_KAFKA_LAG_MAX_PARTITION=${AUDIT_KAFKA_LAG_MAX_PARTITION}" "operational-audit-unit" "kafka_lag_max_partition"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" "operational-audit-unit" "require_cloud_security_group"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE=${AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE}" "operational-audit-unit" "cloud_security_group_rules_file"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS=${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" "operational-audit-unit" "cloud_security_group_public_client_ports"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS=${AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" "operational-audit-unit" "cloud_security_group_deny_public_ports"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS=${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" "operational-audit-unit" "cloud_security_group_admin_ports"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=${AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" "operational-audit-unit" "cloud_security_group_require_public_client_ports"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=${AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" "operational-audit-unit" "cloud_security_group_rules_max_age"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=${AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" "operational-audit-unit" "cloud_security_group_rules_require_root_owner"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" "operational-audit-unit" "cloud_security_group_allow_temp_http_8080"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP=${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" "operational-audit-unit" "cloud_security_group_allow_public_icmp"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX=${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" "operational-audit-unit" "cloud_security_group_public_broad_ipv4"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX=${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" "operational-audit-unit" "cloud_security_group_public_broad_ipv6"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX=${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" "operational-audit-unit" "cloud_security_group_admin_public_ipv4_min_prefix"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX=${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" "operational-audit-unit" "cloud_security_group_admin_public_ipv6_min_prefix"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}" "operational-audit-unit" "cloud_security_group_repair_receipt_required"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" "operational-audit-unit" "cloud_security_group_repair_receipt_json"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" "operational-audit-unit" "cloud_security_group_repair_receipt_max_age"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" "operational-audit-unit" "cloud_security_group_repair_receipt_expect_sg"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" "operational-audit-unit" "cloud_security_group_repair_receipt_expect_region"
  check_unit_contains "${service_file}" "Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" "operational-audit-unit" "cloud_security_group_repair_receipt_expect_admin_cidr"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_TOPOLOGY_SMOKE=${AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE}" "operational-audit-unit" "topology_smoke_required"
  check_unit_contains "${service_file}" "Environment=AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON=${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON}" "operational-audit-unit" "topology_smoke_receipt_json"
  check_unit_contains "${service_file}" "Environment=AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=${AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}" "operational-audit-unit" "topology_smoke_max_age"
  check_unit_contains "${service_file}" "Environment=AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS=${AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS}" "operational-audit-unit" "topology_smoke_max_future_skew"
  check_unit_contains "${service_file}" "Environment=AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS=${AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS}" "operational-audit-unit" "topology_smoke_require_artifacts"
  check_unit_contains "${service_file}" "Environment=AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS=${AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" "operational-audit-unit" "production_acceptance_max_age"
  check_unit_contains "${service_file}" "Environment=AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS=${AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}" "operational-audit-unit" "production_acceptance_max_future_skew"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_DATASTORE_LOOPBACK=${AUDIT_REQUIRE_DATASTORE_LOOPBACK}" "operational-audit-unit" "require_datastore_loopback"
  check_unit_contains "${service_file}" "Environment=AUDIT_REDIS_CONFIG_FILE=${AUDIT_REDIS_CONFIG_FILE}" "operational-audit-unit" "redis_config_file"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_NGINX_CONFIG=${AUDIT_REQUIRE_NGINX_CONFIG}" "operational-audit-unit" "require_nginx_config"
  check_unit_contains "${service_file}" "Environment=AUDIT_NGINX_HTTP_CONF_PATH=${AUDIT_NGINX_HTTP_CONF_PATH}" "operational-audit-unit" "nginx_http_conf_path"
  check_unit_contains "${service_file}" "Environment=AUDIT_NGINX_LOCATIONS_CONF_PATH=${AUDIT_NGINX_LOCATIONS_CONF_PATH}" "operational-audit-unit" "nginx_locations_conf_path"
  check_unit_contains "${service_file}" "Environment=AUDIT_NGINX_SSL_CONF_PATH=${AUDIT_NGINX_SSL_CONF_PATH}" "operational-audit-unit" "nginx_ssl_conf_path"
  check_unit_contains "${service_file}" "Environment=AUDIT_NGINX_REQUIRE_SSL=${AUDIT_NGINX_REQUIRE_SSL}" "operational-audit-unit" "nginx_require_ssl"
  check_unit_contains "${service_file}" "Environment=AUDIT_REQUIRE_ALERT_WEBHOOK=${AUDIT_REQUIRE_ALERT_WEBHOOK_EFFECTIVE}" "operational-audit-unit" "require_alert_webhook"
  check_unit_contains "${service_file}" "Environment=AUDIT_ALERT_ALLOW_INSECURE_HTTP=${AUDIT_ALERT_ALLOW_INSECURE_HTTP:-false}" "operational-audit-unit" "alert_allow_insecure_http"
  check_unit_contains "${service_file}" "Environment=AUDIT_ALERT_REDACT_LOG_TAIL=${AUDIT_ALERT_REDACT_LOG_TAIL:-true}" "operational-audit-unit" "alert_redact_log_tail"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_GATE_JSON=${AUDIT_PERFORMANCE_GATE_JSON}" "operational-audit-unit" "performance_gate_json"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_GATE_PROFILE=${AUDIT_PERFORMANCE_GATE_PROFILE}" "operational-audit-unit" "performance_gate_profile"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS=${AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS}" "operational-audit-unit" "performance_gate_max_age"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT=${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT}" "operational-audit-unit" "performance_gate_require_current_git"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT=${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}" "operational-audit-unit" "performance_gate_require_clean_git"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL=${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL}" "operational-audit-unit" "performance_gate_expect_base_url"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST=${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST}" "operational-audit-unit" "performance_gate_expect_tcp_host"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT=${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT}" "operational-audit-unit" "performance_gate_expect_tcp_port"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_PROFILE_CATALOG=${AUDIT_PERFORMANCE_PROFILE_CATALOG}" "operational-audit-unit" "performance_profile_catalog"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK=${AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK}" "operational-audit-unit" "performance_evidence_current"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE}" "operational-audit-unit" "performance_evidence_profile_artifacts"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE}" "operational-audit-unit" "performance_evidence_product_plan_artifacts"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE}" "operational-audit-unit" "performance_evidence_product_campaign_artifacts"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE}" "operational-audit-unit" "performance_evidence_product_scenario_suite_artifacts"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}" "operational-audit-unit" "performance_evidence_product_scenario_suite_no_large_group"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE}" "operational-audit-unit" "performance_evidence_current_readiness_artifacts"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}" "operational-audit-unit" "performance_evidence_validation_inventory"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" "operational-audit-unit" "performance_evidence_cloud_security_group"
  check_unit_contains "${service_file}" "Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}" "operational-audit-unit" "performance_evidence_production_acceptance"
  check_unit_contains "${service_file}" "Environment=AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=${production_acceptance_receipt_unit_value}" "operational-audit-unit" "production_acceptance_receipt"
  check_unit_contains "${service_file}" "Environment=AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE=${production_acceptance_package_unit_value}" "operational-audit-unit" "production_acceptance_package"
  check_unit_contains "${service_file}" "ExecStart=/bin/bash ${SCRIPT_DIR}/77_operational_audit.sh" "operational-audit-unit" "audit_exec"
  check_unit_contains "${service_file}" "OnFailure=imserver-operational-alert@%n.service" "operational-audit-unit" "on_failure"
  check_unit_contains "${service_file}" "StandardOutput=append:" "operational-audit-unit" "stdout_log"
  check_unit_contains "${service_file}" "StandardError=append:" "operational-audit-unit" "stderr_log"
  check_unit_contains "${service_file}" "Nice=5" "operational-audit-unit" "nice"
  check_unit_contains "${alert_file}" "EnvironmentFile=-" "operational-alert-unit" "alert_env"
  check_unit_contains "${alert_file}" "ExecStart=/bin/bash ${SCRIPT_DIR}/79_send_operational_alert.sh %I" "operational-alert-unit" "alert_exec"
  check_unit_contains "${timer_file}" "Persistent=true" "operational-audit-timer-unit" "persistent"
  check_unit_contains "${timer_file}" "Unit=imserver-operational-audit.service" "operational-audit-timer-unit" "unit_reference"
}

check_backup_timer_units() {
  local service_file="${AUDIT_SYSTEMD_DIR}/imserver-backup.service"
  local alert_file="${AUDIT_SYSTEMD_DIR}/imserver-backup-alert@.service"
  local timer_file="${AUDIT_SYSTEMD_DIR}/imserver-backup.timer"
  check_unit_contains "${service_file}" "Environment=BACKUP_ROOT=${BACKUP_ROOT}" "backup-unit" "backup_root"
  check_unit_contains "${service_file}" "Environment=BACKUP_RETENTION_DAYS=" "backup-unit" "retention"
  check_unit_contains "${service_file}" "ExecStart=/bin/bash ${SCRIPT_DIR}/80_backup_single_node.sh" "backup-unit" "backup_exec"
  check_unit_contains "${service_file}" "ExecStartPost=/bin/bash ${SCRIPT_DIR}/81_verify_backup.sh" "backup-unit" "verify_exec"
  check_unit_contains "${service_file}" "OnFailure=imserver-backup-alert@%n.service" "backup-unit" "on_failure"
  check_unit_contains "${service_file}" "StandardOutput=append:" "backup-unit" "stdout_log"
  check_unit_contains "${service_file}" "StandardError=append:" "backup-unit" "stderr_log"
  check_unit_contains "${service_file}" "Nice=10" "backup-unit" "nice"
  check_unit_contains "${service_file}" "IOSchedulingClass=best-effort" "backup-unit" "io_scheduling"
  check_unit_contains "${alert_file}" "EnvironmentFile=-" "backup-alert-unit" "alert_env"
  check_unit_contains "${alert_file}" "Environment=AUDIT_ALERT_LOG_FILE=" "backup-alert-unit" "alert_log"
  check_unit_contains "${alert_file}" "ExecStart=/bin/bash ${SCRIPT_DIR}/79_send_operational_alert.sh %I" "backup-alert-unit" "alert_exec"
  check_unit_contains "${timer_file}" "Persistent=true" "backup-timer-unit" "persistent"
  check_unit_contains "${timer_file}" "Unit=imserver-backup.service" "backup-timer-unit" "unit_reference"
}

check_restore_drill_timer_units() {
  local service_file="${AUDIT_SYSTEMD_DIR}/imserver-restore-drill.service"
  local alert_file="${AUDIT_SYSTEMD_DIR}/imserver-restore-drill-alert@.service"
  local timer_file="${AUDIT_SYSTEMD_DIR}/imserver-restore-drill.timer"
  check_unit_contains "${service_file}" "Environment=BACKUP_ROOT=${BACKUP_ROOT}" "restore-drill-unit" "backup_root"
  check_unit_contains "${service_file}" "Environment=BACKUP_DIR=${BACKUP_ROOT}/latest" "restore-drill-unit" "backup_dir"
  check_unit_contains "${service_file}" "Environment=RESTORE_DRILL_KEEP_DB=" "restore-drill-unit" "keep_db"
  check_unit_contains "${service_file}" "Environment=RESTORE_DRILL_RECEIPT_FILE=" "restore-drill-unit" "receipt_file"
  check_unit_contains "${service_file}" "ExecStart=/bin/bash ${SCRIPT_DIR}/82_restore_drill_single_node.sh" "restore-drill-unit" "restore_exec"
  check_unit_contains "${service_file}" "OnFailure=imserver-restore-drill-alert@%n.service" "restore-drill-unit" "on_failure"
  check_unit_contains "${service_file}" "StandardOutput=append:" "restore-drill-unit" "stdout_log"
  check_unit_contains "${service_file}" "StandardError=append:" "restore-drill-unit" "stderr_log"
  check_unit_contains "${service_file}" "Nice=10" "restore-drill-unit" "nice"
  check_unit_contains "${service_file}" "IOSchedulingClass=best-effort" "restore-drill-unit" "io_scheduling"
  check_unit_contains "${alert_file}" "EnvironmentFile=-" "restore-drill-alert-unit" "alert_env"
  check_unit_contains "${alert_file}" "Environment=AUDIT_ALERT_LOG_FILE=" "restore-drill-alert-unit" "alert_log"
  check_unit_contains "${alert_file}" "ExecStart=/bin/bash ${SCRIPT_DIR}/79_send_operational_alert.sh %I" "restore-drill-alert-unit" "alert_exec"
  check_unit_contains "${timer_file}" "Persistent=true" "restore-drill-timer-unit" "persistent"
  check_unit_contains "${timer_file}" "Unit=imserver-restore-drill.service" "restore-drill-timer-unit" "unit_reference"
}

check_command() {
  local command_name="$1"
  if command -v "${command_name}" >/dev/null 2>&1; then
    pass "command" "name=${command_name}"
  else
    fail "command" "name=${command_name}_missing"
    return 1
  fi
}

output_contains() {
  local output="$1"
  local token="$2"
  case "${output}" in
    *"${token}"*) return 0 ;;
    *) return 1 ;;
  esac
}

ufw_status_output() {
  if [[ -n "${AUDIT_UFW_STATUS_FIXTURE}" ]]; then
    printf '%s\n' "${AUDIT_UFW_STATUS_FIXTURE}"
  else
    ufw status 2>/dev/null
  fi
}

ufw_status_numbered_output() {
  if [[ -n "${AUDIT_UFW_STATUS_NUMBERED_FIXTURE}" ]]; then
    printf '%s\n' "${AUDIT_UFW_STATUS_NUMBERED_FIXTURE}"
  else
    ufw status numbered 2>/dev/null
  fi
}

ufw_rule_allows_port() {
  local rules="$1"
  local port="$2"
  awk -v port="${port}" '
    BEGIN { port_re = "(^|[^0-9])" port "(/tcp)?([^0-9]|$)" }
    $0 ~ port_re && $0 ~ /[[:space:]]ALLOW[[:space:]]/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' <<<"${rules}"
}

ufw_line_allows_public_source() {
  local line="$1"
  python3 - "${line}" "${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" "${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" <<'PY'
import ipaddress
import re
import sys

line = sys.argv[1]
ipv4_limit = int(sys.argv[2] or "8")
ipv6_limit = int(sys.argv[3] or "16")
if re.search(r"(^|\s)Anywhere(\s|\(|$)", line):
    raise SystemExit(0)
tokens = re.findall(r"(?<![A-Za-z0-9_.:-])(?:[0-9]{1,3}(?:\.[0-9]{1,3}){3}|[0-9A-Fa-f:]*:[0-9A-Fa-f:]+)(?:/\d+)?(?![A-Za-z0-9_.:-])", line)
for token in tokens:
    try:
        if "/" in token:
            network = ipaddress.ip_network(token, strict=False)
        else:
            address = ipaddress.ip_address(token)
            network = ipaddress.ip_network(f"{address}/{address.max_prefixlen}", strict=False)
    except ValueError:
        continue
    if network.version == 4:
        if network.prefixlen > ipv4_limit:
            continue
        probes = (
            ipaddress.ip_address("1.1.1.1"),
            ipaddress.ip_address("8.8.8.8"),
            ipaddress.ip_address("101.6.6.6"),
            ipaddress.ip_address("223.5.5.5"),
        )
        if network.is_global or any(probe in network for probe in probes):
            raise SystemExit(0)
    elif network.version == 6:
        if network.prefixlen > ipv6_limit:
            continue
        probes = (
            ipaddress.ip_address("2606:4700:4700::1111"),
            ipaddress.ip_address("2001:4860:4860::8888"),
        )
        if network.is_global or any(probe in network for probe in probes):
            raise SystemExit(0)
raise SystemExit(1)
PY
}

ufw_rule_allows_public_port() {
  local rules="$1"
  local port="$2"
  local line
  while IFS= read -r line; do
    [[ "${line}" =~ (^|[^0-9])${port}(/tcp)?([^0-9]|$) ]] || continue
    [[ "${line}" =~ [[:space:]]ALLOW[[:space:]] ]] || continue
    if ufw_line_allows_public_source "${line}"; then
      return 0
    fi
  done <<<"${rules}"
  return 1
}

tcp_listen_output() {
  if [[ -n "${AUDIT_SS_LISTEN_FIXTURE}" ]]; then
    printf '%s\n' "${AUDIT_SS_LISTEN_FIXTURE}"
  else
    ss -ltn 2>/dev/null
  fi
}

tcp_listener_non_loopback() {
  local output="$1"
  local port="$2"
  python3 -c '
import re
import sys

port = sys.argv[1]
text = sys.stdin.read().splitlines()
unsafe = []

def normalize(address: str) -> str:
    address = address.strip()
    if address.startswith("[") and "]:" in address:
        return address[1:address.index("]:")]
    if address.endswith(f":{port}"):
        return address[: -(len(port) + 1)]
    return address

for line in text:
    if f":{port}" not in line:
        continue
    parts = line.split()
    if not parts:
        continue
    local = ""
    for part in parts:
        if part.endswith(f":{port}") or part.endswith(f"]:{port}"):
            local = part
            break
    if not local:
        continue
    address = normalize(local)
    if address in {"127.0.0.1", "::1", "localhost"}:
        continue
    unsafe.append(local)

if unsafe:
    print(",".join(unsafe))
    raise SystemExit(0)
raise SystemExit(1)
' "${port}" <<<"${output}"
}

redis_config_directive() {
  local key="$1"
  local file="${AUDIT_REDIS_CONFIG_FILE}"
  [[ -f "${file}" ]] || return 1
  awk -v key="${key}" '
    $0 ~ /^[[:space:]]*#/ { next }
    tolower($1) == tolower(key) {
      value = ""
      for (i = 2; i <= NF; i++) {
        value = value (value == "" ? "" : " ") $i
      }
      found = value
    }
    END {
      if (found != "") {
        print found
      } else {
        exit 1
      }
    }
  ' "${file}"
}

redis_bind_loopback_only() {
  local bind_value="$1"
  local token
  [[ -n "${bind_value}" ]] || return 1
  for token in ${bind_value}; do
    case "${token}" in
      127.0.0.1|::1|localhost) ;;
      *) return 1 ;;
    esac
  done
}

summary_field_value() {
  local output="$1"
  local field="$2"
  printf '%s\n' "${output}" | tr '[:space:]' '\n' | awk -F= -v key="${field}" '
    $1 == key {
      print substr($0, length(key) + 2)
      found = 1
      exit
    }
    END { exit found ? 0 : 1 }
  '
}

summary_field_present() {
  local output="$1"
  local field="$2"
  output_contains "${output}" "${field}="
}

validate_audit_campaign_target_value() {
  local value="$1"
  local base_url tcp_host tcp_port base_scheme base_host base_reason tcp_reason
  IFS=, read -r base_url tcp_host tcp_port <<<"${value}"
  [[ -n "${base_url:-}" && -n "${tcp_host:-}" && -n "${tcp_port:-}" ]] || return 1

  base_scheme="$(audit_scheme_from_url "${base_url}")"
  [[ "${base_scheme}" == "https" ]] || return 1

  base_host="$(audit_host_from_url "${base_url}")"
  base_reason="$(audit_public_host_policy_reason "${base_host}")"
  [[ "${base_reason}" == "ok" ]] || return 1

  tcp_reason="$(audit_public_host_policy_reason "${tcp_host}")"
  [[ "${tcp_reason}" == "ok" ]] || return 1

  [[ "${tcp_port}" =~ ^[0-9]+$ && "${tcp_port}" != "0" ]]
}

validate_performance_evidence_summary() {
  local output="$1"
  local missing=()
  local invalid=()
  local field
  local product_campaign_attempted=""
  local product_campaign_failures=""
  local product_campaign_required_failures=""
  local product_campaign_skipped=""
  local product_plan_domain_count=""
  local product_plan_scenario_count=""
  local value

  if bool_enabled "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "manifestRequireCloudSecurityGroup")"; then
      if [[ "${value}" != "true" ]]; then
        invalid+=("manifestRequireCloudSecurityGroup=${value:-<empty>}")
      fi
    else
      missing+=("manifestRequireCloudSecurityGroup")
    fi
  fi

  if bool_enabled "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "requireProductionAcceptance")"; then
      if [[ "${value}" != "true" ]]; then
        invalid+=("requireProductionAcceptance=${value:-<empty>}")
      fi
    else
      missing+=("requireProductionAcceptance")
    fi
    if value="$(summary_field_value "${output}" "productionAcceptanceReceipt")"; then
      if [[ -z "${value}" || "${value}" == "<unset>" || "${value}" == "-" ]]; then
        invalid+=("productionAcceptanceReceipt=${value:-<empty>}")
      fi
    else
      missing+=("productionAcceptanceReceipt")
    fi
    if value="$(summary_field_value "${output}" "productionAcceptancePackage")"; then
      if [[ -z "${value}" || "${value}" == "<unset>" || "${value}" == "-" ]]; then
        invalid+=("productionAcceptancePackage=${value:-<empty>}")
      fi
    else
      missing+=("productionAcceptancePackage")
    fi
  fi

  if bool_enabled "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "manifestRequireProfileArtifacts")"; then
      if [[ "${value}" != "true" ]]; then
        invalid+=("manifestRequireProfileArtifacts=${value:-<empty>}")
      fi
    else
      missing+=("manifestRequireProfileArtifacts")
    fi
    if value="$(summary_field_value "${output}" "profileRunStatus")"; then
      case "${value}" in
        PASS|NOOP) ;;
        *) invalid+=("profileRunStatus=${value:-<empty>}") ;;
      esac
    else
      missing+=("profileRunStatus")
    fi
    summary_field_present "${output}" "profileRunBlockerType" || missing+=("profileRunBlockerType")
    if value="$(summary_field_value "${output}" "profileEntrypointDiagnosis")"; then
      if [[ -z "${value}" || "${value}" == "-" ]]; then
        invalid+=("profileEntrypointDiagnosis=${value:-<empty>}")
      fi
    fi
    if value="$(summary_field_value "${output}" "profileEntrypointBlocker")"; then
      case "${value}" in
        *,*,*,*) ;;
        *) invalid+=("profileEntrypointBlocker=${value:-<empty>}") ;;
      esac
    fi
  fi

  if bool_enabled "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "productProfileGate")"; then
      if [[ "${value}" != "PASS" ]]; then
        invalid+=("productProfileGate=${value:-<empty>}")
      fi
    else
      missing+=("productProfileGate")
    fi
    if value="$(summary_field_value "${output}" "productProfileGateChecked")"; then
      if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" == "0" ]]; then
        invalid+=("productProfileGateChecked=${value:-<empty>}")
      fi
    else
      missing+=("productProfileGateChecked")
    fi
    if value="$(summary_field_value "${output}" "productProfileGateRequiredDomains")"; then
      if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" == "0" ]]; then
        invalid+=("productProfileGateRequiredDomains=${value:-<empty>}")
      fi
    else
      missing+=("productProfileGateRequiredDomains")
    fi
    if value="$(summary_field_value "${output}" "manifestRequireProductPlanArtifacts")"; then
      if [[ "${value}" != "true" ]]; then
        invalid+=("manifestRequireProductPlanArtifacts=${value:-<empty>}")
      fi
    else
      missing+=("manifestRequireProductPlanArtifacts")
    fi
    if value="$(summary_field_value "${output}" "productPlanStatus")"; then
      if [[ "${value}" != "PASS" ]]; then
        invalid+=("productPlanStatus=${value:-<empty>}")
      fi
    else
      missing+=("productPlanStatus")
    fi
    summary_field_present "${output}" "productPlanBlockerType" || missing+=("productPlanBlockerType")
    if value="$(summary_field_value "${output}" "productPlanScenarioCount")"; then
      if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        invalid+=("productPlanScenarioCount=${value:-<empty>}")
      else
        product_plan_scenario_count="${value}"
      fi
    else
      missing+=("productPlanScenarioCount")
    fi
    if value="$(summary_field_value "${output}" "productPlanLargeGroupIncluded")"; then
      if [[ "${value}" != "false" ]]; then
        invalid+=("productPlanLargeGroupIncluded=${value:-<empty>}")
      fi
    else
      missing+=("productPlanLargeGroupIncluded")
    fi
    if [[ -n "${product_plan_scenario_count}" && "${product_plan_scenario_count}" == "0" ]]; then
      invalid+=("productPlanScenarioCount=${product_plan_scenario_count}")
    fi
    if value="$(summary_field_value "${output}" "productPlanDomainCount")"; then
      if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        invalid+=("productPlanDomainCount=${value:-<empty>}")
      else
        product_plan_domain_count="${value}"
      fi
    else
      missing+=("productPlanDomainCount")
    fi
    if value="$(summary_field_value "${output}" "productPlanRequiredDomainsCovered")"; then
      if [[ "${value}" != "true" ]]; then
        invalid+=("productPlanRequiredDomainsCovered=${value:-<empty>}")
      fi
    else
      missing+=("productPlanRequiredDomainsCovered")
    fi
    if [[ -n "${product_plan_domain_count}" && "${product_plan_domain_count}" == "0" ]]; then
      invalid+=("productPlanDomainCount=${product_plan_domain_count}")
    fi
  fi

  if bool_enabled "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "manifestRequireProductCampaignArtifacts")"; then
      if [[ "${value}" != "true" ]]; then
        invalid+=("manifestRequireProductCampaignArtifacts=${value:-<empty>}")
      fi
    else
      missing+=("manifestRequireProductCampaignArtifacts")
    fi
    if value="$(summary_field_value "${output}" "productCampaign")"; then
      if [[ -z "${value}" || "${value}" == "-" ]]; then
        invalid+=("productCampaign=${value:-<empty>}")
      fi
    else
      missing+=("productCampaign")
    fi
    if value="$(summary_field_value "${output}" "productCampaignStatus")"; then
      if [[ "${value}" != "PASS" ]]; then
        invalid+=("productCampaignStatus=${value:-<empty>}")
      fi
    else
      missing+=("productCampaignStatus")
    fi
    if value="$(summary_field_value "${output}" "productCampaignTarget")"; then
      case "${value}" in
        -,-,-|''|-) invalid+=("productCampaignTarget=${value:-<empty>}") ;;
        *,*,*) validate_audit_campaign_target_value "${value}" || invalid+=("productCampaignTarget=${value}") ;;
        *) invalid+=("productCampaignTarget=${value}") ;;
      esac
    else
      missing+=("productCampaignTarget")
    fi
    for field in \
      productCampaignFailures= \
      productCampaignRequiredFailures= \
      productCampaignAttempted= \
      productCampaignSkipped=
    do
      if value="$(summary_field_value "${output}" "${field%=}")"; then
        if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
          invalid+=("${field}${value:-<empty>}")
        else
          case "${field%=}" in
            productCampaignFailures) product_campaign_failures="${value}" ;;
            productCampaignRequiredFailures) product_campaign_required_failures="${value}" ;;
            productCampaignAttempted) product_campaign_attempted="${value}" ;;
            productCampaignSkipped) product_campaign_skipped="${value}" ;;
          esac
        fi
      else
        missing+=("${field%=}")
      fi
    done
    if [[ -n "${product_campaign_failures}" && "${product_campaign_failures}" != "0" ]]; then
      invalid+=("productCampaignFailures=${product_campaign_failures}")
    fi
    if [[ -n "${product_campaign_required_failures}" && "${product_campaign_required_failures}" != "0" ]]; then
      invalid+=("productCampaignRequiredFailures=${product_campaign_required_failures}")
    fi
    if [[ -n "${product_campaign_attempted}" && "${product_campaign_attempted}" == "0" ]]; then
      invalid+=("productCampaignAttempted=${product_campaign_attempted}")
    fi
    if [[ -n "${product_campaign_skipped}" && "${product_campaign_skipped}" != "0" ]]; then
      invalid+=("productCampaignSkipped=${product_campaign_skipped}")
    fi
  fi

  if bool_enabled "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "manifestRequireCurrentReadinessArtifacts")"; then
      if [[ "${value}" != "true" ]]; then
        invalid+=("manifestRequireCurrentReadinessArtifacts=${value:-<empty>}")
      fi
    else
      missing+=("manifestRequireCurrentReadinessArtifacts")
    fi
    if value="$(summary_field_value "${output}" "currentReadinessStatus")"; then
      if [[ "${value}" != "PASS" ]]; then
        invalid+=("currentReadinessStatus=${value:-<empty>}")
      fi
    else
      missing+=("currentReadinessStatus")
    fi
    summary_field_present "${output}" "currentReadinessReason" || missing+=("currentReadinessReason")
    for field in \
      currentReadinessRequestedSmoke \
      currentReadinessRequestedBaseline \
      currentReadinessRequestedFullAcceptance
    do
      if value="$(summary_field_value "${output}" "${field}")"; then
        if [[ "${value}" != "true" ]]; then
          invalid+=("${field}=${value:-<empty>}")
        fi
      else
        missing+=("${field}")
      fi
    done
    for field in \
      currentReadinessSmokeExitCode \
      currentReadinessBaselineExitCode \
      currentReadinessFullAcceptanceExitCode
    do
      if value="$(summary_field_value "${output}" "${field}")"; then
        if [[ "${value}" != "0" ]]; then
          invalid+=("${field}=${value:-<empty>}")
        fi
      else
        missing+=("${field}")
      fi
    done
    local expected_full_campaign="" actual_full_campaign="" current_full_failures="" current_full_required_failures="" current_full_attempted="" current_full_skipped=""
    if value="$(summary_field_value "${output}" "currentReadinessFullAcceptanceExpectedCampaign")"; then
      if [[ -z "${value}" || "${value}" == "-" ]]; then
        invalid+=("currentReadinessFullAcceptanceExpectedCampaign=${value:-<empty>}")
      else
        expected_full_campaign="${value}"
      fi
    else
      missing+=("currentReadinessFullAcceptanceExpectedCampaign")
    fi
    if value="$(summary_field_value "${output}" "currentReadinessFullAcceptanceCampaign")"; then
      if [[ -z "${value}" || "${value}" == "-" ]]; then
        invalid+=("currentReadinessFullAcceptanceCampaign=${value:-<empty>}")
      else
        actual_full_campaign="${value}"
      fi
    else
      missing+=("currentReadinessFullAcceptanceCampaign")
    fi
    if [[ -n "${expected_full_campaign}" && -n "${actual_full_campaign}" && "${actual_full_campaign}" != "${expected_full_campaign}" ]]; then
      invalid+=("currentReadinessFullAcceptanceCampaign=${actual_full_campaign},expected=${expected_full_campaign}")
    fi
    if value="$(summary_field_value "${output}" "currentReadinessFullAcceptanceStatus")"; then
      [[ "${value}" == "PASS" ]] || invalid+=("currentReadinessFullAcceptanceStatus=${value:-<empty>}")
    else
      missing+=("currentReadinessFullAcceptanceStatus")
    fi
    for field in \
      currentReadinessFullAcceptanceFailures= \
      currentReadinessFullAcceptanceRequiredFailures= \
      currentReadinessFullAcceptanceAttempted= \
      currentReadinessFullAcceptanceSkipped=
    do
      if value="$(summary_field_value "${output}" "${field%=}")"; then
        if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
          invalid+=("${field}${value:-<empty>}")
        else
          case "${field%=}" in
            currentReadinessFullAcceptanceFailures) current_full_failures="${value}" ;;
            currentReadinessFullAcceptanceRequiredFailures) current_full_required_failures="${value}" ;;
            currentReadinessFullAcceptanceAttempted) current_full_attempted="${value}" ;;
            currentReadinessFullAcceptanceSkipped) current_full_skipped="${value}" ;;
          esac
        fi
      else
        missing+=("${field%=}")
      fi
    done
    if [[ -n "${current_full_failures}" && "${current_full_failures}" != "0" ]]; then
      invalid+=("currentReadinessFullAcceptanceFailures=${current_full_failures}")
    fi
    if [[ -n "${current_full_required_failures}" && "${current_full_required_failures}" != "0" ]]; then
      invalid+=("currentReadinessFullAcceptanceRequiredFailures=${current_full_required_failures}")
    fi
    if [[ -n "${current_full_attempted}" && "${current_full_attempted}" == "0" ]]; then
      invalid+=("currentReadinessFullAcceptanceAttempted=${current_full_attempted}")
    fi
    if [[ -n "${current_full_skipped}" && "${current_full_skipped}" != "0" ]]; then
      invalid+=("currentReadinessFullAcceptanceSkipped=${current_full_skipped}")
    fi

    local product_suite_required="false"
    if value="$(summary_field_value "${output}" "manifestRequireProductScenarioSuiteArtifacts")"; then
      case "${value}" in
        true|True|1) product_suite_required="true" ;;
        false|False|0|-) product_suite_required="false" ;;
        *) invalid+=("manifestRequireProductScenarioSuiteArtifacts=${value:-<empty>}") ;;
      esac
    fi
    if [[ "${product_suite_required}" == "true" ]]; then
      if value="$(summary_field_value "${output}" "currentReadinessRequestedProductScenarioSuite")"; then
        [[ "${value}" == "true" || "${value}" == "True" || "${value}" == "1" ]] || invalid+=("currentReadinessRequestedProductScenarioSuite=${value:-<empty>}")
      else
        missing+=("currentReadinessRequestedProductScenarioSuite")
      fi
      if value="$(summary_field_value "${output}" "currentReadinessProductScenarioSuiteExitCode")"; then
        [[ "${value}" == "0" ]] || invalid+=("currentReadinessProductScenarioSuiteExitCode=${value:-<empty>}")
      else
        missing+=("currentReadinessProductScenarioSuiteExitCode")
      fi
      local expected_suite="" actual_suite=""
      if value="$(summary_field_value "${output}" "currentReadinessProductScenarioSuiteExpected")"; then
        if [[ -z "${value}" || "${value}" == "-" ]]; then
          invalid+=("currentReadinessProductScenarioSuiteExpected=${value:-<empty>}")
        else
          expected_suite="${value}"
        fi
      else
        missing+=("currentReadinessProductScenarioSuiteExpected")
      fi
      if value="$(summary_field_value "${output}" "currentReadinessProductScenarioSuite")"; then
        if [[ -z "${value}" || "${value}" == "-" ]]; then
          invalid+=("currentReadinessProductScenarioSuite=${value:-<empty>}")
        else
          actual_suite="${value}"
        fi
      else
        missing+=("currentReadinessProductScenarioSuite")
      fi
      if [[ -n "${expected_suite}" && -n "${actual_suite}" && "${actual_suite}" != "${expected_suite}" ]]; then
        invalid+=("currentReadinessProductScenarioSuite=${actual_suite},expected=${expected_suite}")
      fi
      if value="$(summary_field_value "${output}" "currentReadinessProductScenarioSuiteStatus")"; then
        [[ "${value}" == "PASS" ]] || invalid+=("currentReadinessProductScenarioSuiteStatus=${value:-<empty>}")
      else
        missing+=("currentReadinessProductScenarioSuiteStatus")
      fi
      if value="$(summary_field_value "${output}" "currentReadinessProductScenarioSuiteScenarios")"; then
        if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" == "0" ]]; then
          invalid+=("currentReadinessProductScenarioSuiteScenarios=${value:-<empty>}")
        fi
      else
        missing+=("currentReadinessProductScenarioSuiteScenarios")
      fi
      if value="$(summary_field_value "${output}" "currentReadinessProductScenarioSuiteLargeGroupIncluded")"; then
        [[ "${value}" == "false" || "${value}" == "False" || "${value}" == "0" ]] || invalid+=("currentReadinessProductScenarioSuiteLargeGroupIncluded=${value:-<empty>}")
      else
        missing+=("currentReadinessProductScenarioSuiteLargeGroupIncluded")
      fi
    fi
  fi

  if ((${#missing[@]} > 0)); then
    printf 'performance_evidence_summary_missing fields=%s verifierOutput=%s\n' \
      "$(IFS=,; printf '%s' "${missing[*]}")" \
      "${output//$'\n'/ }"
    return 1
  fi
  if ((${#invalid[@]} > 0)); then
    printf 'performance_evidence_summary_invalid fields=%s verifierOutput=%s\n' \
      "$(IFS=,; printf '%s' "${invalid[*]}")" \
      "${output//$'\n'/ }"
    return 1
  fi
}

run_performance_summary_self_test() {
  local bad_counter_output current_partial_output current_summary gate_summary good_output incomplete_product_domains_output large_group_product_plan_output loopback_campaign_target_output missing_campaign_output missing_plan_output missing_policy_output missing_product_preview_output missing_profile_output nonzero_failure_output placeholder_campaign_output policy_summary skipped_campaign_output validation_output weakened_policy_output zero_attempted_output zero_product_domains_output zero_product_scenarios_output
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=true
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE=true
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE=true
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE=true
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE=true
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=true
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE=true

  policy_summary='manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true requireProductionAcceptance=true productionAcceptanceReceipt=/tmp/production-acceptance.json productionAcceptancePackage=/tmp/production-acceptance-package.tar.gz'
  current_summary='manifestRequireCurrentReadinessArtifacts=true manifestRequireProductScenarioSuiteArtifacts=true currentReadinessStatus=PASS currentReadinessReason=pass currentReadinessRequestedSmoke=true currentReadinessRequestedProductScenarioSuite=true currentReadinessRequestedBaseline=true currentReadinessRequestedFullAcceptance=true currentReadinessSmokeExitCode=0 currentReadinessProductScenarioSuiteExitCode=0 currentReadinessBaselineExitCode=0 currentReadinessFullAcceptanceExitCode=0 currentReadinessProductScenarioSuiteExpected=recommended currentReadinessProductScenarioSuite=recommended currentReadinessProductScenarioSuiteStatus=PASS currentReadinessProductScenarioSuiteScenarios=8 currentReadinessProductScenarioSuiteLargeGroupIncluded=False currentReadinessFullAcceptanceExpectedCampaign=production-full-acceptance currentReadinessFullAcceptanceCampaign=production-full-acceptance currentReadinessFullAcceptanceStatus=PASS currentReadinessFullAcceptanceFailures=0 currentReadinessFullAcceptanceRequiredFailures=0 currentReadinessFullAcceptanceAttempted=6 currentReadinessFullAcceptanceSkipped=0'
  gate_summary='productProfileGate=PASS productProfileGateChecked=3 productProfileGateRequiredDomains=10'
  good_output="performance_evidence result=pass current=/tmp/current evidence=/tmp/evidence gate=/tmp/gate profile=minimum-smoke requireProfileArtifacts=true requireValidationInventory=true docsAudit=PASS docsGroups=10/10 docsErrors=0 inventoryDocs=2 ${policy_summary} ${current_summary} profileRunStatus=PASS profileRunBlockerType=- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000"
  validate_performance_evidence_summary "${good_output}" >/dev/null || {
    printf 'audit-performance-summary-self-test result=fail reason=good_summary_rejected\n' >&2
    return 1
  }

  current_partial_output="performance_evidence result=pass current=/tmp/current evidence=/tmp/evidence gate=/tmp/gate profile=minimum-smoke requireProfileArtifacts=true requireValidationInventory=true docsAudit=PASS docsGroups=10/10 docsErrors=0 inventoryDocs=2 ${policy_summary} manifestRequireCurrentReadinessArtifacts=true profileRunStatus=PASS profileRunBlockerType=- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 currentReadinessStatus=PASS currentReadinessReason=pass currentReadinessRequestedSmoke=true currentReadinessRequestedBaseline=true currentReadinessRequestedFullAcceptance=false currentReadinessSmokeExitCode=0 currentReadinessBaselineExitCode=0 currentReadinessFullAcceptanceExitCode=-"
  if validation_output="$(validate_performance_evidence_summary "${current_partial_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=current_readiness_partial_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "currentReadinessRequestedFullAcceptance=false" || {
    printf 'audit-performance-summary-self-test result=fail reason=current_readiness_partial_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }
  current_mismatch_output="performance_evidence result=pass current=/tmp/current evidence=/tmp/evidence gate=/tmp/gate profile=minimum-smoke requireProfileArtifacts=true requireValidationInventory=true docsAudit=PASS docsGroups=10/10 docsErrors=0 inventoryDocs=2 ${policy_summary} manifestRequireCurrentReadinessArtifacts=true profileRunStatus=PASS profileRunBlockerType=- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 currentReadinessStatus=PASS currentReadinessReason=pass currentReadinessRequestedSmoke=true currentReadinessRequestedBaseline=true currentReadinessRequestedFullAcceptance=true currentReadinessSmokeExitCode=0 currentReadinessBaselineExitCode=0 currentReadinessFullAcceptanceExitCode=0 currentReadinessFullAcceptanceExpectedCampaign=production-full-acceptance currentReadinessFullAcceptanceCampaign=non-large-group-release currentReadinessFullAcceptanceStatus=PASS currentReadinessFullAcceptanceFailures=0 currentReadinessFullAcceptanceRequiredFailures=0 currentReadinessFullAcceptanceAttempted=6 currentReadinessFullAcceptanceSkipped=0"
  if validation_output="$(validate_performance_evidence_summary "${current_mismatch_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=current_full_campaign_mismatch_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "currentReadinessFullAcceptanceCampaign=non-large-group-release,expected=production-full-acceptance" || {
    printf 'audit-performance-summary-self-test result=fail reason=current_full_campaign_mismatch_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE=false

  missing_policy_output='performance_evidence result=pass current=/tmp/current evidence=/tmp/evidence gate=/tmp/gate profile=minimum-smoke requireProfileArtifacts=true requireValidationInventory=true docsAudit=PASS docsGroups=10/10 docsErrors=0 inventoryDocs=2 profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${missing_policy_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=missing_manifest_policy_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "manifestRequireProfileArtifacts" || {
    printf 'audit-performance-summary-self-test result=fail reason=missing_manifest_policy_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  weakened_policy_output='performance_evidence result=pass current=/tmp/current evidence=/tmp/evidence gate=/tmp/gate profile=minimum-smoke requireProfileArtifacts=true requireValidationInventory=true docsAudit=PASS docsGroups=10/10 docsErrors=0 inventoryDocs=2 manifestRequireProfileArtifacts=false manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${weakened_policy_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=weakened_manifest_policy_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "manifestRequireProfileArtifacts=false" || {
    printf 'audit-performance-summary-self-test result=fail reason=weakened_manifest_policy_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  weakened_policy_output="performance_evidence result=pass current=/tmp/current evidence=/tmp/evidence gate=/tmp/gate profile=minimum-smoke requireProfileArtifacts=true requireValidationInventory=true docsAudit=PASS docsGroups=10/10 docsErrors=0 inventoryDocs=2 ${policy_summary} profileRunStatus=PASS profileRunBlockerType=- productProfileGate=FAIL productProfileGateChecked=3 productProfileGateRequiredDomains=10 productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000"
  if validation_output="$(validate_performance_evidence_summary "${weakened_policy_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=failed_product_profile_gate_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productProfileGate=FAIL" || {
    printf 'audit-performance-summary-self-test result=fail reason=failed_product_profile_gate_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  missing_campaign_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0'
  if validation_output="$(validate_performance_evidence_summary "${missing_campaign_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=missing_campaign_counters_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productCampaignRequiredFailures" || {
    printf 'audit-performance-summary-self-test result=fail reason=missing_campaign_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  placeholder_campaign_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=- productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${placeholder_campaign_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=placeholder_campaign_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productCampaign=-" || {
    printf 'audit-performance-summary-self-test result=fail reason=placeholder_campaign_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  loopback_campaign_target_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=http://127.0.0.1:8080,127.0.0.1,9000'
  if validation_output="$(validate_performance_evidence_summary "${loopback_campaign_target_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=loopback_campaign_target_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productCampaignTarget=http://127.0.0.1:8080,127.0.0.1,9000" || {
    printf 'audit-performance-summary-self-test result=fail reason=loopback_campaign_target_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  bad_counter_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=zero productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${bad_counter_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=bad_campaign_counter_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productCampaignFailures=zero" || {
    printf 'audit-performance-summary-self-test result=fail reason=bad_counter_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  nonzero_failure_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=1 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${nonzero_failure_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=nonzero_campaign_failure_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productCampaignFailures=1" || {
    printf 'audit-performance-summary-self-test result=fail reason=nonzero_failure_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  skipped_campaign_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=1 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${skipped_campaign_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=skipped_pass_campaign_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productCampaignSkipped=1" || {
    printf 'audit-performance-summary-self-test result=fail reason=skipped_campaign_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  zero_attempted_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=0 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${zero_attempted_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=zero_attempted_campaign_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productCampaignAttempted=0" || {
    printf 'audit-performance-summary-self-test result=fail reason=zero_attempted_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  missing_plan_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${missing_plan_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=missing_product_plan_summary_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productPlanStatus" || {
    printf 'audit-performance-summary-self-test result=fail reason=missing_plan_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  missing_product_preview_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${missing_product_preview_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=missing_product_preview_summary_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productPlanScenarioCount" || {
    printf 'audit-performance-summary-self-test result=fail reason=missing_product_preview_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  zero_product_scenarios_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=0 productPlanLargeGroupIncluded=false productPlanDomainCount=0 productPlanRequiredDomainsCovered=false productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${zero_product_scenarios_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=zero_product_scenarios_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productPlanScenarioCount=0" || {
    printf 'audit-performance-summary-self-test result=fail reason=zero_product_scenarios_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  large_group_product_plan_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=true productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${large_group_product_plan_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=large_group_product_plan_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productPlanLargeGroupIncluded=true" || {
    printf 'audit-performance-summary-self-test result=fail reason=large_group_product_plan_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  zero_product_domains_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=0 productPlanRequiredDomainsCovered=false productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${zero_product_domains_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=zero_product_domains_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productPlanDomainCount=0" || {
    printf 'audit-performance-summary-self-test result=fail reason=zero_product_domains_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  incomplete_product_domains_output='performance_evidence result=pass profileRunStatus=PASS profileRunBlockerType=- productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=6 productPlanRequiredDomainsCovered=false productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${incomplete_product_domains_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=incomplete_product_domains_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "productPlanRequiredDomainsCovered=false" || {
    printf 'audit-performance-summary-self-test result=fail reason=incomplete_product_domains_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  missing_profile_output='performance_evidence result=pass productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000'
  if validation_output="$(validate_performance_evidence_summary "${missing_profile_output}")"; then
    printf 'audit-performance-summary-self-test result=fail reason=missing_profile_summary_accepted\n' >&2
    return 1
  fi
  output_contains "${validation_output}" "profileRunStatus" || {
    printf 'audit-performance-summary-self-test result=fail reason=missing_profile_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE=false
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE=false
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE=false
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE=false
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=false
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE=false
  validate_performance_evidence_summary 'performance_evidence result=pass current=/tmp/current' >/dev/null || {
    printf 'audit-performance-summary-self-test result=fail reason=optional_summary_rejected\n' >&2
    return 1
  }

  printf 'audit-performance-summary-self-test result=pass\n'
}

run_unit_self_test() {
  local self_test_dir service_file timer_file alert_file expected_failures old_script_dir fake_script_dir fake_bin entrypoint_log entrypoint_output production_env_log production_env_output cloud_sg_good cloud_sg_bad old_cloud_sg_required old_cloud_sg_rules_file old_ss_fixture old_redis_config old_datastore_required redis_conf_good redis_conf_bad
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' RETURN
  AUDIT_SYSTEMD_DIR="${self_test_dir}/systemd"
  BACKUP_ROOT="${self_test_dir}/backups"
  mkdir -p "${AUDIT_SYSTEMD_DIR}"

  service_file="${AUDIT_SYSTEMD_DIR}/imserver-operational-audit.service"
  timer_file="${AUDIT_SYSTEMD_DIR}/imserver-operational-audit.timer"
  cat >"${service_file}" <<EOF
[Unit]
OnFailure=imserver-operational-alert@%n.service
[Service]
Environment=BACKUP_ROOT=${BACKUP_ROOT}
Environment=AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS=${AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS}
Environment=AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS=${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}
Environment=AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS=${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS}
Environment=AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS}
Environment=AUDIT_RESTORE_DRILL_RECEIPT_FILE=${AUDIT_RESTORE_DRILL_RECEIPT_FILE}
Environment=AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS=${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}
Environment=AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS=${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS}
Environment=AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS}
Environment=AUDIT_OFFSITE_BACKUP_RECEIPT_FILE=${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE}
Environment=AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS=${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}
Environment=AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS=${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS}
Environment=PUBLIC_BASE_URL=http://audit-unit.example.test:8080
Environment=AUDIT_REQUIRE_AUDIT_TIMER=true
Environment=AUDIT_REQUIRE_TIME_SYNC=${AUDIT_REQUIRE_TIME_SYNC}
Environment=AUDIT_REQUIRE_PRODUCTION_ENV=${AUDIT_REQUIRE_PRODUCTION_ENV}
Environment=AUDIT_REQUIRE_HTTPS_CERTIFICATE=${AUDIT_REQUIRE_HTTPS_CERTIFICATE}
Environment=AUDIT_HTTPS_CERT_MODE=${AUDIT_HTTPS_CERT_MODE}
Environment=AUDIT_HTTPS_CERT_MIN_VALID_DAYS=${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}
Environment=AUDIT_HTTPS_CERT_FILE=${AUDIT_HTTPS_CERT_FILE}
Environment=AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER=${AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER}
Environment=AUDIT_REQUIRE_RESTRICTED_SSH_CIDR=${AUDIT_REQUIRE_RESTRICTED_SSH_CIDR}
Environment=AUDIT_REQUIRE_RDP_CLOSED=${AUDIT_REQUIRE_RDP_CLOSED}
Environment=AUDIT_REQUIRE_PERFORMANCE_GATE=${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}
Environment=AUDIT_REQUIRE_KAFKA_LAG=${AUDIT_REQUIRE_KAFKA_LAG_EFFECTIVE}
Environment=AUDIT_KAFKA_LAG_MAX_TOTAL=${AUDIT_KAFKA_LAG_MAX_TOTAL}
Environment=AUDIT_KAFKA_LAG_MAX_PARTITION=${AUDIT_KAFKA_LAG_MAX_PARTITION}
Environment=AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}
Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE=${AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE}
Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS=${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}
Environment=AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS=${AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}
Environment=AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS=${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS}
Environment=AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=${AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}
Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=${AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}
Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=${AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}
Environment=AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}
Environment=AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP=${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}
Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX=${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}
Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX=${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}
Environment=AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX=${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}
Environment=AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX=${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}
Environment=AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}
Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}
Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}
Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}
Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}
Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}
Environment=AUDIT_REQUIRE_TOPOLOGY_SMOKE=${AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE}
Environment=AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON=${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON}
Environment=AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=${AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}
Environment=AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS=${AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS}
Environment=AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS=${AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS}
Environment=AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS=${AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}
Environment=AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS=${AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}
Environment=AUDIT_REQUIRE_DATASTORE_LOOPBACK=${AUDIT_REQUIRE_DATASTORE_LOOPBACK}
Environment=AUDIT_REDIS_CONFIG_FILE=${AUDIT_REDIS_CONFIG_FILE}
Environment=AUDIT_REQUIRE_NGINX_CONFIG=${AUDIT_REQUIRE_NGINX_CONFIG}
Environment=AUDIT_NGINX_HTTP_CONF_PATH=${AUDIT_NGINX_HTTP_CONF_PATH}
Environment=AUDIT_NGINX_LOCATIONS_CONF_PATH=${AUDIT_NGINX_LOCATIONS_CONF_PATH}
Environment=AUDIT_NGINX_SSL_CONF_PATH=${AUDIT_NGINX_SSL_CONF_PATH}
Environment=AUDIT_NGINX_REQUIRE_SSL=${AUDIT_NGINX_REQUIRE_SSL}
Environment=AUDIT_REQUIRE_ALERT_WEBHOOK=${AUDIT_REQUIRE_ALERT_WEBHOOK_EFFECTIVE}
Environment=AUDIT_ALERT_ALLOW_INSECURE_HTTP=${AUDIT_ALERT_ALLOW_INSECURE_HTTP:-false}
Environment=AUDIT_ALERT_REDACT_LOG_TAIL=${AUDIT_ALERT_REDACT_LOG_TAIL:-true}
Environment=AUDIT_PERFORMANCE_GATE_JSON=${AUDIT_PERFORMANCE_GATE_JSON}
Environment=AUDIT_PERFORMANCE_GATE_PROFILE=${AUDIT_PERFORMANCE_GATE_PROFILE}
Environment=AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS=${AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS}
Environment=AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT=${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT}
Environment=AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT=${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}
Environment=AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL=${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL}
Environment=AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST=${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST}
Environment=AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT=${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT}
Environment=AUDIT_PERFORMANCE_PROFILE_CATALOG=${AUDIT_PERFORMANCE_PROFILE_CATALOG}
Environment=AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK=${AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}
Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}
Environment=AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=${AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON}
Environment=AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE=${AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE}
ExecStart=/bin/bash ${SCRIPT_DIR}/77_operational_audit.sh
StandardOutput=append:/var/log/imserver/operational-audit.log
StandardError=append:/var/log/imserver/operational-audit.log
Nice=5
EOF
  alert_file="${AUDIT_SYSTEMD_DIR}/imserver-operational-alert@.service"
  cat >"${alert_file}" <<EOF
[Service]
EnvironmentFile=-/etc/imserver/operational-alert.env
ExecStart=/bin/bash ${SCRIPT_DIR}/79_send_operational_alert.sh %I
EOF
  cat >"${timer_file}" <<'EOF'
[Timer]
Persistent=true
Unit=imserver-operational-audit.service
EOF

  service_file="${AUDIT_SYSTEMD_DIR}/imserver-backup.service"
  timer_file="${AUDIT_SYSTEMD_DIR}/imserver-backup.timer"
  cat >"${service_file}" <<EOF
[Service]
Environment=BACKUP_ROOT=${BACKUP_ROOT}
Environment=BACKUP_RETENTION_DAYS=14
ExecStart=/bin/bash ${SCRIPT_DIR}/80_backup_single_node.sh
ExecStartPost=/bin/bash ${SCRIPT_DIR}/81_verify_backup.sh
OnFailure=imserver-backup-alert@%n.service
StandardOutput=append:/var/log/imserver/backup.log
StandardError=append:/var/log/imserver/backup.log
Nice=10
IOSchedulingClass=best-effort
EOF
  alert_file="${AUDIT_SYSTEMD_DIR}/imserver-backup-alert@.service"
  cat >"${alert_file}" <<EOF
[Service]
EnvironmentFile=-/etc/imserver/operational-alert.env
Environment=AUDIT_ALERT_LOG_FILE=/var/log/imserver/backup.log
ExecStart=/bin/bash ${SCRIPT_DIR}/79_send_operational_alert.sh %I
EOF
  cat >"${timer_file}" <<'EOF'
[Timer]
Persistent=true
Unit=imserver-backup.service
EOF

  service_file="${AUDIT_SYSTEMD_DIR}/imserver-restore-drill.service"
  alert_file="${AUDIT_SYSTEMD_DIR}/imserver-restore-drill-alert@.service"
  timer_file="${AUDIT_SYSTEMD_DIR}/imserver-restore-drill.timer"
  cat >"${service_file}" <<EOF
[Unit]
OnFailure=imserver-restore-drill-alert@%n.service
[Service]
Environment=BACKUP_ROOT=${BACKUP_ROOT}
Environment=BACKUP_DIR=${BACKUP_ROOT}/latest
Environment=RESTORE_DRILL_KEEP_DB=false
Environment=RESTORE_DRILL_RECEIPT_FILE=${self_test_dir}/restore-drill/latest.json
ExecStart=/bin/bash ${SCRIPT_DIR}/82_restore_drill_single_node.sh
StandardOutput=append:/var/log/imserver/restore-drill.log
StandardError=append:/var/log/imserver/restore-drill.log
Nice=10
IOSchedulingClass=best-effort
EOF
  cat >"${alert_file}" <<EOF
[Service]
EnvironmentFile=-/etc/imserver/operational-alert.env
Environment=AUDIT_ALERT_LOG_FILE=/var/log/imserver/restore-drill.log
ExecStart=/bin/bash ${SCRIPT_DIR}/79_send_operational_alert.sh %I
EOF
  cat >"${timer_file}" <<'EOF'
[Timer]
Persistent=true
Unit=imserver-restore-drill.service
EOF

  failures=0
  check_operational_audit_timer_units
  check_backup_timer_units
  check_restore_drill_timer_units
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=valid_units_rejected failures=%s\n' "${failures}" >&2
    return 1
  fi
  local release_dir
  release_dir="${self_test_dir}/release"
  mkdir -p "${release_dir}/bin"
  printf 'binary\n' >"${release_dir}/bin/IMServer"
  printf 'release\n' >"${release_dir}/release.env"
  printf '{"schemaVersion":1}\n' >"${release_dir}/release-manifest.json"
  (cd "${release_dir}" && sha256sum bin/IMServer release.env release-manifest.json >SHA256SUMS)
  validate_release_checksum_file "${release_dir}" "${release_dir}/SHA256SUMS" >/dev/null || {
    printf 'audit-unit-self-test result=fail reason=release_checksum_safety_valid_rejected\n' >&2
    return 1
  }
  cp "${release_dir}/SHA256SUMS" "${release_dir}/SHA256SUMS.good"
  {
    cat "${release_dir}/SHA256SUMS.good"
    printf '%064x  /etc/passwd\n' 1
  } >"${release_dir}/SHA256SUMS"
  if validate_release_checksum_file "${release_dir}" "${release_dir}/SHA256SUMS" 2>"${self_test_dir}/release-checksum-unsafe.log"; then
    printf 'audit-unit-self-test result=fail reason=release_checksum_unsafe_path_accepted\n' >&2
    return 1
  fi
  grep -q 'unsafe_path' "${self_test_dir}/release-checksum-unsafe.log" || {
    printf 'audit-unit-self-test result=fail reason=release_checksum_unsafe_path_reason_missing output=%s\n' "$(cat "${self_test_dir}/release-checksum-unsafe.log")" >&2
    return 1
  }
  printf 'extra\n' >"${release_dir}/extra.txt"
  {
    cat "${release_dir}/SHA256SUMS.good"
    printf '%064x  extra.txt\n' 1
  } >"${release_dir}/SHA256SUMS"
  if validate_release_checksum_file "${release_dir}" "${release_dir}/SHA256SUMS" 2>"${self_test_dir}/release-checksum-extra.log"; then
    printf 'audit-unit-self-test result=fail reason=release_checksum_extra_file_accepted\n' >&2
    return 1
  fi
  grep -q 'unexpected_file' "${self_test_dir}/release-checksum-extra.log" || {
    printf 'audit-unit-self-test result=fail reason=release_checksum_extra_file_reason_missing output=%s\n' "$(cat "${self_test_dir}/release-checksum-extra.log")" >&2
    return 1
  }
  local target_output target_log
  target_log="${self_test_dir}/performance-target.log"
  AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE=true
  AUDIT_APP_ENV_EFFECTIVE=production
  AUDIT_PUBLIC_BASE_URL_EFFECTIVE=""
  AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE=""
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE=""
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  failures=0
  validate_performance_gate_public_targets >"${target_log}"
  target_output="$(cat "${target_log}")"
  if [[ "${failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=missing_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'check=performance-gate-target' <<<"${target_output}" || {
    printf 'audit-unit-self-test result=fail reason=missing_public_target_check_absent output=%s\n' "${target_output}" >&2
    return 1
  }
  grep -q 'public_base_url_missing' <<<"${target_output}" || {
    printf 'audit-unit-self-test result=fail reason=missing_public_target_reason_absent output=%s\n' "${target_output}" >&2
    return 1
  }
  AUDIT_PUBLIC_BASE_URL_EFFECTIVE="http://audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE="http://audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE="audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  failures=0
  validate_performance_gate_public_targets >"${target_log}"
  target_output="$(cat "${target_log}")"
  if [[ "${failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=http_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_https_required' <<<"${target_output}" || {
    printf 'audit-unit-self-test result=fail reason=http_public_target_reason_absent output=%s\n' "${target_output}" >&2
    return 1
  }

  AUDIT_PUBLIC_BASE_URL_EFFECTIVE="https://203.0.113.10"
  AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE="https://203.0.113.10"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE="audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  failures=0
  validate_performance_gate_public_targets >"${target_log}"
  target_output="$(cat "${target_log}")"
  if [[ "${failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=ip_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_domain_required' <<<"${target_output}" || {
    printf 'audit-unit-self-test result=fail reason=ip_public_target_reason_absent output=%s\n' "${target_output}" >&2
    return 1
  }

  AUDIT_PUBLIC_BASE_URL_EFFECTIVE="https://audit.example.test"
  AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE="https://audit.example.test"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE="audit.example.test"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  failures=0
  validate_performance_gate_public_targets >"${target_log}"
  target_output="$(cat "${target_log}")"
  if [[ "${failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=placeholder_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_domain_required' <<<"${target_output}" || {
    printf 'audit-unit-self-test result=fail reason=placeholder_public_target_reason_absent output=%s\n' "${target_output}" >&2
    return 1
  }

  AUDIT_PUBLIC_BASE_URL_EFFECTIVE="https://audit.myim-prod.com:8443"
  AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE="https://audit.myim-prod.com:8443"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE="audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  failures=0
  validate_performance_gate_public_targets >"${target_log}"
  target_output="$(cat "${target_log}")"
  if [[ "${failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=non_default_https_port_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_default_https_port_required' <<<"${target_output}" || {
    printf 'audit-unit-self-test result=fail reason=non_default_public_port_reason_absent output=%s\n' "${target_output}" >&2
    return 1
  }
  grep -q 'expect_base_url_default_https_port_required' <<<"${target_output}" || {
    printf 'audit-unit-self-test result=fail reason=non_default_expect_port_reason_absent output=%s\n' "${target_output}" >&2
    return 1
  }

  AUDIT_PUBLIC_BASE_URL_EFFECTIVE="https://audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE="https://audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE="203.0.113.10"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  failures=0
  validate_performance_gate_public_targets >"${target_log}"
  target_output="$(cat "${target_log}")"
  if [[ "${failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=ip_tcp_target_accepted\n' >&2
    return 1
  fi
  grep -q 'expect_tcp_host_domain_required' <<<"${target_output}" || {
    printf 'audit-unit-self-test result=fail reason=ip_tcp_target_reason_absent output=%s\n' "${target_output}" >&2
    return 1
  }

  AUDIT_PUBLIC_BASE_URL_EFFECTIVE="https://audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE="https://audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE="audit.myim-prod.com"
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  failures=0
  validate_performance_gate_public_targets >"${target_log}"
  target_output="$(cat "${target_log}")"
  if [[ "${failures}" != "0" || -n "${target_output}" ]]; then
    printf 'audit-unit-self-test result=fail reason=valid_public_target_rejected failures=%s output=%s\n' "${failures}" "${target_output}" >&2
    return 1
  fi

  fake_script_dir="${self_test_dir}/fake-deploy"
  mkdir -p "${fake_script_dir}"
  cat >"${fake_script_dir}/65_verify_entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake-entrypoint publicBaseURL=%s requirePublic=%s httpPort=%s\n' \
  "${PUBLIC_BASE_URL:-}" \
  "${VERIFY_REQUIRE_PUBLIC:-}" \
  "${HTTP_PORT:-}"
[[ "${PUBLIC_BASE_URL:-}" == "http://audit-unit.example.test:8080" ]]
[[ "${VERIFY_REQUIRE_PUBLIC:-}" == "true" ]]
[[ "${HTTP_PORT:-}" == "18080" ]]
EOF
  chmod +x "${fake_script_dir}/65_verify_entrypoint.sh"
  old_script_dir="${SCRIPT_DIR}"
  SCRIPT_DIR="${fake_script_dir}"
  AUDIT_REQUIRE_ENTRYPOINT=true
  AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE=true
  AUDIT_PUBLIC_BASE_URL_EFFECTIVE="http://audit-unit.example.test:8080"
  HTTP_PORT=18080
  failures=0
  entrypoint_log="${self_test_dir}/entrypoint.log"
  check_entrypoint >"${entrypoint_log}"
  entrypoint_output="$(cat "${entrypoint_log}")"
  SCRIPT_DIR="${old_script_dir}"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=entrypoint_public_target_rejected output=%s\n' "${entrypoint_output}" >&2
    return 1
  fi
  grep -q 'check=entrypoint' <<<"${entrypoint_output}" || {
    printf 'audit-unit-self-test result=fail reason=entrypoint_check_absent output=%s\n' "${entrypoint_output}" >&2
    return 1
  }
  grep -q 'publicBaseURL=http://audit-unit.example.test:8080' <<<"${entrypoint_output}" || {
    printf 'audit-unit-self-test result=fail reason=entrypoint_public_base_url_absent output=%s\n' "${entrypoint_output}" >&2
    return 1
  }

  cat >"${fake_script_dir}/55_verify_production_env.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake-production-env envFile=%s rolesDir=%s requireProduction=%s\n' \
  "${ENV_FILE:-}" \
  "${ROLES_DIR:-}" \
  "${VERIFY_REQUIRE_PRODUCTION:-}"
[[ "${VERIFY_REQUIRE_PRODUCTION:-}" == "true" ]]
EOF
  chmod +x "${fake_script_dir}/55_verify_production_env.sh"
  old_script_dir="${SCRIPT_DIR}"
  SCRIPT_DIR="${fake_script_dir}"
  AUDIT_REQUIRE_PRODUCTION_ENV=true
  AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE=true
  failures=0
  production_env_log="${self_test_dir}/production-env.log"
  check_production_env >"${production_env_log}"
  production_env_output="$(cat "${production_env_log}")"
  SCRIPT_DIR="${old_script_dir}"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=production_env_check_rejected output=%s\n' "${production_env_output}" >&2
    return 1
  fi
  grep -q 'check=production-env' <<<"${production_env_output}" || {
    printf 'audit-unit-self-test result=fail reason=production_env_check_absent output=%s\n' "${production_env_output}" >&2
    return 1
  }

  fake_bin="${self_test_dir}/fake-bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/openssl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"expired.pem"*) exit 1 ;;
  *"-checkend"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${fake_bin}/openssl"
  cat >"${fake_bin}/timedatectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "show -p NTPSynchronized --value" ]]; then
  case "${AUDIT_FAKE_TIME_SYNC_STATE:-synced}" in
    synced) printf 'yes\n' ;;
    unsynced) printf 'no\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
EOF
  cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "is-active --quiet systemd-timesyncd.service"|"is-enabled --quiet systemd-timesyncd.service")
    [[ "${AUDIT_FAKE_TIME_SYNC_SERVICE:-enabled_active}" == "enabled_active" ]]
    ;;
  "is-active --quiet chrony.service"|"is-enabled --quiet chrony.service")
    [[ "${AUDIT_FAKE_TIME_SYNC_SERVICE:-enabled_active}" == "chrony_enabled_active" ]]
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${fake_bin}/timedatectl" "${fake_bin}/systemctl"
  AUDIT_REQUIRE_TIME_SYNC=true
  failures=0
  PATH="${fake_bin}:${PATH}" AUDIT_FAKE_TIME_SYNC_STATE=synced AUDIT_FAKE_TIME_SYNC_SERVICE=enabled_active check_time_sync >"${self_test_dir}/time-sync-valid.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=time_sync_valid_rejected output=%s\n' "$(cat "${self_test_dir}/time-sync-valid.log")" >&2
    return 1
  fi
  failures=0
  PATH="${fake_bin}:${PATH}" AUDIT_FAKE_TIME_SYNC_STATE=unsynced AUDIT_FAKE_TIME_SYNC_SERVICE=enabled_active check_time_sync >"${self_test_dir}/time-sync-unsynced.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=time_sync_unsynced_accepted\n' >&2
    return 1
  fi
  grep -q 'ntpSynchronized=no' "${self_test_dir}/time-sync-unsynced.log" || {
    printf 'audit-unit-self-test result=fail reason=time_sync_unsynced_reason_absent output=%s\n' "$(cat "${self_test_dir}/time-sync-unsynced.log")" >&2
    return 1
  }
  failures=0
  PATH="${fake_bin}:${PATH}" AUDIT_FAKE_TIME_SYNC_STATE=synced AUDIT_FAKE_TIME_SYNC_SERVICE=inactive check_time_sync >"${self_test_dir}/time-sync-service-inactive.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=time_sync_inactive_service_accepted\n' >&2
    return 1
  fi
  grep -q 'no_enabled_active_time_sync_service' "${self_test_dir}/time-sync-service-inactive.log" || {
    printf 'audit-unit-self-test result=fail reason=time_sync_inactive_service_reason_absent output=%s\n' "$(cat "${self_test_dir}/time-sync-service-inactive.log")" >&2
    return 1
  }
  touch "${self_test_dir}/valid.pem" "${self_test_dir}/expired.pem"
  AUDIT_REQUIRE_HTTPS_CERTIFICATE=true
  AUDIT_HTTPS_CERT_FILE="${self_test_dir}/valid.pem"
  AUDIT_PUBLIC_BASE_URL_EFFECTIVE="https://audit-unit.example.test"
  failures=0
  PATH="${fake_bin}:${PATH}" check_https_certificate >"${self_test_dir}/https-cert-valid.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=https_cert_valid_rejected output=%s\n' "$(cat "${self_test_dir}/https-cert-valid.log")" >&2
    return 1
  fi
  AUDIT_HTTPS_CERT_FILE="${self_test_dir}/expired.pem"
  failures=0
  PATH="${fake_bin}:${PATH}" check_https_certificate >"${self_test_dir}/https-cert-expired.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=https_cert_expired_accepted\n' >&2
    return 1
  fi

  mkdir -p "${BACKUP_ROOT}/fresh" "${BACKUP_ROOT}/stale" "${BACKUP_ROOT}/future"
  python3 - "${BACKUP_ROOT}/fresh/manifest.json" "${BACKUP_ROOT}/stale/manifest.json" "${BACKUP_ROOT}/future/manifest.json" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

fresh, stale, future = sys.argv[1:4]
with open(fresh, "w", encoding="utf-8") as handle:
    json.dump({"createdAt": datetime.now(timezone.utc).isoformat()}, handle)
with open(stale, "w", encoding="utf-8") as handle:
    json.dump({"createdAt": "1970-01-01T00:00:00+00:00"}, handle)
with open(future, "w", encoding="utf-8") as handle:
    json.dump({"createdAt": (datetime.now(timezone.utc) + timedelta(seconds=600)).isoformat()}, handle)
PY
  AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS=true
  AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS=60
  AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS=300
  failures=0
  check_latest_backup_freshness "${BACKUP_ROOT}/fresh" >"${self_test_dir}/latest-backup-fresh.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=fresh_latest_backup_rejected output=%s\n' "$(cat "${self_test_dir}/latest-backup-fresh.log")" >&2
    return 1
  fi
  failures=0
  check_latest_backup_freshness "${BACKUP_ROOT}/stale" >"${self_test_dir}/latest-backup-stale.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=stale_latest_backup_accepted\n' >&2
    return 1
  fi
  failures=0
  check_latest_backup_freshness "${BACKUP_ROOT}/future" >"${self_test_dir}/latest-backup-future.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=future_latest_backup_accepted\n' >&2
    return 1
  fi
  grep -q 'manifest_createdAt_in_future' "${self_test_dir}/latest-backup-future.log" || {
    printf 'audit-unit-self-test result=fail reason=future_latest_backup_reason_missing output=%s\n' "$(cat "${self_test_dir}/latest-backup-future.log")" >&2
    return 1
  }

  mkdir -p "${self_test_dir}/restore-drill"
  python3 - "${self_test_dir}/restore-drill/fresh.json" "${self_test_dir}/restore-drill/stale.json" "${self_test_dir}/restore-drill/shallow.json" "${self_test_dir}/restore-drill/future.json" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

fresh, stale, shallow, future = sys.argv[1:5]
base = {
    "schemaVersion": 1,
    "result": "pass",
    "backupID": "backup-unit",
    "backupManifestSha256": "a" * 64,
    "backupDir": "/var/backups/imserver/latest",
    "targetDatabase": "imserver_restore_drill_unit",
    "publicBaseTables": 3,
    "requiredTables": ["users", "im_messages"],
}
fresh_payload = {**base, "completedAt": datetime.now(timezone.utc).isoformat()}
stale_payload = {**base, "completedAt": "1970-01-01T00:00:00+00:00"}
shallow_payload = {**fresh_payload}
shallow_payload.pop("requiredTables", None)
future_payload = {**base, "completedAt": (datetime.now(timezone.utc) + timedelta(seconds=600)).isoformat()}
with open(fresh, "w", encoding="utf-8") as handle:
    json.dump(fresh_payload, handle)
with open(stale, "w", encoding="utf-8") as handle:
    json.dump(stale_payload, handle)
with open(shallow, "w", encoding="utf-8") as handle:
    json.dump(shallow_payload, handle)
with open(future, "w", encoding="utf-8") as handle:
    json.dump(future_payload, handle)
PY
  AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=true
  AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS=60
  AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS=300
  AUDIT_RESTORE_DRILL_RECEIPT_FILE="${self_test_dir}/restore-drill/fresh.json"
  failures=0
  check_restore_drill_freshness >"${self_test_dir}/restore-drill-fresh.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=fresh_restore_drill_rejected output=%s\n' "$(cat "${self_test_dir}/restore-drill-fresh.log")" >&2
    return 1
  fi
  AUDIT_RESTORE_DRILL_RECEIPT_FILE="${self_test_dir}/restore-drill/stale.json"
  failures=0
  check_restore_drill_freshness >"${self_test_dir}/restore-drill-stale.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=stale_restore_drill_accepted\n' >&2
    return 1
  fi
  AUDIT_RESTORE_DRILL_RECEIPT_FILE="${self_test_dir}/restore-drill/shallow.json"
  failures=0
  check_restore_drill_freshness >"${self_test_dir}/restore-drill-shallow.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=shallow_restore_drill_accepted\n' >&2
    return 1
  fi
  grep -q 'receipt_requiredTables_missing' "${self_test_dir}/restore-drill-shallow.log" || {
    printf 'audit-unit-self-test result=fail reason=shallow_restore_drill_reason_missing output=%s\n' "$(cat "${self_test_dir}/restore-drill-shallow.log")" >&2
    return 1
  }
  AUDIT_RESTORE_DRILL_RECEIPT_FILE="${self_test_dir}/restore-drill/future.json"
  failures=0
  check_restore_drill_freshness >"${self_test_dir}/restore-drill-future.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=future_restore_drill_accepted\n' >&2
    return 1
  fi
  grep -q 'receipt_completedAt_in_future' "${self_test_dir}/restore-drill-future.log" || {
    printf 'audit-unit-self-test result=fail reason=future_restore_drill_reason_missing output=%s\n' "$(cat "${self_test_dir}/restore-drill-future.log")" >&2
    return 1
  }
  AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=false

  mkdir -p "${self_test_dir}/offsite-backup"
  python3 - "${self_test_dir}/offsite-backup/fresh.json" "${self_test_dir}/offsite-backup/stale.json" "${self_test_dir}/offsite-backup/unverified.json" "${self_test_dir}/offsite-backup/future.json" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

fresh, stale, unverified, future = sys.argv[1:5]
base = {
    "schemaVersion": 1,
    "result": "pass",
    "backupID": "backup-unit",
    "backupManifestSha256": "a" * 64,
    "backupDir": "/var/backups/imserver/latest",
    "destination": "backup.example.test:/srv/imserver",
    "target": "backup.example.test:/srv/imserver/backup-unit",
    "postSyncVerify": True,
    "postSyncVerifyMode": "rsync-dry-run-checksum-delete",
}
fresh_payload = {**base, "completedAt": datetime.now(timezone.utc).isoformat()}
stale_payload = {**base, "completedAt": "1970-01-01T00:00:00+00:00"}
unverified_payload = {**fresh_payload, "postSyncVerify": False}
future_payload = {**base, "completedAt": (datetime.now(timezone.utc) + timedelta(seconds=600)).isoformat()}
with open(fresh, "w", encoding="utf-8") as handle:
    json.dump(fresh_payload, handle)
with open(stale, "w", encoding="utf-8") as handle:
    json.dump(stale_payload, handle)
with open(unverified, "w", encoding="utf-8") as handle:
    json.dump(unverified_payload, handle)
with open(future, "w", encoding="utf-8") as handle:
    json.dump(future_payload, handle)
PY
  AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=true
  AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS=60
  AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS=300
  AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${self_test_dir}/offsite-backup/fresh.json"
  failures=0
  check_offsite_backup_freshness >"${self_test_dir}/offsite-backup-fresh.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=fresh_offsite_backup_rejected output=%s\n' "$(cat "${self_test_dir}/offsite-backup-fresh.log")" >&2
    return 1
  fi
  AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${self_test_dir}/offsite-backup/stale.json"
  failures=0
  check_offsite_backup_freshness >"${self_test_dir}/offsite-backup-stale.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=stale_offsite_backup_accepted\n' >&2
    return 1
  fi
  AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${self_test_dir}/offsite-backup/unverified.json"
  failures=0
  check_offsite_backup_freshness >"${self_test_dir}/offsite-backup-unverified.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=unverified_offsite_backup_accepted\n' >&2
    return 1
  fi
  grep -q 'receipt_postSyncVerify_not_true' "${self_test_dir}/offsite-backup-unverified.log" || {
    printf 'audit-unit-self-test result=fail reason=unverified_offsite_backup_reason_missing output=%s\n' "$(cat "${self_test_dir}/offsite-backup-unverified.log")" >&2
    return 1
  }
  AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${self_test_dir}/offsite-backup/future.json"
  failures=0
  check_offsite_backup_freshness >"${self_test_dir}/offsite-backup-future.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=future_offsite_backup_accepted\n' >&2
    return 1
  fi
  grep -q 'receipt_completedAt_in_future' "${self_test_dir}/offsite-backup-future.log" || {
    printf 'audit-unit-self-test result=fail reason=future_offsite_backup_reason_missing output=%s\n' "$(cat "${self_test_dir}/offsite-backup-future.log")" >&2
    return 1
  }
  AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=false

  cat >"${fake_script_dir}/74_check_kafka_lag.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake-kafka-lag groups=%s maxTotal=%s maxPartition=%s requireGroups=%s\n' \
  "${KAFKA_LAG_GROUPS:-}" \
  "${KAFKA_LAG_MAX_TOTAL:-}" \
  "${KAFKA_LAG_MAX_PARTITION:-}" \
  "${KAFKA_LAG_REQUIRE_GROUPS:-}"
[[ "${KAFKA_LAG_GROUPS:-}" == "summary-projection-consumer domain-delivery-consumer" ]]
[[ "${KAFKA_LAG_MAX_TOTAL:-}" == "10000" ]]
[[ "${KAFKA_LAG_MAX_PARTITION:-}" == "5000" ]]
EOF
  chmod +x "${fake_script_dir}/74_check_kafka_lag.sh"
  old_script_dir="${SCRIPT_DIR}"
  SCRIPT_DIR="${fake_script_dir}"
  AUDIT_REQUIRE_KAFKA_LAG_EFFECTIVE=true
  AUDIT_KAFKA_LAG_GROUPS="summary-projection-consumer domain-delivery-consumer"
  AUDIT_KAFKA_LAG_MAX_TOTAL=10000
  AUDIT_KAFKA_LAG_MAX_PARTITION=5000
  AUDIT_KAFKA_LAG_REQUIRE_GROUPS=true
  failures=0
  check_kafka_lag >"${self_test_dir}/kafka-lag.log"
  SCRIPT_DIR="${old_script_dir}"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=kafka_lag_check_rejected output=%s\n' "$(cat "${self_test_dir}/kafka-lag.log")" >&2
    return 1
  fi

  local nginx_log old_nginx_required old_nginx_http_conf old_nginx_locations_conf old_nginx_ssl_conf old_nginx_require_ssl
  cat >"${fake_script_dir}/62_verify_nginx_config.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake-nginx-verify http=%s locations=%s ssl=%s requireSSL=%s runNginxTest=%s\n' \
  "${NGINX_HTTP_CONF_PATH:-}" \
  "${NGINX_LOCATIONS_CONF_PATH:-}" \
  "${NGINX_SSL_CONF_PATH:-}" \
  "${NGINX_VERIFY_REQUIRE_SSL:-}" \
  "${NGINX_VERIFY_RUN_NGINX_TEST:-}"
[[ "${NGINX_HTTP_CONF_PATH:-}" == "/tmp/audit-unit-nginx-http.conf" ]]
[[ "${NGINX_LOCATIONS_CONF_PATH:-}" == "/tmp/audit-unit-nginx-locations.conf" ]]
[[ "${NGINX_SSL_CONF_PATH:-}" == "/tmp/audit-unit-nginx-ssl.conf" ]]
[[ "${NGINX_VERIFY_REQUIRE_SSL:-}" == "true" ]]
[[ "${NGINX_VERIFY_RUN_NGINX_TEST:-}" == "true" ]]
EOF
  chmod +x "${fake_script_dir}/62_verify_nginx_config.sh"
  old_script_dir="${SCRIPT_DIR}"
  old_nginx_required="${AUDIT_REQUIRE_NGINX_CONFIG}"
  old_nginx_http_conf="${AUDIT_NGINX_HTTP_CONF_PATH}"
  old_nginx_locations_conf="${AUDIT_NGINX_LOCATIONS_CONF_PATH}"
  old_nginx_ssl_conf="${AUDIT_NGINX_SSL_CONF_PATH}"
  old_nginx_require_ssl="${AUDIT_NGINX_REQUIRE_SSL}"
  SCRIPT_DIR="${fake_script_dir}"
  AUDIT_REQUIRE_NGINX_CONFIG=true
  AUDIT_NGINX_HTTP_CONF_PATH="/tmp/audit-unit-nginx-http.conf"
  AUDIT_NGINX_LOCATIONS_CONF_PATH="/tmp/audit-unit-nginx-locations.conf"
  AUDIT_NGINX_SSL_CONF_PATH="/tmp/audit-unit-nginx-ssl.conf"
  AUDIT_NGINX_REQUIRE_SSL=true
  failures=0
  nginx_log="${self_test_dir}/nginx-config.log"
  check_nginx_config >"${nginx_log}"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=nginx_config_check_rejected output=%s\n' "$(cat "${nginx_log}")" >&2
    SCRIPT_DIR="${old_script_dir}"
    return 1
  fi
  grep -q 'check=nginx-config' "${nginx_log}" || {
    printf 'audit-unit-self-test result=fail reason=nginx_config_check_absent output=%s\n' "$(cat "${nginx_log}")" >&2
    SCRIPT_DIR="${old_script_dir}"
    return 1
  }
  cat >"${fake_script_dir}/62_verify_nginx_config.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake-nginx-verify result=fail reason=bad_config\n' >&2
exit 7
EOF
  chmod +x "${fake_script_dir}/62_verify_nginx_config.sh"
  failures=0
  check_nginx_config >"${self_test_dir}/nginx-config-bad.log"
  expected_failures="${failures}"
  failures=0
  SCRIPT_DIR="${old_script_dir}"
  AUDIT_REQUIRE_NGINX_CONFIG="${old_nginx_required}"
  AUDIT_NGINX_HTTP_CONF_PATH="${old_nginx_http_conf}"
  AUDIT_NGINX_LOCATIONS_CONF_PATH="${old_nginx_locations_conf}"
  AUDIT_NGINX_SSL_CONF_PATH="${old_nginx_ssl_conf}"
  AUDIT_NGINX_REQUIRE_SSL="${old_nginx_require_ssl}"
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=nginx_config_bad_accepted output=%s\n' "$(cat "${self_test_dir}/nginx-config-bad.log")" >&2
    return 1
  fi

  cloud_sg_good="${self_test_dir}/cloud-security-group-good.json"
  cloud_sg_bad="${self_test_dir}/cloud-security-group-bad.json"
  cat >"${cloud_sg_good}" <<'JSON'
[
  {"protocol":"tcp","port":"80/80","source":"0.0.0.0/0","action":"allow"},
  {"protocol":"tcp","port":"443/443","source":"0.0.0.0/0","action":"allow"},
  {"protocol":"tcp","port":"9000/9000","source":"0.0.0.0/0","action":"allow"},
  {"protocol":"tcp","port":"22/22","source":"203.0.113.10/32","action":"allow"}
]
JSON
  cat >"${cloud_sg_bad}" <<'JSON'
[
  {"protocol":"tcp","port":"22/22","source":"0.0.0.0/0","action":"allow"}
]
JSON
  old_cloud_sg_required="${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"
  old_cloud_sg_rules_file="${AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE}"
  old_cloud_sg_require_root_owner="${AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}"
  AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=true
  AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_sg_good}"
  AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false
  failures=0
  check_cloud_security_group >"${self_test_dir}/cloud-security-group-good.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=cloud_security_group_good_rejected output=%s\n' "$(cat "${self_test_dir}/cloud-security-group-good.log")" >&2
    return 1
  fi
  AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_sg_bad}"
  failures=0
  check_cloud_security_group >"${self_test_dir}/cloud-security-group-bad.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=cloud_security_group_bad_accepted output=%s\n' "$(cat "${self_test_dir}/cloud-security-group-bad.log")" >&2
    return 1
  fi
  grep -q 'public_admin_port:22' "${self_test_dir}/cloud-security-group-bad.log" || {
    printf 'audit-unit-self-test result=fail reason=cloud_security_group_bad_reason_missing output=%s\n' "$(cat "${self_test_dir}/cloud-security-group-bad.log")" >&2
    return 1
  }
  repair_snapshot="${self_test_dir}/repair-snapshot.json"
  repair_post_snapshot="${self_test_dir}/repair-snapshot.post-apply"
  repair_plan="${self_test_dir}/repair-plan.json"
  repair_receipt="${self_test_dir}/repair-receipt.json"
  repair_dry_run_receipt="${self_test_dir}/repair-receipt-dry-run.json"
  cp "${cloud_sg_good}" "${repair_snapshot}"
  cp "${cloud_sg_good}" "${repair_post_snapshot}"
  python3 - "${repair_snapshot}" "${repair_post_snapshot}" "${repair_plan}" "${repair_receipt}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

snapshot, post_snapshot, plan_path, receipt_path = map(Path, sys.argv[1:5])
plan = {
    "schemaVersion": 1,
    "securityGroupId": "sg-audit-selftest",
    "snapshot": str(snapshot.resolve()),
    "adminCidr": "203.0.113.10/32",
    "publicClientPorts": [80, 443, 9000],
    "adminPorts": [22],
    "denyPublicPorts": [22, 3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080],
    "status": "NOOP",
    "actions": [],
    "summary": {"actionCount": 0, "authorizeCount": 0, "revokeCount": 0},
}
plan_path.write_text(json.dumps(plan, indent=2, sort_keys=True), encoding="utf-8")

def file_record(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    return {
        "path": str(path.resolve()),
        "present": True,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }

receipt = {
    "schemaVersion": 1,
    "status": "APPLIED_VERIFIED",
    "generatedAtEpoch": int(time.time()),
    "securityGroupId": "sg-audit-selftest",
    "regionId": "cn-shenzhen",
    "adminCidr": "203.0.113.10/32",
    "applyRequested": True,
    "applied": True,
    "verifyRequested": True,
    "verified": True,
    "snapshot": str(snapshot.resolve()),
    "postApplySnapshot": str(post_snapshot.resolve()),
    "plan": str(plan_path.resolve()),
    "planStatus": "NOOP",
    "summary": plan["summary"],
    "artifacts": {
        "snapshot": file_record(snapshot),
        "postApplySnapshot": file_record(post_snapshot),
        "plan": file_record(plan_path),
    },
}
receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
PY
  python3 - "${repair_receipt}" "${repair_dry_run_receipt}" <<'PY'
import json
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:3])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["status"] = "DRY_RUN"
payload["applyRequested"] = False
payload["applied"] = False
payload["verifyRequested"] = True
payload["verified"] = False
payload["postApplySnapshot"] = ""
payload["artifacts"]["postApplySnapshot"] = {
    "path": "",
    "present": False,
    "bytes": 0,
    "sha256": "",
}
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  old_cloud_sg_repair_receipt_required="${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}"
  old_cloud_sg_repair_receipt_json="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}"
  old_cloud_sg_repair_receipt_max_age="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}"
  old_cloud_sg_repair_receipt_expect_sg="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}"
  old_cloud_sg_repair_receipt_expect_region="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}"
  old_cloud_sg_repair_receipt_expect_admin="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}"
  AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE=true
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt}"
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-audit-selftest
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32
  failures=0
  check_cloud_security_group_repair_receipt >"${self_test_dir}/cloud-security-group-repair-receipt-good.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=cloud_security_group_repair_receipt_good_rejected output=%s\n' "$(cat "${self_test_dir}/cloud-security-group-repair-receipt-good.log")" >&2
    return 1
  fi
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-hangzhou
  failures=0
  check_cloud_security_group_repair_receipt >"${self_test_dir}/cloud-security-group-repair-receipt-bad.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=cloud_security_group_repair_receipt_bad_accepted output=%s\n' "$(cat "${self_test_dir}/cloud-security-group-repair-receipt-bad.log")" >&2
    return 1
  fi
  grep -q 'region_id_mismatch' "${self_test_dir}/cloud-security-group-repair-receipt-bad.log" || {
    printf 'audit-unit-self-test result=fail reason=cloud_security_group_repair_receipt_bad_reason_missing output=%s\n' "$(cat "${self_test_dir}/cloud-security-group-repair-receipt-bad.log")" >&2
    return 1
  }
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_dry_run_receipt}"
  failures=0
  check_cloud_security_group_repair_receipt >"${self_test_dir}/cloud-security-group-repair-receipt-dry-run.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=cloud_security_group_repair_receipt_dry_run_accepted output=%s\n' "$(cat "${self_test_dir}/cloud-security-group-repair-receipt-dry-run.log")" >&2
    return 1
  fi
  grep -q 'applied_required' "${self_test_dir}/cloud-security-group-repair-receipt-dry-run.log" || {
    printf 'audit-unit-self-test result=fail reason=cloud_security_group_repair_receipt_dry_run_reason_missing output=%s\n' "$(cat "${self_test_dir}/cloud-security-group-repair-receipt-dry-run.log")" >&2
    return 1
  }
  AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE="${old_cloud_sg_repair_receipt_required}"
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${old_cloud_sg_repair_receipt_json}"
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${old_cloud_sg_repair_receipt_max_age}"
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${old_cloud_sg_repair_receipt_expect_sg}"
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${old_cloud_sg_repair_receipt_expect_region}"
  AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${old_cloud_sg_repair_receipt_expect_admin}"
  AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="${old_cloud_sg_required}"
  AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE="${old_cloud_sg_rules_file}"
  AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${old_cloud_sg_require_root_owner}"

  local topology_smoke_receipt topology_smoke_failed_receipt old_topology_required old_topology_receipt old_topology_max_age old_topology_require_artifacts
  topology_smoke_receipt="${self_test_dir}/latest-production-smoke.json"
  topology_smoke_failed_receipt="${self_test_dir}/failed-production-smoke.json"
  python3 - "${topology_smoke_receipt}" "${topology_smoke_failed_receipt}" "${self_test_dir}/topology-smoke-artifacts" <<'PY'
import json
import sys
import time
from pathlib import Path

receipt, failed_receipt, artifact_dir = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
artifact_dir.mkdir(parents=True, exist_ok=True)
artifacts = {}
for name in ("markdownReport", "stateFile", "composePs", "composeLog", "outboxInspect"):
    artifact = artifact_dir / f"{name}.txt"
    artifact.write_text("ok\n", encoding="utf-8")
    artifacts[name] = str(artifact)
checks = [
    "auth_register_or_login",
    "changes_projection",
    "conversation_create",
    "docker_compose_runtime_roles",
    "http_health",
    "message_write",
    "messages_since",
    "metrics_secret",
    "outbox_recovery",
    "runtime_services_health",
    "summary_projection",
]
payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": "passed",
    "exitCode": 0,
    "environment": "production-smoke",
    "project": "imserver-production-smoke",
    "runtimeEvidence": True,
    "composeFile": "docker-compose.production-smoke.yml",
    "endpoints": {
        "gateway": "http://127.0.0.1:8080",
        "command": "http://127.0.0.1:8081",
        "query": "http://127.0.0.1:8082",
    },
    "conversations": {
        "directConversationID": "direct-1",
        "groupConversationID": "group-1",
    },
    "source": {
        "gitCommit": "abc123",
        "gitBranch": "main",
        "gitDirty": False,
    },
    "artifacts": artifacts,
    "checks": [{"name": name, "status": "passed"} for name in checks],
}
receipt.write_text(json.dumps(payload), encoding="utf-8")
payload["status"] = "failed"
payload["exitCode"] = 1
failed_receipt.write_text(json.dumps(payload), encoding="utf-8")
PY
  old_topology_required="${AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE}"
  old_topology_receipt="${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON}"
  old_topology_max_age="${AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}"
  old_topology_require_artifacts="${AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS}"
  AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE=true
  AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_smoke_receipt}"
  AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=86400
  AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS=true
  failures=0
  check_topology_smoke_receipt >"${self_test_dir}/topology-smoke-good.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=topology_smoke_good_rejected output=%s\n' "$(cat "${self_test_dir}/topology-smoke-good.log")" >&2
    return 1
  fi
  AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_smoke_failed_receipt}"
  failures=0
  check_topology_smoke_receipt >"${self_test_dir}/topology-smoke-bad.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=topology_smoke_bad_accepted output=%s\n' "$(cat "${self_test_dir}/topology-smoke-bad.log")" >&2
    return 1
  fi
  grep -q 'status_not_passed' "${self_test_dir}/topology-smoke-bad.log" || {
    printf 'audit-unit-self-test result=fail reason=topology_smoke_bad_reason_missing output=%s\n' "$(cat "${self_test_dir}/topology-smoke-bad.log")" >&2
    return 1
  }
  AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE="${old_topology_required}"
  AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON="${old_topology_receipt}"
  AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS="${old_topology_max_age}"
  AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS="${old_topology_require_artifacts}"

  local ufw_public_ssh ufw_restricted_ssh ufw_broad_public_ssh ufw_private_ssh ufw_with_rdp
  ufw_public_ssh=$'Status: active\n[ 1] 22/tcp ALLOW IN Anywhere\n[ 2] 9000/tcp ALLOW IN Anywhere'
  ufw_restricted_ssh=$'Status: active\n[ 1] 22/tcp ALLOW IN 203.0.113.10\n[ 2] 9000/tcp ALLOW IN Anywhere'
  ufw_broad_public_ssh=$'Status: active\n[ 1] 22/tcp ALLOW IN 47.0.0.0/8\n[ 2] 9000/tcp ALLOW IN Anywhere'
  ufw_private_ssh=$'Status: active\n[ 1] 22/tcp ALLOW IN 10.0.0.0/8\n[ 2] 9000/tcp ALLOW IN Anywhere'
  ufw_with_rdp=$'Status: active\n[ 1] 3389/tcp ALLOW IN Anywhere\n[ 2] 22/tcp ALLOW IN 203.0.113.10'
  ufw_rule_allows_port "${ufw_public_ssh}" "${SSH_PORT}" || {
    printf 'audit-unit-self-test result=fail reason=ufw_ssh_allow_not_detected\n' >&2
    return 1
  }
  ufw_rule_allows_public_port "${ufw_public_ssh}" "${SSH_PORT}" || {
    printf 'audit-unit-self-test result=fail reason=ufw_public_ssh_not_detected\n' >&2
    return 1
  }
  if ufw_rule_allows_public_port "${ufw_restricted_ssh}" "${SSH_PORT}"; then
    printf 'audit-unit-self-test result=fail reason=ufw_restricted_ssh_marked_public\n' >&2
    return 1
  fi
  ufw_rule_allows_public_port "${ufw_broad_public_ssh}" "${SSH_PORT}" || {
    printf 'audit-unit-self-test result=fail reason=ufw_broad_public_ssh_not_detected\n' >&2
    return 1
  }
  if ufw_rule_allows_public_port "${ufw_private_ssh}" "${SSH_PORT}"; then
    printf 'audit-unit-self-test result=fail reason=ufw_private_ssh_marked_public\n' >&2
    return 1
  fi
  ufw_rule_allows_port "${ufw_with_rdp}" "3389" || {
    printf 'audit-unit-self-test result=fail reason=ufw_rdp_allow_not_detected\n' >&2
    return 1
  }

  redis_conf_good="${self_test_dir}/redis-good.conf"
  redis_conf_bad="${self_test_dir}/redis-bad.conf"
  cat >"${redis_conf_good}" <<'EOF'
bind 127.0.0.1 ::1
protected-mode yes
EOF
  cat >"${redis_conf_bad}" <<'EOF'
bind 0.0.0.0
protected-mode no
EOF
  old_ss_fixture="${AUDIT_SS_LISTEN_FIXTURE}"
  old_redis_config="${AUDIT_REDIS_CONFIG_FILE}"
  old_datastore_required="${AUDIT_REQUIRE_DATASTORE_LOOPBACK}"
  AUDIT_REQUIRE_DATASTORE_LOOPBACK=true
  AUDIT_REDIS_CONFIG_FILE="${redis_conf_good}"
  AUDIT_SS_LISTEN_FIXTURE=$'State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 4096 127.0.0.1:5432 0.0.0.0:*\nLISTEN 0 4096 [::1]:6379 [::]:*'
  failures=0
  check_datastore_exposure >"${self_test_dir}/datastore-good.log"
  if [[ "${failures}" != "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=datastore_good_rejected output=%s\n' "$(cat "${self_test_dir}/datastore-good.log")" >&2
    return 1
  fi
  AUDIT_REDIS_CONFIG_FILE="${redis_conf_bad}"
  AUDIT_SS_LISTEN_FIXTURE=$'State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 4096 0.0.0.0:5432 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:6379 0.0.0.0:*'
  failures=0
  check_datastore_exposure >"${self_test_dir}/datastore-bad.log"
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=datastore_bad_accepted output=%s\n' "$(cat "${self_test_dir}/datastore-bad.log")" >&2
    return 1
  fi
  grep -q 'check=postgres-listener' "${self_test_dir}/datastore-bad.log" || {
    printf 'audit-unit-self-test result=fail reason=datastore_bad_postgres_reason_missing output=%s\n' "$(cat "${self_test_dir}/datastore-bad.log")" >&2
    return 1
  }
  grep -q 'check=redis-protected-mode' "${self_test_dir}/datastore-bad.log" || {
    printf 'audit-unit-self-test result=fail reason=datastore_bad_redis_reason_missing output=%s\n' "$(cat "${self_test_dir}/datastore-bad.log")" >&2
    return 1
  }
  AUDIT_SS_LISTEN_FIXTURE="${old_ss_fixture}"
  AUDIT_REDIS_CONFIG_FILE="${old_redis_config}"
  AUDIT_REQUIRE_DATASTORE_LOOPBACK="${old_datastore_required}"

  service_file="${AUDIT_SYSTEMD_DIR}/imserver-operational-audit.service"
  cp "${service_file}" "${service_file}.good"
  python3 - "${service_file}" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true\n", ""), encoding="utf-8")
PY
  failures=0
  check_operational_audit_timer_units >/dev/null
  expected_failures="${failures}"
  failures=0
  cp "${service_file}.good" "${service_file}"
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=broken_operational_audit_validation_inventory_unit_accepted\n' >&2
    return 1
  fi

  alert_file="${AUDIT_SYSTEMD_DIR}/imserver-backup-alert@.service"
  cp "${alert_file}" "${alert_file}.good"
  python3 - "${alert_file}" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("EnvironmentFile=-/etc/imserver/operational-alert.env\n", ""), encoding="utf-8")
PY
  failures=0
  check_backup_timer_units >/dev/null
  expected_failures="${failures}"
  failures=0
  cp "${alert_file}.good" "${alert_file}"
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=broken_backup_alert_env_unit_accepted\n' >&2
    return 1
  fi

  service_file="${AUDIT_SYSTEMD_DIR}/imserver-backup.service"
  python3 - "${service_file}" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("ExecStartPost=/bin/bash ", "# ExecStartPost removed /bin/bash "), encoding="utf-8")
PY
  failures=0
  check_backup_timer_units >/dev/null
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=broken_backup_unit_accepted\n' >&2
    return 1
  fi

  alert_file="${AUDIT_SYSTEMD_DIR}/imserver-restore-drill-alert@.service"
  cp "${alert_file}" "${alert_file}.good"
  python3 - "${alert_file}" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("Environment=AUDIT_ALERT_LOG_FILE=/var/log/imserver/restore-drill.log\n", ""), encoding="utf-8")
PY
  failures=0
  check_restore_drill_timer_units >/dev/null
  expected_failures="${failures}"
  failures=0
  cp "${alert_file}.good" "${alert_file}"
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=broken_restore_drill_alert_log_unit_accepted\n' >&2
    return 1
  fi

  service_file="${AUDIT_SYSTEMD_DIR}/imserver-operational-audit.service"
  python3 - "${service_file}" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("OnFailure=imserver-operational-alert@%n.service", "# OnFailure removed"), encoding="utf-8")
PY
  failures=0
  check_operational_audit_timer_units >/dev/null
  expected_failures="${failures}"
  failures=0
  if [[ "${expected_failures}" == "0" ]]; then
    printf 'audit-unit-self-test result=fail reason=broken_operational_audit_unit_accepted\n' >&2
    return 1
  fi

  printf 'audit-unit-self-test result=pass\n'
}

file_owner_group() {
  stat -c '%U:%G' "$1" 2>/dev/null || printf 'unknown:unknown'
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || printf 'unknown'
}

check_path_mode() {
  local path="$1"
  local expected_owner_group="$2"
  local expected_mode="$3"
  local check_name="$4"

  if [[ ! -e "${path}" ]]; then
    fail "${check_name}" "missing path=${path}"
    return
  fi

  local owner_group mode
  owner_group="$(file_owner_group "${path}")"
  mode="$(file_mode "${path}")"
  if [[ "${owner_group}" == "${expected_owner_group}" && "${mode}" == "${expected_mode}" ]]; then
    pass "${check_name}" "path=${path} owner=${owner_group} mode=${mode}"
  else
    fail "${check_name}" "path=${path}_owner_${owner_group}_mode_${mode}_expected_${expected_owner_group}_${expected_mode}"
  fi
}

check_config_permissions() {
  check_path_mode "${IMSERVER_ETC_DIR}" "root:root" "750" "config-permissions"
  check_path_mode "${IMSERVER_ETC_DIR}/common.env" "root:root" "640" "config-permissions"
  check_path_mode "${IMSERVER_ETC_DIR}/roles" "root:root" "750" "config-permissions"

  local role_env
  shopt -s nullglob
  for role_env in "${IMSERVER_ETC_DIR}"/roles/*.env; do
    check_path_mode "${role_env}" "root:root" "640" "config-permissions"
  done
  shopt -u nullglob

  if [[ -e "${AUDIT_ALERT_ENV_FILE}" ]]; then
    check_path_mode "${AUDIT_ALERT_ENV_FILE}" "root:root" "600" "config-permissions"
  fi
}

check_production_env() {
  if ! bool_enabled "${AUDIT_REQUIRE_PRODUCTION_ENV}"; then
    pass "production-env" "skipped=true"
    return
  fi

  local output rc=0
  output="$(
    ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}" \
    ROLES_DIR="${ROLES_DIR:-${IMSERVER_ETC_DIR}/roles}" \
    VERIFY_REQUIRE_PRODUCTION="${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-false}" \
      bash "${SCRIPT_DIR}/55_verify_production_env.sh" 2>&1
  )" || rc=$?

  if (( rc == 0 )); then
    if grep -q 'production-env-check=skip' <<<"${output}"; then
      pass "production-env" "skipped=not_production"
    else
      pass "production-env" "result=pass"
    fi
  else
    fail "production-env" "${output//$'\n'/ }"
  fi
}

check_https_certificate() {
  if ! bool_enabled "${AUDIT_REQUIRE_HTTPS_CERTIFICATE}"; then
    pass "https-certificate" "skipped=true"
    return
  fi
  if [[ -z "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}" ]]; then
    pass "https-certificate" "skipped=missing_public_base_url"
    return
  fi

  local scheme host port min_seconds cert_file
  scheme="$(audit_scheme_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
  host="$(audit_host_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
  port="$(audit_port_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
  if [[ "${scheme}" != "https" ]]; then
    fail "https-certificate" "public_base_url_not_https"
    return
  fi
  if [[ -z "${host}" ]]; then
    fail "https-certificate" "public_base_url_missing_host"
    return
  fi
  if ! [[ "${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}" =~ ^[0-9]+$ ]]; then
    fail "https-certificate" "invalid_min_valid_days_${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}"
    return
  fi
  min_seconds=$((AUDIT_HTTPS_CERT_MIN_VALID_DAYS * 86400))
  cert_file="${AUDIT_HTTPS_CERT_FILE:-/etc/letsencrypt/live/${host}/fullchain.pem}"

  if [[ "${AUDIT_HTTPS_CERT_MODE}" == "local" || "${AUDIT_HTTPS_CERT_MODE}" == "auto" ]]; then
    if [[ -f "${cert_file}" ]]; then
      if ! command -v openssl >/dev/null 2>&1; then
        fail "https-certificate" "openssl_missing"
        return
      fi
      if openssl x509 -checkend "${min_seconds}" -noout -in "${cert_file}" >/dev/null 2>&1; then
        pass "https-certificate" "source=local host=${host} minValidDays=${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}"
      else
        fail "https-certificate" "local_cert_expires_within_${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}_days host=${host}"
      fi
      return
    fi
    if [[ "${AUDIT_HTTPS_CERT_MODE}" == "local" ]]; then
      fail "https-certificate" "local_cert_missing path=${cert_file}"
      return
    fi
  fi

  if [[ "${AUDIT_HTTPS_CERT_MODE}" == "public" || "${AUDIT_HTTPS_CERT_MODE}" == "auto" ]]; then
    port="${port:-443}"
    if ! command -v openssl >/dev/null 2>&1; then
      fail "https-certificate" "openssl_missing"
      return
    fi
    if timeout 10 bash -c 'printf "" | openssl s_client -servername "$1" -connect "$1:$2" 2>/dev/null | openssl x509 -checkend "$3" -noout' _ "${host}" "${port}" "${min_seconds}" >/dev/null 2>&1; then
      pass "https-certificate" "source=public host=${host} port=${port} minValidDays=${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}"
    else
      fail "https-certificate" "public_cert_unreachable_or_expires_within_${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}_days host=${host} port=${port}"
    fi
    return
  fi

  fail "https-certificate" "invalid_mode_${AUDIT_HTTPS_CERT_MODE}"
}

check_certbot_renewal_timer() {
  if ! bool_enabled "${AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER}"; then
    pass "certbot-renewal-timer" "skipped=true"
    return
  fi
  if ! bool_enabled "${AUDIT_REQUIRE_HTTPS_CERTIFICATE}"; then
    pass "certbot-renewal-timer" "skipped=https_certificate_not_required"
    return
  fi
  if [[ -z "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}" ]]; then
    pass "certbot-renewal-timer" "skipped=missing_public_base_url"
    return
  fi
  local scheme
  scheme="$(audit_scheme_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
  if [[ "${scheme}" != "https" ]]; then
    pass "certbot-renewal-timer" "skipped=public_base_url_not_https"
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    fail "certbot-renewal-timer" "systemctl_missing"
    return
  fi
  if systemctl is-enabled --quiet certbot.timer && systemctl is-active --quiet certbot.timer; then
    pass "certbot-renewal-timer" "name=certbot.timer"
  else
    fail "certbot-renewal-timer" "certbot_timer_not_enabled_or_inactive"
  fi
}

check_alert_webhook() {
  local webhook_url redact_log_tail
  webhook_url="$(configured_alert_webhook_url)"
  if [[ -z "${webhook_url}" ]]; then
    if bool_enabled "${AUDIT_REQUIRE_ALERT_WEBHOOK_EFFECTIVE}"; then
      fail "alert-webhook" "missing"
    else
      pass "alert-webhook" "skipped=not_configured required=false"
    fi
    return
  fi
  if ! valid_alert_webhook_url "${webhook_url}"; then
    fail "alert-webhook" "invalid_url urlReason=$(alert_webhook_url_policy_reason "${webhook_url}")"
    return
  fi
  redact_log_tail="$(configured_alert_redact_log_tail)"
  if bool_enabled "${AUDIT_REQUIRE_ALERT_LOG_REDACTION_EFFECTIVE}" && ! bool_enabled "${redact_log_tail}"; then
    fail "alert-webhook" "log_tail_redaction_disabled"
    return
  fi
  pass "alert-webhook" "configured=true logTailRedaction=${redact_log_tail}"
}

latest_backup_age_seconds() {
  local manifest_file="$1"
  local max_future_skew_seconds="$2"
  python3 - "${manifest_file}" "${max_future_skew_seconds}" <<'PY'
import json
import sys
from datetime import datetime, timezone

manifest, max_future_skew_seconds = sys.argv[1:3]
with open(manifest, encoding="utf-8") as handle:
    payload = json.load(handle)
created_at = payload.get("createdAt")
if not created_at:
    raise SystemExit("manifest_createdAt_missing")
value = str(created_at).strip()
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
try:
    parsed = datetime.fromisoformat(value)
except ValueError as exc:
    raise SystemExit(f"manifest_createdAt_invalid:{created_at}") from exc
if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)
age = int((datetime.now(timezone.utc) - parsed.astimezone(timezone.utc)).total_seconds())
try:
    max_future_skew = int(max_future_skew_seconds)
except ValueError as exc:
    raise SystemExit(f"manifest_max_future_skew_invalid:{max_future_skew_seconds}") from exc
if age < -max_future_skew:
    raise SystemExit(f"manifest_createdAt_in_future ageSeconds={age} maxFutureSkewSeconds={max_future_skew}")
print(max(age, 0))
PY
}

check_latest_backup_freshness() {
  local backup_dir="$1"
  if ! bool_enabled "${AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS}"; then
    pass "latest-backup-freshness" "skipped=true dir=${backup_dir}"
    return
  fi
  if ! [[ "${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}" =~ ^[0-9]+$ ]] || (( AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS < 1 )); then
    fail "latest-backup-freshness" "invalid_max_age_${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}"
    return
  fi
  if ! [[ "${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS}" =~ ^[0-9]+$ ]]; then
    fail "latest-backup-freshness" "invalid_max_future_skew_${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS}"
    return
  fi
  if [[ ! -f "${backup_dir}/manifest.json" ]]; then
    fail "latest-backup-freshness" "manifest_missing dir=${backup_dir}"
    return
  fi

  local age rc=0
  age="$(latest_backup_age_seconds "${backup_dir}/manifest.json" "${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    fail "latest-backup-freshness" "${age//$'\n'/ }"
    return
  fi
  if (( age <= AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS )); then
    pass "latest-backup-freshness" "ageSeconds=${age} maxAgeSeconds=${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}"
  else
    fail "latest-backup-freshness" "stale ageSeconds=${age} maxAgeSeconds=${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}"
  fi
}

check_latest_backup() {
  local latest_dir="${BACKUP_ROOT}/latest"
  if [[ -d "${latest_dir}" || -L "${latest_dir}" ]]; then
    check_latest_backup_freshness "${latest_dir}"
    if ! bool_enabled "${AUDIT_VERIFY_LATEST_BACKUP}"; then
      pass "latest-backup" "skipped=verification_disabled dir=${latest_dir}"
    elif BACKUP_DIR="${latest_dir}" bash "${SCRIPT_DIR}/81_verify_backup.sh" >/dev/null; then
      pass "latest-backup" "dir=${latest_dir}"
    else
      fail "latest-backup" "verification_failed"
    fi
  elif bool_enabled "${AUDIT_REQUIRE_BACKUP}"; then
    fail "latest-backup" "missing"
  else
    pass "latest-backup" "skipped=missing_latest_backup"
  fi
}

restore_drill_receipt_age_seconds() {
  local receipt_file="$1"
  local max_future_skew_seconds="$2"
  python3 - "${receipt_file}" "${max_future_skew_seconds}" <<'PY'
import json
import sys
from datetime import datetime, timezone

receipt, max_future_skew_seconds = sys.argv[1:3]
with open(receipt, encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("result") != "pass":
    raise SystemExit("receipt_result_not_pass")
if not payload.get("backupManifestSha256"):
    raise SystemExit("receipt_backupManifestSha256_missing")
completed_at = payload.get("completedAt")
if not completed_at:
    raise SystemExit("receipt_completedAt_missing")
try:
    public_tables = int(payload.get("publicBaseTables"))
except (TypeError, ValueError) as exc:
    raise SystemExit("receipt_publicBaseTables_invalid") from exc
if public_tables <= 0:
    raise SystemExit("receipt_publicBaseTables_empty")
required_tables = payload.get("requiredTables")
if not isinstance(required_tables, list) or not required_tables:
    raise SystemExit("receipt_requiredTables_missing")
for table in required_tables:
    if not isinstance(table, str) or not table.strip():
        raise SystemExit("receipt_requiredTables_invalid")
value = str(completed_at).strip()
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
try:
    parsed = datetime.fromisoformat(value)
except ValueError as exc:
    raise SystemExit(f"receipt_completedAt_invalid:{completed_at}") from exc
if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)
age = int((datetime.now(timezone.utc) - parsed.astimezone(timezone.utc)).total_seconds())
try:
    max_future_skew = int(max_future_skew_seconds)
except ValueError as exc:
    raise SystemExit(f"receipt_max_future_skew_invalid:{max_future_skew_seconds}") from exc
if age < -max_future_skew:
    raise SystemExit(f"receipt_completedAt_in_future ageSeconds={age} maxFutureSkewSeconds={max_future_skew}")
print(max(age, 0))
PY
}

check_restore_drill_freshness() {
  if ! bool_enabled "${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS}"; then
    pass "restore-drill-freshness" "skipped=true"
    return
  fi
  if ! [[ "${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}" =~ ^[0-9]+$ ]] || (( AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS < 1 )); then
    fail "restore-drill-freshness" "invalid_max_age_${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}"
    return
  fi
  if ! [[ "${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS}" =~ ^[0-9]+$ ]]; then
    fail "restore-drill-freshness" "invalid_max_future_skew_${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS}"
    return
  fi
  if [[ ! -f "${AUDIT_RESTORE_DRILL_RECEIPT_FILE}" ]]; then
    fail "restore-drill-freshness" "receipt_missing file=${AUDIT_RESTORE_DRILL_RECEIPT_FILE}"
    return
  fi

  local age rc=0
  age="$(restore_drill_receipt_age_seconds "${AUDIT_RESTORE_DRILL_RECEIPT_FILE}" "${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    fail "restore-drill-freshness" "${age//$'\n'/ }"
    return
  fi
  if (( age <= AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS )); then
    pass "restore-drill-freshness" "ageSeconds=${age} maxAgeSeconds=${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}"
  else
    fail "restore-drill-freshness" "stale ageSeconds=${age} maxAgeSeconds=${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}"
  fi
}

offsite_backup_receipt_age_seconds() {
  local receipt_file="$1"
  local max_future_skew_seconds="$2"
  python3 - "${receipt_file}" "${max_future_skew_seconds}" <<'PY'
import json
import sys
from datetime import datetime, timezone

receipt, max_future_skew_seconds = sys.argv[1:3]
with open(receipt, encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("result") != "pass":
    raise SystemExit("receipt_result_not_pass")
for key in ("backupID", "target", "backupManifestSha256"):
    if not payload.get(key):
        raise SystemExit(f"receipt_{key}_missing")
if payload.get("postSyncVerify") is not True:
    raise SystemExit("receipt_postSyncVerify_not_true")
if payload.get("postSyncVerifyMode") != "rsync-dry-run-checksum-delete":
    raise SystemExit("receipt_postSyncVerifyMode_invalid")
completed_at = payload.get("completedAt")
if not completed_at:
    raise SystemExit("receipt_completedAt_missing")
value = str(completed_at).strip()
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
try:
    parsed = datetime.fromisoformat(value)
except ValueError as exc:
    raise SystemExit(f"receipt_completedAt_invalid:{completed_at}") from exc
if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)
age = int((datetime.now(timezone.utc) - parsed.astimezone(timezone.utc)).total_seconds())
try:
    max_future_skew = int(max_future_skew_seconds)
except ValueError as exc:
    raise SystemExit(f"receipt_max_future_skew_invalid:{max_future_skew_seconds}") from exc
if age < -max_future_skew:
    raise SystemExit(f"receipt_completedAt_in_future ageSeconds={age} maxFutureSkewSeconds={max_future_skew}")
print(max(age, 0))
PY
}

check_offsite_backup_freshness() {
  if ! bool_enabled "${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS}"; then
    pass "offsite-backup-freshness" "skipped=true"
    return
  fi
  if ! [[ "${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}" =~ ^[0-9]+$ ]] || (( AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS < 1 )); then
    fail "offsite-backup-freshness" "invalid_max_age_${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}"
    return
  fi
  if ! [[ "${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS}" =~ ^[0-9]+$ ]]; then
    fail "offsite-backup-freshness" "invalid_max_future_skew_${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS}"
    return
  fi
  if [[ ! -f "${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE}" ]]; then
    fail "offsite-backup-freshness" "receipt_missing file=${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE}"
    return
  fi

  local age rc=0
  age="$(offsite_backup_receipt_age_seconds "${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE}" "${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    fail "offsite-backup-freshness" "${age//$'\n'/ }"
    return
  fi
  if (( age <= AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS )); then
    pass "offsite-backup-freshness" "ageSeconds=${age} maxAgeSeconds=${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}"
  else
    fail "offsite-backup-freshness" "stale ageSeconds=${age} maxAgeSeconds=${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}"
  fi
}

check_kafka_lag() {
  if ! bool_enabled "${AUDIT_REQUIRE_KAFKA_LAG_EFFECTIVE}"; then
    pass "kafka-lag" "skipped=true"
    return
  fi
  local output rc=0
  output="$(
    KAFKA_BOOTSTRAP_SERVER="${AUDIT_KAFKA_BOOTSTRAP_SERVER:-${KAFKA_BOOTSTRAP_SERVER:-127.0.0.1:9092}}" \
    KAFKA_CONSUMER_GROUPS_CMD="${AUDIT_KAFKA_CONSUMER_GROUPS_CMD:-${KAFKA_CONSUMER_GROUPS_CMD:-${KAFKA_HOME}/bin/kafka-consumer-groups.sh}}" \
    KAFKA_LAG_GROUPS="${AUDIT_KAFKA_LAG_GROUPS}" \
    KAFKA_LAG_MAX_TOTAL="${AUDIT_KAFKA_LAG_MAX_TOTAL}" \
    KAFKA_LAG_MAX_PARTITION="${AUDIT_KAFKA_LAG_MAX_PARTITION}" \
    KAFKA_LAG_REQUIRE_GROUPS="${AUDIT_KAFKA_LAG_REQUIRE_GROUPS}" \
      bash "${SCRIPT_DIR}/74_check_kafka_lag.sh" 2>&1
  )" || rc=$?
  if (( rc == 0 )); then
    pass "kafka-lag" "${output//$'\n'/ }"
  else
    fail "kafka-lag" "${output//$'\n'/ }"
  fi
}

check_nginx_config() {
  if ! bool_enabled "${AUDIT_REQUIRE_NGINX_CONFIG}"; then
    pass "nginx-config" "skipped=true"
    return
  fi
  local output rc=0
  output="$(
    NGINX_HTTP_CONF_PATH="${AUDIT_NGINX_HTTP_CONF_PATH}" \
    NGINX_LOCATIONS_CONF_PATH="${AUDIT_NGINX_LOCATIONS_CONF_PATH}" \
    NGINX_SSL_CONF_PATH="${AUDIT_NGINX_SSL_CONF_PATH}" \
    NGINX_VERIFY_REQUIRE_SSL="${AUDIT_NGINX_REQUIRE_SSL}" \
    NGINX_VERIFY_RUN_NGINX_TEST=true \
      bash "${SCRIPT_DIR}/62_verify_nginx_config.sh" 2>&1
  )" || rc=$?
  if (( rc == 0 )); then
    pass "nginx-config" "${output//$'\n'/ }"
  else
    fail "nginx-config" "${output//$'\n'/ }"
  fi
}

check_cloud_security_group() {
  if ! bool_enabled "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"; then
    pass "cloud-security-group" "skipped=true"
    return
  fi
  local output rc=0
  output="$(
    CLOUD_SECURITY_GROUP_RULES_FILE="${AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE}" \
    CLOUD_SECURITY_GROUP_PROFILE=production \
    CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
    CLOUD_SECURITY_GROUP_ADMIN_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
    CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
    CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
    CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
    CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
    CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
      bash "${SCRIPT_DIR}/26_audit_cloud_security_group.sh" 2>&1
  )" || rc=$?
  if (( rc == 0 )); then
    pass "cloud-security-group" "${output//$'\n'/ }"
  else
    fail "cloud-security-group" "${output//$'\n'/ }"
  fi
}

check_cloud_security_group_repair_receipt() {
  if ! bool_enabled "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}"; then
    pass "cloud-security-group-repair-receipt" "skipped=true"
    return
  fi
  local output rc=0
  output="$(
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
      bash "${SCRIPT_DIR}/31_verify_aliyun_security_group_repair_receipt.sh" 2>&1
  )" || rc=$?
  if (( rc == 0 )); then
    pass "cloud-security-group-repair-receipt" "${output//$'\n'/ }"
  else
    fail "cloud-security-group-repair-receipt" "${output//$'\n'/ }"
  fi
}

check_topology_smoke_receipt() {
  if ! bool_enabled "${AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE}"; then
    pass "topology-smoke-receipt" "skipped=true"
    return
  fi
  if [[ ! -f "${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON}" ]]; then
    fail "topology-smoke-receipt" "receipt_missing file=${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON}"
    return
  fi
  if [[ ! -f "${AUDIT_TOPOLOGY_SMOKE_VERIFIER}" ]]; then
    fail "topology-smoke-receipt" "verifier_missing file=${AUDIT_TOPOLOGY_SMOKE_VERIFIER}"
    return
  fi

  local args output rc=0
  args=(
    "--receipt-json" "${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON}"
    "--require-pass"
    "--max-age-seconds" "${AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}"
    "--max-future-skew-seconds" "${AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS}"
  )
  if bool_enabled "${AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS}"; then
    args+=("--require-artifacts-exist")
  fi
  output="$(python3 "${AUDIT_TOPOLOGY_SMOKE_VERIFIER}" "${args[@]}" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    pass "topology-smoke-receipt" "${output//$'\n'/ }"
  else
    fail "topology-smoke-receipt" "${output//$'\n'/ }"
  fi
}

check_release() {
  if [[ ! -L "${IMSERVER_BIN_DIR}/IMServer" ]]; then
    fail "release" "binary_is_not_symlink"
    return
  fi
  local target release_dir
  target="$(readlink -f "${IMSERVER_BIN_DIR}/IMServer")"
  if [[ -x "${target}" ]]; then
    pass "release" "binary=${target}"
  else
    fail "release" "target_not_executable"
    return
  fi
  release_dir="$(dirname "$(dirname "${target}")")"
  if [[ -L "${IMSERVER_CURRENT_LINK}" ]]; then
    pass "release-current" "current=$(readlink -f "${IMSERVER_CURRENT_LINK}")"
  else
    fail "release-current" "missing_current_symlink"
  fi
  if ! bool_enabled "${AUDIT_REQUIRE_RELEASE_MANIFEST}"; then
    pass "release-manifest" "skipped=true release=${release_dir}"
    return
  fi
  if [[ ! -f "${release_dir}/release-manifest.json" ]]; then
    fail "release-manifest" "missing release=${release_dir}"
  elif ! command -v python3 >/dev/null 2>&1; then
    fail "release-manifest" "python3_missing"
  elif python3 - "${release_dir}/release-manifest.json" "$(basename "${release_dir}")" >/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)

expected_release_id = sys.argv[2]
if manifest.get("schemaVersion") != 1:
    raise SystemExit("schemaVersion_mismatch")
if manifest.get("releaseID") != expected_release_id:
    raise SystemExit("releaseID_mismatch")
binary = ((manifest.get("artifacts") or {}).get("binary") or {})
if binary.get("path") != "bin/IMServer":
    raise SystemExit("binary_path_mismatch")
if not binary.get("sha256"):
    raise SystemExit("binary_sha256_missing")
if not ((manifest.get("git") or {}).get("commit")):
    raise SystemExit("git_commit_missing")
PY
  then
    pass "release-manifest" "release=$(basename "${release_dir}")"
  else
    fail "release-manifest" "invalid release=${release_dir}"
  fi
  if [[ ! -f "${release_dir}/SHA256SUMS" ]]; then
    fail "release-checksum" "missing release=${release_dir}"
  elif ! validate_release_checksum_file "${release_dir}" "${release_dir}/SHA256SUMS" >/dev/null 2>&1; then
    fail "release-checksum" "unsafe_checksum_file release=${release_dir}"
  elif (cd "${release_dir}" && sha256sum -c SHA256SUMS >/dev/null); then
    pass "release-checksum" "release=$(basename "${release_dir}")"
  else
    fail "release-checksum" "verification_failed release=${release_dir}"
  fi
}

check_sysctl_at_least() {
  local key="$1"
  local minimum="$2"
  local value
  value="$(sysctl -n "${key}" 2>/dev/null || printf '0')"
  if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= minimum )); then
    pass "sysctl" "${key}=${value}"
  else
    fail "sysctl" "${key}_below_${minimum}_got_${value}"
  fi
}

check_disk() {
  local path="$1"
  local use_percent
  use_percent="$(df -P "${path}" | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"
  if [[ "${use_percent}" =~ ^[0-9]+$ ]] && (( use_percent <= AUDIT_DISK_MAX_USE_PERCENT )); then
    pass "disk" "path=${path} use=${use_percent}%"
  else
    fail "disk" "path=${path}_use_${use_percent}%"
  fi
}

check_host_security() {
  if ! bool_enabled "${AUDIT_REQUIRE_HOST_SECURITY}"; then
    pass "host-security" "skipped=true"
    return
  fi

  if [[ -n "${AUDIT_UFW_STATUS_FIXTURE}${AUDIT_UFW_STATUS_NUMBERED_FIXTURE}" ]] || check_command ufw; then
    local ufw_status ufw_numbered
    ufw_status="$(ufw_status_output || true)"
    ufw_numbered="$(ufw_status_numbered_output || true)"
    if grep -q '^Status: active' <<<"${ufw_status}"; then
      pass "ufw" "status=active"
    else
      fail "ufw" "status_not_active"
    fi
    if ufw_rule_allows_port "${ufw_numbered}" "${SSH_PORT}"; then
      pass "ufw-ssh" "port=${SSH_PORT}"
    else
      fail "ufw-ssh" "port_${SSH_PORT}_not_allowed"
    fi
    if bool_enabled "${AUDIT_REQUIRE_RESTRICTED_SSH_CIDR}"; then
      if ufw_rule_allows_public_port "${ufw_numbered}" "${SSH_PORT}"; then
        fail "ufw-ssh-cidr" "port_${SSH_PORT}_allows_public_anywhere"
      else
        pass "ufw-ssh-cidr" "port=${SSH_PORT}_restricted"
      fi
    else
      pass "ufw-ssh-cidr" "skipped=true"
    fi
    if bool_enabled "${AUDIT_REQUIRE_RDP_CLOSED}"; then
      if ufw_rule_allows_port "${ufw_numbered}" "3389"; then
        fail "ufw-rdp" "port_3389_allowed"
      else
        pass "ufw-rdp" "port_3389_not_allowed"
      fi
    else
      pass "ufw-rdp" "skipped=true"
    fi
  fi

  check_service fail2ban

  if systemctl is-enabled --quiet unattended-upgrades && systemctl is-active --quiet unattended-upgrades; then
    pass "unattended-upgrades" "status=enabled_active"
  else
    fail "unattended-upgrades" "not_enabled_or_inactive"
  fi
}

check_time_sync() {
  if ! bool_enabled "${AUDIT_REQUIRE_TIME_SYNC}"; then
    pass "time-sync" "skipped=true"
    return
  fi

  if ! command -v timedatectl >/dev/null 2>&1; then
    fail "time-sync" "timedatectl_missing"
    return
  fi

  local synchronized
  synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "${synchronized}" == "yes" ]]; then
    pass "time-sync" "ntpSynchronized=yes"
  else
    fail "time-sync" "ntpSynchronized=${synchronized:-unknown}"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    fail "time-sync-service" "systemctl_missing"
    return
  fi

  local service found=false
  for service in systemd-timesyncd.service chrony.service chronyd.service ntp.service ntpsec.service; do
    if systemctl is-active --quiet "${service}" && systemctl is-enabled --quiet "${service}"; then
      pass "time-sync-service" "name=${service} status=enabled_active"
      found=true
      break
    fi
  done

  if [[ "${found}" != "true" ]]; then
    fail "time-sync-service" "no_enabled_active_time_sync_service"
  fi
}

check_datastore_exposure() {
  if ! bool_enabled "${AUDIT_REQUIRE_DATASTORE_LOOPBACK}"; then
    pass "datastore-loopback" "skipped=true"
    return
  fi

  local listen_output unsafe postgres_port redis_port redis_bind redis_protected
  listen_output="$(tcp_listen_output || true)"
  postgres_port="${POSTGRES_PORT:-5432}"
  redis_port="${REDIS_PORT:-6379}"

  unsafe="$(tcp_listener_non_loopback "${listen_output}" "${postgres_port}" || true)"
  if [[ -n "${unsafe}" ]]; then
    fail "postgres-listener" "port=${postgres_port}_non_loopback=${unsafe}"
  else
    pass "postgres-listener" "port=${postgres_port}_loopback_only"
  fi

  unsafe="$(tcp_listener_non_loopback "${listen_output}" "${redis_port}" || true)"
  if [[ -n "${unsafe}" ]]; then
    fail "redis-listener" "port=${redis_port}_non_loopback=${unsafe}"
  else
    pass "redis-listener" "port=${redis_port}_loopback_only"
  fi

  redis_bind="$(redis_config_directive bind || true)"
  if redis_bind_loopback_only "${redis_bind}"; then
    pass "redis-bind" "value=${redis_bind}"
  else
    fail "redis-bind" "not_loopback_only value=${redis_bind:-<missing>} file=${AUDIT_REDIS_CONFIG_FILE}"
  fi

  redis_protected="$(redis_config_directive protected-mode || true)"
  if [[ "${redis_protected}" == "yes" ]]; then
    pass "redis-protected-mode" "value=yes"
  else
    fail "redis-protected-mode" "value=${redis_protected:-<missing>} file=${AUDIT_REDIS_CONFIG_FILE}"
  fi
}

check_tcp_listener() {
  local check_name="$1"
  local port="$2"
  if command -v ss >/dev/null 2>&1 && ss -ltn | awk -v port=":${port}" 'NR > 1 && index($4, port) > 0 { found=1 } END { exit found ? 0 : 1 }'; then
    pass "${check_name}" "port=${port}"
  else
    fail "${check_name}" "port_${port}_not_listening"
  fi
}

check_ssh_access() {
  if ! bool_enabled "${AUDIT_REQUIRE_SSH_ACCESS}"; then
    pass "ssh-access" "skipped=true"
    return
  fi
  if systemctl is-active --quiet ssh; then
    pass "ssh-service" "name=ssh"
  elif systemctl is-active --quiet sshd; then
    pass "ssh-service" "name=sshd"
  else
    fail "ssh-service" "inactive"
  fi
  check_tcp_listener "ssh-listener" "${SSH_PORT}"
}

check_performance_gate() {
  if ! bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}"; then
    pass "performance-gate" "skipped=true appEnv=${AUDIT_APP_ENV_EFFECTIVE}"
    return
  fi
  if [[ -z "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}" \
    || -z "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
    || -z "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
    || -z "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE}" ]]; then
    fail "performance-gate" "skipped_invalid_target"
    return
  fi

  local output rc=0
  rc=0
  output="$(
    PERF_PRODUCTION_GATE_JSON="${AUDIT_PERFORMANCE_GATE_JSON}" \
    PERF_PRODUCTION_GATE_PROFILE="${AUDIT_PERFORMANCE_GATE_PROFILE}" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT}" \
    PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}" \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE}" \
    PERF_PRODUCTION_PROFILE_CATALOG="${AUDIT_PERFORMANCE_PROFILE_CATALOG}" \
      bash "${SCRIPT_DIR}/67_verify_performance_gate.sh" 2>&1
  )" || rc=$?

  if (( rc == 0 )); then
    pass "performance-gate" "${output}"
  else
    fail "performance-gate" "${output}"
  fi

  rc=0
  output="$(
    PERF_PRODUCTION_EVIDENCE_CURRENT_LINK="${AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE="${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}" \
    PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
    PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE}" \
    PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}" \
    PERF_PRODUCTION_GATE_JSON="${AUDIT_PERFORMANCE_GATE_JSON}" \
    PERF_PRODUCTION_GATE_PROFILE="${AUDIT_PERFORMANCE_GATE_PROFILE}" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT}" \
    PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}" \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE}" \
    PERF_PRODUCTION_PROFILE_CATALOG="${AUDIT_PERFORMANCE_PROFILE_CATALOG}" \
      bash "${SCRIPT_DIR}/70_verify_performance_evidence_package.sh" 2>&1
  )" || rc=$?

  if (( rc == 0 )); then
    local validation_output
    if validation_output="$(validate_performance_evidence_summary "${output}")"; then
      pass "performance-evidence" "${output}"
    else
      fail "performance-evidence" "${validation_output}"
    fi
  else
    fail "performance-evidence" "${output}"
  fi
}

check_entrypoint() {
  if ! bool_enabled "${AUDIT_REQUIRE_ENTRYPOINT}"; then
    pass "entrypoint" "skipped=true"
    return
  fi

  local output rc=0
  output="$(
    HTTP_PORT="${HTTP_PORT}" \
    PUBLIC_BASE_URL="${AUDIT_PUBLIC_BASE_URL_EFFECTIVE:-}" \
    VERIFY_REQUIRE_PUBLIC="${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-false}" \
      bash "${SCRIPT_DIR}/65_verify_entrypoint.sh" 2>&1
  )" || rc=$?

  if (( rc == 0 )); then
    pass "entrypoint" "port=${HTTP_PORT} publicBaseURL=${AUDIT_PUBLIC_BASE_URL_EFFECTIVE:-<unset>} requirePublic=${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-false}"
  else
    fail "entrypoint" "${output//$'\n'/ }"
  fi
}

if bool_enabled "${AUDIT_UNIT_SELF_TEST}"; then
  run_unit_self_test
  exit 0
fi

if bool_enabled "${AUDIT_PERFORMANCE_SUMMARY_SELF_TEST}"; then
  run_performance_summary_self_test
  exit 0
fi

printf 'IMServer operational audit\n'
printf 'date=%s host=%s appEnv=%s requirePerformanceGate=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(hostname)" \
  "${AUDIT_APP_ENV_EFFECTIVE}" \
  "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}"
printf 'performanceGateTarget publicBaseURL=%s expectBaseURL=%s expectTCPHost=%s expectTCPPort=%s\n' \
  "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE:-<unset>}" \
  "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE:-<unset>}" \
  "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE:-<unset>}" \
  "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE:-<unset>}"
printf 'topologySmoke require=%s receipt=%s maxAgeSeconds=%s maxFutureSkewSeconds=%s requireArtifacts=%s\n' \
  "${AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE}" \
  "${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON}" \
  "${AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}" \
  "${AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS}" \
  "${AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS}"
printf 'streamConsumerInstances=%s\n' "${AUDIT_STREAM_CONSUMER_INSTANCE_UNITS:-<legacy-units>}"

for service in \
  postgresql \
  redis-server \
  kafka \
  nginx \
  imserver-command-api \
  imserver-gateway \
  imserver-query-api \
  imserver-outbox-relay
do
  check_service "${service}"
done

if [[ -n "${AUDIT_STREAM_CONSUMER_INSTANCE_UNITS}" ]]; then
  IFS=',' read -r -a stream_consumer_instances <<< "${AUDIT_STREAM_CONSUMER_INSTANCE_UNITS}"
  for instance in "${stream_consumer_instances[@]}"; do
    instance="${instance//[[:space:]]/}"
    if [[ ! "${instance}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      fail "stream-consumer-instance" "invalid_instance_name_${instance}"
      continue
    fi
    check_service "imserver-stream-consumer@${instance}"
  done
else
  check_service imserver-stream-consumer
  check_service imserver-domain-delivery-consumer
fi

check_timer imserver-backup.timer
check_backup_timer_units
if bool_enabled "${AUDIT_REQUIRE_AUDIT_TIMER}"; then
  check_timer imserver-operational-audit.timer
  check_operational_audit_timer_units
fi
if bool_enabled "${AUDIT_REQUIRE_RESTORE_DRILL_TIMER}"; then
  check_timer imserver-restore-drill.timer
  check_restore_drill_timer_units
fi
check_restore_drill_freshness
check_offsite_backup_freshness
check_release
check_config_permissions
check_production_env
check_https_certificate
check_certbot_renewal_timer
check_nginx_config
check_alert_webhook
check_sysctl_at_least fs.file-max 1000000
check_sysctl_at_least net.core.somaxconn 8192
check_sysctl_at_least net.ipv4.tcp_max_syn_backlog 8192
check_disk /
check_disk "${IMSERVER_HOME}"
check_disk "${BACKUP_ROOT}"
check_host_security
check_time_sync
check_datastore_exposure
check_cloud_security_group
check_cloud_security_group_repair_receipt
check_topology_smoke_receipt
check_ssh_access
validate_performance_gate_public_targets
check_performance_gate
check_kafka_lag

check_latest_backup

check_entrypoint

if [[ "${failures}" != "0" ]]; then
  printf 'audit result=fail failures=%s\n' "${failures}" >&2
  exit 1
fi

printf 'audit result=pass\n'
