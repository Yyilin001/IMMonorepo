#!/usr/bin/env bash
set -Eeuo pipefail

# The retained local Docker volume uses one immutable schema fact per numbered
# migration to decide whether it can safely record or must apply that migration.
# A new migration without a marker would otherwise be discovered only when a
# developer starts a pre-existing local stack.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
migrations_dir="${root_dir}/IMV2/sql"
migrator="${root_dir}/IMV2/scripts/apply_v2_local_schema_migrations.sh"

sql_migrations() {
  find "${migrations_dir}" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' \
    -exec basename {} \; | sort -u
}

marker_migrations() {
  sed -n '/migration_marker() {/,/^}/p' "${migrator}" \
    | sed -nE 's/^[[:space:]]*([0-9]{4}_[a-z0-9_]+\.sql)\)$/\1/p' \
    | sort -u
}

missing="$(comm -23 <(sql_migrations) <(marker_migrations))"
unexpected="$(comm -13 <(sql_migrations) <(marker_migrations))"

if [[ -n "${missing}" || -n "${unexpected}" ]]; then
  [[ -z "${missing}" ]] || {
    printf 'Numbered SQL migrations without a retained-volume marker:\n%s\n' "${missing}" >&2
  }
  [[ -z "${unexpected}" ]] || {
    printf 'Retained-volume markers without a numbered SQL migration:\n%s\n' "${unexpected}" >&2
  }
  exit 1
fi

printf 'V2 local schema migration marker coverage check passed.\n'
