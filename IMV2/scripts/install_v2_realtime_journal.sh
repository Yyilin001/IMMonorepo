#!/usr/bin/env bash
set -Eeuo pipefail

# Explicit migration entrypoint. Connection flags are forwarded without logging;
# credentials can use the ordinary libpq environment/.pgpass. Runtime does not
# automatically mutate schemas. Every physical room/user/control source needs it.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
journal_schema='im_v2'
print_sql=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --schema) journal_schema="${2:?--schema requires a PostgreSQL identifier}"; shift 2 ;;
    --print-sql) print_sql=true; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[[ "${journal_schema}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
  printf 'invalid journal schema identifier\n' >&2
  exit 2
}
emit_install_sql() {
  sed "s/im_v2/${journal_schema}/g" "${script_dir}/../sql/realtime-change-journal.sql"
}
if [[ "${print_sql}" == true ]]; then
  [[ "$#" -eq 0 ]] || { printf 'connection arguments are not accepted with --print-sql\n' >&2; exit 2; }
  emit_install_sql
else
  emit_install_sql | psql -X --set=ON_ERROR_STOP=1 "$@"
fi
