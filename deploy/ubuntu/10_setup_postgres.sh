#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

POSTGRES_LISTEN_ADDRESSES="${POSTGRES_LISTEN_ADDRESSES:-127.0.0.1}"
POSTGRES_PASSWORD_ENCRYPTION="${POSTGRES_PASSWORD_ENCRYPTION:-scram-sha-256}"

valid_pg_identifier() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]
}

sql_literal() {
  python3 -c 'import sys; print(sys.argv[1].replace("'"'"'", "'"'"''"'"'"))' "$1"
}

if ! valid_pg_identifier "${POSTGRES_USER}"; then
  printf 'postgres setup result=fail reason=invalid_postgres_user value=%s\n' "${POSTGRES_USER}" >&2
  exit 2
fi
if ! valid_pg_identifier "${POSTGRES_DB}"; then
  printf 'postgres setup result=fail reason=invalid_postgres_db value=%s\n' "${POSTGRES_DB}" >&2
  exit 2
fi
case "${POSTGRES_LISTEN_ADDRESSES}" in
  127.0.0.1|localhost|127.0.0.1,::1|localhost,127.0.0.1) ;;
  *)
    printf 'postgres setup result=fail reason=unsafe_listen_addresses value=%s action=keep_postgres_loopback_only_for_single_node\n' "${POSTGRES_LISTEN_ADDRESSES}" >&2
    exit 2
    ;;
esac
case "${POSTGRES_PASSWORD_ENCRYPTION}" in
  scram-sha-256|md5) ;;
  *)
    printf 'postgres setup result=fail reason=invalid_password_encryption value=%s\n' "${POSTGRES_PASSWORD_ENCRYPTION}" >&2
    exit 2
    ;;
esac

require_root

systemctl enable --now postgresql

listen_addresses_sql="$(sql_literal "${POSTGRES_LISTEN_ADDRESSES}")"
password_encryption_sql="$(sql_literal "${POSTGRES_PASSWORD_ENCRYPTION}")"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET listen_addresses = '${listen_addresses_sql}';
ALTER SYSTEM SET password_encryption = '${password_encryption_sql}';
SQL
systemctl restart postgresql

postgres_password_sql="$(sql_literal "${POSTGRES_PASSWORD}")"

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_USER}') THEN
    CREATE ROLE ${POSTGRES_USER} LOGIN PASSWORD '${postgres_password_sql}';
  ELSE
    ALTER ROLE ${POSTGRES_USER} WITH LOGIN PASSWORD '${postgres_password_sql}';
  END IF;
END
\$\$;
SQL

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" | grep -q 1; then
  sudo -u postgres createdb -O "${POSTGRES_USER}" "${POSTGRES_DB}"
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${POSTGRES_DB}" <<SQL
GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};
GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};
ALTER SCHEMA public OWNER TO ${POSTGRES_USER};
SQL

echo "PostgreSQL is ready: db=${POSTGRES_DB}, user=${POSTGRES_USER}"
