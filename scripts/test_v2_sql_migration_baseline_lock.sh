#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
fixture_sql="$fixture_root/IMV2/sql"
mkdir -p "$fixture_sql"

printf 'CREATE TABLE baseline (id INTEGER PRIMARY KEY);\n' > "$fixture_sql/0001_core.sql"
printf 'ALTER TABLE baseline ADD COLUMN name TEXT;\n' > "$fixture_sql/0002_name.sql"
for migration in "$fixture_sql"/[0-9][0-9][0-9][0-9]_*.sql; do
  hash="$(shasum -a 256 "$migration" | awk '{ print $1 }')"
  printf '%s  IMV2/sql/%s\n' "$hash" "$(basename "$migration")" >> "$fixture_sql/migration-baseline.lock.sha256"
done

check() {
  V2_SQL_MIGRATION_ROOT="$fixture_root" \
    bash "$ROOT_DIR/scripts/check_v2_sql_migration_baseline_lock.sh"
}

check
printf 'ALTER TABLE baseline ADD COLUMN rewritten INTEGER;\n' >> "$fixture_sql/0001_core.sql"
if check; then
  printf 'baseline lock accepted a rewritten historical migration\n' >&2
  exit 1
fi

printf 'CREATE TABLE baseline (id INTEGER PRIMARY KEY);\n' > "$fixture_sql/0001_core.sql"
printf 'CREATE TABLE invalid_append (id INTEGER PRIMARY KEY);\n' > "$fixture_sql/0000_invalid.sql"
if check; then
  printf 'baseline lock accepted a non-appended migration\n' >&2
  exit 1
fi

rm "$fixture_sql/0000_invalid.sql"
printf 'ALTER TABLE baseline ADD COLUMN later TEXT;\n' > "$fixture_sql/0003_later.sql"
check
printf 'V2 SQL migration baseline lock regression passed.\n'
