#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

BACKUP_CREATE_SELF_TEST="${BACKUP_CREATE_SELF_TEST:-false}"
ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/imserver}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_ID="${BACKUP_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
BACKUP_DIR="${BACKUP_DIR:-${BACKUP_ROOT}/${BACKUP_ID}}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_backup_target() {
  if [[ ! "${BACKUP_ID}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Refusing unsafe BACKUP_ID: ${BACKUP_ID}" >&2
    return 1
  fi
  if [[ ! "${BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]] || (( BACKUP_RETENTION_DAYS < 1 )); then
    echo "Refusing invalid BACKUP_RETENTION_DAYS: ${BACKUP_RETENTION_DAYS}" >&2
    return 1
  fi
  if [[ "${BACKUP_ROOT}" != /* || "${BACKUP_ROOT}" == "/" ]]; then
    echo "Refusing unsafe BACKUP_ROOT: ${BACKUP_ROOT}" >&2
    return 1
  fi
  if [[ "${BACKUP_DIR}" != /* ]]; then
    echo "Refusing non-absolute BACKUP_DIR: ${BACKUP_DIR}" >&2
    return 1
  fi
  if [[ -L "${BACKUP_ROOT}" ]]; then
    echo "Refusing symlink BACKUP_ROOT: ${BACKUP_ROOT}" >&2
    return 1
  fi
  if [[ -L "${BACKUP_DIR}" ]]; then
    echo "Refusing symlink BACKUP_DIR: ${BACKUP_DIR}" >&2
    return 1
  fi
  python3 - "${BACKUP_ROOT}" "${BACKUP_DIR}" <<'PY'
import os
import sys

root = os.path.abspath(os.path.normpath(sys.argv[1]))
target = os.path.abspath(os.path.normpath(sys.argv[2]))
try:
    common = os.path.commonpath([root, target])
except ValueError:
    raise SystemExit(f"Refusing BACKUP_DIR outside BACKUP_ROOT: {target}")
if common != root or target == root:
    raise SystemExit(f"Refusing BACKUP_DIR outside BACKUP_ROOT: {target}")
PY
  local path_rc=$?
  if (( path_rc != 0 )); then
    return "${path_rc}"
  fi
  if [[ -e "${BACKUP_DIR}" && ! -d "${BACKUP_DIR}" ]]; then
    echo "Refusing non-directory BACKUP_DIR: ${BACKUP_DIR}" >&2
    return 1
  fi
  if [[ -d "${BACKUP_DIR}" ]] && find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "Refusing non-empty BACKUP_DIR: ${BACKUP_DIR}" >&2
    return 1
  fi
}

validate_latest_pointer() {
  local latest_path="${BACKUP_ROOT%/}/latest"
  if [[ -e "${latest_path}" && ! -L "${latest_path}" ]]; then
    echo "Refusing to replace non-symlink latest backup pointer: ${latest_path}" >&2
    return 1
  fi
}

update_latest_pointer() {
  local latest_path="${BACKUP_ROOT%/}/latest"
  local tmp_latest="${BACKUP_ROOT%/}/.latest.${BACKUP_ID}.$$"
  validate_latest_pointer || return 1
  if [[ -e "${tmp_latest}" || -L "${tmp_latest}" ]]; then
    echo "Refusing to reuse temporary latest backup pointer: ${tmp_latest}" >&2
    return 1
  fi
  ln -s "${BACKUP_DIR}" "${tmp_latest}"
  if ! python3 - "${tmp_latest}" "${latest_path}" <<'PY'
import os
import stat
import sys

tmp_latest, latest_path = sys.argv[1:3]
try:
    latest_stat = os.lstat(latest_path)
except FileNotFoundError:
    latest_stat = None
if latest_stat is not None and not stat.S_ISLNK(latest_stat.st_mode):
    raise SystemExit(f"Refusing to replace non-symlink latest backup pointer: {latest_path}")
os.replace(tmp_latest, latest_path)
PY
  then
    rm -f "${tmp_latest}"
    return 1
  fi
}

if bool_enabled "${BACKUP_CREATE_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT

  BACKUP_ROOT="${self_test_dir}/backups"
  BACKUP_ID="safe-backup_001"
  BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_ID}"
  BACKUP_RETENTION_DAYS=3
  mkdir -p "${BACKUP_ROOT}"
  validate_backup_target || {
    printf 'backup_create_self_test result=fail reason=safe_target_rejected\n' >&2
    exit 1
  }

  BACKUP_ID="../bad"
  BACKUP_DIR="${BACKUP_ROOT}/bad"
  if validate_backup_target 2>"${self_test_dir}/bad-id.log"; then
    printf 'backup_create_self_test result=fail reason=bad_id_passed\n' >&2
    exit 1
  fi

  BACKUP_ID="safe-backup_002"
  BACKUP_ROOT="relative/backups"
  BACKUP_DIR="${self_test_dir}/relative-backup"
  if validate_backup_target 2>"${self_test_dir}/bad-root.log"; then
    printf 'backup_create_self_test result=fail reason=relative_root_passed\n' >&2
    exit 1
  fi

  BACKUP_ROOT="${self_test_dir}/backups"
  BACKUP_DIR="${self_test_dir}/outside"
  if validate_backup_target 2>"${self_test_dir}/outside.log"; then
    printf 'backup_create_self_test result=fail reason=outside_dir_passed\n' >&2
    exit 1
  fi

  BACKUP_DIR="${BACKUP_ROOT}/non-empty"
  mkdir -p "${BACKUP_DIR}"
  printf 'existing\n' >"${BACKUP_DIR}/file"
  if validate_backup_target 2>"${self_test_dir}/non-empty.log"; then
    printf 'backup_create_self_test result=fail reason=non_empty_dir_passed\n' >&2
    exit 1
  fi

  BACKUP_ROOT="${self_test_dir}/backups-link"
  BACKUP_DIR="${BACKUP_ROOT}/backup"
  ln -s "${self_test_dir}/backups" "${BACKUP_ROOT}"
  if validate_backup_target 2>"${self_test_dir}/symlink-root.log"; then
    printf 'backup_create_self_test result=fail reason=symlink_root_passed\n' >&2
    exit 1
  fi

  BACKUP_ROOT="${self_test_dir}/backups"
  rm -f "${BACKUP_ROOT}/latest"
  validate_latest_pointer || {
    printf 'backup_create_self_test result=fail reason=missing_latest_rejected\n' >&2
    exit 1
  }

  ln -s "${BACKUP_ROOT}/safe-backup_001" "${BACKUP_ROOT}/latest"
  validate_latest_pointer || {
    printf 'backup_create_self_test result=fail reason=symlink_latest_rejected\n' >&2
    exit 1
  }

  rm -f "${BACKUP_ROOT}/latest"
  mkdir -p "${BACKUP_ROOT}/latest"
  if validate_latest_pointer 2>"${self_test_dir}/latest-dir.log"; then
    printf 'backup_create_self_test result=fail reason=latest_directory_passed\n' >&2
    exit 1
  fi

  rm -rf "${BACKUP_ROOT}/latest"
  mkdir -p "${BACKUP_ROOT}/safe-backup_001" "${BACKUP_ROOT}/safe-backup_002"
  BACKUP_ID="safe-backup_002"
  BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_ID}"
  ln -s "${BACKUP_ROOT}/safe-backup_001" "${BACKUP_ROOT}/latest"
  update_latest_pointer || {
    printf 'backup_create_self_test result=fail reason=atomic_latest_update_failed\n' >&2
    exit 1
  }
  latest_target="$(readlink "${BACKUP_ROOT}/latest")"
  if [[ "${latest_target}" != "${BACKUP_DIR}" ]]; then
    printf 'backup_create_self_test result=fail reason=latest_target_mismatch target=%s\n' "${latest_target}" >&2
    exit 1
  fi
  if find "${BACKUP_ROOT}" -maxdepth 1 -name '.latest.*' -print -quit | grep -q .; then
    printf 'backup_create_self_test result=fail reason=latest_temp_leftover\n' >&2
    exit 1
  fi

  printf 'backup_create_self_test result=pass\n'
  exit 0
fi

require_root
validate_backup_target

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Environment file not found: ${ENV_FILE}" >&2
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
media_provider="${MEDIA_STORAGE_PROVIDER:-local}"
media_directory="${MEDIA_STORAGE_DIRECTORY:-${IMSERVER_HOME}/media}"

install -d -o root -g root -m 0700 "${BACKUP_ROOT}"
install -d -o root -g root -m 0700 "${BACKUP_DIR}"

printf 'backup id=%s dir=%s\n' "${BACKUP_ID}" "${BACKUP_DIR}"

PGPASSWORD="${db_password}" pg_dump \
  --host "${db_host}" \
  --port "${db_port}" \
  --username "${db_user}" \
  --dbname "${db_name}" \
  --format custom \
  --file "${BACKUP_DIR}/postgres.dump"

tar -C /etc -czf "${BACKUP_DIR}/imserver-etc.tgz" imserver

media_archive=""
if [[ "${media_provider}" == "local" && -d "${media_directory}" ]]; then
  tar -C "$(dirname "${media_directory}")" -czf "${BACKUP_DIR}/media.tgz" "$(basename "${media_directory}")"
  media_archive="media.tgz"
elif [[ "${media_provider}" == "local" ]]; then
  printf 'backup warning=media_directory_missing path=%s\n' "${media_directory}" >&2
else
  printf 'backup mediaProvider=%s action=metadata-only\n' "${media_provider}"
fi

{
  printf '# service states\n'
  systemctl --no-pager --plain --type=service --state=running,failed list-units 'imserver-*' nginx postgresql redis-server kafka || true
  printf '\n# selected listeners\n'
  ss -ltnp 2>/dev/null | awk 'NR == 1 || /:(8080|18080|8081|8082|9000|5432|6379|9092)[[:space:]]/' || true
} > "${BACKUP_DIR}/runtime-state.txt"

manifest_artifact_files=(postgres.dump imserver-etc.tgz runtime-state.txt)
if [[ -n "${media_archive}" ]]; then
  manifest_artifact_files+=("${media_archive}")
fi
python3 - \
  "${BACKUP_DIR}" \
  "${BACKUP_DIR}/manifest.json" \
  "${BACKUP_ID}" \
  "${ENV_FILE}" \
  "${db_host}" \
  "${db_port}" \
  "${db_name}" \
  "${db_user}" \
  "${media_provider}" \
  "${media_directory}" \
  "${media_archive}" \
  "${manifest_artifact_files[@]}" <<'PY'
import hashlib
import json
import os
import platform
import sys
from datetime import datetime, timezone

(
    backup_dir,
    manifest_path,
    backup_id,
    env_file,
    db_host,
    db_port,
    db_name,
    db_user,
    media_provider,
    media_directory,
    media_archive,
    *artifact_names,
) = sys.argv[1:]


def file_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


artifacts = {}
for name in artifact_names:
    path = os.path.join(backup_dir, name)
    artifacts[name] = {
        "file": name,
        "sha256": file_sha256(path),
        "sizeBytes": os.path.getsize(path),
    }

manifest = {
    "schemaVersion": 2,
    "backupID": backup_id,
    "createdAt": datetime.now(timezone.utc).isoformat(),
    "hostname": platform.node(),
    "environmentFile": env_file,
    "database": {
        "host": db_host,
        "port": db_port,
        "name": db_name,
        "user": db_user,
        "format": "pg_dump_custom",
        "file": "postgres.dump",
    },
    "configuration": {
        "file": "imserver-etc.tgz",
    },
    "media": {
        "provider": media_provider,
        "directory": media_directory,
        "file": media_archive,
    },
    "runtimeState": "runtime-state.txt",
    "artifacts": artifacts,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

checksum_files=(manifest.json "${manifest_artifact_files[@]}")
(
  cd "${BACKUP_DIR}"
  sha256sum "${checksum_files[@]}" > SHA256SUMS
)

chmod -R go-rwx "${BACKUP_DIR}"
update_latest_pointer

find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS}" -print -exec rm -rf {} +

printf 'backup result=pass dir=%s\n' "${BACKUP_DIR}"
printf 'verify with: sudo BACKUP_DIR=%q bash deploy/ubuntu/81_verify_backup.sh\n' "${BACKUP_DIR}"
