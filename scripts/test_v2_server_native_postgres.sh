#!/usr/bin/env bash
# Run current server tests against seven fresh, owned PostgreSQL databases.
# Requires an existing local PostgreSQL server and a role allowed to CREATE DATABASE.
set -Eeuo pipefail

if [[ "${1:-}" == '--help' ]]; then
  cat <<'HELP'
Usage: PGHOST=127.0.0.1 PGPORT=55439 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh [swift test options]
Creates unique primary, secondary, control, resource, resource-target, actor-cancellation and actor-overload
databases, enables disposable PostgreSQL tests, then removes only these databases
on exit. Additional options
(e.g. --filter PostgresV2RoomRecoverySchemaTests) are passed to swift test.
PGPASSWORD is optional and is not printed. External-service opt-in tests require
their own environment configuration; a successful run does not prove they ran.
HELP
  exit 0
fi

: "${PGHOST:?Set PGHOST explicitly}"
: "${PGPORT:?Set PGPORT explicitly}"
: "${PGUSER:?Set PGUSER explicitly}"
for tool in createdb dropdb psql python3 swift; do
  command -v "$tool" >/dev/null || { printf 'Missing required tool: %s\n' "$tool" >&2; exit 1; }
done
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="imv2_acceptance_$(python3 -c 'import uuid; print(uuid.uuid4().hex[:16])')"
created=()
cleanup() {
  local result=$?
  trap - EXIT
  for database in ${created[@]+"${created[@]}"}; do
    if ! dropdb --if-exists "$database"; then
      printf 'Failed to clean owned database: %s\n' "$database" >&2
      result=1
    fi
  done
  exit "$result"
}
trap cleanup EXIT
for suffix in primary secondary control resource resource_target actor_cancel actor_overload; do
  database="${prefix}_${suffix}"
  createdb --template=template0 "$database"
  created+=("$database")
done
connection_url() {
  python3 - "$1" <<'PY'
import os, sys
from urllib.parse import quote
host = os.environ['PGHOST']
if ':' in host and not host.startswith('['):
    host = '[' + host + ']'
user = quote(os.environ['PGUSER'], safe='')
password = os.environ.get('PGPASSWORD')
auth = user if password is None else user + ':' + quote(password, safe='')
print('postgres://' + auth + '@' + host + ':' + os.environ['PGPORT'] + '/' + quote(sys.argv[1], safe=''))
PY
}
export IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1
export IMV2_POSTGRES_TEST_DATABASE_URL="$(connection_url "${prefix}_primary")"
export IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL="$(connection_url "${prefix}_secondary")"
export IMV2_POSTGRES_TEST_CONTROL_DATABASE_URL="$(connection_url "${prefix}_control")"
export IMV2_RESOURCE_TEST_DATABASE_URL="$(connection_url "${prefix}_resource")"
export IMV2_RESOURCE_FORWARD_TARGET_DATABASE_URL="$(connection_url "${prefix}_resource_target")"
psql -Xq -v ON_ERROR_STOP=1 -d "${prefix}_resource" -f "${root_dir}/IMV2/sql/schema.sql" > /dev/null
psql -Xq -v ON_ERROR_STOP=1 -d "${prefix}_resource_target" -f "${root_dir}/IMV2/sql/schema.sql" > /dev/null
export IMV2_REQUIRE_CROSS_STORE_POSTGRES_TESTS=1
export IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE=1
export IMV2_ACTOR_CANCEL_MAINT_DATABASE_URL="$(connection_url "${prefix}_actor_cancel")"
export IMV2_ACTOR_HOST_OVERLOAD_DATABASE_IS_DISPOSABLE=1
export IMV2_ACTOR_HOST_OVERLOAD_DATABASE_URL="$(connection_url "${prefix}_actor_overload")"
printf 'Running server tests with seven owned disposable databases (%s).\n' "$prefix"
swift test --disable-automatic-resolution --package-path "${root_dir}/IMV2Server" --jobs 4 --no-parallel "$@"
