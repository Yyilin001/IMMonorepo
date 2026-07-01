#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

repo="$(repo_root)"

AUDIT_TIMER_RENDER_SELF_TEST="${AUDIT_TIMER_RENDER_SELF_TEST:-false}"
AUDIT_TIMER_REQUIRE_ROOT="${AUDIT_TIMER_REQUIRE_ROOT:-true}"
AUDIT_TIMER_ENABLE="${AUDIT_TIMER_ENABLE:-true}"
AUDIT_SYSTEMD_DIR="${AUDIT_SYSTEMD_DIR:-/etc/systemd/system}"
AUDIT_CALENDAR="${AUDIT_CALENDAR:-*-*-* *:0/15:00}"
AUDIT_RANDOMIZED_DELAY_SEC="${AUDIT_RANDOMIZED_DELAY_SEC:-60}"
AUDIT_LOG_FILE="${AUDIT_LOG_FILE:-${IMSERVER_LOG_DIR}/operational-audit.log}"
AUDIT_HTTP_PORT="${AUDIT_HTTP_PORT:-${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}}"
AUDIT_BACKUP_ROOT="${AUDIT_BACKUP_ROOT:-${BACKUP_ROOT:-/var/backups/imserver}}"
AUDIT_REQUIRE_BACKUP="${AUDIT_REQUIRE_BACKUP:-false}"
AUDIT_VERIFY_LATEST_BACKUP="${AUDIT_VERIFY_LATEST_BACKUP:-false}"
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
AUDIT_REQUIRE_ALERT_WEBHOOK="${AUDIT_REQUIRE_ALERT_WEBHOOK:-}"
AUDIT_PERFORMANCE_GATE_JSON="${AUDIT_PERFORMANCE_GATE_JSON:-/var/lib/imserver/performance/production-gate.json}"
AUDIT_PERFORMANCE_GATE_PROFILE="${AUDIT_PERFORMANCE_GATE_PROFILE:-normal-product-baseline}"
AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS="${AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS:-604800}"
AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT="${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT:-false}"
AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT="${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT:-false}"
AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL="${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL:-}"
AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST="${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST:-}"
AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT="${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT:-}"
AUDIT_PERFORMANCE_PROFILE_CATALOG="${AUDIT_PERFORMANCE_PROFILE_CATALOG:-${repo}/IMServer/LoadTests/perf_production_profiles.json}"
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
AUDIT_REDIS_CONFIG_FILE="${AUDIT_REDIS_CONFIG_FILE:-/etc/redis/redis.conf}"
AUDIT_REQUIRE_NGINX_CONFIG="${AUDIT_REQUIRE_NGINX_CONFIG:-true}"
AUDIT_NGINX_HTTP_CONF_PATH="${AUDIT_NGINX_HTTP_CONF_PATH:-/etc/nginx/conf.d/imserver.conf}"
AUDIT_NGINX_LOCATIONS_CONF_PATH="${AUDIT_NGINX_LOCATIONS_CONF_PATH:-/etc/nginx/snippets/imserver_locations.conf}"
AUDIT_NGINX_SSL_CONF_PATH="${AUDIT_NGINX_SSL_CONF_PATH:-/etc/nginx/conf.d/imserver_ssl.conf}"
AUDIT_NGINX_REQUIRE_SSL="${AUDIT_NGINX_REQUIRE_SSL:-false}"
AUDIT_ALERT_ENV_FILE="${AUDIT_ALERT_ENV_FILE:-${IMSERVER_ETC_DIR}/operational-alert.env}"
AUDIT_ALERT_WEBHOOK_URL="${AUDIT_ALERT_WEBHOOK_URL:-}"
AUDIT_ALERT_WEBHOOK_HEADER="${AUDIT_ALERT_WEBHOOK_HEADER:-}"
AUDIT_ALERT_ALLOW_INSECURE_HTTP="${AUDIT_ALERT_ALLOW_INSECURE_HTTP:-false}"
AUDIT_ALERT_REDACT_LOG_TAIL="${AUDIT_ALERT_REDACT_LOG_TAIL:-true}"
AUDIT_ALERT_TIMEOUT_SECONDS="${AUDIT_ALERT_TIMEOUT_SECONDS:-10}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

quote_env_value() {
  python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$1"
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

audit_timer_env_value() {
  local key="$1"
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local value="${!key:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  read_env_file_value "${env_file}" "${key}"
}

audit_timer_host_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
}

audit_timer_scheme_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).scheme or "")
PY
}

audit_timer_port_from_url() {
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

audit_timer_public_host_policy_reason() {
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

audit_timer_app_env() {
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

resolve_audit_timer_public_base_url() {
  local value
  value="$(audit_timer_env_value "PUBLIC_BASE_URL")"
  if [[ -z "${value}" ]]; then
    value="$(audit_timer_env_value "IM_PUBLIC_BASE_URL")"
  fi
  printf '%s\n' "${value}"
}

default_performance_gate_requirement() {
  local app_env
  app_env="$(audit_timer_app_env)"
  case "${app_env}" in
    production) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

resolve_performance_gate_requirement_for_timer() {
  if [[ -n "${AUDIT_REQUIRE_PERFORMANCE_GATE}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_PERFORMANCE_GATE}"
  else
    default_performance_gate_requirement
  fi
}

resolve_artifact_requirement_for_timer() {
  local value="$1"
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement_for_timer)}"; then
    printf 'true\n'
  elif [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
  else
    printf '\n'
  fi
}

resolve_alert_webhook_requirement_for_timer() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement_for_timer)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_REQUIRE_ALERT_WEBHOOK}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_ALERT_WEBHOOK}"
  else
    printf 'false\n'
  fi
}

resolve_kafka_lag_requirement_for_timer() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement_for_timer)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_REQUIRE_KAFKA_LAG}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_KAFKA_LAG}"
  else
    printf 'false\n'
  fi
}

resolve_cloud_security_group_requirement_for_timer() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement_for_timer)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP}"
  else
    printf 'false\n'
  fi
}

resolve_cloud_security_group_evidence_requirement_for_timer() {
  if bool_enabled "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE:-$(resolve_cloud_security_group_requirement_for_timer)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}"
  else
    printf 'false\n'
  fi
}

resolve_cloud_security_group_repair_receipt_requirement_for_timer() {
  if [[ -n "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}"
  elif bool_enabled "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE:-$(resolve_cloud_security_group_requirement_for_timer)}"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

resolve_topology_smoke_requirement_for_timer() {
  if bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement_for_timer)}"; then
    printf 'true\n'
  elif [[ -n "${AUDIT_REQUIRE_TOPOLOGY_SMOKE}" ]]; then
    printf '%s\n' "${AUDIT_REQUIRE_TOPOLOGY_SMOKE}"
  else
    printf 'false\n'
  fi
}

resolve_audit_timer_expect_base_url() {
  if [[ -n "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL}"
    return 0
  fi
  resolve_audit_timer_public_base_url
}

resolve_audit_timer_expect_tcp_host() {
  if [[ -n "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST}"
    return 0
  fi
  local value
  value="$(audit_timer_env_value "TCP_HOST")"
  if [[ -z "${value}" ]]; then
    value="$(audit_timer_env_value "IM_PUBLIC_HOST")"
  fi
  if [[ -z "${value}" ]]; then
    value="$(audit_timer_host_from_url "$(resolve_audit_timer_public_base_url)")"
  fi
  printf '%s\n' "${value}"
}

resolve_audit_timer_expect_tcp_port() {
  if [[ -n "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT}" ]]; then
    printf '%s\n' "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT}"
    return 0
  fi
  local value
  value="$(audit_timer_env_value "TCP_PORT")"
  if [[ -z "${value}" ]]; then
    value="$(audit_timer_env_value "IM_TCP_PORT")"
  fi
  printf '%s\n' "${value:-9000}"
}

validate_audit_timer_public_targets() {
  local public_base_url_scheme public_base_url_port public_base_url_host public_base_url_host_reason
  local expect_base_url_scheme expect_base_url_port expect_base_url_host expect_base_url_host_reason
  local expect_tcp_host_reason
  if ! bool_enabled "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}"; then
    return 0
  fi
  if [[ -z "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}" ]]; then
    printf 'operational_audit_timer result=fail reason=public_base_url_missing appEnv=%s requirePerformanceGate=%s hint=set_PUBLIC_BASE_URL_or_IM_PUBLIC_BASE_URL\n' \
      "$(audit_timer_app_env)" \
      "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}" >&2
    return 2
  fi
  public_base_url_scheme="$(audit_timer_scheme_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
  if [[ "${public_base_url_scheme}" != "https" ]]; then
    printf 'operational_audit_timer result=fail reason=public_base_url_https_required publicBaseURL=%s hint=set_PUBLIC_BASE_URL_or_IM_PUBLIC_BASE_URL_to_https_or_disable_gate_for_first_bootstrap\n' \
      "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}" >&2
    return 2
  fi
  public_base_url_port="$(audit_timer_port_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
  if [[ "${public_base_url_port}" != "443" ]]; then
    printf 'operational_audit_timer result=fail reason=public_base_url_default_https_port_required publicBaseURL=%s port=%s hint=use_default_https_443_for_long_term_production\n' \
      "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}" \
      "${public_base_url_port:-<empty>}" >&2
    return 2
  fi
  public_base_url_host="$(audit_timer_host_from_url "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}")"
  public_base_url_host_reason="$(audit_timer_public_host_policy_reason "${public_base_url_host}")"
  if [[ "${public_base_url_host_reason}" != "ok" ]]; then
    printf 'operational_audit_timer result=fail reason=public_base_url_domain_required publicBaseURL=%s host=%s hostReason=%s hint=use_a_real_production_domain_not_a_raw_ip_or_placeholder\n' \
      "${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}" \
      "${public_base_url_host:-<empty>}" \
      "${public_base_url_host_reason}" >&2
    return 2
  fi
  if [[ -z "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}" ]]; then
    printf 'operational_audit_timer result=fail reason=expect_base_url_missing hint=set_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_or_PUBLIC_BASE_URL\n' >&2
    return 2
  fi
  expect_base_url_scheme="$(audit_timer_scheme_from_url "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
  if [[ "${expect_base_url_scheme}" != "https" ]]; then
    printf 'operational_audit_timer result=fail reason=expect_base_url_https_required expectBaseURL=%s hint=bind_production_performance_evidence_to_https_BASE_URL\n' \
      "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}" >&2
    return 2
  fi
  expect_base_url_port="$(audit_timer_port_from_url "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
  if [[ "${expect_base_url_port}" != "443" ]]; then
    printf 'operational_audit_timer result=fail reason=expect_base_url_default_https_port_required expectBaseURL=%s port=%s hint=bind_production_performance_evidence_to_default_https_443\n' \
      "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
      "${expect_base_url_port:-<empty>}" >&2
    return 2
  fi
  expect_base_url_host="$(audit_timer_host_from_url "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
  expect_base_url_host_reason="$(audit_timer_public_host_policy_reason "${expect_base_url_host}")"
  if [[ "${expect_base_url_host_reason}" != "ok" ]]; then
    printf 'operational_audit_timer result=fail reason=expect_base_url_domain_required expectBaseURL=%s host=%s hostReason=%s hint=bind_production_performance_evidence_to_the_real_https_domain\n' \
      "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
      "${expect_base_url_host:-<empty>}" \
      "${expect_base_url_host_reason}" >&2
    return 2
  fi
  if [[ -z "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}" ]]; then
    printf 'operational_audit_timer result=fail reason=expect_tcp_host_missing hint=set_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_or_TCP_HOST_or_IM_PUBLIC_HOST_or_PUBLIC_BASE_URL\n' >&2
    return 2
  fi
  expect_tcp_host_reason="$(audit_timer_public_host_policy_reason "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}")"
  if [[ "${expect_tcp_host_reason}" != "ok" ]]; then
    printf 'operational_audit_timer result=fail reason=expect_tcp_host_domain_required tcpHost=%s hostReason=%s hint=use_a_real_production_tcp_domain_not_a_raw_ip_or_placeholder\n' \
      "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
      "${expect_tcp_host_reason}" >&2
    return 2
  fi
  if [[ -z "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE}" ]]; then
    printf 'operational_audit_timer result=fail reason=expect_tcp_port_missing hint=set_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_or_TCP_PORT_or_IM_TCP_PORT\n' >&2
    return 2
  fi
}

if bool_enabled "${AUDIT_TIMER_RENDER_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  mkdir -p "${self_test_dir}/etc/imserver"
  printf 'APP_ENV=production\n' >"${self_test_dir}/etc/imserver/common.env"
  printf 'PUBLIC_BASE_URL=https://audit.myim-prod.com\n' >>"${self_test_dir}/etc/imserver/common.env"
  printf 'TCP_HOST=tcp.myim-prod.com\n' >>"${self_test_dir}/etc/imserver/common.env"
  printf 'TCP_PORT=9000\n' >>"${self_test_dir}/etc/imserver/common.env"
  AUDIT_TIMER_RENDER_SELF_TEST=false \
  AUDIT_TIMER_REQUIRE_ROOT=false \
  AUDIT_TIMER_ENABLE=false \
  AUDIT_SYSTEMD_DIR="${self_test_dir}/systemd" \
  AUDIT_LOG_FILE="${self_test_dir}/logs/operational-audit.log" \
  IMSERVER_ETC_DIR="${self_test_dir}/etc/imserver" \
  AUDIT_REQUIRE_PERFORMANCE_GATE= \
  AUDIT_REQUIRE_ALERT_WEBHOOK=false \
  AUDIT_PERFORMANCE_GATE_PROFILE=normal-product-baseline \
  AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT=true \
  AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK="${self_test_dir}/performance/current-evidence" \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=false \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=false \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=false \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=false \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=false \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=false \
  AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${self_test_dir}/production-acceptance.json" \
  AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${self_test_dir}/production-evidence.tar.gz" \
  AUDIT_REQUIRE_NGINX_CONFIG=true \
  AUDIT_NGINX_HTTP_CONF_PATH="${self_test_dir}/nginx/imserver.conf" \
  AUDIT_NGINX_LOCATIONS_CONF_PATH="${self_test_dir}/nginx/imserver_locations.conf" \
  AUDIT_NGINX_SSL_CONF_PATH="${self_test_dir}/nginx/imserver_ssl.conf" \
  AUDIT_NGINX_REQUIRE_SSL=true \
    bash "${BASH_SOURCE[0]}" >"${self_test_dir}/render.log"
  service_file="${self_test_dir}/systemd/imserver-operational-audit.service"
  alert_file="${self_test_dir}/systemd/imserver-operational-alert@.service"
  timer_file="${self_test_dir}/systemd/imserver-operational-audit.timer"
  [[ -f "${service_file}" && -f "${alert_file}" && -f "${timer_file}" ]] || {
    printf 'operational_audit_timer_render_self_test result=fail reason=unit_missing\n' >&2
    exit 1
  }
  grep -q 'OnFailure=imserver-operational-alert@%n.service' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=on_failure_missing\n' >&2
    exit 1
  }
  grep -q "ExecStart=/bin/bash ${repo}/deploy/ubuntu/77_operational_audit.sh" "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=audit_exec_missing\n' >&2
    exit 1
  }
  grep -q "StandardOutput=append:${self_test_dir}/logs/operational-audit.log" "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stdout_log_missing\n' >&2
    exit 1
  }
  grep -q "StandardError=append:${self_test_dir}/logs/operational-audit.log" "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stderr_log_missing\n' >&2
    exit 1
  }
  grep -q "EnvironmentFile=-${self_test_dir}/etc/imserver/operational-alert.env" "${alert_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=alert_env_missing\n' >&2
    exit 1
  }
  grep -Fq 'AUDIT_ALERT_ALLOW_INSECURE_HTTP=false' "${self_test_dir}/etc/imserver/operational-alert.env" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=alert_allow_insecure_http_missing\n' >&2
    exit 1
  }
  grep -Fq 'AUDIT_ALERT_REDACT_LOG_TAIL=true' "${self_test_dir}/etc/imserver/operational-alert.env" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=alert_redact_log_tail_missing\n' >&2
    exit 1
  }
  stale_alert_dir="${self_test_dir}/stale-alert-env"
  mkdir -p "${stale_alert_dir}/etc/imserver" "${stale_alert_dir}/systemd" "${stale_alert_dir}/logs"
  {
    printf 'APP_ENV=production\n'
    printf 'PUBLIC_BASE_URL=https://audit.myim-prod.com\n'
    printf 'TCP_HOST=tcp.myim-prod.com\n'
    printf 'TCP_PORT=9000\n'
  } >"${stale_alert_dir}/etc/imserver/common.env"
  {
    printf 'AUDIT_ALERT_WEBHOOK_URL=https://alerts.myim-prod.com/imserver\n'
    printf 'AUDIT_ALERT_WEBHOOK_HEADER=Authorization: Bearer existing-token\n'
    printf 'AUDIT_ALERT_ALLOW_INSECURE_HTTP=true\n'
    printf 'AUDIT_ALERT_REDACT_LOG_TAIL=false\n'
    printf 'AUDIT_ALERT_LOG_FILE=/tmp/stale-audit.log\n'
    printf 'AUDIT_ALERT_TIMEOUT_SECONDS=99\n'
  } >"${stale_alert_dir}/etc/imserver/operational-alert.env"
  AUDIT_TIMER_RENDER_SELF_TEST=false \
  AUDIT_TIMER_REQUIRE_ROOT=false \
  AUDIT_TIMER_ENABLE=false \
  AUDIT_SYSTEMD_DIR="${stale_alert_dir}/systemd" \
  AUDIT_LOG_FILE="${stale_alert_dir}/logs/operational-audit.log" \
  IMSERVER_ETC_DIR="${stale_alert_dir}/etc/imserver" \
  AUDIT_REQUIRE_PERFORMANCE_GATE= \
  AUDIT_REQUIRE_ALERT_WEBHOOK=false \
    bash "${BASH_SOURCE[0]}" >"${stale_alert_dir}/render.log"
  stale_alert_env="${stale_alert_dir}/etc/imserver/operational-alert.env"
  stale_alert_service="${stale_alert_dir}/systemd/imserver-operational-audit.service"
  grep -Fq 'AUDIT_ALERT_WEBHOOK_URL=https://alerts.myim-prod.com/imserver' "${stale_alert_env}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stale_alert_env_url_not_preserved\n' >&2
    exit 1
  }
  grep -Fq 'existing-token' "${stale_alert_env}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stale_alert_env_header_not_preserved\n' >&2
    exit 1
  }
  grep -Fq 'AUDIT_ALERT_ALLOW_INSECURE_HTTP=false' "${stale_alert_env}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stale_alert_env_allow_insecure_not_reset\n' >&2
    exit 1
  }
  grep -Fq 'AUDIT_ALERT_REDACT_LOG_TAIL=true' "${stale_alert_env}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stale_alert_env_redact_not_reset\n' >&2
    exit 1
  }
  grep -Fq "AUDIT_ALERT_LOG_FILE=${stale_alert_dir}/logs/operational-audit.log" "${stale_alert_env}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stale_alert_env_log_file_not_updated\n' >&2
    exit 1
  }
  grep -Fq 'AUDIT_ALERT_TIMEOUT_SECONDS=10' "${stale_alert_env}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stale_alert_env_timeout_not_updated\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_ALERT_REDACT_LOG_TAIL=true' "${stale_alert_service}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=stale_alert_env_service_redact_not_reset\n' >&2
    exit 1
  }
  grep -q "ExecStart=/bin/bash ${repo}/deploy/ubuntu/79_send_operational_alert.sh %I" "${alert_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=alert_exec_missing\n' >&2
    exit 1
  }
  grep -q 'Persistent=true' "${timer_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=persistent_missing\n' >&2
    exit 1
  }
  grep -q 'Unit=imserver-operational-audit.service' "${timer_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=unit_reference_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK=' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_current_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_profile_artifacts_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_product_plan_artifacts_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_product_campaign_artifacts_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_product_scenario_suite_artifacts_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_product_scenario_suite_no_large_group_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_current_readiness_artifacts_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_validation_inventory_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_cloud_security_group_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=evidence_production_acceptance_missing\n' >&2
    exit 1
  }
  grep -q '^Environment=AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=$' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=production_acceptance_receipt_not_current_evidence_only\n' >&2
    exit 1
  }
  grep -q '^Environment=AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE=$' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=production_acceptance_package_not_current_evidence_only\n' >&2
    exit 1
  }
  if grep -q "${self_test_dir}/production-acceptance.json" "${service_file}" || grep -q "${self_test_dir}/production-evidence.tar.gz" "${service_file}"; then
    printf 'operational_audit_timer_render_self_test result=fail reason=temporary_production_acceptance_path_leaked\n' >&2
    exit 1
  fi
  grep -q 'Environment=AUDIT_REQUIRE_PERFORMANCE_GATE=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_performance_gate_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_KAFKA_LAG=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_kafka_lag_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_KAFKA_LAG_MAX_TOTAL=10000' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=kafka_lag_max_total_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_KAFKA_LAG_MAX_PARTITION=5000' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=kafka_lag_max_partition_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_ALERT_WEBHOOK=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_alert_webhook_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_ALERT_ALLOW_INSECURE_HTTP=false' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=service_alert_allow_insecure_http_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_ALERT_REDACT_LOG_TAIL=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=service_alert_redact_log_tail_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_PRODUCTION_ENV=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_production_env_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_HTTPS_CERTIFICATE=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_https_certificate_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_HTTPS_CERT_MODE=auto' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=https_cert_mode_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_HTTPS_CERT_MIN_VALID_DAYS=14' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=https_cert_min_valid_days_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_HTTPS_CERT_FILE=' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=https_cert_file_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_certbot_renewal_timer_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_RESTRICTED_SSH_CIDR=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_restricted_ssh_cidr_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_RDP_CLOSED=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_rdp_closed_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_SSH_ACCESS=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_ssh_access_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_RELEASE_MANIFEST=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_release_manifest_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_DATASTORE_LOOPBACK=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_datastore_loopback_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REDIS_CONFIG_FILE=/etc/redis/redis.conf' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=redis_config_file_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_REQUIRE_NGINX_CONFIG=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_nginx_config_missing\n' >&2
    exit 1
  }
  grep -Fq "Environment=AUDIT_NGINX_HTTP_CONF_PATH=${self_test_dir}/nginx/imserver.conf" "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=nginx_http_conf_path_missing\n' >&2
    exit 1
  }
  grep -Fq "Environment=AUDIT_NGINX_LOCATIONS_CONF_PATH=${self_test_dir}/nginx/imserver_locations.conf" "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=nginx_locations_conf_path_missing\n' >&2
    exit 1
  }
  grep -Fq "Environment=AUDIT_NGINX_SSL_CONF_PATH=${self_test_dir}/nginx/imserver_ssl.conf" "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=nginx_ssl_conf_path_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_NGINX_REQUIRE_SSL=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=nginx_require_ssl_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_cloud_security_group_missing\n' >&2
    exit 1
  }
  grep -Fq "Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE=${self_test_dir}/etc/imserver/cloud-security-group.json" "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_rules_file_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS=80 443 9000' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_public_client_ports_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS=3389 5432 6379 9092 8081 8082 18080 8080' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_deny_public_ports_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_require_public_client_ports_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_rules_max_age_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_rules_require_root_owner_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX=8' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_public_broad_ipv4_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX=16' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_public_broad_ipv6_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX=32' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_admin_public_ipv4_min_prefix_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX=128' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_admin_public_ipv6_min_prefix_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_repair_receipt_required_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_repair_receipt_json_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=cloud_security_group_repair_receipt_max_age_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_REQUIRE_TOPOLOGY_SMOKE=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_topology_smoke_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON=/var/lib/imserver/production-smoke/latest-production-smoke.json' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=topology_smoke_receipt_json_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=86400' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=topology_smoke_max_age_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS=300' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=topology_smoke_max_future_skew_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=topology_smoke_require_artifacts_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS=86400' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=production_acceptance_max_age_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS=300' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=production_acceptance_max_future_skew_missing\n' >&2
    exit 1
  }
  grep -Fq 'CloudSecurityGroupRepairReceiptMaxAgeSeconds=86400' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_cloud_security_group_repair_receipt_max_age_missing\n' >&2
    exit 1
  }
  grep -Fq 'RequireTopologySmoke=true' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_require_topology_smoke_missing\n' >&2
    exit 1
  }
  grep -Fq 'TopologySmokeReceipt=/var/lib/imserver/production-smoke/latest-production-smoke.json' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_topology_smoke_receipt_missing\n' >&2
    exit 1
  }
  grep -Fq 'TopologySmokeMaxAgeSeconds=86400' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_topology_smoke_max_age_missing\n' >&2
    exit 1
  }
  grep -Fq 'TopologySmokeMaxFutureSkewSeconds=300' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_topology_smoke_max_future_skew_missing\n' >&2
    exit 1
  }
  grep -Fq 'TopologySmokeRequireArtifacts=true' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_topology_smoke_require_artifacts_missing\n' >&2
    exit 1
  }
  grep -Fq 'AlertAllowInsecureHTTP=false' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_alert_allow_insecure_http_missing\n' >&2
    exit 1
  }
  grep -Fq 'AlertRedactLogTail=true' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_alert_redact_log_tail_missing\n' >&2
    exit 1
  }
  grep -Fq 'ProductionAcceptanceMaxAgeSeconds=86400' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_production_acceptance_max_age_missing\n' >&2
    exit 1
  }
  grep -Fq 'ProductionAcceptanceMaxFutureSkewSeconds=300' "${self_test_dir}/render.log" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=summary_production_acceptance_max_future_skew_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=false' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_restore_drill_freshness_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_RESTORE_DRILL_RECEIPT_FILE=/var/lib/imserver/restore-drill/latest.json' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=restore_drill_receipt_file_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS=3888000' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=restore_drill_max_age_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS=300' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=restore_drill_max_future_skew_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=false' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_offsite_backup_freshness_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_OFFSITE_BACKUP_RECEIPT_FILE=/var/lib/imserver/offsite-backup/latest.json' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=offsite_backup_receipt_file_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS=172800' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=offsite_backup_max_age_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS=300' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=offsite_backup_max_future_skew_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=PUBLIC_BASE_URL=https://audit.myim-prod.com' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=public_base_url_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=latest_backup_freshness_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS=172800' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=latest_backup_max_age_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS=300' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=latest_backup_max_future_skew_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_REQUIRE_TIME_SYNC=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_time_sync_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT=true' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=require_clean_git_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL=https://audit.myim-prod.com' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=expected_base_url_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=expected_tcp_host_missing\n' >&2
    exit 1
  }
  grep -q 'Environment=AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT=9000' "${service_file}" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=expected_tcp_port_missing\n' >&2
    exit 1
  }
  fallback_env_file="${self_test_dir}/etc/imserver/fallback-common.env"
  printf 'APP_ENV=production\n' >"${fallback_env_file}"
  printf 'PUBLIC_BASE_URL=https://fallback-timer.myim-prod.com\n' >>"${fallback_env_file}"
  fallback_host="$(
    AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST= \
    TCP_HOST= \
    IM_PUBLIC_HOST= \
    PUBLIC_BASE_URL= \
    ENV_FILE="${fallback_env_file}" \
      resolve_audit_timer_expect_tcp_host
  )"
  [[ "${fallback_host}" == "fallback-timer.myim-prod.com" ]] || {
    printf 'operational_audit_timer_render_self_test result=fail reason=fallback_tcp_host_invalid value=%s\n' "${fallback_host}" >&2
    exit 1
  }
  missing_dir="${self_test_dir}/missing-public"
  mkdir -p "${missing_dir}/etc" "${missing_dir}/systemd" "${missing_dir}/logs"
  printf 'APP_ENV=production\n' >"${missing_dir}/etc/common.env"
  if AUDIT_TIMER_RENDER_SELF_TEST=false \
    AUDIT_TIMER_REQUIRE_ROOT=false \
    AUDIT_TIMER_ENABLE=false \
    AUDIT_SYSTEMD_DIR="${missing_dir}/systemd" \
    AUDIT_LOG_FILE="${missing_dir}/logs/operational-audit.log" \
    IMSERVER_ETC_DIR="${missing_dir}/etc" \
    AUDIT_REQUIRE_PERFORMANCE_GATE= \
      bash "${BASH_SOURCE[0]}" >"${missing_dir}/render.out" 2>"${missing_dir}/render.err"; then
    printf 'operational_audit_timer_render_self_test result=fail reason=missing_public_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=public_base_url_missing' "${missing_dir}/render.err" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=missing_public_target_reason_absent\n' >&2
    cat "${missing_dir}/render.err" >&2
    exit 1
  }

  invalid_http_dir="${self_test_dir}/invalid-http-public"
  mkdir -p "${invalid_http_dir}/etc" "${invalid_http_dir}/systemd" "${invalid_http_dir}/logs"
  {
    printf 'APP_ENV=production\n'
    printf 'PUBLIC_BASE_URL=http://audit.myim-prod.com\n'
    printf 'TCP_HOST=tcp.myim-prod.com\n'
    printf 'TCP_PORT=9000\n'
  } >"${invalid_http_dir}/etc/common.env"
  if AUDIT_TIMER_RENDER_SELF_TEST=false \
    AUDIT_TIMER_REQUIRE_ROOT=false \
    AUDIT_TIMER_ENABLE=false \
    AUDIT_SYSTEMD_DIR="${invalid_http_dir}/systemd" \
    AUDIT_LOG_FILE="${invalid_http_dir}/logs/operational-audit.log" \
    IMSERVER_ETC_DIR="${invalid_http_dir}/etc" \
    AUDIT_REQUIRE_PERFORMANCE_GATE= \
      bash "${BASH_SOURCE[0]}" >"${invalid_http_dir}/render.out" 2>"${invalid_http_dir}/render.err"; then
    printf 'operational_audit_timer_render_self_test result=fail reason=http_public_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=public_base_url_https_required' "${invalid_http_dir}/render.err" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=http_public_target_reason_absent\n' >&2
    cat "${invalid_http_dir}/render.err" >&2
    exit 1
  }

  invalid_port_dir="${self_test_dir}/invalid-port-public"
  mkdir -p "${invalid_port_dir}/etc" "${invalid_port_dir}/systemd" "${invalid_port_dir}/logs"
  {
    printf 'APP_ENV=production\n'
    printf 'PUBLIC_BASE_URL=https://audit.myim-prod.com:9443\n'
    printf 'TCP_HOST=tcp.myim-prod.com\n'
    printf 'TCP_PORT=9000\n'
  } >"${invalid_port_dir}/etc/common.env"
  if AUDIT_TIMER_RENDER_SELF_TEST=false \
    AUDIT_TIMER_REQUIRE_ROOT=false \
    AUDIT_TIMER_ENABLE=false \
    AUDIT_SYSTEMD_DIR="${invalid_port_dir}/systemd" \
    AUDIT_LOG_FILE="${invalid_port_dir}/logs/operational-audit.log" \
    IMSERVER_ETC_DIR="${invalid_port_dir}/etc" \
    AUDIT_REQUIRE_PERFORMANCE_GATE= \
      bash "${BASH_SOURCE[0]}" >"${invalid_port_dir}/render.out" 2>"${invalid_port_dir}/render.err"; then
    printf 'operational_audit_timer_render_self_test result=fail reason=non_default_https_port_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=public_base_url_default_https_port_required' "${invalid_port_dir}/render.err" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=non_default_https_port_reason_absent\n' >&2
    cat "${invalid_port_dir}/render.err" >&2
    exit 1
  }

  invalid_ip_dir="${self_test_dir}/invalid-ip-public"
  mkdir -p "${invalid_ip_dir}/etc" "${invalid_ip_dir}/systemd" "${invalid_ip_dir}/logs"
  {
    printf 'APP_ENV=production\n'
    printf 'PUBLIC_BASE_URL=https://203.0.113.10\n'
    printf 'TCP_HOST=tcp.myim-prod.com\n'
    printf 'TCP_PORT=9000\n'
  } >"${invalid_ip_dir}/etc/common.env"
  if AUDIT_TIMER_RENDER_SELF_TEST=false \
    AUDIT_TIMER_REQUIRE_ROOT=false \
    AUDIT_TIMER_ENABLE=false \
    AUDIT_SYSTEMD_DIR="${invalid_ip_dir}/systemd" \
    AUDIT_LOG_FILE="${invalid_ip_dir}/logs/operational-audit.log" \
    IMSERVER_ETC_DIR="${invalid_ip_dir}/etc" \
    AUDIT_REQUIRE_PERFORMANCE_GATE= \
      bash "${BASH_SOURCE[0]}" >"${invalid_ip_dir}/render.out" 2>"${invalid_ip_dir}/render.err"; then
    printf 'operational_audit_timer_render_self_test result=fail reason=ip_public_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=public_base_url_domain_required' "${invalid_ip_dir}/render.err" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=ip_public_target_reason_absent\n' >&2
    cat "${invalid_ip_dir}/render.err" >&2
    exit 1
  }

  invalid_tcp_dir="${self_test_dir}/invalid-tcp-host"
  mkdir -p "${invalid_tcp_dir}/etc" "${invalid_tcp_dir}/systemd" "${invalid_tcp_dir}/logs"
  {
    printf 'APP_ENV=production\n'
    printf 'PUBLIC_BASE_URL=https://audit.myim-prod.com\n'
    printf 'TCP_HOST=203.0.113.10\n'
    printf 'TCP_PORT=9000\n'
  } >"${invalid_tcp_dir}/etc/common.env"
  if AUDIT_TIMER_RENDER_SELF_TEST=false \
    AUDIT_TIMER_REQUIRE_ROOT=false \
    AUDIT_TIMER_ENABLE=false \
    AUDIT_SYSTEMD_DIR="${invalid_tcp_dir}/systemd" \
    AUDIT_LOG_FILE="${invalid_tcp_dir}/logs/operational-audit.log" \
    IMSERVER_ETC_DIR="${invalid_tcp_dir}/etc" \
    AUDIT_REQUIRE_PERFORMANCE_GATE= \
      bash "${BASH_SOURCE[0]}" >"${invalid_tcp_dir}/render.out" 2>"${invalid_tcp_dir}/render.err"; then
    printf 'operational_audit_timer_render_self_test result=fail reason=ip_tcp_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=expect_tcp_host_domain_required' "${invalid_tcp_dir}/render.err" || {
    printf 'operational_audit_timer_render_self_test result=fail reason=ip_tcp_target_reason_absent\n' >&2
    cat "${invalid_tcp_dir}/render.err" >&2
    exit 1
  }
  printf 'operational_audit_timer_render_self_test result=pass\n'
  exit 0
fi

if bool_enabled "${AUDIT_TIMER_REQUIRE_ROOT}"; then
  require_root
fi

if bool_enabled "${AUDIT_TIMER_REQUIRE_ROOT}"; then
  install -d -o root -g root -m 0755 "$(dirname "${AUDIT_LOG_FILE}")"
else
  mkdir -p "$(dirname "${AUDIT_LOG_FILE}")"
fi
touch "${AUDIT_LOG_FILE}"
if bool_enabled "${AUDIT_TIMER_REQUIRE_ROOT}"; then
  chown root:adm "${AUDIT_LOG_FILE}" 2>/dev/null || chown root:root "${AUDIT_LOG_FILE}"
fi
chmod 0640 "${AUDIT_LOG_FILE}"
if bool_enabled "${AUDIT_TIMER_REQUIRE_ROOT}"; then
  install -d -o root -g root -m 0750 "${IMSERVER_ETC_DIR}"
else
  mkdir -p "${IMSERVER_ETC_DIR}"
  chmod 0750 "${IMSERVER_ETC_DIR}"
fi
AUDIT_ALERT_WEBHOOK_URL_EFFECTIVE="${AUDIT_ALERT_WEBHOOK_URL}"
AUDIT_ALERT_WEBHOOK_HEADER_EFFECTIVE="${AUDIT_ALERT_WEBHOOK_HEADER}"
if [[ -f "${AUDIT_ALERT_ENV_FILE}" ]]; then
  if [[ -z "${AUDIT_ALERT_WEBHOOK_URL_EFFECTIVE}" ]]; then
    AUDIT_ALERT_WEBHOOK_URL_EFFECTIVE="$(read_env_file_value "${AUDIT_ALERT_ENV_FILE}" "AUDIT_ALERT_WEBHOOK_URL")"
  fi
  if [[ -z "${AUDIT_ALERT_WEBHOOK_HEADER_EFFECTIVE}" ]]; then
    AUDIT_ALERT_WEBHOOK_HEADER_EFFECTIVE="$(read_env_file_value "${AUDIT_ALERT_ENV_FILE}" "AUDIT_ALERT_WEBHOOK_HEADER")"
  fi
fi
cat > "${AUDIT_ALERT_ENV_FILE}" <<EOF
AUDIT_ALERT_WEBHOOK_URL=$(quote_env_value "${AUDIT_ALERT_WEBHOOK_URL_EFFECTIVE}")
AUDIT_ALERT_WEBHOOK_HEADER=$(quote_env_value "${AUDIT_ALERT_WEBHOOK_HEADER_EFFECTIVE}")
AUDIT_ALERT_ALLOW_INSECURE_HTTP=$(quote_env_value "${AUDIT_ALERT_ALLOW_INSECURE_HTTP}")
AUDIT_ALERT_REDACT_LOG_TAIL=$(quote_env_value "${AUDIT_ALERT_REDACT_LOG_TAIL}")
AUDIT_ALERT_LOG_FILE=$(quote_env_value "${AUDIT_LOG_FILE}")
AUDIT_ALERT_TIMEOUT_SECONDS=$(quote_env_value "${AUDIT_ALERT_TIMEOUT_SECONDS}")
EOF
if bool_enabled "${AUDIT_TIMER_REQUIRE_ROOT}"; then
  chown root:root "${AUDIT_ALERT_ENV_FILE}"
fi
chmod 0600 "${AUDIT_ALERT_ENV_FILE}"

mkdir -p "${AUDIT_SYSTEMD_DIR}"

AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE="$(resolve_performance_gate_requirement_for_timer)"
AUDIT_REQUIRE_ALERT_WEBHOOK_EFFECTIVE="$(resolve_alert_webhook_requirement_for_timer)"
AUDIT_REQUIRE_KAFKA_LAG_EFFECTIVE="$(resolve_kafka_lag_requirement_for_timer)"
AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_cloud_security_group_requirement_for_timer)"
AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE="$(resolve_cloud_security_group_repair_receipt_requirement_for_timer)"
AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE="$(resolve_topology_smoke_requirement_for_timer)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE="$(resolve_artifact_requirement_for_timer "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}")"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE="$(resolve_artifact_requirement_for_timer "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}")"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE="$(resolve_artifact_requirement_for_timer "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}")"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE="$(resolve_artifact_requirement_for_timer "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}")"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE="$(resolve_artifact_requirement_for_timer "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS}")"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_cloud_security_group_evidence_requirement_for_timer)"
AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE="$(resolve_artifact_requirement_for_timer "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE}")"
AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EFFECTIVE="${AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE_EFFECTIVE="${AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE}"
if bool_enabled "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}"; then
  AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EFFECTIVE=""
  AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE_EFFECTIVE=""
fi
AUDIT_PUBLIC_BASE_URL_EFFECTIVE="$(resolve_audit_timer_public_base_url)"
AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE="$(resolve_audit_timer_expect_base_url)"
AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE="$(resolve_audit_timer_expect_tcp_host)"
AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE="$(resolve_audit_timer_expect_tcp_port)"
validate_audit_timer_public_targets

cat > "${AUDIT_SYSTEMD_DIR}/imserver-operational-audit.service" <<EOF
[Unit]
Description=IMServer operational audit
Documentation=file://${repo}/deploy/ubuntu/README.md
Wants=network-online.target
After=network-online.target postgresql.service redis-server.service kafka.service nginx.service
OnFailure=imserver-operational-alert@%n.service

[Service]
Type=oneshot
Environment=HTTP_PORT=${AUDIT_HTTP_PORT}
Environment=PUBLIC_BASE_URL=${AUDIT_PUBLIC_BASE_URL_EFFECTIVE}
Environment=BACKUP_ROOT=${AUDIT_BACKUP_ROOT}
Environment=AUDIT_REQUIRE_BACKUP=${AUDIT_REQUIRE_BACKUP}
Environment=AUDIT_VERIFY_LATEST_BACKUP=${AUDIT_VERIFY_LATEST_BACKUP}
Environment=AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS=${AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS}
Environment=AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS=${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}
Environment=AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS=${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS}
Environment=AUDIT_REQUIRE_ENTRYPOINT=${AUDIT_REQUIRE_ENTRYPOINT}
Environment=AUDIT_REQUIRE_HOST_SECURITY=${AUDIT_REQUIRE_HOST_SECURITY}
Environment=AUDIT_REQUIRE_TIME_SYNC=${AUDIT_REQUIRE_TIME_SYNC}
Environment=AUDIT_REQUIRE_PRODUCTION_ENV=${AUDIT_REQUIRE_PRODUCTION_ENV}
Environment=AUDIT_REQUIRE_HTTPS_CERTIFICATE=${AUDIT_REQUIRE_HTTPS_CERTIFICATE}
Environment=AUDIT_HTTPS_CERT_MODE=${AUDIT_HTTPS_CERT_MODE}
Environment=AUDIT_HTTPS_CERT_MIN_VALID_DAYS=${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}
Environment=AUDIT_HTTPS_CERT_FILE=${AUDIT_HTTPS_CERT_FILE}
Environment=AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER=${AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER}
Environment=AUDIT_REQUIRE_RESTRICTED_SSH_CIDR=${AUDIT_REQUIRE_RESTRICTED_SSH_CIDR}
Environment=AUDIT_REQUIRE_RDP_CLOSED=${AUDIT_REQUIRE_RDP_CLOSED}
Environment=AUDIT_REQUIRE_SSH_ACCESS=${AUDIT_REQUIRE_SSH_ACCESS}
Environment=AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS}
Environment=AUDIT_RESTORE_DRILL_RECEIPT_FILE=${AUDIT_RESTORE_DRILL_RECEIPT_FILE}
Environment=AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS=${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}
Environment=AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS=${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS}
Environment=AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS}
Environment=AUDIT_OFFSITE_BACKUP_RECEIPT_FILE=${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE}
Environment=AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS=${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}
Environment=AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS=${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS}
Environment=AUDIT_REQUIRE_RELEASE_MANIFEST=${AUDIT_REQUIRE_RELEASE_MANIFEST}
Environment=AUDIT_REQUIRE_AUDIT_TIMER=true
Environment=AUDIT_REQUIRE_PERFORMANCE_GATE=${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}
Environment=AUDIT_REQUIRE_KAFKA_LAG=${AUDIT_REQUIRE_KAFKA_LAG_EFFECTIVE}
Environment=AUDIT_KAFKA_LAG_GROUPS=${AUDIT_KAFKA_LAG_GROUPS}
Environment=AUDIT_KAFKA_LAG_MAX_TOTAL=${AUDIT_KAFKA_LAG_MAX_TOTAL}
Environment=AUDIT_KAFKA_LAG_MAX_PARTITION=${AUDIT_KAFKA_LAG_MAX_PARTITION}
Environment=AUDIT_KAFKA_LAG_REQUIRE_GROUPS=${AUDIT_KAFKA_LAG_REQUIRE_GROUPS}
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
Environment=AUDIT_REQUIRE_ALERT_WEBHOOK=${AUDIT_REQUIRE_ALERT_WEBHOOK_EFFECTIVE}
Environment=AUDIT_ALERT_ALLOW_INSECURE_HTTP=${AUDIT_ALERT_ALLOW_INSECURE_HTTP}
Environment=AUDIT_ALERT_REDACT_LOG_TAIL=${AUDIT_ALERT_REDACT_LOG_TAIL}
Environment=AUDIT_PERFORMANCE_GATE_JSON=${AUDIT_PERFORMANCE_GATE_JSON}
Environment=AUDIT_PERFORMANCE_GATE_PROFILE=${AUDIT_PERFORMANCE_GATE_PROFILE}
Environment=AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS=${AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS}
Environment=AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT=${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT}
Environment=AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT=${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}
Environment=AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL=${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE}
Environment=AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST=${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE}
Environment=AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT=${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE}
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
Environment=AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS=${AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}
Environment=AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS=${AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}
Environment=AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=${AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EFFECTIVE}
Environment=AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE=${AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE_EFFECTIVE}
Environment=AUDIT_DISK_MAX_USE_PERCENT=${AUDIT_DISK_MAX_USE_PERCENT}
Environment=AUDIT_REQUIRE_DATASTORE_LOOPBACK=${AUDIT_REQUIRE_DATASTORE_LOOPBACK}
Environment=AUDIT_REDIS_CONFIG_FILE=${AUDIT_REDIS_CONFIG_FILE}
Environment=AUDIT_REQUIRE_NGINX_CONFIG=${AUDIT_REQUIRE_NGINX_CONFIG}
Environment=AUDIT_NGINX_HTTP_CONF_PATH=${AUDIT_NGINX_HTTP_CONF_PATH}
Environment=AUDIT_NGINX_LOCATIONS_CONF_PATH=${AUDIT_NGINX_LOCATIONS_CONF_PATH}
Environment=AUDIT_NGINX_SSL_CONF_PATH=${AUDIT_NGINX_SSL_CONF_PATH}
Environment=AUDIT_NGINX_REQUIRE_SSL=${AUDIT_NGINX_REQUIRE_SSL}
ExecStart=/bin/bash ${repo}/deploy/ubuntu/77_operational_audit.sh
StandardOutput=append:${AUDIT_LOG_FILE}
StandardError=append:${AUDIT_LOG_FILE}
Nice=5
EOF

cat > "${AUDIT_SYSTEMD_DIR}/imserver-operational-alert@.service" <<EOF
[Unit]
Description=Send IMServer operational alert for %I
Documentation=file://${repo}/deploy/ubuntu/README.md

[Service]
Type=oneshot
EnvironmentFile=-${AUDIT_ALERT_ENV_FILE}
ExecStart=/bin/bash ${repo}/deploy/ubuntu/79_send_operational_alert.sh %I
EOF

cat > "${AUDIT_SYSTEMD_DIR}/imserver-operational-audit.timer" <<EOF
[Unit]
Description=Run IMServer operational audit

[Timer]
OnCalendar=${AUDIT_CALENDAR}
RandomizedDelaySec=${AUDIT_RANDOMIZED_DELAY_SEC}
AccuracySec=1min
Persistent=true
Unit=imserver-operational-audit.service

[Install]
WantedBy=timers.target
EOF

if bool_enabled "${AUDIT_TIMER_ENABLE}"; then
  systemctl daemon-reload
  systemctl enable --now imserver-operational-audit.timer
  systemctl list-timers --no-pager imserver-operational-audit.timer || true
fi

printf 'Operational audit timer installed: OnCalendar=%s RandomizedDelaySec=%s LogFile=%s VerifyLatestBackup=%s RequireLatestBackupFreshness=%s LatestBackupMaxAgeSeconds=%s RequireRestoreDrillFreshness=%s RestoreDrillMaxAgeSeconds=%s RequireOffsiteBackupFreshness=%s OffsiteBackupMaxAgeSeconds=%s RequireHTTPSCertificate=%s HTTPSCertMode=%s HTTPSCertMinValidDays=%s RequireCertbotRenewalTimer=%s RequirePerformanceGate=%s RequireKafkaLag=%s KafkaLagMaxTotal=%s KafkaLagMaxPartition=%s RequireCloudSecurityGroup=%s CloudSecurityGroupRulesFile=%s RequireCloudSecurityGroupRepairReceipt=%s CloudSecurityGroupRepairReceipt=%s CloudSecurityGroupRepairReceiptMaxAgeSeconds=%s CloudSecurityGroupRepairReceiptExpectSecurityGroupID=%s CloudSecurityGroupRepairReceiptExpectRegionID=%s CloudSecurityGroupRepairReceiptExpectAdminCIDR=%s RequireTopologySmoke=%s TopologySmokeReceipt=%s TopologySmokeMaxAgeSeconds=%s TopologySmokeMaxFutureSkewSeconds=%s TopologySmokeRequireArtifacts=%s RequireNginxConfig=%s NginxRequireSSL=%s NginxHTTPConf=%s NginxLocationsConf=%s NginxSSLConf=%s PerformanceGateProfile=%s RequireCurrentGit=%s RequireCleanGit=%s ExpectBaseURL=%s ExpectTCPHost=%s ExpectTCPPort=%s EvidenceCurrent=%s RequireProfileArtifacts=%s RequireProductPlanArtifacts=%s RequireProductCampaignArtifacts=%s RequireProductScenarioSuiteArtifacts=%s RequireProductScenarioSuiteNoLargeGroup=%s RequireCurrentReadinessArtifacts=%s RequireValidationInventory=%s RequireCloudSecurityGroupEvidence=%s RequireProductionAcceptance=%s ProductionAcceptanceMaxAgeSeconds=%s ProductionAcceptanceMaxFutureSkewSeconds=%s ProductionAcceptanceReceipt=%s ProductionAcceptancePackage=%s AlertEnv=%s AlertConfigured=%s AlertAllowInsecureHTTP=%s AlertRedactLogTail=%s\n' \
  "${AUDIT_CALENDAR}" \
  "${AUDIT_RANDOMIZED_DELAY_SEC}" \
  "${AUDIT_LOG_FILE}" \
  "${AUDIT_VERIFY_LATEST_BACKUP}" \
  "${AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS}" \
  "${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}" \
  "${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS}" \
  "${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}" \
  "${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS}" \
  "${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}" \
  "${AUDIT_REQUIRE_HTTPS_CERTIFICATE}" \
  "${AUDIT_HTTPS_CERT_MODE}" \
  "${AUDIT_HTTPS_CERT_MIN_VALID_DAYS}" \
  "${AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER}" \
  "${AUDIT_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}" \
  "${AUDIT_REQUIRE_KAFKA_LAG_EFFECTIVE}" \
  "${AUDIT_KAFKA_LAG_MAX_TOTAL}" \
  "${AUDIT_KAFKA_LAG_MAX_PARTITION}" \
  "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
  "${AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE}" \
  "${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}" \
  "${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
  "${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
  "${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-<unset>}" \
  "${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-<unset>}" \
  "${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-<unset>}" \
  "${AUDIT_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE}" \
  "${AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON}" \
  "${AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}" \
  "${AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS}" \
  "${AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS}" \
  "${AUDIT_REQUIRE_NGINX_CONFIG}" \
  "${AUDIT_NGINX_REQUIRE_SSL}" \
  "${AUDIT_NGINX_HTTP_CONF_PATH}" \
  "${AUDIT_NGINX_LOCATIONS_CONF_PATH}" \
  "${AUDIT_NGINX_SSL_CONF_PATH}" \
  "${AUDIT_PERFORMANCE_GATE_PROFILE}" \
  "${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT}" \
  "${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}" \
  "${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_EFFECTIVE:-<unset>}" \
  "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_EFFECTIVE:-<unset>}" \
  "${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_EFFECTIVE}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
  "${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}" \
  "${AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" \
  "${AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}" \
  "${AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EFFECTIVE:-<unset>}" \
  "${AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE_EFFECTIVE:-<unset>}" \
  "${AUDIT_ALERT_ENV_FILE}" \
  "$([[ -n "${AUDIT_ALERT_WEBHOOK_URL}" ]] && printf true || printf false)" \
  "${AUDIT_ALERT_ALLOW_INSECURE_HTTP}" \
  "${AUDIT_ALERT_REDACT_LOG_TAIL}"
