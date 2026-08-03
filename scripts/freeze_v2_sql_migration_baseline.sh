#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${V2_SQL_MIGRATION_BASELINE_LOCK:-$ROOT_DIR/IMV2/sql/migration-baseline.lock.sha256}"

[[ ! -e "$LOCK_FILE" ]] || {
  printf 'V2 SQL migration baseline is already frozen: %s\n' "$LOCK_FILE" >&2
  exit 1
}

V2_SQL_MIGRATION_MANIFEST="$LOCK_FILE" \
  "$ROOT_DIR/scripts/generate_v2_sql_migration_manifest.sh"

printf 'V2 SQL migration baseline frozen: %s\n' "$LOCK_FILE"
