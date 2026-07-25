#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COUNT="${COUNT:-1000}"
PREFIX="${PREFIX:-load}"
DOMAIN="${DOMAIN:-example.com}"
PASSWORD="${PASSWORD:-password1234}"
SOURCE_EMAIL="${SOURCE_EMAIL:-demo@example.com}"
SSH_HOST="${SSH_HOST:-}"
DB_NAME="${DB_NAME:-imserver}"
DB_USER="${DB_USER:-postgres}"
POSTGRES_DOCKER_CONTAINER="${POSTGRES_DOCKER_CONTAINER:-}"
OUTPUT_FILE="${OUTPUT_FILE:-${SCRIPT_DIR}/accounts/${PREFIX}-${COUNT}.csv}"
PROVISION_REMOTE="${PROVISION_REMOTE:-true}"
PROVISION_LOAD_ACCOUNTS_SELF_TEST="${PROVISION_LOAD_ACCOUNTS_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

fail() {
  echo "provision_load_accounts result=fail reason=$1" >&2
  exit 1
}

validate_inputs() {
  [[ "${COUNT}" =~ ^[0-9]+$ ]] || fail "invalid_count count=${COUNT}"
  [[ "${COUNT}" -gt 0 ]] || fail "invalid_count count=${COUNT}"
  [[ "${PREFIX}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid_prefix prefix=${PREFIX}"
  [[ "${DOMAIN}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid_domain domain=${DOMAIN}"
  [[ "${SOURCE_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9._-]+$ ]] || fail "invalid_source_email email=${SOURCE_EMAIL}"
  [[ "${DB_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid_db_name db=${DB_NAME}"
  [[ "${DB_USER}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid_db_user user=${DB_USER}"
  [[ -z "${POSTGRES_DOCKER_CONTAINER}" || "${POSTGRES_DOCKER_CONTAINER}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid_postgres_docker_container"
  if bool_enabled "${PROVISION_REMOTE}" && [[ -z "${SSH_HOST}" ]]; then
    fail "ssh_host_required set_SSH_HOST_or_PROVISION_REMOTE_false"
  fi
}

write_account_file() {
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  umask 077
  echo "Writing account file: ${OUTPUT_FILE}"
  {
    for index in $(seq 1 "${COUNT}"); do
      printf "%s-%05d@%s,%s\n" "${PREFIX}" "${index}" "${DOMAIN}" "${PASSWORD}"
    done
  } >"${OUTPUT_FILE}"
  chmod 600 "${OUTPUT_FILE}"
}

run_self_test() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" EXIT

  COUNT=3 \
  PREFIX=loadtest \
  DOMAIN=example.test \
  PASSWORD=self-test-password \
  OUTPUT_FILE="${tmpdir}/loadtest-3.csv" \
  PROVISION_REMOTE=false \
  PROVISION_LOAD_ACCOUNTS_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${tmpdir}/local.out"

  [[ -f "${tmpdir}/loadtest-3.csv" ]] || fail "self_test_output_missing"
  [[ "$(wc -l <"${tmpdir}/loadtest-3.csv" | tr -d ' ')" == "3" ]] || fail "self_test_row_count_invalid"
  [[ "$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "${tmpdir}/loadtest-3.csv")" == "600" ]] || fail "self_test_mode_invalid"
  grep -q 'provision_load_accounts result=pass' "${tmpdir}/local.out" || fail "self_test_local_result_missing"

  if COUNT=1 \
    PREFIX=loadtest \
    DOMAIN=example.test \
    PASSWORD=self-test-password \
    OUTPUT_FILE="${tmpdir}/remote-missing.csv" \
    PROVISION_REMOTE=true \
    PROVISION_LOAD_ACCOUNTS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/remote-missing.out" 2>"${tmpdir}/remote-missing.err"; then
    fail "self_test_missing_ssh_host_passed"
  fi
  grep -q 'ssh_host_required' "${tmpdir}/remote-missing.err" || fail "self_test_missing_ssh_host_reason_absent"

  echo "provision_load_accounts_self_test result=pass"
}

if bool_enabled "${PROVISION_LOAD_ACCOUNTS_SELF_TEST}"; then
  run_self_test
  exit 0
fi

validate_inputs

write_account_file

if ! bool_enabled "${PROVISION_REMOTE}"; then
  echo "Remote provisioning skipped: PROVISION_REMOTE=false"
  echo "provision_load_accounts result=pass mode=local output=${OUTPUT_FILE} count=${COUNT}"
  echo "Done. Use ACCOUNT_FILE=${OUTPUT_FILE}"
  exit 0
fi

echo "Provisioning ${COUNT} users on ${SSH_HOST}..."
ssh "${SSH_HOST}" \
  "COUNT='${COUNT}' PREFIX='${PREFIX}' DOMAIN='${DOMAIN}' SOURCE_EMAIL='${SOURCE_EMAIL}' DB_NAME='${DB_NAME}' DB_USER='${DB_USER}' POSTGRES_DOCKER_CONTAINER='${POSTGRES_DOCKER_CONTAINER}' bash -s" <<'REMOTE'
set -euo pipefail

if [[ -n "${POSTGRES_DOCKER_CONTAINER}" ]]; then
  psql_exec() {
    docker exec -i "${POSTGRES_DOCKER_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" "$@"
  }
else
  psql_exec() {
    sudo -u "${DB_USER}" psql -d "${DB_NAME}" "$@"
  }
fi

source_count="$(psql_exec \
  -v ON_ERROR_STOP=1 \
  -v source_email="${SOURCE_EMAIL}" \
  -At <<'SQL'
SELECT count(*)
FROM users
WHERE email = :'source_email';
SQL
)"
if [[ "${source_count}" != "1" ]]; then
  echo "Source account not found or not unique: ${SOURCE_EMAIL}" >&2
  exit 1
fi

psql_exec \
  -v ON_ERROR_STOP=1 \
  -v count="${COUNT}" \
  -v prefix="${PREFIX}" \
  -v domain="${DOMAIN}" \
  -v source_email="${SOURCE_EMAIL}" <<'SQL'
WITH source AS (
  SELECT password_hash
  FROM users
  WHERE email = :'source_email'
),
generated AS (
  SELECT
    gen_random_uuid() AS id,
    format(
      '%s-%s@%s',
      :'prefix',
      CASE
        WHEN series < 100000 THEN lpad(series::text, 5, '0')
        ELSE series::text
      END,
      :'domain'
    ) AS email,
    (SELECT password_hash FROM source) AS password_hash,
    format('Load %s', lpad(series::text, 5, '0')) AS display_name
  FROM generate_series(1, :'count'::int) AS series
)
INSERT INTO users (
  id,
  email,
  password_hash,
  status,
  display_name,
  profile_revision,
  email_verified_at,
  created_at,
  updated_at
)
SELECT
  id,
  email,
  password_hash,
  'active',
  display_name,
  0,
  now(),
  now(),
  now()
FROM generated
WHERE password_hash IS NOT NULL
ON CONFLICT (email) DO UPDATE
SET
  password_hash = EXCLUDED.password_hash,
  status = 'active',
  display_name = EXCLUDED.display_name,
  email_verified_at = COALESCE(users.email_verified_at, now()),
  updated_at = now();
SQL

psql_exec \
  -v ON_ERROR_STOP=1 \
  -v prefix="${PREFIX}" \
  -v domain="${DOMAIN}" <<'SQL'
SELECT count(*) AS provisioned
FROM users
WHERE email LIKE :'prefix' || '-%@' || :'domain';
SQL
REMOTE

echo "provision_load_accounts result=pass mode=remote output=${OUTPUT_FILE} count=${COUNT} sshHost=${SSH_HOST} postgresDockerContainer=${POSTGRES_DOCKER_CONTAINER:-none}"
echo "Done. Use ACCOUNT_FILE=${OUTPUT_FILE}"
