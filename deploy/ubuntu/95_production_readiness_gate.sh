#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

READINESS_REQUIRE_SMOKE="${READINESS_REQUIRE_SMOKE:-true}"
READINESS_REQUIRE_BACKUP="${READINESS_REQUIRE_BACKUP:-true}"
READINESS_VERIFY_BACKUP="${READINESS_VERIFY_BACKUP:-true}"
READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS="${READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS:-true}"
READINESS_LATEST_BACKUP_MAX_AGE_SECONDS="${READINESS_LATEST_BACKUP_MAX_AGE_SECONDS:-${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS:-172800}}"
READINESS_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS="${READINESS_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS:-${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS:-300}}"
READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS="${READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS:-${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS:-false}}"
READINESS_RESTORE_DRILL_RECEIPT_FILE="${READINESS_RESTORE_DRILL_RECEIPT_FILE:-${AUDIT_RESTORE_DRILL_RECEIPT_FILE:-/var/lib/imserver/restore-drill/latest.json}}"
READINESS_RESTORE_DRILL_MAX_AGE_SECONDS="${READINESS_RESTORE_DRILL_MAX_AGE_SECONDS:-${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS:-3888000}}"
READINESS_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS="${READINESS_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS:-${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS:-300}}"
READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS="${READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS:-${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS:-false}}"
READINESS_OFFSITE_BACKUP_RECEIPT_FILE="${READINESS_OFFSITE_BACKUP_RECEIPT_FILE:-${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE:-/var/lib/imserver/offsite-backup/latest.json}}"
READINESS_OFFSITE_BACKUP_MAX_AGE_SECONDS="${READINESS_OFFSITE_BACKUP_MAX_AGE_SECONDS:-${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS:-172800}}"
READINESS_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS="${READINESS_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS:-${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS:-300}}"
READINESS_RUN_RESTORE_DRILL="${READINESS_RUN_RESTORE_DRILL:-false}"
READINESS_COLLECT_DIAGNOSTICS="${READINESS_COLLECT_DIAGNOSTICS:-false}"
READINESS_REQUIRE_AUDIT_TIMER="${READINESS_REQUIRE_AUDIT_TIMER:-true}"
READINESS_REQUIRE_RESTORE_DRILL_TIMER="${READINESS_REQUIRE_RESTORE_DRILL_TIMER:-true}"
READINESS_REQUIRE_TIME_SYNC="${READINESS_REQUIRE_TIME_SYNC:-${AUDIT_REQUIRE_TIME_SYNC:-true}}"
READINESS_REQUIRE_PERFORMANCE_GATE="${READINESS_REQUIRE_PERFORMANCE_GATE:-}"
READINESS_REQUIRE_TOPOLOGY_SMOKE="${READINESS_REQUIRE_TOPOLOGY_SMOKE:-}"
READINESS_TOPOLOGY_SMOKE_JSON="${READINESS_TOPOLOGY_SMOKE_JSON:-/var/lib/imserver/production-smoke/latest-production-smoke.json}"
READINESS_TOPOLOGY_SMOKE_MAX_AGE_SECONDS="${READINESS_TOPOLOGY_SMOKE_MAX_AGE_SECONDS:-86400}"
READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS="${READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS:-true}"
READINESS_REQUIRE_ALERT_WEBHOOK="${READINESS_REQUIRE_ALERT_WEBHOOK:-false}"
READINESS_REQUIRE_CLOUD_SECURITY_GROUP="${READINESS_REQUIRE_CLOUD_SECURITY_GROUP:-}"
READINESS_CLOUD_SECURITY_GROUP_RULES_FILE="${READINESS_CLOUD_SECURITY_GROUP_RULES_FILE:-${IMSERVER_ETC_DIR}/cloud-security-group.json}"
READINESS_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
READINESS_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${READINESS_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
READINESS_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
READINESS_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${READINESS_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}"
READINESS_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${READINESS_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-}"
READINESS_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${READINESS_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-}"
READINESS_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${READINESS_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}"
READINESS_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${READINESS_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}"
READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}"
READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}"
READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}"
READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}"
READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT:-}"
READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json}"
READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-86400}"
READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${ALIYUN_SECURITY_GROUP_ID:-}}"
READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${ALIYUN_REGION_ID:-}}"
READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}}"
READINESS_REQUIRE_NGINX_CONFIG="${READINESS_REQUIRE_NGINX_CONFIG:-true}"
READINESS_NGINX_HTTP_CONF_PATH="${READINESS_NGINX_HTTP_CONF_PATH:-/etc/nginx/conf.d/imserver.conf}"
READINESS_NGINX_LOCATIONS_CONF_PATH="${READINESS_NGINX_LOCATIONS_CONF_PATH:-/etc/nginx/snippets/imserver_locations.conf}"
READINESS_NGINX_SSL_CONF_PATH="${READINESS_NGINX_SSL_CONF_PATH:-/etc/nginx/conf.d/imserver_ssl.conf}"
READINESS_NGINX_REQUIRE_SSL="${READINESS_NGINX_REQUIRE_SSL:-false}"
READINESS_DEFAULTS_SELF_TEST="${READINESS_DEFAULTS_SELF_TEST:-false}"
READINESS_AUDIT_ENV_SELF_TEST="${READINESS_AUDIT_ENV_SELF_TEST:-false}"
READINESS_PUBLIC_TARGET_SELF_TEST="${READINESS_PUBLIC_TARGET_SELF_TEST:-false}"
READINESS_PERFORMANCE_EVIDENCE_SUMMARY_SELF_TEST="${READINESS_PERFORMANCE_EVIDENCE_SUMMARY_SELF_TEST:-false}"
READINESS_TOPOLOGY_SMOKE_SELF_TEST="${READINESS_TOPOLOGY_SMOKE_SELF_TEST:-false}"
READINESS_RECEIPT_SELF_TEST="${READINESS_RECEIPT_SELF_TEST:-false}"
READINESS_WRITE_RECEIPT="${READINESS_WRITE_RECEIPT:-true}"
READINESS_RECEIPT_JSON="${READINESS_RECEIPT_JSON:-/var/lib/imserver/readiness/latest.json}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/imserver}"
PERF_PRODUCTION_GATE_JSON="${PERF_PRODUCTION_GATE_JSON:-/var/lib/imserver/performance/production-gate.json}"
PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE:-normal-product-baseline}"
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS:-604800}"
PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT:-false}"
PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT:-false}"
PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-86400}"
PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-300}"
PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG:-${SCRIPT_DIR}/../../IMServer/LoadTests/perf_production_profiles.json}"
PERF_PRODUCTION_EVIDENCE_CURRENT_LINK="${PERF_PRODUCTION_EVIDENCE_CURRENT_LINK:-/var/lib/imserver/performance/current-evidence}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS:-}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS:-}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS:-}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP:-}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE:-}"
PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}"
PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE:-}"
HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL:-${PUBLIC_BASE_URL}}"
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT:-}"

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

readiness_env_value() {
  local key="$1"
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local value="${!key:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  read_env_file_value "${env_file}" "${key}"
}

readiness_app_env() {
  if [[ -n "${READINESS_APP_ENV:-}" ]]; then
    printf '%s\n' "${READINESS_APP_ENV}"
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

resolve_readiness_public_base_url() {
  if [[ -n "${PUBLIC_BASE_URL}" ]]; then
    printf '%s\n' "${PUBLIC_BASE_URL}"
    return 0
  fi
  local value
  value="$(readiness_env_value "PUBLIC_BASE_URL")"
  if [[ -z "${value}" ]]; then
    value="$(readiness_env_value "IM_PUBLIC_BASE_URL")"
  fi
  printf '%s\n' "${value}"
}

resolve_readiness_expect_base_url() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}"
    return 0
  fi
  resolve_readiness_public_base_url
}

readiness_host_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
}

readiness_scheme_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).scheme or "")
PY
}

readiness_port_from_url() {
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

readiness_public_host_policy_reason() {
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

resolve_readiness_expect_tcp_host() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}"
    return 0
  fi
  local value
  value="$(readiness_env_value "TCP_HOST")"
  if [[ -z "${value}" ]]; then
    value="$(readiness_env_value "IM_PUBLIC_HOST")"
  fi
  if [[ -z "${value}" ]]; then
    value="$(readiness_host_from_url "$(resolve_readiness_public_base_url)")"
  fi
  printf '%s\n' "${value}"
}

resolve_readiness_expect_tcp_port() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}"
    return 0
  fi
  local value
  value="$(readiness_env_value "TCP_PORT")"
  if [[ -z "${value}" ]]; then
    value="$(readiness_env_value "IM_TCP_PORT")"
  fi
  printf '%s\n' "${value:-9000}"
}

default_performance_gate_requirement() {
  local app_env
  app_env="$(readiness_app_env)"
  case "${app_env}" in
    production) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

resolve_performance_gate_requirement() {
  if [[ -n "${READINESS_REQUIRE_PERFORMANCE_GATE}" ]]; then
    printf '%s\n' "${READINESS_REQUIRE_PERFORMANCE_GATE}"
  else
    default_performance_gate_requirement
  fi
}

resolve_profile_evidence_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_product_plan_evidence_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_product_campaign_evidence_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_product_scenario_suite_evidence_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_current_readiness_evidence_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS:-}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS}"
  else
    printf 'false\n'
  fi
}

resolve_production_acceptance_evidence_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE:-}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE}"
  else
    printf 'false\n'
  fi
}

resolve_restore_drill_freshness_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  else
    printf '%s\n' "${READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS}"
  fi
}

resolve_offsite_backup_freshness_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  else
    printf '%s\n' "${READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS}"
  fi
}

resolve_topology_smoke_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${READINESS_REQUIRE_TOPOLOGY_SMOKE}" ]]; then
    printf '%s\n' "${READINESS_REQUIRE_TOPOLOGY_SMOKE}"
  else
    printf 'false\n'
  fi
}

resolve_alert_webhook_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  else
    printf '%s\n' "${READINESS_REQUIRE_ALERT_WEBHOOK}"
  fi
}

resolve_cloud_security_group_requirement() {
  if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE:-$(resolve_performance_gate_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${READINESS_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${READINESS_REQUIRE_CLOUD_SECURITY_GROUP}"
  else
    printf 'false\n'
  fi
}

resolve_cloud_security_group_evidence_requirement() {
  if bool_enabled "${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE:-$(resolve_cloud_security_group_requirement)}"; then
    printf 'true\n'
  elif [[ -n "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}"
  else
    printf 'false\n'
  fi
}

resolve_cloud_security_group_repair_receipt_requirement() {
  if [[ -n "${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}" ]]; then
    printf '%s\n' "${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}"
  elif bool_enabled "${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE:-$(resolve_cloud_security_group_requirement)}"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

run_defaults_self_test() {
  local actual tmpdir env_file
  grep -q 'READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS="${READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS:-true}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=latest_backup_freshness_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_LATEST_BACKUP_MAX_AGE_SECONDS="${READINESS_LATEST_BACKUP_MAX_AGE_SECONDS:-${AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS:-172800}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=latest_backup_max_age_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS="${READINESS_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS:-${AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS:-300}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=latest_backup_max_future_skew_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS="${READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS:-${AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS:-false}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=restore_drill_freshness_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_RESTORE_DRILL_RECEIPT_FILE="${READINESS_RESTORE_DRILL_RECEIPT_FILE:-${AUDIT_RESTORE_DRILL_RECEIPT_FILE:-/var/lib/imserver/restore-drill/latest.json}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=restore_drill_receipt_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_RESTORE_DRILL_MAX_AGE_SECONDS="${READINESS_RESTORE_DRILL_MAX_AGE_SECONDS:-${AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS:-3888000}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=restore_drill_max_age_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS="${READINESS_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS:-${AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS:-300}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=restore_drill_max_future_skew_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS="${READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS:-${AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS:-false}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=offsite_backup_freshness_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_OFFSITE_BACKUP_RECEIPT_FILE="${READINESS_OFFSITE_BACKUP_RECEIPT_FILE:-${AUDIT_OFFSITE_BACKUP_RECEIPT_FILE:-/var/lib/imserver/offsite-backup/latest.json}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=offsite_backup_receipt_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_OFFSITE_BACKUP_MAX_AGE_SECONDS="${READINESS_OFFSITE_BACKUP_MAX_AGE_SECONDS:-${AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS:-172800}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=offsite_backup_max_age_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS="${READINESS_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS:-${AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS:-300}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=offsite_backup_max_future_skew_default_missing\n' >&2
    return 1
  }
  grep -q 'READINESS_REQUIRE_TIME_SYNC="${READINESS_REQUIRE_TIME_SYNC:-${AUDIT_REQUIRE_TIME_SYNC:-true}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-defaults result=fail case=time_sync_default_missing\n' >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= default_performance_gate_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=production expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=development READINESS_REQUIRE_PERFORMANCE_GATE= default_performance_gate_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=development expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false resolve_performance_gate_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=explicit_override expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=false resolve_profile_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=profile_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=false resolve_profile_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=performance_gate_disabled_profile_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS= resolve_product_plan_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=production_product_plan_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS= resolve_product_plan_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=performance_gate_disabled_product_plan_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false resolve_product_plan_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=product_plan_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS= resolve_product_campaign_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=production_product_campaign_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS= resolve_product_campaign_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=performance_gate_disabled_product_campaign_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=false resolve_product_campaign_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=product_campaign_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS= resolve_product_scenario_suite_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=production_product_scenario_suite_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS= resolve_product_scenario_suite_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=performance_gate_disabled_product_scenario_suite_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=false resolve_product_scenario_suite_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=product_scenario_suite_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS= resolve_current_readiness_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=production_current_readiness_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS= resolve_current_readiness_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=performance_gate_disabled_current_readiness_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=false resolve_current_readiness_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=current_readiness_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE= resolve_production_acceptance_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=production_acceptance_default expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE= resolve_production_acceptance_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=performance_gate_disabled_production_acceptance_default expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=false resolve_production_acceptance_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=production_acceptance_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS=false resolve_restore_drill_freshness_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=restore_drill_freshness_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS=false resolve_restore_drill_freshness_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=restore_drill_freshness_respects_false_when_gate_disabled expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS=false resolve_offsite_backup_freshness_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=offsite_backup_freshness_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS=false resolve_offsite_backup_freshness_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=offsite_backup_freshness_respects_false_when_gate_disabled expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= READINESS_REQUIRE_TOPOLOGY_SMOKE=false resolve_topology_smoke_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=topology_smoke_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false READINESS_REQUIRE_TOPOLOGY_SMOKE=false resolve_topology_smoke_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=topology_smoke_respects_false_when_gate_disabled expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= READINESS_REQUIRE_ALERT_WEBHOOK=false resolve_alert_webhook_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=alert_explicit_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false READINESS_REQUIRE_ALERT_WEBHOOK=false resolve_alert_webhook_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=alert_respects_false_when_gate_disabled expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= READINESS_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_cloud_security_group_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=cloud_security_group_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false READINESS_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_cloud_security_group_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=cloud_security_group_respects_false_when_gate_disabled expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= READINESS_REQUIRE_CLOUD_SECURITY_GROUP=false PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_cloud_security_group_evidence_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=cloud_security_group_evidence_false_ignored_when_gate_required expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE=false READINESS_REQUIRE_CLOUD_SECURITY_GROUP=false PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=false resolve_cloud_security_group_evidence_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=cloud_security_group_evidence_respects_false_when_gate_disabled expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= READINESS_REQUIRE_CLOUD_SECURITY_GROUP=false READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=false resolve_cloud_security_group_repair_receipt_requirement)"
  [[ "${actual}" == "false" ]] || {
    printf 'readiness-defaults result=fail case=cloud_security_group_repair_receipt_explicit_false_respected expected=false actual=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(READINESS_APP_ENV=production READINESS_REQUIRE_PERFORMANCE_GATE= READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT= READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=true resolve_cloud_security_group_repair_receipt_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=cloud_security_group_repair_receipt_follows_cloud_sg expected=true actual=%s\n' "${actual}" >&2
    return 1
  }
  tmpdir="$(mktemp -d)"
  env_file="${tmpdir}/common.env"
  {
    printf 'APP_ENV=production\n'
    printf 'IM_PUBLIC_BASE_URL=http://readiness-env-file.test:8080\n'
    printf 'IM_PUBLIC_HOST=tcp.readiness-env-file.test\n'
    printf 'IM_TCP_PORT=9443\n'
  } >"${env_file}"
  actual="$(READINESS_APP_ENV= APP_ENV= ENV_FILE="${env_file}" IMSERVER_RUN_ENV=development default_performance_gate_requirement)"
  [[ "${actual}" == "true" ]] || {
    printf 'readiness-defaults result=fail case=env_file_production expected=true actual=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  actual="$(PUBLIC_BASE_URL= ENV_FILE="${env_file}" resolve_readiness_public_base_url)"
  [[ "${actual}" == "http://readiness-env-file.test:8080" ]] || {
    printf 'readiness-defaults result=fail case=env_file_public_base_url expected=http://readiness-env-file.test:8080 actual=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  actual="$(PUBLIC_BASE_URL= PERF_PRODUCTION_GATE_EXPECT_BASE_URL= ENV_FILE="${env_file}" resolve_readiness_expect_base_url)"
  [[ "${actual}" == "http://readiness-env-file.test:8080" ]] || {
    printf 'readiness-defaults result=fail case=env_file_expect_base_url expected=http://readiness-env-file.test:8080 actual=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  actual="$(PERF_PRODUCTION_GATE_EXPECT_TCP_HOST= TCP_HOST= ENV_FILE="${env_file}" resolve_readiness_expect_tcp_host)"
  [[ "${actual}" == "tcp.readiness-env-file.test" ]] || {
    printf 'readiness-defaults result=fail case=env_file_tcp_host expected=tcp.readiness-env-file.test actual=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  actual="$(PERF_PRODUCTION_GATE_EXPECT_TCP_PORT= TCP_PORT= ENV_FILE="${env_file}" resolve_readiness_expect_tcp_port)"
  [[ "${actual}" == "9443" ]] || {
    printf 'readiness-defaults result=fail case=env_file_tcp_port expected=9443 actual=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  env_file="${tmpdir}/fallback-common.env"
  {
    printf 'APP_ENV=production\n'
    printf 'IM_PUBLIC_BASE_URL=http://fallback-host.test:8080\n'
    printf 'IM_TCP_PORT=9000\n'
  } >"${env_file}"
  actual="$(PERF_PRODUCTION_GATE_EXPECT_TCP_HOST= TCP_HOST= IM_PUBLIC_HOST= PUBLIC_BASE_URL= ENV_FILE="${env_file}" resolve_readiness_expect_tcp_host)"
  rm -rf "${tmpdir}"
  [[ "${actual}" == "fallback-host.test" ]] || {
    printf 'readiness-defaults result=fail case=public_url_tcp_host_fallback expected=fallback-host.test actual=%s\n' "${actual}" >&2
    return 1
  }
  printf 'readiness-defaults result=pass\n'
}

if bool_enabled "${READINESS_DEFAULTS_SELF_TEST}"; then
  run_defaults_self_test
  exit 0
fi

READINESS_APP_ENV_EFFECTIVE="$(readiness_app_env)"
READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE="$(resolve_performance_gate_requirement)"
READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS_EFFECTIVE="$(resolve_restore_drill_freshness_requirement)"
READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS_EFFECTIVE="$(resolve_offsite_backup_freshness_requirement)"
READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_cloud_security_group_requirement)"
READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE="$(resolve_cloud_security_group_repair_receipt_requirement)"
READINESS_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE="$(resolve_topology_smoke_requirement)"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE="$(resolve_profile_evidence_requirement)"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE="$(resolve_product_plan_evidence_requirement)"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE="$(resolve_product_campaign_evidence_requirement)"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE="$(resolve_product_scenario_suite_evidence_requirement)"
PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE="$(resolve_current_readiness_evidence_requirement)"
PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_cloud_security_group_evidence_requirement)"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE="$(resolve_production_acceptance_evidence_requirement)"
READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE="$(resolve_alert_webhook_requirement)"
PUBLIC_BASE_URL_EFFECTIVE="$(resolve_readiness_public_base_url)"
PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="$(resolve_readiness_expect_base_url)"
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="$(resolve_readiness_expect_tcp_host)"
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="$(resolve_readiness_expect_tcp_port)"

validate_readiness_public_targets() {
  local public_base_url_scheme public_base_url_port public_base_url_host public_base_url_host_reason
  local expect_base_url_scheme expect_base_url_port expect_base_url_host expect_base_url_host_reason
  local expect_tcp_host_reason
  if ! bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}"; then
    return 0
  fi
  if [[ -z "${PUBLIC_BASE_URL_EFFECTIVE}" ]]; then
    printf 'readiness result=fail reason=public_base_url_missing appEnv=%s requirePerformanceGate=%s hint=set_PUBLIC_BASE_URL_or_IM_PUBLIC_BASE_URL\n' \
      "${READINESS_APP_ENV_EFFECTIVE}" \
      "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}" >&2
    return 1
  fi
  public_base_url_scheme="$(readiness_scheme_from_url "${PUBLIC_BASE_URL_EFFECTIVE}")"
  if [[ "${public_base_url_scheme}" != "https" ]]; then
    printf 'readiness result=fail reason=public_base_url_https_required publicBaseURL=%s hint=set_PUBLIC_BASE_URL_or_IM_PUBLIC_BASE_URL_to_https_or_disable_gate_for_first_bootstrap\n' \
      "${PUBLIC_BASE_URL_EFFECTIVE}" >&2
    return 1
  fi
  public_base_url_port="$(readiness_port_from_url "${PUBLIC_BASE_URL_EFFECTIVE}")"
  if [[ "${public_base_url_port}" != "443" ]]; then
    printf 'readiness result=fail reason=public_base_url_default_https_port_required publicBaseURL=%s port=%s hint=use_default_https_443_for_long_term_production\n' \
      "${PUBLIC_BASE_URL_EFFECTIVE}" \
      "${public_base_url_port:-<empty>}" >&2
    return 1
  fi
  public_base_url_host="$(readiness_host_from_url "${PUBLIC_BASE_URL_EFFECTIVE}")"
  public_base_url_host_reason="$(readiness_public_host_policy_reason "${public_base_url_host}")"
  if [[ "${public_base_url_host_reason}" != "ok" ]]; then
    printf 'readiness result=fail reason=public_base_url_domain_required publicBaseURL=%s host=%s hostReason=%s hint=use_a_real_production_domain_not_a_raw_ip_or_placeholder\n' \
      "${PUBLIC_BASE_URL_EFFECTIVE}" \
      "${public_base_url_host:-<empty>}" \
      "${public_base_url_host_reason}" >&2
    return 1
  fi
  if [[ -z "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}" ]]; then
    printf 'readiness result=fail reason=performance_gate_expect_base_url_missing hint=set_PERF_PRODUCTION_GATE_EXPECT_BASE_URL_or_PUBLIC_BASE_URL\n' >&2
    return 1
  fi
  expect_base_url_scheme="$(readiness_scheme_from_url "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
  if [[ "${expect_base_url_scheme}" != "https" ]]; then
    printf 'readiness result=fail reason=performance_gate_expect_base_url_https_required expectBaseURL=%s hint=bind_production_performance_evidence_to_https_BASE_URL\n' \
      "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}" >&2
    return 1
  fi
  expect_base_url_port="$(readiness_port_from_url "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
  if [[ "${expect_base_url_port}" != "443" ]]; then
    printf 'readiness result=fail reason=performance_gate_expect_base_url_default_https_port_required expectBaseURL=%s port=%s hint=bind_production_performance_evidence_to_default_https_443\n' \
      "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
      "${expect_base_url_port:-<empty>}" >&2
    return 1
  fi
  expect_base_url_host="$(readiness_host_from_url "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}")"
  expect_base_url_host_reason="$(readiness_public_host_policy_reason "${expect_base_url_host}")"
  if [[ "${expect_base_url_host_reason}" != "ok" ]]; then
    printf 'readiness result=fail reason=performance_gate_expect_base_url_domain_required expectBaseURL=%s host=%s hostReason=%s hint=bind_production_performance_evidence_to_the_real_https_domain\n' \
      "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
      "${expect_base_url_host:-<empty>}" \
      "${expect_base_url_host_reason}" >&2
    return 1
  fi
  if [[ -z "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE}" ]]; then
    printf 'readiness result=fail reason=performance_gate_expect_tcp_host_missing hint=set_PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_or_TCP_HOST_or_IM_PUBLIC_HOST\n' >&2
    return 1
  fi
  expect_tcp_host_reason="$(readiness_public_host_policy_reason "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE}")"
  if [[ "${expect_tcp_host_reason}" != "ok" ]]; then
    printf 'readiness result=fail reason=performance_gate_expect_tcp_host_domain_required tcpHost=%s hostReason=%s hint=use_a_real_production_tcp_domain_not_a_raw_ip_or_placeholder\n' \
      "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
      "${expect_tcp_host_reason}" >&2
    return 1
  fi
  if [[ -z "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE}" ]]; then
    printf 'readiness result=fail reason=performance_gate_expect_tcp_port_missing hint=set_PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_or_TCP_PORT_or_IM_TCP_PORT\n' >&2
    return 1
  fi
}

validate_readiness_hard_gates() {
  if ! bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}"; then
    return 0
  fi
  if ! bool_enabled "${READINESS_REQUIRE_SMOKE}"; then
    printf 'readiness result=fail reason=application_smoke_required_when_performance_gate_required hint=set_READINESS_REQUIRE_PERFORMANCE_GATE=false_for_first_bootstrap\n' >&2
    return 1
  fi
  if ! bool_enabled "${READINESS_REQUIRE_BACKUP}"; then
    printf 'readiness result=fail reason=latest_backup_required_when_performance_gate_required hint=set_READINESS_REQUIRE_PERFORMANCE_GATE=false_for_first_bootstrap\n' >&2
    return 1
  fi
  if ! bool_enabled "${READINESS_VERIFY_BACKUP}"; then
    printf 'readiness result=fail reason=latest_backup_verify_required_when_performance_gate_required hint=set_READINESS_REQUIRE_PERFORMANCE_GATE=false_for_first_bootstrap\n' >&2
    return 1
  fi
  if ! bool_enabled "${READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS}"; then
    printf 'readiness result=fail reason=latest_backup_freshness_required_when_performance_gate_required hint=set_READINESS_REQUIRE_PERFORMANCE_GATE=false_for_first_bootstrap\n' >&2
    return 1
  fi
  if [[ -n "${READINESS_REQUIRE_TOPOLOGY_SMOKE}" ]] && ! bool_enabled "${READINESS_REQUIRE_TOPOLOGY_SMOKE}"; then
    printf 'readiness result=fail reason=topology_smoke_required_when_performance_gate_required hint=set_READINESS_REQUIRE_PERFORMANCE_GATE=false_for_first_bootstrap\n' >&2
    return 1
  fi
}

verify_topology_smoke_receipt() {
  if ! bool_enabled "${READINESS_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE}"; then
    printf 'readiness step=topology-smoke-receipt skipped=true require=false path=%s\n' \
      "${READINESS_TOPOLOGY_SMOKE_JSON}"
    return 0
  fi

  if [[ ! -f "${READINESS_TOPOLOGY_SMOKE_JSON}" ]]; then
    printf 'readiness result=fail reason=topology_smoke_receipt_missing path=%s hint=run_make_run-imserver-production-smoke_and_install_latest-production-smoke.json\n' \
      "${READINESS_TOPOLOGY_SMOKE_JSON}" >&2
    return 1
  fi

  local artifact_args=()
  if bool_enabled "${READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS}"; then
    artifact_args+=(--require-artifacts-exist)
  fi

  python3 "${SCRIPT_DIR}/../../IMServer/scripts/verify_production_smoke.py" \
    --receipt-json "${READINESS_TOPOLOGY_SMOKE_JSON}" \
    --require-pass \
    "${artifact_args[@]}" \
    --max-age-seconds "${READINESS_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}"
}

run_topology_smoke_self_test() {
  local tmpdir receipt artifact output
  tmpdir="$(mktemp -d)"
  receipt="${tmpdir}/latest-production-smoke.json"
  for artifact in markdownReport stateFile composePs composeLog outboxInspect; do
    printf 'ok\n' >"${tmpdir}/${artifact}.txt"
  done
  python3 - "${receipt}" "${tmpdir}" <<'PY'
import json
import sys
import time
from pathlib import Path

receipt = Path(sys.argv[1])
tmp = Path(sys.argv[2])
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
    "artifacts": {
        "markdownReport": str(tmp / "markdownReport.txt"),
        "stateFile": str(tmp / "stateFile.txt"),
        "composePs": str(tmp / "composePs.txt"),
        "composeLog": str(tmp / "composeLog.txt"),
        "outboxInspect": str(tmp / "outboxInspect.txt"),
    },
    "checks": [{"name": name, "status": "passed"} for name in checks],
}
receipt.write_text(json.dumps(payload), encoding="utf-8")
PY

  READINESS_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE=true
  READINESS_TOPOLOGY_SMOKE_JSON="${receipt}"
  READINESS_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=60
  READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS=true
  if ! output="$(verify_topology_smoke_receipt 2>&1)"; then
    printf 'readiness-topology-smoke result=fail reason=valid_receipt_rejected output=%s\n' "${output}" >&2
    rm -rf "${tmpdir}"
    return 1
  fi
  grep -q 'production_smoke_verify result=pass' <<<"${output}" || {
    printf 'readiness-topology-smoke result=fail reason=valid_receipt_pass_output_missing output=%s\n' "${output}" >&2
    rm -rf "${tmpdir}"
    return 1
  }

  READINESS_TOPOLOGY_SMOKE_JSON="${tmpdir}/missing.json"
  if output="$(verify_topology_smoke_receipt 2>&1)"; then
    printf 'readiness-topology-smoke result=fail reason=missing_receipt_accepted\n' >&2
    rm -rf "${tmpdir}"
    return 1
  fi
  grep -q 'topology_smoke_receipt_missing' <<<"${output}" || {
    printf 'readiness-topology-smoke result=fail reason=missing_receipt_reason_absent output=%s\n' "${output}" >&2
    rm -rf "${tmpdir}"
    return 1
  }

  READINESS_TOPOLOGY_SMOKE_JSON="${receipt}"
  python3 - "${receipt}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["generatedAt"] = "2000-01-01T00:00:00Z"
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if output="$(verify_topology_smoke_receipt 2>&1)"; then
    printf 'readiness-topology-smoke result=fail reason=stale_receipt_accepted\n' >&2
    rm -rf "${tmpdir}"
    return 1
  fi
  grep -q 'receipt_stale' <<<"${output}" || {
    printf 'readiness-topology-smoke result=fail reason=stale_receipt_reason_absent output=%s\n' "${output}" >&2
    rm -rf "${tmpdir}"
    return 1
  }

  READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE=true
  READINESS_REQUIRE_SMOKE=true
  READINESS_REQUIRE_BACKUP=true
  READINESS_VERIFY_BACKUP=true
  READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS=true
  READINESS_REQUIRE_TOPOLOGY_SMOKE=false
  if output="$(validate_readiness_hard_gates 2>&1)"; then
    printf 'readiness-topology-smoke result=fail reason=topology_smoke_skip_accepted_when_performance_gate_required\n' >&2
    rm -rf "${tmpdir}"
    return 1
  fi
  grep -q 'topology_smoke_required_when_performance_gate_required' <<<"${output}" || {
    printf 'readiness-topology-smoke result=fail reason=topology_smoke_skip_reason_absent output=%s\n' "${output}" >&2
    rm -rf "${tmpdir}"
    return 1
  }

  rm -rf "${tmpdir}"
  printf 'readiness-topology-smoke result=pass\n'
}

run_public_target_self_test() {
  local output

  READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE=true
  READINESS_APP_ENV_EFFECTIVE=production
  PUBLIC_BASE_URL_EFFECTIVE=""
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE=""
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE=""
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  if output="$(validate_readiness_public_targets 2>&1)"; then
    printf 'readiness-public-target result=fail reason=missing_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_missing' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=missing_public_target_reason_absent output=%s\n' "${output}" >&2
    return 1
  }

  READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE=true
  READINESS_APP_ENV_EFFECTIVE=production
  PUBLIC_BASE_URL_EFFECTIVE="http://chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="http://chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  if output="$(validate_readiness_public_targets 2>&1)"; then
    printf 'readiness-public-target result=fail reason=http_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_https_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=http_public_target_reason_absent output=%s\n' "${output}" >&2
    return 1
  }

  PUBLIC_BASE_URL_EFFECTIVE="https://203.0.113.10"
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="https://203.0.113.10"
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  if output="$(validate_readiness_public_targets 2>&1)"; then
    printf 'readiness-public-target result=fail reason=ip_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_domain_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=ip_public_target_reason_absent output=%s\n' "${output}" >&2
    return 1
  }

  PUBLIC_BASE_URL_EFFECTIVE="https://public.example.test"
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="https://public.example.test"
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="public.example.test"
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  if output="$(validate_readiness_public_targets 2>&1)"; then
    printf 'readiness-public-target result=fail reason=placeholder_public_target_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_domain_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=placeholder_public_target_reason_absent output=%s\n' "${output}" >&2
    return 1
  }

  PUBLIC_BASE_URL_EFFECTIVE="https://chat.myim-prod.com:8443"
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="https://chat.myim-prod.com:8443"
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  if output="$(validate_readiness_public_targets 2>&1)"; then
    printf 'readiness-public-target result=fail reason=non_default_https_port_accepted\n' >&2
    return 1
  fi
  grep -q 'public_base_url_default_https_port_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=non_default_public_port_reason_absent output=%s\n' "${output}" >&2
    return 1
  }

  PUBLIC_BASE_URL_EFFECTIVE="https://chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="https://chat.myim-prod.com:8443"
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  if output="$(validate_readiness_public_targets 2>&1)"; then
    printf 'readiness-public-target result=fail reason=non_default_expect_https_port_accepted\n' >&2
    return 1
  fi
  grep -q 'performance_gate_expect_base_url_default_https_port_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=non_default_expect_port_reason_absent output=%s\n' "${output}" >&2
    return 1
  }

  PUBLIC_BASE_URL_EFFECTIVE="https://chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="https://chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="203.0.113.10"
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  if output="$(validate_readiness_public_targets 2>&1)"; then
    printf 'readiness-public-target result=fail reason=ip_tcp_target_accepted\n' >&2
    return 1
  fi
  grep -q 'performance_gate_expect_tcp_host_domain_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=ip_tcp_target_reason_absent output=%s\n' "${output}" >&2
    return 1
  }

  PUBLIC_BASE_URL_EFFECTIVE="https://chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="https://chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="chat.myim-prod.com"
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="9000"
  validate_readiness_public_targets || {
    printf 'readiness-public-target result=fail reason=valid_public_target_rejected\n' >&2
    return 1
  }
  READINESS_REQUIRE_SMOKE=false
  READINESS_REQUIRE_BACKUP=true
  READINESS_VERIFY_BACKUP=true
  if output="$(validate_readiness_hard_gates 2>&1)"; then
    printf 'readiness-public-target result=fail reason=smoke_skip_accepted_when_performance_gate_required\n' >&2
    return 1
  fi
  grep -q 'application_smoke_required_when_performance_gate_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=smoke_skip_reason_absent output=%s\n' "${output}" >&2
    return 1
  }
  READINESS_REQUIRE_SMOKE=true
  READINESS_REQUIRE_BACKUP=false
  READINESS_VERIFY_BACKUP=true
  if output="$(validate_readiness_hard_gates 2>&1)"; then
    printf 'readiness-public-target result=fail reason=backup_skip_accepted_when_performance_gate_required\n' >&2
    return 1
  fi
  grep -q 'latest_backup_required_when_performance_gate_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=backup_skip_reason_absent output=%s\n' "${output}" >&2
    return 1
  }
  READINESS_REQUIRE_SMOKE=true
  READINESS_REQUIRE_BACKUP=true
  READINESS_VERIFY_BACKUP=false
  READINESS_REQUIRE_ALERT_WEBHOOK=true
  if output="$(validate_readiness_hard_gates 2>&1)"; then
    printf 'readiness-public-target result=fail reason=backup_verify_skip_accepted_when_performance_gate_required\n' >&2
    return 1
  fi
  grep -q 'latest_backup_verify_required_when_performance_gate_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=backup_verify_skip_reason_absent output=%s\n' "${output}" >&2
    return 1
  }
  READINESS_REQUIRE_SMOKE=true
  READINESS_REQUIRE_BACKUP=true
  READINESS_VERIFY_BACKUP=true
  READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS=false
  if output="$(validate_readiness_hard_gates 2>&1)"; then
    printf 'readiness-public-target result=fail reason=backup_freshness_skip_accepted_when_performance_gate_required\n' >&2
    return 1
  fi
  grep -q 'latest_backup_freshness_required_when_performance_gate_required' <<<"${output}" || {
    printf 'readiness-public-target result=fail reason=backup_freshness_skip_reason_absent output=%s\n' "${output}" >&2
    return 1
  }
  READINESS_REQUIRE_SMOKE=true
  READINESS_REQUIRE_BACKUP=true
  READINESS_VERIFY_BACKUP=true
  READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS=true
  READINESS_REQUIRE_ALERT_WEBHOOK=false
  READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE="$(resolve_alert_webhook_requirement)"
  [[ "${READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE}" == "true" ]] || {
    printf 'readiness-public-target result=fail reason=alert_effective_not_forced_when_performance_gate_required actual=%s\n' "${READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE}" >&2
    return 1
  }
  READINESS_REQUIRE_ALERT_WEBHOOK=true
  validate_readiness_hard_gates || {
    printf 'readiness-public-target result=fail reason=valid_hard_gates_rejected\n' >&2
    return 1
  }
  grep -q 'PUBLIC_BASE_URL="${PUBLIC_BASE_URL_EFFECTIVE}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-public-target result=fail reason=application_smoke_public_base_url_missing\n' >&2
    return 1
  }
  grep -q 'BASE_URL="${PUBLIC_BASE_URL_EFFECTIVE:-http://127.0.0.1:${HTTP_PORT}}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-public-target result=fail reason=application_smoke_base_url_missing\n' >&2
    return 1
  }

  printf 'readiness-public-target result=pass\n'
}

if bool_enabled "${READINESS_PUBLIC_TARGET_SELF_TEST}"; then
  run_public_target_self_test
  exit 0
fi

if bool_enabled "${READINESS_TOPOLOGY_SMOKE_SELF_TEST}"; then
  run_topology_smoke_self_test
  exit 0
fi

validate_readiness_public_targets
validate_readiness_hard_gates

run_operational_audit_command() {
  env \
    BACKUP_ROOT="${BACKUP_ROOT}" \
    AUDIT_REQUIRE_BACKUP="${READINESS_REQUIRE_BACKUP}" \
    AUDIT_VERIFY_LATEST_BACKUP="${READINESS_VERIFY_BACKUP}" \
    AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS="${READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS}" \
    AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS="${READINESS_LATEST_BACKUP_MAX_AGE_SECONDS}" \
    AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS="${READINESS_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS}" \
    AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS="${READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS_EFFECTIVE}" \
    AUDIT_RESTORE_DRILL_RECEIPT_FILE="${READINESS_RESTORE_DRILL_RECEIPT_FILE}" \
    AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS="${READINESS_RESTORE_DRILL_MAX_AGE_SECONDS}" \
    AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS="${READINESS_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS}" \
    AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS="${READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS_EFFECTIVE}" \
    AUDIT_OFFSITE_BACKUP_RECEIPT_FILE="${READINESS_OFFSITE_BACKUP_RECEIPT_FILE}" \
    AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS="${READINESS_OFFSITE_BACKUP_MAX_AGE_SECONDS}" \
    AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS="${READINESS_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS}" \
    AUDIT_REQUIRE_AUDIT_TIMER="${READINESS_REQUIRE_AUDIT_TIMER}" \
    AUDIT_REQUIRE_RESTORE_DRILL_TIMER="${READINESS_REQUIRE_RESTORE_DRILL_TIMER}" \
    AUDIT_REQUIRE_TIME_SYNC="${READINESS_REQUIRE_TIME_SYNC}" \
    AUDIT_REQUIRE_ALERT_WEBHOOK="${READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE}" \
    AUDIT_REQUIRE_ALERT_LOG_REDACTION="${READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE}" \
    AUDIT_REQUIRE_PERFORMANCE_GATE="${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}" \
    AUDIT_REQUIRE_CLOUD_SECURITY_GROUP="${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
    AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE="${READINESS_CLOUD_SECURITY_GROUP_RULES_FILE}" \
    AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${READINESS_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
    AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
    AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${READINESS_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
    AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${READINESS_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${READINESS_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
    AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${READINESS_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
    AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${READINESS_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
    AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
    AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
    AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
    AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
    AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}" \
    AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
    AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    AUDIT_REQUIRE_NGINX_CONFIG="${READINESS_REQUIRE_NGINX_CONFIG}" \
    AUDIT_NGINX_HTTP_CONF_PATH="${READINESS_NGINX_HTTP_CONF_PATH}" \
    AUDIT_NGINX_LOCATIONS_CONF_PATH="${READINESS_NGINX_LOCATIONS_CONF_PATH}" \
    AUDIT_NGINX_SSL_CONF_PATH="${READINESS_NGINX_SSL_CONF_PATH}" \
    AUDIT_NGINX_REQUIRE_SSL="${READINESS_NGINX_REQUIRE_SSL}" \
    AUDIT_PERFORMANCE_GATE_JSON="${PERF_PRODUCTION_GATE_JSON}" \
    AUDIT_PERFORMANCE_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
    AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT}" \
    AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT}" \
    AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
    AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
    AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE}" \
    AUDIT_PERFORMANCE_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG}" \
    AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK="${PERF_PRODUCTION_EVIDENCE_CURRENT_LINK}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
    AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}" \
    AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" \
    AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}" \
    AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON= \
    AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE= \
    HTTP_PORT="${HTTP_PORT}" \
    "$@"
}

run_audit_env_self_test() {
  local output
  READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE=true
  PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=/tmp/production-acceptance.json
  PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE=/tmp/production-evidence.tar.gz
  PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS=86400
  PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS=300
  READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE=true
  READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true
  BACKUP_ROOT=/tmp/readiness-backups
  READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS=true
  READINESS_LATEST_BACKUP_MAX_AGE_SECONDS=172800
  READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS=true
  READINESS_RESTORE_DRILL_RECEIPT_FILE=/tmp/readiness-restore-drill/latest.json
  READINESS_RESTORE_DRILL_MAX_AGE_SECONDS=3888000
  READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS=true
  READINESS_OFFSITE_BACKUP_RECEIPT_FILE=/tmp/readiness-offsite-backup/latest.json
  READINESS_OFFSITE_BACKUP_MAX_AGE_SECONDS=172800
  READINESS_CLOUD_SECURITY_GROUP_RULES_FILE=/tmp/readiness-cloud-security-group.json
  READINESS_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="80 443 9000"
  READINESS_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="3389 5432 6379 9092 8081 8082 18080 8080"
  READINESS_CLOUD_SECURITY_GROUP_ADMIN_PORTS="22"
  READINESS_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=true
  READINESS_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400
  READINESS_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=true
  READINESS_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false
  READINESS_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP=true
  READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX=8
  READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX=16
  READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE=true
  READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=/tmp/readiness-cloud-security-group-repair-receipt.json
  READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400
  READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-readiness
  READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen
  READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32
  READINESS_REQUIRE_NGINX_CONFIG=true
  READINESS_NGINX_HTTP_CONF_PATH=/tmp/readiness-nginx-http.conf
  READINESS_NGINX_LOCATIONS_CONF_PATH=/tmp/readiness-nginx-locations.conf
  READINESS_NGINX_SSL_CONF_PATH=/tmp/readiness-nginx-ssl.conf
  READINESS_NGINX_REQUIRE_SSL=true
  PERF_PRODUCTION_GATE_JSON=/tmp/readiness-gate.json
  PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline
  PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT=true
  PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=true
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE=https://chat.myim-prod.com
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE=tcp.myim-prod.com
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE=9000
  PERF_PRODUCTION_EVIDENCE_CURRENT_LINK=/tmp/current-evidence
  output="$(run_operational_audit_command env)"
  grep -q '^AUDIT_REQUIRE_PERFORMANCE_GATE=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_performance_gate\n' >&2
    return 1
  }
  grep -Fq "BACKUP_ROOT=${BACKUP_ROOT}" <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=backup_root_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_BACKUP=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_backup_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_VERIFY_LATEST_BACKUP=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=verify_latest_backup_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=latest_backup_freshness_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS=172800$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=latest_backup_max_age_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS=300$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=latest_backup_max_future_skew_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=restore_drill_freshness_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_RESTORE_DRILL_RECEIPT_FILE=/tmp/readiness-restore-drill/latest.json$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=restore_drill_receipt_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS=3888000$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=restore_drill_max_age_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS=300$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=restore_drill_max_future_skew_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=offsite_backup_freshness_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_OFFSITE_BACKUP_RECEIPT_FILE=/tmp/readiness-offsite-backup/latest.json$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=offsite_backup_receipt_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS=172800$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=offsite_backup_max_age_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS=300$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=offsite_backup_max_future_skew_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_AUDIT_TIMER=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_audit_timer_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_RESTORE_DRILL_TIMER=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_restore_drill_timer_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_TIME_SYNC=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_time_sync_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_ALERT_WEBHOOK=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_alert_webhook_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_ALERT_LOG_REDACTION=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_alert_log_redaction_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_cloud_security_group_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE=/tmp/readiness-cloud-security-group.json$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_rules_file_mapping\n' >&2
    return 1
  }
  grep -Fq 'AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS=80 443 9000' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_public_client_ports_mapping\n' >&2
    return 1
  }
  grep -Fq 'AUDIT_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS=3389 5432 6379 9092 8081 8082 18080 8080' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_deny_public_ports_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PORTS=22$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_admin_ports_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_require_public_client_ports_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_rules_max_age_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_rules_require_root_owner_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_temp_http_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_icmp_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX=8$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_public_broad_ipv4_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX=16$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_public_broad_ipv6_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX=32$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_admin_public_ipv4_min_prefix_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX=128$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_admin_public_ipv6_min_prefix_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_repair_receipt_required_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=/tmp/readiness-cloud-security-group-repair-receipt.json$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_repair_receipt_json_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_repair_receipt_max_age_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-readiness$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_repair_receipt_expect_sg_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_repair_receipt_expect_region_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=cloud_security_group_repair_receipt_expect_admin_cidr_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_REQUIRE_NGINX_CONFIG=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_nginx_config_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_NGINX_HTTP_CONF_PATH=/tmp/readiness-nginx-http.conf$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=nginx_http_conf_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_NGINX_LOCATIONS_CONF_PATH=/tmp/readiness-nginx-locations.conf$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=nginx_locations_conf_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_NGINX_SSL_CONF_PATH=/tmp/readiness-nginx-ssl.conf$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=nginx_ssl_conf_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_NGINX_REQUIRE_SSL=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=nginx_require_ssl_mapping\n' >&2
    return 1
  }
  grep -Fq "AUDIT_PERFORMANCE_GATE_PROFILE=${PERF_PRODUCTION_GATE_PROFILE}" <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=profile_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_GATE_JSON=/tmp/readiness-gate.json$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=gate_json_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK=/tmp/current-evidence$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_current_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_profile_artifacts_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_product_plan_artifacts_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_product_campaign_artifacts_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_product_scenario_suite_artifacts_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_product_scenario_suite_no_large_group_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_current_readiness_artifacts_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_validation_inventory_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_cloud_security_group_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=evidence_production_acceptance_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS=86400$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=production_acceptance_max_age_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS=300$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=production_acceptance_max_future_skew_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=production_acceptance_receipt_not_current_evidence_only\n' >&2
    return 1
  }
  grep -q '^AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE=$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=production_acceptance_package_not_current_evidence_only\n' >&2
    return 1
  }
  if grep -q '/tmp/production-acceptance.json' <<<"${output}" || grep -q '/tmp/production-evidence.tar.gz' <<<"${output}"; then
    printf 'readiness-audit-env result=fail reason=temporary_production_acceptance_path_leaked\n' >&2
    return 1
  fi
  grep -q '^AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_current_git_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT=true$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=require_clean_git_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=expected_base_url_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=expected_tcp_host_mapping\n' >&2
    return 1
  }
  grep -q '^AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT=9000$' <<<"${output}" || {
    printf 'readiness-audit-env result=fail reason=expected_tcp_port_mapping\n' >&2
    return 1
  }
  printf 'readiness-audit-env result=pass\n'
}

if bool_enabled "${READINESS_AUDIT_ENV_SELF_TEST}"; then
  run_audit_env_self_test
  exit 0
fi

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

is_unsigned_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_positive_int() {
  is_unsigned_int "${1:-}" || return 1
  [[ "${1}" -gt 0 ]]
}

validate_readiness_campaign_target_value() {
  local value="$1"
  local base_url tcp_host tcp_port base_scheme base_host base_reason tcp_reason

  IFS=, read -r base_url tcp_host tcp_port <<<"${value}"
  if [[ -z "${base_url:-}" || -z "${tcp_host:-}" || -z "${tcp_port:-}" ]]; then
    return 1
  fi
  base_scheme="$(readiness_scheme_from_url "${base_url}")"
  if [[ "${base_scheme}" != "https" ]]; then
    return 1
  fi
  base_host="$(readiness_host_from_url "${base_url}")"
  base_reason="$(readiness_public_host_policy_reason "${base_host}")"
  if [[ "${base_reason}" != "ok" ]]; then
    return 1
  fi
  tcp_reason="$(readiness_public_host_policy_reason "${tcp_host}")"
  if [[ "${tcp_reason}" != "ok" ]]; then
    return 1
  fi
  is_positive_int "${tcp_port}" || return 1
}

validate_readiness_performance_evidence_summary() {
  local output="$1"
  local missing=()
  local invalid=()
  local value

  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "manifestRequireCloudSecurityGroup")"; then
      [[ "${value}" == "true" ]] || invalid+=("manifestRequireCloudSecurityGroup=${value:-<empty>}")
    else
      missing+=("manifestRequireCloudSecurityGroup")
    fi
  fi

  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "requireProductionAcceptance")"; then
      [[ "${value}" == "true" ]] || invalid+=("requireProductionAcceptance=${value:-<empty>}")
    else
      missing+=("requireProductionAcceptance")
    fi
    if value="$(summary_field_value "${output}" "productionAcceptanceReceipt")"; then
      [[ -n "${value}" && "${value}" != "<unset>" && "${value}" != "-" ]] || invalid+=("productionAcceptanceReceipt=${value:-<empty>}")
    else
      missing+=("productionAcceptanceReceipt")
    fi
    if value="$(summary_field_value "${output}" "productionAcceptancePackage")"; then
      [[ -n "${value}" && "${value}" != "<unset>" && "${value}" != "-" ]] || invalid+=("productionAcceptancePackage=${value:-<empty>}")
    else
      missing+=("productionAcceptancePackage")
    fi
  fi

  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "manifestRequireProfileArtifacts")"; then
      [[ "${value}" == "true" ]] || invalid+=("manifestRequireProfileArtifacts=${value:-<empty>}")
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
    summary_field_value "${output}" "profileRunBlockerType" >/dev/null || missing+=("profileRunBlockerType")
    if value="$(summary_field_value "${output}" "profileEntrypointDiagnosis")"; then
      if [[ -z "${value}" || "${value}" == "-" ]]; then
        invalid+=("profileEntrypointDiagnosis=${value:-<empty>}")
      fi
    else
      missing+=("profileEntrypointDiagnosis")
    fi
    if value="$(summary_field_value "${output}" "profileEntrypointBlocker")"; then
      case "${value}" in
        *,*,false,*|*,*,-,*) ;;
        *,*,true,*) invalid+=("profileEntrypointBlocker=${value}") ;;
        *) invalid+=("profileEntrypointBlocker=${value:-<empty>}") ;;
      esac
    else
      missing+=("profileEntrypointBlocker")
    fi
  fi

  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "productProfileGate")"; then
      [[ "${value}" == "PASS" ]] || invalid+=("productProfileGate=${value:-<empty>}")
    else
      missing+=("productProfileGate")
    fi
    if value="$(summary_field_value "${output}" "productProfileGateChecked")"; then
      is_positive_int "${value}" || invalid+=("productProfileGateChecked=${value:-<empty>}")
    else
      missing+=("productProfileGateChecked")
    fi
    if value="$(summary_field_value "${output}" "productProfileGateRequiredDomains")"; then
      is_positive_int "${value}" || invalid+=("productProfileGateRequiredDomains=${value:-<empty>}")
    else
      missing+=("productProfileGateRequiredDomains")
    fi
    if value="$(summary_field_value "${output}" "manifestRequireProductPlanArtifacts")"; then
      [[ "${value}" == "true" ]] || invalid+=("manifestRequireProductPlanArtifacts=${value:-<empty>}")
    else
      missing+=("manifestRequireProductPlanArtifacts")
    fi
    if value="$(summary_field_value "${output}" "productPlanStatus")"; then
      [[ "${value}" == "PASS" ]] || invalid+=("productPlanStatus=${value:-<empty>}")
    else
      missing+=("productPlanStatus")
    fi
    if value="$(summary_field_value "${output}" "productPlanBlockerType")"; then
      [[ "${value}" == "-" || -z "${value}" ]] || invalid+=("productPlanBlockerType=${value:-<empty>}")
    else
      missing+=("productPlanBlockerType")
    fi
    if value="$(summary_field_value "${output}" "productPlanScenarioCount")"; then
      is_positive_int "${value}" || invalid+=("productPlanScenarioCount=${value:-<empty>}")
    else
      missing+=("productPlanScenarioCount")
    fi
    if value="$(summary_field_value "${output}" "productPlanLargeGroupIncluded")"; then
      [[ "${value}" == "false" ]] || invalid+=("productPlanLargeGroupIncluded=${value:-<empty>}")
    else
      missing+=("productPlanLargeGroupIncluded")
    fi
    if value="$(summary_field_value "${output}" "productPlanDomainCount")"; then
      is_positive_int "${value}" || invalid+=("productPlanDomainCount=${value:-<empty>}")
    else
      missing+=("productPlanDomainCount")
    fi
    if value="$(summary_field_value "${output}" "productPlanRequiredDomainsCovered")"; then
      [[ "${value}" == "true" ]] || invalid+=("productPlanRequiredDomainsCovered=${value:-<empty>}")
    else
      missing+=("productPlanRequiredDomainsCovered")
    fi
  fi

  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "manifestRequireProductCampaignArtifacts")"; then
      [[ "${value}" == "true" ]] || invalid+=("manifestRequireProductCampaignArtifacts=${value:-<empty>}")
    else
      missing+=("manifestRequireProductCampaignArtifacts")
    fi
    if value="$(summary_field_value "${output}" "productCampaign")"; then
      [[ -n "${value}" && "${value}" != "-" ]] || invalid+=("productCampaign=${value:-<empty>}")
    else
      missing+=("productCampaign")
    fi
    if value="$(summary_field_value "${output}" "productCampaignStatus")"; then
      [[ "${value}" == "PASS" ]] || invalid+=("productCampaignStatus=${value:-<empty>}")
    else
      missing+=("productCampaignStatus")
    fi
    if value="$(summary_field_value "${output}" "productCampaignTarget")"; then
      case "${value}" in
        -,-,-|'') invalid+=("productCampaignTarget=${value:-<empty>}") ;;
        *,*,*)
          validate_readiness_campaign_target_value "${value}" || invalid+=("productCampaignTarget=${value}") ;;
        *) invalid+=("productCampaignTarget=${value}") ;;
      esac
    else
      missing+=("productCampaignTarget")
    fi
    if value="$(summary_field_value "${output}" "productCampaignFailures")"; then
      [[ "${value}" == "0" ]] || invalid+=("productCampaignFailures=${value:-<empty>}")
    else
      missing+=("productCampaignFailures")
    fi
    if value="$(summary_field_value "${output}" "productCampaignRequiredFailures")"; then
      [[ "${value}" == "0" ]] || invalid+=("productCampaignRequiredFailures=${value:-<empty>}")
    else
      missing+=("productCampaignRequiredFailures")
    fi
    if value="$(summary_field_value "${output}" "productCampaignAttempted")"; then
      is_positive_int "${value}" || invalid+=("productCampaignAttempted=${value:-<empty>}")
    else
      missing+=("productCampaignAttempted")
    fi
    if value="$(summary_field_value "${output}" "productCampaignSkipped")"; then
      [[ "${value}" == "0" ]] || invalid+=("productCampaignSkipped=${value:-<empty>}")
    else
      missing+=("productCampaignSkipped")
    fi
  fi

  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE}"; then
    if value="$(summary_field_value "${output}" "manifestRequireCurrentReadinessArtifacts")"; then
      [[ "${value}" == "true" ]] || invalid+=("manifestRequireCurrentReadinessArtifacts=${value:-<empty>}")
    else
      missing+=("manifestRequireCurrentReadinessArtifacts")
    fi
    if value="$(summary_field_value "${output}" "currentReadinessStatus")"; then
      [[ "${value}" == "PASS" ]] || invalid+=("currentReadinessStatus=${value:-<empty>}")
    else
      missing+=("currentReadinessStatus")
    fi
    summary_field_value "${output}" "currentReadinessReason" >/dev/null || missing+=("currentReadinessReason")
    if value="$(summary_field_value "${output}" "currentReadinessRequestedSmoke")"; then
      [[ "${value}" == "true" ]] || invalid+=("currentReadinessRequestedSmoke=${value:-<empty>}")
    else
      missing+=("currentReadinessRequestedSmoke")
    fi
    if value="$(summary_field_value "${output}" "currentReadinessRequestedBaseline")"; then
      [[ "${value}" == "true" ]] || invalid+=("currentReadinessRequestedBaseline=${value:-<empty>}")
    else
      missing+=("currentReadinessRequestedBaseline")
    fi
    if value="$(summary_field_value "${output}" "currentReadinessRequestedFullAcceptance")"; then
      [[ "${value}" == "true" ]] || invalid+=("currentReadinessRequestedFullAcceptance=${value:-<empty>}")
    else
      missing+=("currentReadinessRequestedFullAcceptance")
    fi
    for value in \
      "currentReadinessSmokeExitCode" \
      "currentReadinessBaselineExitCode" \
      "currentReadinessFullAcceptanceExitCode"
    do
      if exit_code="$(summary_field_value "${output}" "${value}")"; then
        [[ "${exit_code}" == "0" ]] || invalid+=("${value}=${exit_code:-<empty>}")
      else
        missing+=("${value}")
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
        is_positive_int "${value}" || invalid+=("currentReadinessProductScenarioSuiteScenarios=${value:-<empty>}")
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
    printf 'readiness result=fail reason=performance_evidence_policy_summary_missing fields=%s verifierOutput=%s\n' \
      "$(IFS=,; printf '%s' "${missing[*]}")" \
      "${output//$'\n'/ }" >&2
    return 1
  fi

  if ((${#invalid[@]} > 0)); then
    printf 'readiness result=fail reason=performance_evidence_policy_summary_invalid fields=%s verifierOutput=%s\n' \
      "$(IFS=,; printf '%s' "${invalid[*]}")" \
      "${output//$'\n'/ }" >&2
    return 1
  fi
}

run_performance_evidence_summary_self_test() {
  local acceptance_summary gate_summary good_output missing_output optional_output validation_output weakened_output

  grep -q 'PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=acceptance_max_age_not_forwarded\n' >&2
    return 1
  }
  grep -q 'PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=acceptance_max_future_skew_not_forwarded\n' >&2
    return 1
  }
  grep -q 'PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}"' "${BASH_SOURCE[0]}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=cloud_security_group_repair_receipt_max_age_not_forwarded\n' >&2
    return 1
  }

  PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE=true
  acceptance_summary='requireProductionAcceptance=true productionAcceptanceReceipt=/tmp/production-acceptance.json productionAcceptancePackage=/tmp/production-acceptance-package.tar.gz'
  gate_summary='productProfileGate=PASS productProfileGateChecked=3 productProfileGateRequiredDomains=10'
  current_summary='manifestRequireCurrentReadinessArtifacts=true manifestRequireProductScenarioSuiteArtifacts=true currentReadinessStatus=PASS currentReadinessReason=pass currentReadinessRequestedSmoke=true currentReadinessRequestedProductScenarioSuite=true currentReadinessRequestedBaseline=true currentReadinessRequestedFullAcceptance=true currentReadinessSmokeExitCode=0 currentReadinessProductScenarioSuiteExitCode=0 currentReadinessBaselineExitCode=0 currentReadinessFullAcceptanceExitCode=0 currentReadinessProductScenarioSuiteExpected=recommended currentReadinessProductScenarioSuite=recommended currentReadinessProductScenarioSuiteStatus=PASS currentReadinessProductScenarioSuiteScenarios=8 currentReadinessProductScenarioSuiteLargeGroupIncluded=False currentReadinessFullAcceptanceExpectedCampaign=production-full-acceptance currentReadinessFullAcceptanceCampaign=production-full-acceptance currentReadinessFullAcceptanceStatus=PASS currentReadinessFullAcceptanceFailures=0 currentReadinessFullAcceptanceRequiredFailures=0 currentReadinessFullAcceptanceAttempted=6 currentReadinessFullAcceptanceSkipped=0'

  good_output="performance_evidence result=pass ${acceptance_summary} manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=ok profileEntrypointBlocker=-,-,-,- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 ${current_summary}"
  validate_readiness_performance_evidence_summary "${good_output}" >/dev/null || {
    printf 'readiness-performance-evidence-summary result=fail reason=good_summary_rejected\n' >&2
    return 1
  }

  weakened_output="performance_evidence result=pass ${acceptance_summary} manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=ok profileEntrypointBlocker=-,-,-,- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=http://127.0.0.1:8080,127.0.0.1,9000 productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 ${current_summary}"
  if validation_output="$(validate_readiness_performance_evidence_summary "${weakened_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=loopback_campaign_target_accepted\n' >&2
    return 1
  fi
  grep -q 'productCampaignTarget=http://127.0.0.1:8080,127.0.0.1,9000' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=loopback_campaign_target_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  missing_output='performance_evidence result=pass profileRunStatus=PASS productPlanStatus=PASS productCampaignStatus=PASS currentReadinessStatus=PASS'
  if validation_output="$(validate_readiness_performance_evidence_summary "${missing_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=missing_policy_accepted\n' >&2
    return 1
  fi
  grep -q 'manifestRequireProfileArtifacts' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=missing_policy_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  missing_output="performance_evidence result=pass manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true manifestRequireCurrentReadinessArtifacts=true profileRunStatus=PASS profileRunBlockerType=- ${gate_summary} productPlanStatus=PASS productCampaignStatus=PASS currentReadinessStatus=PASS"
  if validation_output="$(validate_readiness_performance_evidence_summary "${missing_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=missing_entrypoint_summary_accepted\n' >&2
    return 1
  fi
  grep -q 'profileEntrypointDiagnosis' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=missing_entrypoint_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  weakened_output="performance_evidence result=pass manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=cloud_edge_http_403_intercept profileEntrypointBlocker=entrypoint,P0,true,cloud_console_rescue_required ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 ${current_summary}"
  if validation_output="$(validate_readiness_performance_evidence_summary "${weakened_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=entrypoint_blocker_accepted\n' >&2
    return 1
  fi
  grep -q 'profileEntrypointBlocker=entrypoint,P0,true,cloud_console_rescue_required' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=entrypoint_blocker_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  weakened_output="performance_evidence result=pass manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=ok profileEntrypointBlocker=-,-,-,- productProfileGate=FAIL productProfileGateChecked=3 productProfileGateRequiredDomains=10 productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 ${current_summary}"
  if validation_output="$(validate_readiness_performance_evidence_summary "${weakened_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=failed_product_profile_gate_accepted\n' >&2
    return 1
  fi
  grep -q 'productProfileGate=FAIL' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=failed_product_profile_gate_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  weakened_output="performance_evidence result=pass manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=false manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=ok profileEntrypointBlocker=-,-,-,- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 ${current_summary}"
  if validation_output="$(validate_readiness_performance_evidence_summary "${weakened_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=weakened_policy_accepted\n' >&2
    return 1
  fi
  grep -q 'manifestRequireProductPlanArtifacts=false' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=weakened_policy_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  weakened_output="performance_evidence result=pass manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=ok profileEntrypointBlocker=-,-,-,- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=true productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 ${current_summary}"
  if validation_output="$(validate_readiness_performance_evidence_summary "${weakened_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=large_group_product_plan_accepted\n' >&2
    return 1
  fi
  grep -q 'productPlanLargeGroupIncluded=true' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=large_group_product_plan_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  weakened_output="performance_evidence result=pass manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=ok profileEntrypointBlocker=-,-,-,- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 productCampaignFailures=1 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 ${current_summary}"
  if validation_output="$(validate_readiness_performance_evidence_summary "${weakened_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=campaign_failure_accepted\n' >&2
    return 1
  fi
  grep -q 'productCampaignFailures=1' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=campaign_failure_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  weakened_output="performance_evidence result=pass ${acceptance_summary} manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true manifestRequireCurrentReadinessArtifacts=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=ok profileEntrypointBlocker=-,-,-,- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 currentReadinessStatus=PASS currentReadinessReason=pass currentReadinessRequestedSmoke=true currentReadinessRequestedBaseline=true currentReadinessRequestedFullAcceptance=false currentReadinessSmokeExitCode=0 currentReadinessBaselineExitCode=0 currentReadinessFullAcceptanceExitCode=-"
  if validation_output="$(validate_readiness_performance_evidence_summary "${weakened_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=current_readiness_partial_accepted\n' >&2
    return 1
  fi
  grep -q 'currentReadinessRequestedFullAcceptance=false' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=current_readiness_partial_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }
  weakened_output="performance_evidence result=pass ${acceptance_summary} manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true manifestRequireCloudSecurityGroup=true manifestRequireCurrentReadinessArtifacts=true profileRunStatus=PASS profileRunBlockerType=- profileEntrypointDiagnosis=ok profileEntrypointBlocker=-,-,-,- ${gate_summary} productPlanStatus=PASS productPlanBlockerType=- productPlanScenarioCount=53 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true productCampaign=non-large-group-release productCampaignStatus=PASS productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000 productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0 currentReadinessStatus=PASS currentReadinessReason=pass currentReadinessRequestedSmoke=true currentReadinessRequestedBaseline=true currentReadinessRequestedFullAcceptance=true currentReadinessSmokeExitCode=0 currentReadinessBaselineExitCode=0 currentReadinessFullAcceptanceExitCode=0 currentReadinessFullAcceptanceExpectedCampaign=production-full-acceptance currentReadinessFullAcceptanceCampaign=non-large-group-release currentReadinessFullAcceptanceStatus=PASS currentReadinessFullAcceptanceFailures=0 currentReadinessFullAcceptanceRequiredFailures=0 currentReadinessFullAcceptanceAttempted=6 currentReadinessFullAcceptanceSkipped=0"
  if validation_output="$(validate_readiness_performance_evidence_summary "${weakened_output}" 2>&1)"; then
    printf 'readiness-performance-evidence-summary result=fail reason=current_full_campaign_mismatch_accepted\n' >&2
    return 1
  fi
  grep -q 'currentReadinessFullAcceptanceCampaign=non-large-group-release,expected=production-full-acceptance' <<<"${validation_output}" || {
    printf 'readiness-performance-evidence-summary result=fail reason=current_full_campaign_mismatch_reason_absent output=%s\n' "${validation_output}" >&2
    return 1
  }

  PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE=false
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE=false
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE=false
  PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE=false
  PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=false
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE=false
  optional_output='performance_evidence result=pass current=/tmp/current'
  validate_readiness_performance_evidence_summary "${optional_output}" >/dev/null || {
    printf 'readiness-performance-evidence-summary result=fail reason=optional_summary_rejected\n' >&2
    return 1
  }

  printf 'readiness-performance-evidence-summary result=pass\n'
}

if bool_enabled "${READINESS_PERFORMANCE_EVIDENCE_SUMMARY_SELF_TEST}"; then
  run_performance_evidence_summary_self_test
  exit 0
fi

write_readiness_receipt() {
  local status="${1:-pass}"
  if ! bool_enabled "${READINESS_WRITE_RECEIPT}"; then
    printf 'readiness step=receipt skipped=true reason=disabled\n'
    return 0
  fi
  if [[ -z "${READINESS_RECEIPT_JSON}" ]]; then
    printf 'readiness result=fail reason=readiness_receipt_json_missing\n' >&2
    return 1
  fi

  install -d -m 0750 "$(dirname "${READINESS_RECEIPT_JSON}")"
  (
    export READINESS_RECEIPT_JSON_TARGET="${READINESS_RECEIPT_JSON}"
    export READINESS_RECEIPT_STATUS="${status}"
    export READINESS_APP_ENV_EFFECTIVE
    export READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE
    export READINESS_REQUIRE_SMOKE
    export READINESS_REQUIRE_BACKUP
    export READINESS_VERIFY_BACKUP
    export READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS
    export READINESS_LATEST_BACKUP_MAX_AGE_SECONDS
    export READINESS_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS
    export READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS_EFFECTIVE
    export READINESS_RESTORE_DRILL_RECEIPT_FILE
    export READINESS_RESTORE_DRILL_MAX_AGE_SECONDS
    export READINESS_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS
    export READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS_EFFECTIVE
    export READINESS_OFFSITE_BACKUP_RECEIPT_FILE
    export READINESS_OFFSITE_BACKUP_MAX_AGE_SECONDS
    export READINESS_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS
    export READINESS_LATEST_BACKUP_VERIFY_STEP_STATUS
    export READINESS_RUN_RESTORE_DRILL
    export READINESS_COLLECT_DIAGNOSTICS
    export READINESS_REQUIRE_AUDIT_TIMER
    export READINESS_REQUIRE_RESTORE_DRILL_TIMER
    export READINESS_REQUIRE_TIME_SYNC
    export READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE
    export READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE
    export READINESS_CLOUD_SECURITY_GROUP_RULES_FILE
    export READINESS_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS
    export READINESS_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS
    export READINESS_CLOUD_SECURITY_GROUP_ADMIN_PORTS
    export READINESS_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS
    export READINESS_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS
    export READINESS_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER
    export READINESS_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080
    export READINESS_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP
    export READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX
    export READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX
    export READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX
    export READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX
    export READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE
    export READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON
    export READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS
    export READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID
    export READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID
    export READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR
    export READINESS_REQUIRE_NGINX_CONFIG
    export READINESS_NGINX_REQUIRE_SSL
    export READINESS_NGINX_HTTP_CONF_PATH
    export READINESS_NGINX_LOCATIONS_CONF_PATH
    export READINESS_NGINX_SSL_CONF_PATH
    export READINESS_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE
    export READINESS_TOPOLOGY_SMOKE_JSON
    export READINESS_TOPOLOGY_SMOKE_MAX_AGE_SECONDS
    export READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS
    export PERF_PRODUCTION_GATE_JSON
    export PERF_PRODUCTION_GATE_PROFILE
    export PERF_PRODUCTION_GATE_MAX_AGE_SECONDS
    export PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT
    export PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT
    export PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE
    export PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE
    export PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE
    export PERF_PRODUCTION_EVIDENCE_CURRENT_LINK
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE
    export PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE
    export PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON
    export PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE
    export PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS
    export PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS
    export PUBLIC_BASE_URL_EFFECTIVE
    export HTTP_PORT
    export BACKUP_ROOT
    python3 - <<'PY'
from __future__ import annotations

import json
import os
import socket
import time
from datetime import datetime, timezone
from pathlib import Path


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def bool_env(name: str) -> bool:
    return env(name).lower() in {"1", "true", "yes", "on"}


def maybe_int(name: str):
    value = env(name)
    if value == "":
        return None
    try:
        return int(value)
    except ValueError:
        return value


def path_or_none(name: str):
    value = env(name)
    return value or None


generated_epoch = int(time.time())
steps = [
    {"name": "systemd-units", "status": "pass"},
    {"name": "production-env", "status": "pass"},
    {"name": "entrypoint", "status": "pass"},
    {"name": "application-smoke", "status": "pass" if bool_env("READINESS_REQUIRE_SMOKE") else "skipped"},
    {"name": "topology-smoke-receipt", "status": "pass" if bool_env("READINESS_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE") else "skipped"},
    {"name": "operational-audit", "status": "pass"},
    {"name": "latest-backup-verify", "status": env("READINESS_LATEST_BACKUP_VERIFY_STEP_STATUS", "skipped")},
    {"name": "restore-drill", "status": "pass" if bool_env("READINESS_RUN_RESTORE_DRILL") else "skipped"},
    {"name": "diagnostics-redaction-self-test", "status": "pass"},
    {"name": "performance-gate", "status": "pass" if bool_env("READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE") else "skipped"},
    {"name": "performance-evidence", "status": "pass" if bool_env("READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE") else "skipped"},
    {"name": "diagnostics-bundle", "status": "pass" if bool_env("READINESS_COLLECT_DIAGNOSTICS") else "skipped"},
    {"name": "receipt", "status": "pass"},
]

payload = {
    "schemaVersion": 1,
    "kind": "imserver-production-readiness-gate",
    "status": env("READINESS_RECEIPT_STATUS", "pass"),
    "generatedAt": datetime.fromtimestamp(generated_epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z"),
    "generatedAtEpoch": generated_epoch,
    "host": socket.gethostname(),
    "appEnv": env("READINESS_APP_ENV_EFFECTIVE"),
    "target": {
        "publicBaseURL": env("PUBLIC_BASE_URL_EFFECTIVE"),
        "httpPort": maybe_int("HTTP_PORT"),
        "performanceGateExpectBaseURL": env("PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE"),
        "performanceGateExpectTCPHost": env("PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE"),
        "performanceGateExpectTCPPort": str(env("PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE")),
    },
    "policy": {
        "requirePerformanceGate": bool_env("READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE"),
        "requireSmoke": bool_env("READINESS_REQUIRE_SMOKE"),
        "requireBackup": bool_env("READINESS_REQUIRE_BACKUP"),
        "verifyBackup": bool_env("READINESS_VERIFY_BACKUP"),
        "requireLatestBackupFreshness": bool_env("READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS"),
        "latestBackupMaxAgeSeconds": maybe_int("READINESS_LATEST_BACKUP_MAX_AGE_SECONDS"),
        "latestBackupMaxFutureSkewSeconds": maybe_int("READINESS_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS"),
        "requireRestoreDrillFreshness": bool_env("READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS_EFFECTIVE"),
        "restoreDrillMaxAgeSeconds": maybe_int("READINESS_RESTORE_DRILL_MAX_AGE_SECONDS"),
        "restoreDrillMaxFutureSkewSeconds": maybe_int("READINESS_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS"),
        "requireOffsiteBackupFreshness": bool_env("READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS_EFFECTIVE"),
        "offsiteBackupMaxAgeSeconds": maybe_int("READINESS_OFFSITE_BACKUP_MAX_AGE_SECONDS"),
        "offsiteBackupMaxFutureSkewSeconds": maybe_int("READINESS_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS"),
        "runRestoreDrill": bool_env("READINESS_RUN_RESTORE_DRILL"),
        "requireAuditTimer": bool_env("READINESS_REQUIRE_AUDIT_TIMER"),
        "requireRestoreDrillTimer": bool_env("READINESS_REQUIRE_RESTORE_DRILL_TIMER"),
        "requireTimeSync": bool_env("READINESS_REQUIRE_TIME_SYNC"),
        "requireAlertWebhook": bool_env("READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE"),
        "requireCloudSecurityGroup": bool_env("READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE"),
        "requireCloudSecurityGroupRepairReceipt": bool_env("READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE"),
        "requireNginxConfig": bool_env("READINESS_REQUIRE_NGINX_CONFIG"),
        "nginxRequireSSL": bool_env("READINESS_NGINX_REQUIRE_SSL"),
        "requireTopologySmoke": bool_env("READINESS_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE"),
        "topologySmokeMaxAgeSeconds": maybe_int("READINESS_TOPOLOGY_SMOKE_MAX_AGE_SECONDS"),
        "topologySmokeRequireArtifacts": bool_env("READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS"),
        "collectDiagnostics": bool_env("READINESS_COLLECT_DIAGNOSTICS"),
    },
    "cloudSecurityGroupPolicy": {
        "publicClientPorts": env("READINESS_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS").split(),
        "denyPublicPorts": env("READINESS_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS").split(),
        "adminPorts": env("READINESS_CLOUD_SECURITY_GROUP_ADMIN_PORTS").split(),
        "requirePublicClientPorts": bool_env("READINESS_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS"),
        "rulesMaxAgeSeconds": maybe_int("READINESS_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS"),
        "rulesRequireRootOwner": bool_env("READINESS_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER"),
        "allowTempHTTP8080": bool_env("READINESS_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080"),
        "allowPublicICMP": bool_env("READINESS_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP"),
        "publicBroadIPv4MaxPrefix": maybe_int("READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX"),
        "publicBroadIPv6MaxPrefix": maybe_int("READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX"),
        "adminPublicIPv4MinPrefix": maybe_int("READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX"),
        "adminPublicIPv6MinPrefix": maybe_int("READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX"),
    },
    "performanceEvidencePolicy": {
        "gateJSON": path_or_none("PERF_PRODUCTION_GATE_JSON"),
        "gateProfile": env("PERF_PRODUCTION_GATE_PROFILE"),
        "gateMaxAgeSeconds": maybe_int("PERF_PRODUCTION_GATE_MAX_AGE_SECONDS"),
        "gateRequireCurrentGit": bool_env("PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT"),
        "gateRequireCleanGit": bool_env("PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT"),
        "evidenceCurrentLink": path_or_none("PERF_PRODUCTION_EVIDENCE_CURRENT_LINK"),
        "requireProfileArtifacts": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE"),
        "requireProductPlanArtifacts": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE"),
        "requireProductCampaignArtifacts": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE"),
        "requireProductScenarioSuiteArtifacts": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS_EFFECTIVE"),
        "requireProductScenarioSuiteNoLargeGroup": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP"),
        "requireValidationInventory": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY"),
        "requireCurrentReadinessArtifacts": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE"),
        "requireCloudSecurityGroup": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE"),
        "requireProductionAcceptance": bool_env("PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE"),
        "productionAcceptanceReceiptJSON": path_or_none("PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON"),
        "productionAcceptancePackageFile": path_or_none("PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE"),
        "productionAcceptanceMaxAgeSeconds": maybe_int("PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS"),
        "productionAcceptanceMaxFutureSkewSeconds": maybe_int("PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS"),
    },
    "artifacts": {
        "latestBackupDir": str(Path(env("BACKUP_ROOT", "/var/backups/imserver")) / "latest"),
        "restoreDrillReceipt": path_or_none("READINESS_RESTORE_DRILL_RECEIPT_FILE"),
        "offsiteBackupReceipt": path_or_none("READINESS_OFFSITE_BACKUP_RECEIPT_FILE"),
        "cloudSecurityGroupRulesFile": path_or_none("READINESS_CLOUD_SECURITY_GROUP_RULES_FILE"),
        "cloudSecurityGroupRepairReceipt": path_or_none("READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON"),
        "nginxHTTPConf": path_or_none("READINESS_NGINX_HTTP_CONF_PATH"),
        "nginxLocationsConf": path_or_none("READINESS_NGINX_LOCATIONS_CONF_PATH"),
        "nginxSSLConf": path_or_none("READINESS_NGINX_SSL_CONF_PATH"),
        "topologySmokeReceipt": path_or_none("READINESS_TOPOLOGY_SMOKE_JSON"),
    },
    "steps": steps,
}

target = Path(env("READINESS_RECEIPT_JSON_TARGET")).expanduser()
target.parent.mkdir(parents=True, exist_ok=True)
tmp = target.with_name(f".{target.name}.{os.getpid()}.tmp")
tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.replace(tmp, target)
PY
  )
  printf 'readiness step=receipt result=pass path=%s\n' "${READINESS_RECEIPT_JSON}"
}

run_readiness_receipt_self_test() {
  local tmpdir receipt
  tmpdir="$(mktemp -d)"
  receipt="${tmpdir}/readiness/latest.json"
  READINESS_WRITE_RECEIPT=true
  READINESS_RECEIPT_JSON="${receipt}"
  READINESS_APP_ENV_EFFECTIVE=production
  READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE=true
  READINESS_REQUIRE_SMOKE=true
  READINESS_REQUIRE_BACKUP=true
  READINESS_VERIFY_BACKUP=true
  READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS=true
  READINESS_LATEST_BACKUP_VERIFY_STEP_STATUS=pass
  READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS_EFFECTIVE=true
  READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS_EFFECTIVE=true
  READINESS_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE=true
  READINESS_REQUIRE_ALERT_WEBHOOK_EFFECTIVE=true
  READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=true
  READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE=true
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE=true
  PUBLIC_BASE_URL_EFFECTIVE=https://chat.myim-prod.com
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE=https://chat.myim-prod.com
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE=tcp.myim-prod.com
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE=9000
  write_readiness_receipt pass >/dev/null
  python3 - "${receipt}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["kind"] == "imserver-production-readiness-gate"
assert payload["status"] == "pass"
assert payload["target"]["publicBaseURL"] == "https://chat.myim-prod.com"
assert payload["target"]["performanceGateExpectTCPHost"] == "tcp.myim-prod.com"
assert payload["policy"]["requirePerformanceGate"] is True
assert payload["policy"]["requireRestoreDrillFreshness"] is True
assert payload["policy"]["requireOffsiteBackupFreshness"] is True
assert payload["policy"]["requireTopologySmoke"] is True
assert payload["policy"]["requireAlertWebhook"] is True
assert payload["policy"]["requireCloudSecurityGroup"] is True
assert payload["policy"]["requireCloudSecurityGroupRepairReceipt"] is True
assert payload["performanceEvidencePolicy"]["requireCurrentReadinessArtifacts"] is True
assert any(step["name"] == "receipt" and step["status"] == "pass" for step in payload["steps"])
PY
  rm -rf "${tmpdir}"
  printf 'readiness-receipt result=pass\n'
}

if bool_enabled "${READINESS_RECEIPT_SELF_TEST}"; then
  run_readiness_receipt_self_test
  exit 0
fi

require_root

run_step() {
  local name="$1"
  shift
  printf '\n==> readiness step: %s\n' "${name}"
  "$@"
}

run_performance_evidence_step() {
  local output
  printf '\n==> readiness step: performance-evidence\n'
  if ! output="$(
    PERF_PRODUCTION_EVIDENCE_CURRENT_LINK="${PERF_PRODUCTION_EVIDENCE_CURRENT_LINK}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS_EFFECTIVE}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS_EFFECTIVE}" \
    PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS_EFFECTIVE}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS_EFFECTIVE}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${READINESS_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${READINESS_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${READINESS_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${READINESS_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${READINESS_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
	    PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${READINESS_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
	    PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE_EFFECTIVE}" \
    PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
    PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE}" \
    PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}" \
    PERF_PRODUCTION_GATE_JSON="${PERF_PRODUCTION_GATE_JSON}" \
    PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT}" \
    PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT}" \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE}" \
    PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG}" \
      bash "${SCRIPT_DIR}/70_verify_performance_evidence_package.sh" 2>&1
  )"; then
    printf '%s\n' "${output}"
    return 1
  fi
  printf '%s\n' "${output}"
  validate_readiness_performance_evidence_summary "${output}"
}

printf 'IMServer production readiness gate\n'
printf 'date=%s host=%s appEnv=%s requirePerformanceGate=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(hostname)" \
  "${READINESS_APP_ENV_EFFECTIVE}" \
  "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}"
printf 'readinessPolicy requireCloudSecurityGroup=%s cloudSecurityGroupRulesFile=%s requireNginxConfig=%s nginxRequireSSL=%s nginxHTTPConf=%s nginxLocationsConf=%s nginxSSLConf=%s\n' \
  "${READINESS_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
  "${READINESS_CLOUD_SECURITY_GROUP_RULES_FILE}" \
  "${READINESS_REQUIRE_NGINX_CONFIG}" \
  "${READINESS_NGINX_REQUIRE_SSL}" \
  "${READINESS_NGINX_HTTP_CONF_PATH}" \
  "${READINESS_NGINX_LOCATIONS_CONF_PATH}" \
  "${READINESS_NGINX_SSL_CONF_PATH}"
printf 'readinessEvidence requireTopologySmoke=%s topologySmokeJSON=%s topologySmokeMaxAgeSeconds=%s topologySmokeRequireArtifacts=%s\n' \
  "${READINESS_REQUIRE_TOPOLOGY_SMOKE_EFFECTIVE}" \
  "${READINESS_TOPOLOGY_SMOKE_JSON}" \
  "${READINESS_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}" \
  "${READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS}"

run_step "systemd-units" bash "${SCRIPT_DIR}/52_verify_systemd_units.sh"
run_step "production-env" bash "${SCRIPT_DIR}/55_verify_production_env.sh"
run_step "entrypoint" env \
  HTTP_PORT="${HTTP_PORT}" \
  PUBLIC_BASE_URL="${PUBLIC_BASE_URL_EFFECTIVE}" \
  VERIFY_REQUIRE_PUBLIC="${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}" \
  bash "${SCRIPT_DIR}/65_verify_entrypoint.sh"

if bool_enabled "${READINESS_REQUIRE_SMOKE}"; then
  run_step "application-smoke" env \
    HTTP_PORT="${HTTP_PORT}" \
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL_EFFECTIVE}" \
    BASE_URL="${PUBLIC_BASE_URL_EFFECTIVE:-http://127.0.0.1:${HTTP_PORT}}" \
    bash "${SCRIPT_DIR}/66_smoke_entrypoint.sh"
else
  printf 'readiness step=application-smoke skipped=true\n'
fi

run_step "topology-smoke-receipt" verify_topology_smoke_receipt

run_step "operational-audit" run_operational_audit_command \
  bash "${SCRIPT_DIR}/77_operational_audit.sh"

READINESS_BACKUP_DIR="${BACKUP_ROOT%/}/latest"

if bool_enabled "${READINESS_VERIFY_BACKUP}" && [[ -e "${READINESS_BACKUP_DIR}" ]]; then
  READINESS_LATEST_BACKUP_VERIFY_STEP_STATUS=pass
  run_step "latest-backup-verify" env \
    BACKUP_ROOT="${BACKUP_ROOT}" \
    BACKUP_DIR="${READINESS_BACKUP_DIR}" \
    bash "${SCRIPT_DIR}/81_verify_backup.sh"
elif bool_enabled "${READINESS_REQUIRE_BACKUP}"; then
  printf 'readiness result=fail reason=latest_backup_missing path=%s\n' "${READINESS_BACKUP_DIR}" >&2
  exit 1
else
  READINESS_LATEST_BACKUP_VERIFY_STEP_STATUS=skipped
  printf 'readiness step=latest-backup-verify skipped=true\n'
fi

if bool_enabled "${READINESS_RUN_RESTORE_DRILL}"; then
  run_step "restore-drill" env \
    BACKUP_ROOT="${BACKUP_ROOT}" \
    BACKUP_DIR="${READINESS_BACKUP_DIR}" \
    bash "${SCRIPT_DIR}/82_restore_drill_single_node.sh"
else
  printf 'readiness step=restore-drill skipped=true\n'
fi

run_step "diagnostics-redaction-self-test" env \
  DIAGNOSTIC_REDACTION_SELF_TEST=true \
  bash "${SCRIPT_DIR}/76_collect_diagnostics_bundle.sh"

if bool_enabled "${READINESS_REQUIRE_PERFORMANCE_GATE_EFFECTIVE}"; then
  run_step "performance-gate" env \
    PERF_PRODUCTION_GATE_JSON="${PERF_PRODUCTION_GATE_JSON}" \
    PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT}" \
    PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT}" \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE}" \
    PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG}" \
    bash "${SCRIPT_DIR}/67_verify_performance_gate.sh"
  run_performance_evidence_step
else
  printf 'readiness step=performance-gate skipped=true require=false appEnv=%s path=%s catalog=%s\n' \
    "${READINESS_APP_ENV_EFFECTIVE}" \
    "${PERF_PRODUCTION_GATE_JSON}" \
    "${PERF_PRODUCTION_PROFILE_CATALOG}"
fi

if bool_enabled "${READINESS_COLLECT_DIAGNOSTICS}"; then
run_step "diagnostics-bundle" env \
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL_EFFECTIVE}" \
    HTTP_PORT="${HTTP_PORT}" \
    bash "${SCRIPT_DIR}/76_collect_diagnostics_bundle.sh"
else
  printf 'readiness step=diagnostics-bundle skipped=true\n'
fi

write_readiness_receipt pass

printf 'readiness result=pass\n'
