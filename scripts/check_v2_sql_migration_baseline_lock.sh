#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${V2_SQL_MIGRATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SQL_DIR="${V2_SQL_MIGRATIONS_DIR:-$ROOT_DIR/IMV2/sql}"
LOCK_FILE="${V2_SQL_MIGRATION_BASELINE_LOCK:-$SQL_DIR/migration-baseline.lock.sha256}"

fail() {
  printf 'V2 SQL migration baseline lock check failed: %s\n' "$1" >&2
  exit 1
}

[[ -s "$LOCK_FILE" ]] || fail "missing frozen baseline at $LOCK_FILE"

locked_paths="$(mktemp)"
current_paths="$(mktemp)"
trap 'rm -f "$locked_paths" "$current_paths"' EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  expected_hash="${line%%  *}"
  relative_path="${line#*  }"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash entry: $line"
  [[ "$relative_path" =~ ^IMV2/sql/[0-9]{4}_.+\.sql$ ]] || fail "invalid migration entry: $relative_path"
  migration_path="$ROOT_DIR/$relative_path"
  [[ -f "$migration_path" ]] || fail "frozen migration is missing: $relative_path"
  actual_hash="$(shasum -a 256 "$migration_path" | awk '{ print $1 }')"
  [[ "$actual_hash" == "$expected_hash" ]] || fail "frozen migration changed: $relative_path"
  printf '%s\n' "$relative_path" >> "$locked_paths"
done < "$LOCK_FILE"

[[ -s "$locked_paths" ]] || fail "baseline contains no migrations"
duplicate_path="$(LC_ALL=C sort "$locked_paths" | uniq -d | head -n 1 || true)"
[[ -z "$duplicate_path" ]] || fail "baseline repeats migration: $duplicate_path"

while IFS= read -r migration_path; do
  relative_path="${migration_path#$ROOT_DIR/}"
  printf '%s\n' "$relative_path" >> "$current_paths"
done < <(find "$SQL_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' -print | LC_ALL=C sort)

[[ -s "$current_paths" ]] || fail "no numbered SQL migrations found"
max_locked="$(LC_ALL=C sort "$locked_paths" | tail -n 1)"
max_locked_name="${max_locked##*/}"
while IFS= read -r relative_path; do
  if ! grep -Fxq "$relative_path" "$locked_paths"; then
    migration_name="${relative_path##*/}"
    [[ "$migration_name" > "$max_locked_name" ]] || fail "new migration must append after $max_locked_name: $relative_path"
  fi
done < "$current_paths"

printf 'V2 SQL migration baseline lock check passed.\n'
