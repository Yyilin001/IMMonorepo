#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET_RELEASE_ID="${1:-${TARGET_RELEASE_ID:-}}"
HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
IM_RELEASE_RESTART_SERVICES="${IM_RELEASE_RESTART_SERVICES:-true}"
IM_RELEASE_VERIFY_AFTER_ROLLBACK="${IM_RELEASE_VERIFY_AFTER_ROLLBACK:-true}"
IM_RELEASE_VERIFY_REQUIRE_PUBLIC="${IM_RELEASE_VERIFY_REQUIRE_PUBLIC:-}"
IM_RELEASE_AUDIT_AFTER_ROLLBACK="${IM_RELEASE_AUDIT_AFTER_ROLLBACK:-}"
IM_RELEASE_AUDIT_REQUIRE_AUDIT_TIMER="${IM_RELEASE_AUDIT_REQUIRE_AUDIT_TIMER:-true}"
IM_RELEASE_AUDIT_REQUIRE_RESTORE_DRILL_TIMER="${IM_RELEASE_AUDIT_REQUIRE_RESTORE_DRILL_TIMER:-true}"
IM_RELEASE_AUDIT_REQUIRE_BACKUP="${IM_RELEASE_AUDIT_REQUIRE_BACKUP:-true}"
IM_RELEASE_AUDIT_VERIFY_BACKUP="${IM_RELEASE_AUDIT_VERIFY_BACKUP:-false}"
IM_RELEASE_AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS:-true}"
IM_RELEASE_AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS:-${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS:-172800}}"
IM_RELEASE_AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS:-${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS:-false}}"
IM_RELEASE_AUDIT_RESTORE_DRILL_RECEIPT_FILE="${IM_RELEASE_AUDIT_RESTORE_DRILL_RECEIPT_FILE:-${AUDIT_RESTORE_DRILL_RECEIPT_FILE:-/var/lib/imserver/restore-drill/latest.json}}"
IM_RELEASE_AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS:-${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS:-3888000}}"
IM_RELEASE_AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS:-${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS:-false}}"
IM_RELEASE_AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${IM_RELEASE_AUDIT_OFFSITE_BACKUP_RECEIPT_FILE:-${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE:-/var/lib/imserver/offsite-backup/latest.json}}"
IM_RELEASE_AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS:-${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS:-172800}}"
IM_RELEASE_AUDIT_REQUIRE_ENTRYPOINT="${IM_RELEASE_AUDIT_REQUIRE_ENTRYPOINT:-true}"
IM_RELEASE_AUDIT_REQUIRE_HOST_SECURITY="${IM_RELEASE_AUDIT_REQUIRE_HOST_SECURITY:-true}"
IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ENV="${IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ENV:-true}"
IM_RELEASE_AUDIT_REQUIRE_HTTPS_CERTIFICATE="${IM_RELEASE_AUDIT_REQUIRE_HTTPS_CERTIFICATE:-true}"
IM_RELEASE_AUDIT_HTTPS_CERT_MODE="${IM_RELEASE_AUDIT_HTTPS_CERT_MODE:-${AUDIT_HTTPS_CERT_MODE:-auto}}"
IM_RELEASE_AUDIT_HTTPS_CERT_MIN_VALID_DAYS="${IM_RELEASE_AUDIT_HTTPS_CERT_MIN_VALID_DAYS:-${AUDIT_HTTPS_CERT_MIN_VALID_DAYS:-14}}"
IM_RELEASE_AUDIT_HTTPS_CERT_FILE="${IM_RELEASE_AUDIT_HTTPS_CERT_FILE:-${AUDIT_HTTPS_CERT_FILE:-}}"
IM_RELEASE_AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER="${IM_RELEASE_AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER:-true}"
IM_RELEASE_AUDIT_REQUIRE_RESTRICTED_SSH_CIDR="${IM_RELEASE_AUDIT_REQUIRE_RESTRICTED_SSH_CIDR:-true}"
IM_RELEASE_AUDIT_REQUIRE_RDP_CLOSED="${IM_RELEASE_AUDIT_REQUIRE_RDP_CLOSED:-true}"
IM_RELEASE_AUDIT_REQUIRE_SSH_ACCESS="${IM_RELEASE_AUDIT_REQUIRE_SSH_ACCESS:-true}"
IM_RELEASE_AUDIT_REQUIRE_RELEASE_MANIFEST="${IM_RELEASE_AUDIT_REQUIRE_RELEASE_MANIFEST:-true}"
IM_RELEASE_AUDIT_REQUIRE_DATASTORE_LOOPBACK="${IM_RELEASE_AUDIT_REQUIRE_DATASTORE_LOOPBACK:-true}"
IM_RELEASE_AUDIT_DISK_MAX_USE_PERCENT="${IM_RELEASE_AUDIT_DISK_MAX_USE_PERCENT:-${AUDIT_DISK_MAX_USE_PERCENT:-85}}"
IM_RELEASE_AUDIT_REQUIRE_ALERT_WEBHOOK="${IM_RELEASE_AUDIT_REQUIRE_ALERT_WEBHOOK:-false}"
IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE="${IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE:-}"
IM_RELEASE_AUDIT_PERFORMANCE_GATE_JSON="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_JSON:-${AUDIT_PERFORMANCE_GATE_JSON:-/var/lib/imserver/performance/production-gate.json}}"
IM_RELEASE_AUDIT_PERFORMANCE_GATE_PROFILE="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_PROFILE:-${AUDIT_PERFORMANCE_GATE_PROFILE:-normal-product-baseline}}"
IM_RELEASE_AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS:-${AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS:-604800}}"
IM_RELEASE_AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT:-${AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT:-false}}"
IM_RELEASE_AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT:-${AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT:-false}}"
IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL:-${AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL:-}}"
IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST:-${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST:-}}"
IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT:-${AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT:-}}"
IM_RELEASE_AUDIT_PERFORMANCE_PROFILE_CATALOG="${IM_RELEASE_AUDIT_PERFORMANCE_PROFILE_CATALOG:-${AUDIT_PERFORMANCE_PROFILE_CATALOG:-${SCRIPT_DIR}/../../IMServer/LoadTests/perf_production_profiles.json}}"
IM_RELEASE_AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK="${IM_RELEASE_AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK:-${AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK:-/var/lib/imserver/performance/current-evidence}}"
IM_RELEASE_AUDIT_REQUIRE_PROFILE_ARTIFACTS="${IM_RELEASE_AUDIT_REQUIRE_PROFILE_ARTIFACTS:-${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS:-}}"
IM_RELEASE_AUDIT_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_PLAN_ARTIFACTS:-${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS:-}}"
IM_RELEASE_AUDIT_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS:-${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS:-}}"
IM_RELEASE_AUDIT_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS:-${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS:-}}"
IM_RELEASE_AUDIT_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP:-${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP:-true}}"
IM_RELEASE_AUDIT_REQUIRE_CURRENT_READINESS_ARTIFACTS="${IM_RELEASE_AUDIT_REQUIRE_CURRENT_READINESS_ARTIFACTS:-${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS:-}}"
IM_RELEASE_AUDIT_REQUIRE_VALIDATION_INVENTORY="${IM_RELEASE_AUDIT_REQUIRE_VALIDATION_INVENTORY:-${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY:-true}}"
IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ACCEPTANCE="${IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ACCEPTANCE:-${AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE:-}}"
IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-${AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-86400}}}"
IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-${AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-300}}}"
IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-${AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}}"
IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE:-${AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE:-}}"
IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP="${IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP:-}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE:-${AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE:-${IMSERVER_ETC_DIR}/cloud-security-group.json}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-${AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-${AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-${AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-${AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-${AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-${AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}}"
IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT:-${AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT:-}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-86400}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${ALIYUN_SECURITY_GROUP_ID:-}}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${ALIYUN_REGION_ID:-}}}"
IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}}}"
IM_RELEASE_AUDIT_REQUIRE_NGINX_CONFIG="${IM_RELEASE_AUDIT_REQUIRE_NGINX_CONFIG:-${AUDIT_REQUIRE_NGINX_CONFIG:-true}}"
IM_RELEASE_AUDIT_NGINX_HTTP_CONF_PATH="${IM_RELEASE_AUDIT_NGINX_HTTP_CONF_PATH:-${AUDIT_NGINX_HTTP_CONF_PATH:-/etc/nginx/conf.d/imserver.conf}}"
IM_RELEASE_AUDIT_NGINX_LOCATIONS_CONF_PATH="${IM_RELEASE_AUDIT_NGINX_LOCATIONS_CONF_PATH:-${AUDIT_NGINX_LOCATIONS_CONF_PATH:-/etc/nginx/snippets/imserver_locations.conf}}"
IM_RELEASE_AUDIT_NGINX_SSL_CONF_PATH="${IM_RELEASE_AUDIT_NGINX_SSL_CONF_PATH:-${AUDIT_NGINX_SSL_CONF_PATH:-/etc/nginx/conf.d/imserver_ssl.conf}}"
IM_RELEASE_AUDIT_NGINX_REQUIRE_SSL="${IM_RELEASE_AUDIT_NGINX_REQUIRE_SSL:-${AUDIT_NGINX_REQUIRE_SSL:-false}}"
ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
ROLLBACK_SELF_TEST="${ROLLBACK_SELF_TEST:-false}"

service_units=(
  imserver-command-api
  imserver-gateway
  imserver-query-api
  imserver-outbox-relay
  imserver-stream-consumer
  imserver-domain-delivery-consumer
)

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

rollback_env_value() {
  local key="$1"
  local value="${!key:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  read_env_file_value "${ENV_FILE}" "${key}"
}

rollback_app_env() {
  if [[ -n "${APP_ENV:-}" ]]; then
    printf '%s\n' "${APP_ENV}"
    return 0
  fi
  local value
  value="$(read_env_file_value "${ENV_FILE}" "APP_ENV")"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  printf '%s\n' "${IMSERVER_RUN_ENV:-development}"
}

resolve_rollback_public_base_url() {
  local value
  value="$(rollback_env_value "PUBLIC_BASE_URL")"
  if [[ -z "${value}" ]]; then
    value="$(rollback_env_value "IM_PUBLIC_BASE_URL")"
  fi
  printf '%s\n' "${value}"
}

resolve_rollback_require_public() {
  if [[ -n "${IM_RELEASE_VERIFY_REQUIRE_PUBLIC}" ]]; then
    printf '%s\n' "${IM_RELEASE_VERIFY_REQUIRE_PUBLIC}"
    return 0
  fi
  case "$(rollback_app_env)" in
    production) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

resolve_rollback_audit_requirement() {
  if [[ -n "${IM_RELEASE_AUDIT_AFTER_ROLLBACK}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_AFTER_ROLLBACK}"
    return 0
  fi
  case "$(rollback_app_env)" in
    production) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

resolve_rollback_performance_gate_requirement() {
  if [[ -n "${IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE}"
    return 0
  fi
  case "$(rollback_app_env)" in
    production) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

resolve_rollback_alert_webhook_requirement() {
  if bool_enabled "$(resolve_rollback_performance_gate_requirement)"; then
    printf 'true\n'
  else
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_ALERT_WEBHOOK}"
  fi
}

resolve_rollback_profile_artifact_requirement() {
  if bool_enabled "$(resolve_rollback_performance_gate_requirement)"; then
    printf 'true\n'
  elif [[ -n "${IM_RELEASE_AUDIT_REQUIRE_PROFILE_ARTIFACTS}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_PROFILE_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_rollback_product_plan_artifact_requirement() {
  if bool_enabled "$(resolve_rollback_performance_gate_requirement)"; then
    printf 'true\n'
  elif [[ -n "${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_PLAN_ARTIFACTS}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_PLAN_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_rollback_product_campaign_artifact_requirement() {
  if bool_enabled "$(resolve_rollback_performance_gate_requirement)"; then
    printf 'true\n'
  elif [[ -n "${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_rollback_product_scenario_suite_artifact_requirement() {
  if bool_enabled "$(resolve_rollback_performance_gate_requirement)"; then
    printf 'true\n'
  elif [[ -n "${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_rollback_current_readiness_artifact_requirement() {
  if bool_enabled "$(resolve_rollback_performance_gate_requirement)"; then
    printf 'true\n'
  elif [[ -n "${IM_RELEASE_AUDIT_REQUIRE_CURRENT_READINESS_ARTIFACTS}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_CURRENT_READINESS_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_rollback_production_acceptance_requirement() {
  if bool_enabled "$(resolve_rollback_performance_gate_requirement)"; then
    printf 'true\n'
  elif [[ -n "${IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ACCEPTANCE}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ACCEPTANCE}"
  else
    printf 'false\n'
  fi
}

resolve_rollback_cloud_security_group_requirement() {
  if bool_enabled "$(resolve_rollback_performance_gate_requirement)"; then
    printf 'true\n'
  elif [[ -n "${IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP}"
  else
    printf 'false\n'
  fi
}

rollback_host_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
}

rollback_scheme_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).scheme or "")
PY
}

rollback_port_from_url() {
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

rollback_public_host_policy_reason() {
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

resolve_rollback_performance_gate_expect_base_url() {
  if [[ -n "${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL}"
    return 0
  fi
  resolve_rollback_public_base_url
}

resolve_rollback_performance_gate_expect_tcp_host() {
  if [[ -n "${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST}"
    return 0
  fi
  local value
  value="$(rollback_env_value "TCP_HOST")"
  if [[ -z "${value}" ]]; then
    value="$(rollback_env_value "IM_PUBLIC_HOST")"
  fi
  if [[ -z "${value}" ]]; then
    value="$(rollback_host_from_url "$(resolve_rollback_public_base_url)")"
  fi
  printf '%s\n' "${value}"
}

resolve_rollback_performance_gate_expect_tcp_port() {
  if [[ -n "${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT}" ]]; then
    printf '%s\n' "${IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT}"
    return 0
  fi
  local value
  value="$(rollback_env_value "TCP_PORT")"
  if [[ -z "${value}" ]]; then
    value="$(rollback_env_value "IM_TCP_PORT")"
  fi
  printf '%s\n' "${value:-9000}"
}

validate_rollback_public_targets() {
  local require_performance_gate="$1"
  local public_base_url="$2"
  local expect_base_url="$3"
  local expect_tcp_host="$4"
  local expect_tcp_port="$5"
  local public_base_url_scheme public_base_url_port public_base_url_host public_base_url_host_reason
  local expect_base_url_scheme expect_base_url_port expect_base_url_host expect_base_url_host_reason
  local expect_tcp_host_reason

  if ! bool_enabled "${require_performance_gate}"; then
    return 0
  fi
  if [[ -z "${public_base_url}" ]]; then
    printf 'rollback result=fail reason=public_base_url_missing hint=set_PUBLIC_BASE_URL_or_IM_PUBLIC_BASE_URL_or_disable_performance_gate_for_first_bootstrap\n' >&2
    return 2
  fi
  public_base_url_scheme="$(rollback_scheme_from_url "${public_base_url}")"
  if [[ "${public_base_url_scheme}" != "https" ]]; then
    printf 'rollback result=fail reason=public_base_url_https_required publicBaseURL=%s hint=set_PUBLIC_BASE_URL_or_IM_PUBLIC_BASE_URL_to_https_or_disable_performance_gate_for_first_bootstrap\n' \
      "${public_base_url}" >&2
    return 2
  fi
  public_base_url_port="$(rollback_port_from_url "${public_base_url}")"
  if [[ "${public_base_url_port}" != "443" ]]; then
    printf 'rollback result=fail reason=public_base_url_default_https_port_required publicBaseURL=%s port=%s hint=use_default_https_443_for_long_term_production\n' \
      "${public_base_url}" \
      "${public_base_url_port:-<empty>}" >&2
    return 2
  fi
  public_base_url_host="$(rollback_host_from_url "${public_base_url}")"
  public_base_url_host_reason="$(rollback_public_host_policy_reason "${public_base_url_host}")"
  if [[ "${public_base_url_host_reason}" != "ok" ]]; then
    printf 'rollback result=fail reason=public_base_url_domain_required publicBaseURL=%s host=%s hostReason=%s hint=use_a_real_production_domain_not_a_raw_ip_or_placeholder\n' \
      "${public_base_url}" \
      "${public_base_url_host:-<empty>}" \
      "${public_base_url_host_reason}" >&2
    return 2
  fi
  if [[ -z "${expect_base_url}" ]]; then
    printf 'rollback result=fail reason=expect_base_url_missing hint=set_IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL_or_PUBLIC_BASE_URL\n' >&2
    return 2
  fi
  expect_base_url_scheme="$(rollback_scheme_from_url "${expect_base_url}")"
  if [[ "${expect_base_url_scheme}" != "https" ]]; then
    printf 'rollback result=fail reason=expect_base_url_https_required expectBaseURL=%s hint=bind_production_performance_evidence_to_https_BASE_URL\n' \
      "${expect_base_url}" >&2
    return 2
  fi
  expect_base_url_port="$(rollback_port_from_url "${expect_base_url}")"
  if [[ "${expect_base_url_port}" != "443" ]]; then
    printf 'rollback result=fail reason=expect_base_url_default_https_port_required expectBaseURL=%s port=%s hint=bind_production_performance_evidence_to_default_https_443\n' \
      "${expect_base_url}" \
      "${expect_base_url_port:-<empty>}" >&2
    return 2
  fi
  expect_base_url_host="$(rollback_host_from_url "${expect_base_url}")"
  expect_base_url_host_reason="$(rollback_public_host_policy_reason "${expect_base_url_host}")"
  if [[ "${expect_base_url_host_reason}" != "ok" ]]; then
    printf 'rollback result=fail reason=expect_base_url_domain_required expectBaseURL=%s host=%s hostReason=%s hint=bind_production_performance_evidence_to_the_real_https_domain\n' \
      "${expect_base_url}" \
      "${expect_base_url_host:-<empty>}" \
      "${expect_base_url_host_reason}" >&2
    return 2
  fi
  if [[ -z "${expect_tcp_host}" ]]; then
    printf 'rollback result=fail reason=expect_tcp_host_missing hint=set_IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST_or_TCP_HOST_or_IM_PUBLIC_HOST_or_PUBLIC_BASE_URL\n' >&2
    return 2
  fi
  expect_tcp_host_reason="$(rollback_public_host_policy_reason "${expect_tcp_host}")"
  if [[ "${expect_tcp_host_reason}" != "ok" ]]; then
    printf 'rollback result=fail reason=expect_tcp_host_domain_required tcpHost=%s hostReason=%s hint=use_a_real_production_tcp_domain_not_a_raw_ip_or_placeholder\n' \
      "${expect_tcp_host}" \
      "${expect_tcp_host_reason}" >&2
    return 2
  fi
  if [[ -z "${expect_tcp_port}" ]]; then
    printf 'rollback result=fail reason=expect_tcp_port_missing hint=set_IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT_or_TCP_PORT_or_IM_TCP_PORT\n' >&2
    return 2
  fi
}

verify_after_rollback() {
  local public_base_url require_public smoke_base_url require_audit require_alert_webhook require_performance_gate require_cloud_security_group expect_base_url expect_tcp_host expect_tcp_port
  local require_profile_artifacts require_product_plan_artifacts require_product_campaign_artifacts require_product_scenario_suite_artifacts require_current_readiness_artifacts
  public_base_url="$(resolve_rollback_public_base_url)"
  require_public="$(resolve_rollback_require_public)"
  require_audit="$(resolve_rollback_audit_requirement)"
  require_performance_gate="$(resolve_rollback_performance_gate_requirement)"
  require_alert_webhook="$(resolve_rollback_alert_webhook_requirement)"
  require_profile_artifacts="$(resolve_rollback_profile_artifact_requirement)"
  require_product_plan_artifacts="$(resolve_rollback_product_plan_artifact_requirement)"
  require_product_campaign_artifacts="$(resolve_rollback_product_campaign_artifact_requirement)"
  require_product_scenario_suite_artifacts="$(resolve_rollback_product_scenario_suite_artifact_requirement)"
  require_current_readiness_artifacts="$(resolve_rollback_current_readiness_artifact_requirement)"
  require_production_acceptance="$(resolve_rollback_production_acceptance_requirement)"
  require_cloud_security_group="$(resolve_rollback_cloud_security_group_requirement)"
  expect_base_url="$(resolve_rollback_performance_gate_expect_base_url)"
  expect_tcp_host="$(resolve_rollback_performance_gate_expect_tcp_host)"
  expect_tcp_port="$(resolve_rollback_performance_gate_expect_tcp_port)"
  validate_rollback_public_targets "${require_performance_gate}" "${public_base_url}" "${expect_base_url}" "${expect_tcp_host}" "${expect_tcp_port}"
  smoke_base_url="${public_base_url:-http://127.0.0.1:${HTTP_PORT}}"

  HTTP_PORT="${HTTP_PORT}" \
    PUBLIC_BASE_URL="${public_base_url}" \
    VERIFY_REQUIRE_PUBLIC="${require_public}" \
    bash "${SCRIPT_DIR}/65_verify_entrypoint.sh"
  HTTP_PORT="${HTTP_PORT}" \
    BASE_URL="${smoke_base_url}" \
    bash "${SCRIPT_DIR}/66_smoke_entrypoint.sh"
  if bool_enabled "${require_audit}"; then
    HTTP_PORT="${HTTP_PORT}" \
      PUBLIC_BASE_URL="${public_base_url}" \
      AUDIT_REQUIRE_AUDIT_TIMER="${IM_RELEASE_AUDIT_REQUIRE_AUDIT_TIMER}" \
      AUDIT_REQUIRE_RESTORE_DRILL_TIMER="${IM_RELEASE_AUDIT_REQUIRE_RESTORE_DRILL_TIMER}" \
      AUDIT_REQUIRE_BACKUP="${IM_RELEASE_AUDIT_REQUIRE_BACKUP}" \
      AUDIT_VERIFY_LATEST_BACKUP="${IM_RELEASE_AUDIT_VERIFY_BACKUP}" \
      AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS}" \
      AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}" \
      AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS}" \
      AUDIT_RESTORE_DRILL_RECEIPT_FILE="${IM_RELEASE_AUDIT_RESTORE_DRILL_RECEIPT_FILE}" \
      AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}" \
      AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS}" \
      AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${IM_RELEASE_AUDIT_OFFSITE_BACKUP_RECEIPT_FILE}" \
      AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}" \
      AUDIT_REQUIRE_ENTRYPOINT="${IM_RELEASE_AUDIT_REQUIRE_ENTRYPOINT}" \
      AUDIT_REQUIRE_HOST_SECURITY="${IM_RELEASE_AUDIT_REQUIRE_HOST_SECURITY}" \
      AUDIT_REQUIRE_PRODUCTION_ENV="${IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ENV}" \
      AUDIT_REQUIRE_HTTPS_CERTIFICATE="${IM_RELEASE_AUDIT_REQUIRE_HTTPS_CERTIFICATE}" \
      AUDIT_HTTPS_CERT_MODE="${IM_RELEASE_AUDIT_HTTPS_CERT_MODE}" \
      AUDIT_HTTPS_CERT_MIN_VALID_DAYS="${IM_RELEASE_AUDIT_HTTPS_CERT_MIN_VALID_DAYS}" \
      AUDIT_HTTPS_CERT_FILE="${IM_RELEASE_AUDIT_HTTPS_CERT_FILE}" \
      AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER="${IM_RELEASE_AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER}" \
      AUDIT_REQUIRE_RESTRICTED_SSH_CIDR="${IM_RELEASE_AUDIT_REQUIRE_RESTRICTED_SSH_CIDR}" \
      AUDIT_REQUIRE_RDP_CLOSED="${IM_RELEASE_AUDIT_REQUIRE_RDP_CLOSED}" \
      AUDIT_REQUIRE_SSH_ACCESS="${IM_RELEASE_AUDIT_REQUIRE_SSH_ACCESS}" \
      AUDIT_REQUIRE_RELEASE_MANIFEST="${IM_RELEASE_AUDIT_REQUIRE_RELEASE_MANIFEST}" \
      AUDIT_REQUIRE_DATASTORE_LOOPBACK="${IM_RELEASE_AUDIT_REQUIRE_DATASTORE_LOOPBACK}" \
      AUDIT_DISK_MAX_USE_PERCENT="${IM_RELEASE_AUDIT_DISK_MAX_USE_PERCENT}" \
      AUDIT_REQUIRE_ALERT_WEBHOOK="${require_alert_webhook}" \
      AUDIT_REQUIRE_PERFORMANCE_GATE="${require_performance_gate}" \
      AUDIT_PERFORMANCE_GATE_JSON="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_JSON}" \
      AUDIT_PERFORMANCE_GATE_PROFILE="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_PROFILE}" \
      AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS}" \
      AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT}" \
      AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}" \
      AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL="${expect_base_url}" \
      AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST="${expect_tcp_host}" \
      AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT="${expect_tcp_port}" \
      AUDIT_PERFORMANCE_PROFILE_CATALOG="${IM_RELEASE_AUDIT_PERFORMANCE_PROFILE_CATALOG}" \
      AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK="${IM_RELEASE_AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK}" \
      AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${require_profile_artifacts}" \
      AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${require_product_plan_artifacts}" \
      AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${require_product_campaign_artifacts}" \
      AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${require_product_scenario_suite_artifacts}" \
      AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${IM_RELEASE_AUDIT_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}" \
      AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS="${require_current_readiness_artifacts}" \
      AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${IM_RELEASE_AUDIT_REQUIRE_VALIDATION_INVENTORY}" \
      AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE="${require_production_acceptance}" \
      AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" \
      AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}" \
      AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
      AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE}" \
      AUDIT_REQUIRE_CLOUD_SECURITY_GROUP="${require_cloud_security_group}" \
      AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE}" \
      AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
      AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
      AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
      AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
      AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
      AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
      AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
      AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
      AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
      AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
      AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
      AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
      AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}" \
      AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
      AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
      AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
      AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
      AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
      AUDIT_REQUIRE_NGINX_CONFIG="${IM_RELEASE_AUDIT_REQUIRE_NGINX_CONFIG}" \
      AUDIT_NGINX_HTTP_CONF_PATH="${IM_RELEASE_AUDIT_NGINX_HTTP_CONF_PATH}" \
      AUDIT_NGINX_LOCATIONS_CONF_PATH="${IM_RELEASE_AUDIT_NGINX_LOCATIONS_CONF_PATH}" \
      AUDIT_NGINX_SSL_CONF_PATH="${IM_RELEASE_AUDIT_NGINX_SSL_CONF_PATH}" \
      AUDIT_NGINX_REQUIRE_SSL="${IM_RELEASE_AUDIT_NGINX_REQUIRE_SSL}" \
      bash "${SCRIPT_DIR}/77_operational_audit.sh"
  fi
}

run_self_test() {
  local tmpdir env_file fallback_env_file actual
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  env_file="${tmpdir}/common.env"
  printf 'APP_ENV=production\n' >"${env_file}"
  printf 'IM_PUBLIC_BASE_URL=https://rollback.myim-prod.com\n' >>"${env_file}"
  printf 'TCP_HOST=rollback-tcp.myim-prod.com\n' >>"${env_file}"
  printf 'TCP_PORT=9443\n' >>"${env_file}"
  fallback_env_file="${tmpdir}/fallback.env"
  printf 'APP_ENV=production\n' >"${fallback_env_file}"

  actual="$(ENV_FILE="${env_file}" PUBLIC_BASE_URL= IM_PUBLIC_BASE_URL= resolve_rollback_public_base_url)"
  [[ "${actual}" == "https://rollback.myim-prod.com" ]] || {
    printf 'rollback-self-test result=fail reason=public_base_url_resolution expected=https://rollback.myim-prod.com actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV= IMSERVER_RUN_ENV=development IM_RELEASE_VERIFY_REQUIRE_PUBLIC= resolve_rollback_require_public)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=production_default_require_public expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_VERIFY_REQUIRE_PUBLIC=false resolve_rollback_require_public)"
  [[ "${actual}" == "false" ]] || {
    printf 'rollback-self-test result=fail reason=explicit_require_public_override expected=false actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV= IMSERVER_RUN_ENV=development IM_RELEASE_AUDIT_AFTER_ROLLBACK= resolve_rollback_audit_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=production_default_audit expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_AFTER_ROLLBACK=false resolve_rollback_audit_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'rollback-self-test result=fail reason=explicit_audit_override expected=false actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV= IMSERVER_RUN_ENV=development IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= resolve_rollback_performance_gate_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=production_default_performance_gate expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE=false resolve_rollback_performance_gate_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'rollback-self-test result=fail reason=explicit_performance_gate_override expected=false actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= IM_RELEASE_AUDIT_REQUIRE_ALERT_WEBHOOK=false resolve_rollback_alert_webhook_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_forces_alert_webhook expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= IM_RELEASE_AUDIT_REQUIRE_PROFILE_ARTIFACTS=false resolve_rollback_profile_artifact_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_forces_profile_artifacts expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= IM_RELEASE_AUDIT_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false resolve_rollback_product_plan_artifact_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_forces_product_plan_artifacts expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= IM_RELEASE_AUDIT_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=false resolve_rollback_product_campaign_artifact_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_forces_product_campaign_artifacts expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= IM_RELEASE_AUDIT_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=false resolve_rollback_product_scenario_suite_artifact_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_forces_product_scenario_suite_artifacts expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= IM_RELEASE_AUDIT_REQUIRE_CURRENT_READINESS_ARTIFACTS=false resolve_rollback_current_readiness_artifact_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_forces_current_readiness_artifacts expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ACCEPTANCE=false resolve_rollback_production_acceptance_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_forces_production_acceptance expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE=false IM_RELEASE_AUDIT_REQUIRE_PROFILE_ARTIFACTS=false resolve_rollback_profile_artifact_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'rollback-self-test result=fail reason=profile_artifacts_override_without_performance_gate expected=false actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE=false IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ACCEPTANCE=false resolve_rollback_production_acceptance_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'rollback-self-test result=fail reason=production_acceptance_override_without_performance_gate expected=false actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" PUBLIC_BASE_URL= IM_PUBLIC_BASE_URL= IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL= resolve_rollback_performance_gate_expect_base_url)"
  [[ "${actual}" == "https://rollback.myim-prod.com" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_expect_base_url expected=https://rollback.myim-prod.com actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" TCP_HOST= IM_PUBLIC_HOST= PUBLIC_BASE_URL= IM_PUBLIC_BASE_URL= IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST= resolve_rollback_performance_gate_expect_tcp_host)"
  [[ "${actual}" == "rollback-tcp.myim-prod.com" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_expect_tcp_host expected=rollback-tcp.myim-prod.com actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" TCP_PORT= IM_TCP_PORT= IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT= resolve_rollback_performance_gate_expect_tcp_port)"
  [[ "${actual}" == "9443" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_expect_tcp_port expected=9443 actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${fallback_env_file}" TCP_HOST= IM_PUBLIC_HOST= PUBLIC_BASE_URL=https://fallback.myim-prod.com IM_PUBLIC_BASE_URL= IM_RELEASE_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST= resolve_rollback_performance_gate_expect_tcp_host)"
  [[ "${actual}" == "fallback.myim-prod.com" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_expect_tcp_host_from_public_url expected=fallback.myim-prod.com actual=%s\n' "${actual}" >&2
    return 1
  }

  if validate_rollback_public_targets true "http://rollback.myim-prod.com" "http://rollback.myim-prod.com" "rollback-tcp.myim-prod.com" "9000" >/tmp/im-rollback-self-test.log 2>&1; then
    printf 'rollback-self-test result=fail reason=http_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'reason=public_base_url_https_required' /tmp/im-rollback-self-test.log || {
    printf 'rollback-self-test result=fail reason=http_public_target_reason_absent\n' >&2
    cat /tmp/im-rollback-self-test.log >&2
    return 1
  }

  if validate_rollback_public_targets true "https://203.0.113.10" "https://203.0.113.10" "rollback-tcp.myim-prod.com" "9000" >/tmp/im-rollback-self-test.log 2>&1; then
    printf 'rollback-self-test result=fail reason=ip_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'reason=public_base_url_domain_required' /tmp/im-rollback-self-test.log || {
    printf 'rollback-self-test result=fail reason=ip_public_target_reason_absent\n' >&2
    cat /tmp/im-rollback-self-test.log >&2
    return 1
  }

  if validate_rollback_public_targets true "https://rollback.myim-prod.com:8443" "https://rollback.myim-prod.com:8443" "rollback-tcp.myim-prod.com" "9000" >/tmp/im-rollback-self-test.log 2>&1; then
    printf 'rollback-self-test result=fail reason=non_default_https_port_accepted\n' >&2
    return 1
  fi
  grep -q 'reason=public_base_url_default_https_port_required' /tmp/im-rollback-self-test.log || {
    printf 'rollback-self-test result=fail reason=non_default_public_port_reason_absent\n' >&2
    cat /tmp/im-rollback-self-test.log >&2
    return 1
  }

  if validate_rollback_public_targets true "https://rollback.myim-prod.com" "https://rollback.myim-prod.com:8443" "rollback-tcp.myim-prod.com" "9000" >/tmp/im-rollback-self-test.log 2>&1; then
    printf 'rollback-self-test result=fail reason=non_default_expect_https_port_accepted\n' >&2
    return 1
  fi
  grep -q 'reason=expect_base_url_default_https_port_required' /tmp/im-rollback-self-test.log || {
    printf 'rollback-self-test result=fail reason=non_default_expect_port_reason_absent\n' >&2
    cat /tmp/im-rollback-self-test.log >&2
    return 1
  }

  if validate_rollback_public_targets true "https://rollback.myim-prod.com" "https://rollback.myim-prod.com" "203.0.113.10" "9000" >/tmp/im-rollback-self-test.log 2>&1; then
    printf 'rollback-self-test result=fail reason=ip_tcp_target_accepted\n' >&2
    return 1
  fi
  grep -q 'reason=expect_tcp_host_domain_required' /tmp/im-rollback-self-test.log || {
    printf 'rollback-self-test result=fail reason=ip_tcp_target_reason_absent\n' >&2
    cat /tmp/im-rollback-self-test.log >&2
    return 1
  }
  validate_rollback_public_targets true "https://rollback.myim-prod.com" "https://rollback.myim-prod.com" "rollback-tcp.myim-prod.com" "9000" >/tmp/im-rollback-self-test.log 2>&1 || {
    printf 'rollback-self-test result=fail reason=valid_public_target_rejected\n' >&2
    cat /tmp/im-rollback-self-test.log >&2
    return 1
  }
  rm -f /tmp/im-rollback-self-test.log

  actual="$(ENV_FILE="${env_file}" APP_ENV= IMSERVER_RUN_ENV=development IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP= resolve_rollback_cloud_security_group_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=production_default_cloud_security_group expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE= IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_rollback_cloud_security_group_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'rollback-self-test result=fail reason=performance_gate_forces_cloud_security_group expected=true actual=%s\n' "${actual}" >&2
    return 1
  }

  actual="$(ENV_FILE="${env_file}" APP_ENV=production IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE=false IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_rollback_cloud_security_group_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'rollback-self-test result=fail reason=explicit_cloud_security_group_override_without_performance_gate expected=false actual=%s\n' "${actual}" >&2
    return 1
  }

  grep -q 'PUBLIC_BASE_URL="${public_base_url}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=verify_entrypoint_public_base_url_missing\n' >&2
    return 1
  }
  grep -q 'VERIFY_REQUIRE_PUBLIC="${require_public}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=verify_entrypoint_require_public_missing\n' >&2
    return 1
  }
  grep -q 'BASE_URL="${smoke_base_url}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=smoke_public_base_url_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_AUDIT_TIMER="${IM_RELEASE_AUDIT_REQUIRE_AUDIT_TIMER}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_timer_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_BACKUP="${IM_RELEASE_AUDIT_REQUIRE_BACKUP}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_backup_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_latest_backup_freshness_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_latest_backup_max_age_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_restore_drill_freshness_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_RESTORE_DRILL_RECEIPT_FILE="${IM_RELEASE_AUDIT_RESTORE_DRILL_RECEIPT_FILE}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_restore_drill_receipt_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_restore_drill_max_age_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS="${IM_RELEASE_AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_offsite_backup_freshness_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${IM_RELEASE_AUDIT_OFFSITE_BACKUP_RECEIPT_FILE}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_offsite_backup_receipt_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_offsite_backup_max_age_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_ENTRYPOINT="${IM_RELEASE_AUDIT_REQUIRE_ENTRYPOINT}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_entrypoint_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_PRODUCTION_ENV="${IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ENV}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_production_env_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_HTTPS_CERTIFICATE="${IM_RELEASE_AUDIT_REQUIRE_HTTPS_CERTIFICATE}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_https_certificate_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_HTTPS_CERT_MODE="${IM_RELEASE_AUDIT_HTTPS_CERT_MODE}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_https_certificate_mode_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_HTTPS_CERT_MIN_VALID_DAYS="${IM_RELEASE_AUDIT_HTTPS_CERT_MIN_VALID_DAYS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_https_certificate_min_valid_days_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER="${IM_RELEASE_AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_certbot_timer_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_RESTRICTED_SSH_CIDR="${IM_RELEASE_AUDIT_REQUIRE_RESTRICTED_SSH_CIDR}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_restricted_ssh_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_RDP_CLOSED="${IM_RELEASE_AUDIT_REQUIRE_RDP_CLOSED}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_rdp_closed_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_SSH_ACCESS="${IM_RELEASE_AUDIT_REQUIRE_SSH_ACCESS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_ssh_access_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_RELEASE_MANIFEST="${IM_RELEASE_AUDIT_REQUIRE_RELEASE_MANIFEST}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_release_manifest_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_DATASTORE_LOOPBACK="${IM_RELEASE_AUDIT_REQUIRE_DATASTORE_LOOPBACK}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_datastore_loopback_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_ALERT_WEBHOOK="${require_alert_webhook}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_alert_webhook_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_PERFORMANCE_GATE="${require_performance_gate}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_gate_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_GATE_JSON="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_JSON}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_gate_json_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_GATE_PROFILE="${IM_RELEASE_AUDIT_PERFORMANCE_GATE_PROFILE}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_gate_profile_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL="${expect_base_url}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_gate_expect_base_url_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST="${expect_tcp_host}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_gate_expect_tcp_host_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT="${expect_tcp_port}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_gate_expect_tcp_port_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK="${IM_RELEASE_AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_evidence_current_link_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${require_profile_artifacts}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_evidence_profile_artifacts_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${require_product_plan_artifacts}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_evidence_product_plan_artifacts_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${require_product_campaign_artifacts}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_evidence_product_campaign_artifacts_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${require_product_scenario_suite_artifacts}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_evidence_product_scenario_suite_artifacts_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS="${require_current_readiness_artifacts}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_evidence_current_readiness_artifacts_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${IM_RELEASE_AUDIT_REQUIRE_VALIDATION_INVENTORY}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_evidence_validation_inventory_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE="${require_production_acceptance}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_performance_evidence_production_acceptance_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_production_acceptance_max_age_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_production_acceptance_max_future_skew_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_production_acceptance_receipt_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_production_acceptance_package_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_CLOUD_SECURITY_GROUP="${require_cloud_security_group}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_rules_file_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_deny_ports_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_require_public_client_ports_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_rules_max_age_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_rules_require_root_owner_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_public_broad_ipv4_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_public_broad_ipv6_missing\n' >&2
    return 1
  }
  grep -q 'IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_admin_public_ipv4_min_prefix_default_missing\n' >&2
    return 1
  }
  grep -q 'IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-${AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_admin_public_ipv6_min_prefix_default_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_admin_public_ipv4_min_prefix_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_admin_public_ipv6_min_prefix_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_repair_receipt_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_repair_receipt_json_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_repair_receipt_max_age_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_repair_receipt_expect_sg_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_repair_receipt_expect_region_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_cloud_security_group_repair_receipt_expect_admin_cidr_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_REQUIRE_NGINX_CONFIG="${IM_RELEASE_AUDIT_REQUIRE_NGINX_CONFIG}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_nginx_config_requirement_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_NGINX_HTTP_CONF_PATH="${IM_RELEASE_AUDIT_NGINX_HTTP_CONF_PATH}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_nginx_http_conf_missing\n' >&2
    return 1
  }
  grep -q 'AUDIT_NGINX_REQUIRE_SSL="${IM_RELEASE_AUDIT_NGINX_REQUIRE_SSL}"' "${BASH_SOURCE[0]}" || {
    printf 'rollback-self-test result=fail reason=audit_nginx_require_ssl_missing\n' >&2
    return 1
  }

  printf 'rollback-self-test result=pass\n'
}

if bool_enabled "${ROLLBACK_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root

current_release_dir=""
if [[ -L "${IMSERVER_CURRENT_LINK}" ]]; then
  current_release_dir="$(readlink -f "${IMSERVER_CURRENT_LINK}")"
elif [[ -L "${IMSERVER_BIN_DIR}/IMServer" ]]; then
  current_release_dir="$(dirname "$(dirname "$(readlink -f "${IMSERVER_BIN_DIR}/IMServer")")")"
fi

target_release_dir=""
if [[ -n "${TARGET_RELEASE_ID}" ]]; then
  target_release_dir="${IMSERVER_RELEASES_DIR}/${TARGET_RELEASE_ID}"
else
  while IFS= read -r candidate; do
    if [[ -n "${current_release_dir}" && "$(readlink -f "${candidate}")" == "${current_release_dir}" ]]; then
      continue
    fi
    target_release_dir="${candidate}"
    break
  done < <(find "${IMSERVER_RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d | sort -r)
fi

if [[ -z "${target_release_dir}" || ! -x "${target_release_dir}/bin/IMServer" ]]; then
  echo "No rollback target found. Pass a release id or keep at least two releases in ${IMSERVER_RELEASES_DIR}." >&2
  exit 1
fi

printf 'rollback current=%s target=%s\n' "${current_release_dir:-<none>}" "${target_release_dir}"

ln -sfn "${target_release_dir}" "${IMSERVER_CURRENT_LINK}"
ln -sfn "${target_release_dir}/bin/IMServer" "${IMSERVER_BIN_DIR}/IMServer"
if [[ -d "${target_release_dir}/Public" ]]; then
  ln -sfn "${target_release_dir}/Public" "${IMSERVER_HOME}/Public"
fi

if bool_enabled "${IM_RELEASE_RESTART_SERVICES}"; then
  restart_units=()
  for unit in "${service_units[@]}"; do
    if systemctl is-active --quiet "${unit}"; then
      restart_units+=("${unit}")
    fi
  done
  while IFS= read -r unit; do
    [[ -n "${unit}" ]] && restart_units+=("${unit}")
  done < <(
    systemctl list-units --type=service --state=active --no-legend --plain 'imserver-stream-consumer@*.service' 2>/dev/null \
      | awk '{print $1}'
  )
  if (( ${#restart_units[@]} > 0 )); then
    systemctl restart "${restart_units[@]}"
  fi
fi

if bool_enabled "${IM_RELEASE_VERIFY_AFTER_ROLLBACK}"; then
  verify_after_rollback
fi

printf 'rollback result=pass target=%s\n' "${target_release_dir}"
