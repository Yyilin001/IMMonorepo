#!/usr/bin/env bash
set -Eeuo pipefail

# The shared gateway/account/operator startup gate must fail before traffic if
# any table from the clean V2 schema is absent. Keep this check independent of
# a live database so a newly added numbered migration cannot silently escape
# `V2SchemaReadiness.requiredTables`.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sql_dir="${root_dir}/IMV2/sql"
readiness_source="${root_dir}/IMV2Server/Sources/IMV2Server/V2SchemaReadiness.swift"

command -v rg >/dev/null 2>&1 || {
  printf 'ripgrep (rg) is required to validate V2 schema-readiness coverage.\n' >&2
  exit 1
}

sql_tables() {
  # Replay the numbered migrations in filename order so tables removed by a
  # later protocol migration are not mistaken for part of the final schema.
  # A table dropped and recreated later in the chain remains present.
  awk '
    /^[[:space:]]*CREATE TABLE( IF NOT EXISTS)? im_v2\.[a-z0-9_]+/ {
      table = $0
      sub(/^[[:space:]]*CREATE TABLE( IF NOT EXISTS)? im_v2\./, "", table)
      sub(/[^a-z0-9_].*$/, "", table)
      tables[table] = 1
      next
    }
    /^[[:space:]]*DROP TABLE( IF EXISTS)? im_v2\.[a-z0-9_]+/ {
      table = $0
      sub(/^[[:space:]]*DROP TABLE( IF EXISTS)? im_v2\./, "", table)
      sub(/[^a-z0-9_].*$/, "", table)
      delete tables[table]
    }
    END {
      for (table in tables) {
        print table
      }
    }
  ' "${sql_dir}"/*.sql | sort
}

readiness_tables() {
  sed -n '/requiredTables = \[/,/^    \]/p' "${readiness_source}" \
    | rg -No '"[a-z0-9_]+"' \
    | tr -d '"' \
    | sort -u
}

missing="$(comm -23 <(sql_tables) <(readiness_tables))"
unexpected="$(comm -13 <(sql_tables) <(readiness_tables))"

if [[ -n "${missing}" || -n "${unexpected}" ]]; then
  [[ -z "${missing}" ]] || {
    printf 'V2 schema tables missing from V2SchemaReadiness:\n%s\n' "${missing}" >&2
  }
  [[ -z "${unexpected}" ]] || {
    printf 'V2SchemaReadiness tables absent from numbered SQL migrations:\n%s\n' "${unexpected}" >&2
  }
  exit 1
fi

printf 'V2 schema readiness table coverage check passed.\n'
