#!/usr/bin/env bash
set -Eeuo pipefail

# The shared gateway/account/operator startup gate must fail before traffic if
# any required relation from the clean V2 schema is absent. Keep this check independent of
# a live database so a canonical schema edit cannot silently escape
# `V2SchemaReadiness.requiredTables`.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sql_dir="${root_dir}/IMV2/sql"
readiness_source="${root_dir}/IMV2Server/Sources/IMV2ServerInfrastructure/V2SchemaReadiness.swift"

command -v rg >/dev/null 2>&1 || {
  printf 'ripgrep (rg) is required to validate V2 schema-readiness coverage.\n' >&2
  exit 1
}

sql_relations() {
  sed -nE 's/^[[:space:]]*CREATE (TABLE|VIEW) im_v2\.([a-z0-9_]+).*/\2/p' \
    "${sql_dir}/schema.sql" | sort -u
}

readiness_tables() {
  sed -n '/requiredTables = \[/,/^    \]/p' "${readiness_source}" \
    | rg -No '"[a-z0-9_]+"' \
    | tr -d '"' \
    | sort -u
}

missing="$(comm -23 <(sql_relations) <(readiness_tables))"
unexpected="$(comm -13 <(sql_relations) <(readiness_tables))"

if [[ -n "${missing}" || -n "${unexpected}" ]]; then
  [[ -z "${missing}" ]] || {
    printf 'V2 schema relations missing from V2SchemaReadiness:\n%s\n' "${missing}" >&2
  }
  [[ -z "${unexpected}" ]] || {
    printf 'V2SchemaReadiness relations absent from canonical SQL schema:\n%s\n' "${unexpected}" >&2
  }
  exit 1
fi

printf 'V2 schema readiness relation coverage check passed.\n'
