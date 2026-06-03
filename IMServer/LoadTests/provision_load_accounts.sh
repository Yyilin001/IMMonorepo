#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COUNT="${COUNT:-1000}"
PREFIX="${PREFIX:-load}"
DOMAIN="${DOMAIN:-example.com}"
PASSWORD="${PASSWORD:-password1234}"
SOURCE_EMAIL="${SOURCE_EMAIL:-demo@example.com}"
SSH_HOST="${SSH_HOST:-root@120.25.106.200}"
DB_NAME="${DB_NAME:-imserver}"
DB_USER="${DB_USER:-postgres}"
OUTPUT_FILE="${OUTPUT_FILE:-${SCRIPT_DIR}/accounts/${PREFIX}-${COUNT}.csv}"

mkdir -p "$(dirname "${OUTPUT_FILE}")"

echo "Writing account file: ${OUTPUT_FILE}"
{
  for index in $(seq 1 "${COUNT}"); do
    printf "%s-%05d@%s,%s\n" "${PREFIX}" "${index}" "${DOMAIN}" "${PASSWORD}"
  done
} >"${OUTPUT_FILE}"

echo "Provisioning ${COUNT} users on ${SSH_HOST}..."
ssh "${SSH_HOST}" \
  "COUNT='${COUNT}' PREFIX='${PREFIX}' DOMAIN='${DOMAIN}' SOURCE_EMAIL='${SOURCE_EMAIL}' DB_NAME='${DB_NAME}' DB_USER='${DB_USER}' bash -s" <<'REMOTE'
set -euo pipefail

sudo -u "${DB_USER}" psql -d "${DB_NAME}" \
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
    format('%s-%s@%s', :'prefix', lpad(series::text, 5, '0'), :'domain') AS email,
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

sudo -u "${DB_USER}" psql -d "${DB_NAME}" \
  -v ON_ERROR_STOP=1 \
  -v prefix="${PREFIX}" \
  -v domain="${DOMAIN}" <<'SQL'
SELECT count(*) AS provisioned
FROM users
WHERE email LIKE :'prefix' || '-%@' || :'domain';
SQL
REMOTE

echo "Done. Use ACCOUNT_FILE=${OUTPUT_FILE}"
