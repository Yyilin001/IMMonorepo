#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/IMV2/sql/migration-manifest.sha256"

[[ -f "$MANIFEST" ]] || {
  echo "V2 SQL migration manifest is missing. Run scripts/generate_v2_sql_migration_manifest.sh." >&2
  exit 1
}

temporary_manifest="$(mktemp)"
trap 'rm -f "$temporary_manifest"' EXIT
V2_SQL_MIGRATION_MANIFEST="$temporary_manifest" \
  "$ROOT_DIR/scripts/generate_v2_sql_migration_manifest.sh"

diff -u "$MANIFEST" "$temporary_manifest"
echo "V2 SQL migration manifest check passed."
