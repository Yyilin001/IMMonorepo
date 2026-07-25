#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQL_DIR="$ROOT_DIR/IMV2/sql"
MANIFEST="${V2_SQL_MIGRATION_MANIFEST:-$SQL_DIR/migration-manifest.sha256}"

[[ -d "$SQL_DIR" ]] || {
  echo "generate V2 SQL migration manifest failed: SQL directory is missing" >&2
  exit 1
}

temporary_manifest="$(mktemp)"
trap 'rm -f "$temporary_manifest"' EXIT

while IFS= read -r migration; do
  hash="$(shasum -a 256 "$migration" | awk '{ print $1 }')"
  relative_path="${migration#"$ROOT_DIR"/}"
  printf '%s  %s\n' "$hash" "$relative_path" >> "$temporary_manifest"
done < <(find "$SQL_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' -print | LC_ALL=C sort)

[[ -s "$temporary_manifest" ]] || {
  echo "generate V2 SQL migration manifest failed: no numbered SQL migrations found" >&2
  exit 1
}

mkdir -p "$(dirname "$MANIFEST")"
mv "$temporary_manifest" "$MANIFEST"
trap - EXIT
