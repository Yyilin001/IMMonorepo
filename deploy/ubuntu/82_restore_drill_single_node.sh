#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

RESTORE_DRILL_SAFETY_SELF_TEST="${RESTORE_DRILL_SAFETY_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

if bool_enabled "${RESTORE_DRILL_SAFETY_SELF_TEST}"; then
  python3 - "${BASH_SOURCE[0]}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

def require(needle: str, reason: str) -> None:
    if needle not in text:
        raise SystemExit(f"restore_drill_safety_self_test result=fail reason={reason}")

require('case "${RESTORE_DRILL_DB}" in', "marker_guard_missing")
require('*restore_drill*)', "marker_pattern_missing")
require('^[A-Za-z0-9_]+$', "safe_name_regex_missing")
require('if [[ "${RESTORE_DRILL_DB}" == "${db_name}" ]]; then', "production_db_refusal_missing")
require('trap drop_restore_db EXIT', "cleanup_trap_missing")
require('BACKUP_DIR="${BACKUP_DIR}" bash "${SCRIPT_DIR}/81_verify_backup.sh"', "backup_verify_missing")
require('pg_restore', "pg_restore_missing")
require('--exit-on-error', "pg_restore_exit_on_error_missing")
require('--single-transaction', "pg_restore_single_transaction_missing")
require('information_schema.tables', "schema_probe_missing")
require('RESTORE_DRILL_REQUIRED_TABLES', "required_tables_config_missing")
require('parse_restore_drill_required_tables()', "required_tables_parser_missing")
require('restore-drill step=critical_tables result=pass', "critical_tables_probe_missing")
require('requiredTables', "receipt_required_tables_missing")
require('RESTORE_DRILL_KEEP_DB', "keep_db_guard_missing")
require('RESTORE_DRILL_RECEIPT_FILE', "receipt_file_missing")
require('backupManifestSha256', "backup_manifest_sha_missing")
require('os.replace', "receipt_atomic_replace_missing")

verify_index = text.index('BACKUP_DIR="${BACKUP_DIR}" bash "${SCRIPT_DIR}/81_verify_backup.sh"')
restore_index = text.index('pg_restore')
if verify_index > restore_index:
    raise SystemExit("restore_drill_safety_self_test result=fail reason=backup_verify_after_restore")

trap_index = text.index('trap drop_restore_db EXIT')
create_index = text.index('CREATE DATABASE "${RESTORE_DRILL_DB}"')
if trap_index > create_index:
    raise SystemExit("restore_drill_safety_self_test result=fail reason=cleanup_trap_after_create")

print("restore_drill_safety_self_test result=pass")
PY
  exit 0
fi

require_root

ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/imserver}"
BACKUP_DIR="${BACKUP_DIR:-${BACKUP_ROOT}/latest}"
RESTORE_DRILL_DB="${RESTORE_DRILL_DB:-imserver_restore_drill_$(date -u +%Y%m%d%H%M%S)}"
RESTORE_DRILL_KEEP_DB="${RESTORE_DRILL_KEEP_DB:-false}"
RESTORE_DRILL_RECEIPT_DIR="${RESTORE_DRILL_RECEIPT_DIR:-/var/lib/imserver/restore-drill}"
RESTORE_DRILL_RECEIPT_FILE="${RESTORE_DRILL_RECEIPT_FILE:-${RESTORE_DRILL_RECEIPT_DIR}/latest.json}"
RESTORE_DRILL_REQUIRED_TABLES="${RESTORE_DRILL_REQUIRED_TABLES:-users,auth_sessions,im_conversations,im_conversation_members,im_messages,conversation_domain_events,owner_domain_event_deliveries,im_conversation_user_summaries,conversation_read_model_tokens}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Environment file not found: ${ENV_FILE}" >&2
  exit 1
fi
if [[ ! -d "${BACKUP_DIR}" ]]; then
  echo "Backup directory not found: ${BACKUP_DIR}" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

db_host="${DATABASE_PRIMARY_HOST:-${DATABASE_HOST:-127.0.0.1}}"
db_port="${DATABASE_PRIMARY_PORT:-${DATABASE_PORT:-5432}}"
db_user="${DATABASE_PRIMARY_USERNAME:-${DATABASE_USERNAME:-${POSTGRES_USER}}}"
db_password="${DATABASE_PRIMARY_PASSWORD:-${DATABASE_PASSWORD:-${POSTGRES_PASSWORD}}}"
db_name="${DATABASE_PRIMARY_NAME:-${DATABASE_NAME:-${POSTGRES_DB}}}"

case "${RESTORE_DRILL_DB}" in
  *restore_drill*) ;;
  *)
    echo "Refusing restore drill database name without restore_drill marker: ${RESTORE_DRILL_DB}" >&2
    exit 1
    ;;
esac
if [[ ! "${RESTORE_DRILL_DB}" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Refusing restore drill database name with unsafe characters: ${RESTORE_DRILL_DB}" >&2
  exit 1
fi

if [[ "${RESTORE_DRILL_DB}" == "${db_name}" ]]; then
  echo "Refusing to restore over production database: ${RESTORE_DRILL_DB}" >&2
  exit 1
fi

required_tables=()
parse_restore_drill_required_tables() {
  local raw="$1"
  local table
  required_tables=()
  while IFS= read -r table; do
    [[ -z "${table}" ]] && continue
    if [[ ! "${table}" =~ ^[A-Za-z0-9_]+$ ]]; then
      echo "Refusing unsafe RESTORE_DRILL_REQUIRED_TABLES entry: ${table}" >&2
      exit 1
    fi
    required_tables+=("${table}")
  done < <(printf '%s' "${raw}" | tr ',[:space:]' '\n')

  if (( ${#required_tables[@]} == 0 )); then
    echo "RESTORE_DRILL_REQUIRED_TABLES must contain at least one table." >&2
    exit 1
  fi
}

join_by_comma() {
  local joined=""
  local item
  for item in "$@"; do
    if [[ -z "${joined}" ]]; then
      joined="${item}"
    else
      joined="${joined},${item}"
    fi
  done
  printf '%s\n' "${joined}"
}

parse_restore_drill_required_tables "${RESTORE_DRILL_REQUIRED_TABLES}"

psql_cmd=(
  psql
  --host "${db_host}"
  --port "${db_port}"
  --username "${db_user}"
  --dbname postgres
  --no-psqlrc
  --set ON_ERROR_STOP=1
)

restore_psql_cmd=(
  psql
  --host "${db_host}"
  --port "${db_port}"
  --username "${db_user}"
  --dbname "${RESTORE_DRILL_DB}"
  --no-psqlrc
  --set ON_ERROR_STOP=1
)

drop_restore_db() {
  if ! bool_enabled "${RESTORE_DRILL_KEEP_DB}"; then
    PGPASSWORD="${db_password}" "${psql_cmd[@]}" >/dev/null <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${RESTORE_DRILL_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${RESTORE_DRILL_DB}";
SQL
  fi
}

trap drop_restore_db EXIT

printf 'restore-drill backupDir=%s targetDb=%s keepDb=%s\n' \
  "${BACKUP_DIR}" \
  "${RESTORE_DRILL_DB}" \
  "${RESTORE_DRILL_KEEP_DB}"

BACKUP_DIR="${BACKUP_DIR}" bash "${SCRIPT_DIR}/81_verify_backup.sh" >/dev/null
printf 'restore-drill step=backup_verify result=pass\n'

PGPASSWORD="${db_password}" "${psql_cmd[@]}" >/dev/null <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${RESTORE_DRILL_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${RESTORE_DRILL_DB}";
CREATE DATABASE "${RESTORE_DRILL_DB}" TEMPLATE template0 ENCODING 'UTF8';
SQL
printf 'restore-drill step=create_database result=pass db=%s\n' "${RESTORE_DRILL_DB}"

PGPASSWORD="${db_password}" pg_restore \
  --host "${db_host}" \
  --port "${db_port}" \
  --username "${db_user}" \
  --dbname "${RESTORE_DRILL_DB}" \
  --exit-on-error \
  --single-transaction \
  --no-owner \
  --no-privileges \
  "${BACKUP_DIR}/postgres.dump"
printf 'restore-drill step=pg_restore result=pass\n'

table_count="$(
  PGPASSWORD="${db_password}" "${restore_psql_cmd[@]}" --tuples-only --no-align <<'SQL'
SELECT count(*)
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE';
SQL
)"

if [[ ! "${table_count}" =~ ^[0-9]+$ ]] || (( table_count <= 0 )); then
  echo "Restore drill found no public base tables in ${RESTORE_DRILL_DB}" >&2
  exit 1
fi
printf 'restore-drill step=schema_probe result=pass publicBaseTables=%s\n' "${table_count}"

missing_required_tables=()
for required_table in "${required_tables[@]}"; do
  table_exists="$(
    PGPASSWORD="${db_password}" "${restore_psql_cmd[@]}" --tuples-only --no-align <<SQL
SELECT CASE WHEN EXISTS (
  SELECT 1
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_type = 'BASE TABLE'
    AND table_name = '${required_table}'
) THEN '1' ELSE '0' END;
SQL
  )"
  if [[ "${table_exists}" != "1" ]]; then
    missing_required_tables+=("${required_table}")
  fi
done

if (( ${#missing_required_tables[@]} > 0 )); then
  printf 'Restore drill missing required tables: %s\n' "$(join_by_comma "${missing_required_tables[@]}")" >&2
  exit 1
fi
required_tables_csv="$(join_by_comma "${required_tables[@]}")"
printf 'restore-drill step=critical_tables result=pass count=%s tables=%s\n' \
  "${#required_tables[@]}" \
  "${required_tables_csv}"

manifest_backup_id="$(
  python3 - "${BACKUP_DIR}/manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print(data.get("backupID") or "")
PY
)"
printf 'restore-drill step=manifest result=pass backupID=%s\n' "${manifest_backup_id}"
manifest_sha256="$(sha256sum "${BACKUP_DIR}/manifest.json" | awk '{print $1}')"

install -d -o root -g root -m 0750 "$(dirname "${RESTORE_DRILL_RECEIPT_FILE}")"
python3 - "${RESTORE_DRILL_RECEIPT_FILE}" "${manifest_backup_id}" "${manifest_sha256}" "${BACKUP_DIR}" "${RESTORE_DRILL_DB}" "${table_count}" "${RESTORE_DRILL_KEEP_DB}" "${required_tables_csv}" <<'PY'
import json
import os
import socket
import sys
import tempfile
from datetime import datetime, timezone

receipt_file, backup_id, manifest_sha256, backup_dir, target_db, table_count, keep_db, required_tables_csv = sys.argv[1:9]
directory = os.path.dirname(receipt_file)
payload = {
    "schemaVersion": 1,
    "completedAt": datetime.now(timezone.utc).isoformat(),
    "hostname": socket.gethostname(),
    "backupID": backup_id,
    "backupManifestSha256": manifest_sha256,
    "backupDir": backup_dir,
    "targetDatabase": target_db,
    "publicBaseTables": int(table_count),
    "requiredTables": [table for table in required_tables_csv.split(",") if table],
    "keepDatabase": keep_db.lower() in {"1", "true", "yes", "on"},
    "result": "pass",
}
fd, tmp_path = tempfile.mkstemp(prefix=".latest.", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(tmp_path, 0o640)
    os.replace(tmp_path, receipt_file)
finally:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
PY
printf 'restore-drill step=receipt result=pass file=%s\n' "${RESTORE_DRILL_RECEIPT_FILE}"

if bool_enabled "${RESTORE_DRILL_KEEP_DB}"; then
  printf 'restore-drill result=pass db=%s cleanup=kept\n' "${RESTORE_DRILL_DB}"
else
  printf 'restore-drill result=pass db=%s cleanup=drop_on_exit\n' "${RESTORE_DRILL_DB}"
fi
