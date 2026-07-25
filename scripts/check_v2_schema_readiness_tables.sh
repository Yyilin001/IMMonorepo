#!/usr/bin/env bash
set -Eeuo pipefail

# The shared gateway/account/operator startup gate must fail before traffic if
# any table from the clean V2 schema is absent. Keep this check independent of
# a live database so a newly added numbered migration cannot silently escape
# `V2SchemaReadiness.requiredTables`.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sql_dir="${root_dir}/IMV2/sql"
readiness_source="${root_dir}/IMV2Server/Sources/IMV2Server/V2SchemaReadiness.swift"

sql_tables() {
  rg -No --glob '*.sql' 'CREATE TABLE(?: IF NOT EXISTS)? im_v2\.([a-z0-9_]+)' "${sql_dir}" \
    | sed -E 's/.*im_v2\.([a-z0-9_]+)/\1/' \
    | sort -u
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
