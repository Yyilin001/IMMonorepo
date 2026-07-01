#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLOUD_SECURITY_GROUP_INSTALL_SELF_TEST="${CLOUD_SECURITY_GROUP_INSTALL_SELF_TEST:-false}"
CLOUD_SECURITY_GROUP_SOURCE_FILE="${CLOUD_SECURITY_GROUP_SOURCE_FILE:-}"
CLOUD_SECURITY_GROUP_TARGET_FILE="${CLOUD_SECURITY_GROUP_TARGET_FILE:-/etc/imserver/cloud-security-group.json}"
CLOUD_SECURITY_GROUP_INSTALL_REQUIRE_ROOT="${CLOUD_SECURITY_GROUP_INSTALL_REQUIRE_ROOT:-true}"
CLOUD_SECURITY_GROUP_INSTALL_OWNER="${CLOUD_SECURITY_GROUP_INSTALL_OWNER:-root}"
CLOUD_SECURITY_GROUP_INSTALL_GROUP="${CLOUD_SECURITY_GROUP_INSTALL_GROUP:-root}"
CLOUD_SECURITY_GROUP_INSTALL_MODE="${CLOUD_SECURITY_GROUP_INSTALL_MODE:-0644}"
CLOUD_SECURITY_GROUP_INSTALL_BACKUP_EXISTING="${CLOUD_SECURITY_GROUP_INSTALL_BACKUP_EXISTING:-true}"

CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}"
CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-}"
CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}"
CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}"
CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}"
CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}"
CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}"
CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    printf 'cloud-security-group-install result=fail reason=root_required action=run_with_sudo\n' >&2
    exit 1
  fi
}

audit_snapshot() {
  local rules_file="$1"
  local require_root_owner="$2"
  local max_age_seconds="$3"
  CLOUD_SECURITY_GROUP_RULES_FILE="${rules_file}" \
  CLOUD_SECURITY_GROUP_PROFILE=production \
  CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
  CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
  CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
  CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
  CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${max_age_seconds}" \
  CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${require_root_owner}" \
  CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
	  CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
	  CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
	  CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
	  CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
	  CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
	    bash "${SCRIPT_DIR}/26_audit_cloud_security_group.sh"
}

install_snapshot() {
  local source_file="$1"
  local target_file="$2"
  local target_dir backup_file root_owner_required

  if [[ -z "${source_file}" ]]; then
    printf 'cloud-security-group-install result=fail reason=source_file_required action=set CLOUD_SECURITY_GROUP_SOURCE_FILE=<rules.json>\n' >&2
    return 2
  fi
  if [[ ! -f "${source_file}" ]]; then
    printf 'cloud-security-group-install result=fail reason=source_file_missing path=%s\n' "${source_file}" >&2
    return 2
  fi

  # Source exports are often downloaded by an operator account. Validate their
  # cloud posture before install, but enforce root ownership only after install.
  audit_snapshot "${source_file}" false 0 >/dev/null

  if bool_enabled "${CLOUD_SECURITY_GROUP_INSTALL_REQUIRE_ROOT}"; then
    require_root
  fi

  target_dir="$(dirname "${target_file}")"
  if bool_enabled "${CLOUD_SECURITY_GROUP_INSTALL_REQUIRE_ROOT}"; then
    install -d -o "${CLOUD_SECURITY_GROUP_INSTALL_OWNER}" -g "${CLOUD_SECURITY_GROUP_INSTALL_GROUP}" -m 0750 "${target_dir}"
  else
    mkdir -p "${target_dir}"
    chmod 0750 "${target_dir}"
  fi

  backup_file=""
  if [[ -f "${target_file}" ]] && bool_enabled "${CLOUD_SECURITY_GROUP_INSTALL_BACKUP_EXISTING}"; then
    backup_file="${target_file}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "${target_file}" "${backup_file}"
    chmod 0600 "${backup_file}" || true
  fi

  if bool_enabled "${CLOUD_SECURITY_GROUP_INSTALL_REQUIRE_ROOT}"; then
    install \
      -o "${CLOUD_SECURITY_GROUP_INSTALL_OWNER}" \
      -g "${CLOUD_SECURITY_GROUP_INSTALL_GROUP}" \
      -m "${CLOUD_SECURITY_GROUP_INSTALL_MODE}" \
      "${source_file}" \
      "${target_file}"
    root_owner_required=true
  else
    install -m "${CLOUD_SECURITY_GROUP_INSTALL_MODE}" "${source_file}" "${target_file}"
    root_owner_required=false
  fi

  audit_snapshot "${target_file}" "${root_owner_required}" "${CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" >/dev/null
  printf 'cloud-security-group-install result=pass source=%s target=%s mode=%s requireRoot=%s backup=%s\n' \
    "${source_file}" \
    "${target_file}" \
    "${CLOUD_SECURITY_GROUP_INSTALL_MODE}" \
    "${CLOUD_SECURITY_GROUP_INSTALL_REQUIRE_ROOT}" \
    "${backup_file:-none}"
}

run_self_test() {
  local tmp_dir good bad target target_bad log
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN
  good="${tmp_dir}/good.json"
  bad="${tmp_dir}/bad.json"
  target="${tmp_dir}/etc/imserver/cloud-security-group.json"
  target_bad="${tmp_dir}/etc/imserver/bad-cloud-security-group.json"
  log="${tmp_dir}/install.log"

  cat >"${good}" <<'JSON'
[
  {"protocol":"tcp","port":"80/80","source":"0.0.0.0/0","action":"allow"},
  {"protocol":"tcp","port":"443/443","source":"0.0.0.0/0","action":"allow"},
  {"protocol":"tcp","port":"9000/9000","source":"0.0.0.0/0","action":"allow"},
  {"protocol":"tcp","port":"22/22","source":"203.0.113.10/32","action":"allow"}
]
JSON

  cat >"${bad}" <<'JSON'
[
  {"protocol":"tcp","port":"22/22","source":"0.0.0.0/0","action":"allow"}
]
JSON

  CLOUD_SECURITY_GROUP_INSTALL_SELF_TEST=false \
  CLOUD_SECURITY_GROUP_INSTALL_REQUIRE_ROOT=false \
  CLOUD_SECURITY_GROUP_SOURCE_FILE="${good}" \
  CLOUD_SECURITY_GROUP_TARGET_FILE="${target}" \
    bash "${BASH_SOURCE[0]}" >"${log}"
  grep -q 'cloud-security-group-install result=pass' "${log}"
  [[ -f "${target}" ]] || {
    printf 'cloud-security-group-install-self-test result=fail reason=target_missing\n' >&2
    return 1
  }
  python3 - "${target}" <<'PY'
import os
import sys

mode = os.stat(sys.argv[1]).st_mode & 0o777
if mode != 0o644:
    print(f"cloud-security-group-install-self-test result=fail reason=target_mode_invalid mode={mode:04o}", file=sys.stderr)
    raise SystemExit(1)
PY
  CLOUD_SECURITY_GROUP_RULES_FILE="${target}" \
  CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false \
    bash "${SCRIPT_DIR}/26_audit_cloud_security_group.sh" >/dev/null

  if CLOUD_SECURITY_GROUP_INSTALL_SELF_TEST=false \
    CLOUD_SECURITY_GROUP_INSTALL_REQUIRE_ROOT=false \
    CLOUD_SECURITY_GROUP_SOURCE_FILE="${bad}" \
    CLOUD_SECURITY_GROUP_TARGET_FILE="${target_bad}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'cloud-security-group-install-self-test result=fail reason=bad_source_unexpectedly_installed\n' >&2
    return 1
  fi
  grep -q 'public_admin_port:22' "${log}"
  [[ ! -f "${target_bad}" ]] || {
    printf 'cloud-security-group-install-self-test result=fail reason=bad_target_created\n' >&2
    return 1
  }

  printf 'cloud-security-group-install-self-test result=pass\n'
}

if bool_enabled "${CLOUD_SECURITY_GROUP_INSTALL_SELF_TEST}"; then
  run_self_test
  exit 0
fi

install_snapshot "${CLOUD_SECURITY_GROUP_SOURCE_FILE}" "${CLOUD_SECURITY_GROUP_TARGET_FILE}"
