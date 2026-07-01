#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

JWT_ROTATION_MIGRATION_SELF_TEST="${JWT_ROTATION_MIGRATION_SELF_TEST:-false}"
ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

env_value() {
  local file="$1"
  local key="$2"
  local line value
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(trim "${line}")"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" == export\ * ]] && line="$(trim "${line#export }")"
    [[ "${line}" == "${key}="* ]] || continue
    value="${line#*=}"
    value="$(trim "${value}")"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    printf '%s' "${value}"
    return 0
  done < "${file}"
  return 1
}

validate_migratable_secret() {
  local value="$1"
  if [[ -z "${value}" ]]; then
    printf 'jwt-rotation-migration result=fail reason=empty_legacy_jwt_secret\n' >&2
    return 1
  fi
  if [[ "${value}" == *","* || "${value}" =~ [[:space:]] ]]; then
    printf 'jwt-rotation-migration result=fail reason=legacy_jwt_secret_contains_unsupported_characters\n' >&2
    return 1
  fi
}

migrate_env_file() {
  local env_file="$1"
  local legacy_secret jwt_secrets active_kid backup tmp
  if [[ ! -f "${env_file}" ]]; then
    printf 'jwt-rotation-migration result=skip reason=env_file_missing path=%s\n' "${env_file}"
    return 0
  fi

  legacy_secret="$(env_value "${env_file}" "JWT_SECRET" || true)"
  jwt_secrets="$(env_value "${env_file}" "JWT_SECRETS" || true)"
  active_kid="$(env_value "${env_file}" "JWT_ACTIVE_KID" || true)"

  if [[ -z "${legacy_secret}" ]]; then
    printf 'jwt-rotation-migration result=skip reason=no_legacy_jwt_secret path=%s\n' "${env_file}"
    return 0
  fi
  if [[ -n "${jwt_secrets}" ]]; then
    printf 'jwt-rotation-migration result=fail reason=ambiguous_legacy_and_rotated_jwt_keys path=%s\n' "${env_file}" >&2
    return 1
  fi
  if [[ -n "${active_kid}" ]]; then
    printf 'jwt-rotation-migration result=fail reason=active_kid_without_jwt_secrets path=%s\n' "${env_file}" >&2
    return 1
  fi
  validate_migratable_secret "${legacy_secret}"

  backup="${env_file}.legacy-jwt-secret.$(date -u +%Y%m%dT%H%M%SZ).bak"
  cp -p "${env_file}" "${backup}"
  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*(export[[:space:]]+)?JWT_SECRET=/ { next }
    /^[[:space:]]*(export[[:space:]]+)?JWT_SECRETS=/ { next }
    /^[[:space:]]*(export[[:space:]]+)?JWT_ACTIVE_KID=/ { next }
    { print }
  ' "${env_file}" > "${tmp}"
  {
    cat "${tmp}"
    printf 'JWT_SECRETS=active:%s\n' "${legacy_secret}"
    printf 'JWT_ACTIVE_KID=active\n'
  } > "${env_file}"
  rm -f "${tmp}"
  printf 'jwt-rotation-migration result=pass path=%s backup=%s\n' "${env_file}" "${backup}"
}

run_self_test() {
  local tmp_dir env_file backup_count output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  env_file="${tmp_dir}/legacy.env"
  cat > "${env_file}" <<'EOF'
APP_ENV=production
JWT_SECRET=0123456789abcdef0123456789abcdef
IM_INTERNAL_SHARED_SECRET=fedcba9876543210fedcba9876543210
EOF
  migrate_env_file "${env_file}" > "${tmp_dir}/legacy.log"
  grep -q '^JWT_SECRETS=active:0123456789abcdef0123456789abcdef$' "${env_file}" || {
    echo "jwt-rotation-migration self-test failed: rotated secret missing" >&2
    return 1
  }
  grep -q '^JWT_ACTIVE_KID=active$' "${env_file}" || {
    echo "jwt-rotation-migration self-test failed: active kid missing" >&2
    return 1
  }
  if grep -q '^JWT_SECRET=' "${env_file}"; then
    echo "jwt-rotation-migration self-test failed: legacy key remained" >&2
    return 1
  fi
  backup_count="$(find "${tmp_dir}" -name 'legacy.env.legacy-jwt-secret.*.bak' | wc -l | tr -d ' ')"
  [[ "${backup_count}" == "1" ]] || {
    echo "jwt-rotation-migration self-test failed: backup missing" >&2
    return 1
  }

  migrate_env_file "${env_file}" > "${tmp_dir}/idempotent.log"
  grep -q 'reason=no_legacy_jwt_secret' "${tmp_dir}/idempotent.log" || {
    echo "jwt-rotation-migration self-test failed: idempotent skip missing" >&2
    return 1
  }

  cat > "${tmp_dir}/ambiguous.env" <<'EOF'
APP_ENV=production
JWT_SECRET=0123456789abcdef0123456789abcdef
JWT_SECRETS=active:abcdef0123456789abcdef0123456789
JWT_ACTIVE_KID=active
EOF
  set +e
  output="$(migrate_env_file "${tmp_dir}/ambiguous.env" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )) || [[ "${output}" != *"reason=ambiguous_legacy_and_rotated_jwt_keys"* ]]; then
    echo "jwt-rotation-migration self-test failed: ambiguous config unexpectedly passed" >&2
    return 1
  fi

  printf 'jwt-rotation-migration-self-test result=pass\n'
}

if bool_enabled "${JWT_ROTATION_MIGRATION_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root
migrate_env_file "${ENV_FILE}"
