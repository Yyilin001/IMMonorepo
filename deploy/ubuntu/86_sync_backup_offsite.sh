#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

OFFSITE_BACKUP_SYNC_SELF_TEST="${OFFSITE_BACKUP_SYNC_SELF_TEST:-false}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/imserver}"
BACKUP_DIR="${BACKUP_DIR:-${BACKUP_ROOT}/latest}"
OFFSITE_BACKUP_DESTINATION="${OFFSITE_BACKUP_DESTINATION:-}"
OFFSITE_BACKUP_VERIFY="${OFFSITE_BACKUP_VERIFY:-true}"
OFFSITE_BACKUP_POST_VERIFY="${OFFSITE_BACKUP_POST_VERIFY:-true}"
OFFSITE_BACKUP_RECEIPT_DIR="${OFFSITE_BACKUP_RECEIPT_DIR:-/var/lib/imserver/offsite-backup}"
OFFSITE_BACKUP_RECEIPT_FILE="${OFFSITE_BACKUP_RECEIPT_FILE:-${OFFSITE_BACKUP_RECEIPT_DIR}/latest.json}"
OFFSITE_BACKUP_RSYNC_BIN="${OFFSITE_BACKUP_RSYNC_BIN:-rsync}"
OFFSITE_BACKUP_RSYNC_EXTRA_ARGS="${OFFSITE_BACKUP_RSYNC_EXTRA_ARGS:-}"
RSYNC_EXTRA_ARGS=()

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

backup_manifest_value() {
  local manifest_file="$1"
  local key="$2"
  python3 - "${manifest_file}" "${key}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
value = payload.get(sys.argv[2]) or ""
print(value)
PY
}

validate_offsite_destination() {
  local destination="$1"
  if [[ -z "${destination}" ]]; then
    echo "Set OFFSITE_BACKUP_DESTINATION to an rsync destination." >&2
    return 1
  fi
  case "${destination}" in
    -*|*[$'\n\r']*)
      echo "Refusing unsafe OFFSITE_BACKUP_DESTINATION: ${destination}" >&2
      return 1
      ;;
  esac
  if [[ "${destination}" == "/" ]]; then
    echo "Refusing root OFFSITE_BACKUP_DESTINATION." >&2
    return 1
  fi
  if [[ "${destination}" != *:* && "${destination}" != /* ]]; then
    echo "Refusing relative OFFSITE_BACKUP_DESTINATION: ${destination}" >&2
    return 1
  fi
  if [[ "${destination}" == *:* ]]; then
    local remote_path="${destination#*:}"
    if [[ -z "${remote_path}" || "${remote_path}" == "/" || "${remote_path}" == *"/../"* || "${remote_path}" == "../"* || "${remote_path}" == *"/.." ]]; then
      echo "Refusing unsafe remote OFFSITE_BACKUP_DESTINATION: ${destination}" >&2
      return 1
    fi
  fi
}

join_destination_path() {
  local destination="$1"
  local child="$2"
  printf '%s/%s\n' "${destination%/}" "${child}"
}

parse_rsync_extra_args() {
  RSYNC_EXTRA_ARGS=()
  if [[ -n "${OFFSITE_BACKUP_RSYNC_EXTRA_ARGS}" ]]; then
    # shellcheck disable=SC2206
    RSYNC_EXTRA_ARGS=( ${OFFSITE_BACKUP_RSYNC_EXTRA_ARGS} )
  fi
}

run_rsync_copy() {
  local source_dir="$1"
  local target_dir="$2"
  if (( ${#RSYNC_EXTRA_ARGS[@]} > 0 )); then
    "${OFFSITE_BACKUP_RSYNC_BIN}" -a "${RSYNC_EXTRA_ARGS[@]}" "${source_dir%/}/" "${target_dir%/}/"
  else
    "${OFFSITE_BACKUP_RSYNC_BIN}" -a "${source_dir%/}/" "${target_dir%/}/"
  fi
}

run_post_sync_verify() {
  local source_dir="$1"
  local target_dir="$2"
  local verify_output

  if (( ${#RSYNC_EXTRA_ARGS[@]} > 0 )); then
    verify_output="$(
      "${OFFSITE_BACKUP_RSYNC_BIN}" \
        -ani \
        --checksum \
        --delete \
        "${RSYNC_EXTRA_ARGS[@]}" \
        "${source_dir%/}/" \
        "${target_dir%/}/"
    )"
  else
    verify_output="$(
      "${OFFSITE_BACKUP_RSYNC_BIN}" \
        -ani \
        --checksum \
        --delete \
        "${source_dir%/}/" \
        "${target_dir%/}/"
    )"
  fi
  if [[ -n "${verify_output}" ]]; then
    printf 'Offsite backup post-sync verification found drift for %s:\n%s\n' \
      "${target_dir}" \
      "${verify_output}" >&2
    return 1
  fi
}

run_sync() {
  validate_offsite_destination "${OFFSITE_BACKUP_DESTINATION}"
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "Backup directory not found: ${BACKUP_DIR}" >&2
    return 1
  fi
  if [[ ! -f "${BACKUP_DIR}/manifest.json" ]]; then
    echo "Backup manifest not found: ${BACKUP_DIR}/manifest.json" >&2
    return 1
  fi
  if bool_enabled "${OFFSITE_BACKUP_VERIFY}"; then
    BACKUP_DIR="${BACKUP_DIR}" bash "${SCRIPT_DIR}/81_verify_backup.sh" >/dev/null
  fi

  local backup_id target
  backup_id="$(backup_manifest_value "${BACKUP_DIR}/manifest.json" "backupID")"
  if [[ -z "${backup_id}" || ! "${backup_id}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Backup manifest has unsafe backupID: ${backup_id}" >&2
    return 1
  fi
  local manifest_sha256
  manifest_sha256="$(sha256sum "${BACKUP_DIR}/manifest.json" | awk '{print $1}')"
  target="$(join_destination_path "${OFFSITE_BACKUP_DESTINATION}" "${backup_id}")"

  parse_rsync_extra_args
  run_rsync_copy "${BACKUP_DIR}" "${target}"
  if bool_enabled "${OFFSITE_BACKUP_POST_VERIFY}"; then
    run_post_sync_verify "${BACKUP_DIR}" "${target}"
  fi

  install -d -m 0750 "$(dirname "${OFFSITE_BACKUP_RECEIPT_FILE}")"
  python3 - "${OFFSITE_BACKUP_RECEIPT_FILE}" "${backup_id}" "${manifest_sha256}" "${BACKUP_DIR}" "${OFFSITE_BACKUP_DESTINATION}" "${target}" "${OFFSITE_BACKUP_POST_VERIFY}" <<'PY'
import json
import os
import socket
import sys
import tempfile
from datetime import datetime, timezone

receipt_file, backup_id, manifest_sha256, backup_dir, destination, target, post_verify = sys.argv[1:8]
directory = os.path.dirname(receipt_file)
payload = {
    "schemaVersion": 1,
    "completedAt": datetime.now(timezone.utc).isoformat(),
    "hostname": socket.gethostname(),
    "backupID": backup_id,
    "backupManifestSha256": manifest_sha256,
    "backupDir": backup_dir,
    "destination": destination,
    "target": target,
    "postSyncVerify": post_verify.lower() in {"1", "true", "yes", "on"},
    "postSyncVerifyMode": "rsync-dry-run-checksum-delete",
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

  printf 'offsite-backup result=pass backupID=%s target=%s receipt=%s\n' \
    "${backup_id}" \
    "${target}" \
    "${OFFSITE_BACKUP_RECEIPT_FILE}"
}

run_self_test() {
  local self_test_dir fake_bin rsync_log receipt_file output
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' RETURN
  fake_bin="${self_test_dir}/bin"
  mkdir -p "${fake_bin}" "${self_test_dir}/backup" "${self_test_dir}/remote" "${self_test_dir}/receipt"
  printf '{"backupID":"backup-001","createdAt":"2026-01-01T00:00:00+00:00"}\n' >"${self_test_dir}/backup/manifest.json"
  printf 'dump\n' >"${self_test_dir}/backup/postgres.dump"
  rsync_log="${self_test_dir}/rsync.log"
  receipt_file="${self_test_dir}/receipt/latest.json"
  cat >"${fake_bin}/rsync" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${OFFSITE_SELF_TEST_RSYNC_LOG}"
src="${@: -2:1}"
dst="${@: -1}"
dry_run=false
for arg in "$@"; do
  case "${arg}" in
    -n|-*n*|--dry-run) dry_run=true ;;
  esac
done
if [[ "${dry_run}" == "true" ]]; then
  if [[ ! -f "${dst%/}/manifest.json" || ! -f "${dst%/}/postgres.dump" ]] ||
    ! cmp -s "${src%/}/manifest.json" "${dst%/}/manifest.json" ||
    ! cmp -s "${src%/}/postgres.dump" "${dst%/}/postgres.dump"; then
    printf '>fcsT...... drift-detected\n'
  fi
  exit 0
fi
mkdir -p "${dst}"
cp -R "${src%/}/." "${dst%/}/"
SH
  chmod +x "${fake_bin}/rsync"

  output="$(
    PATH="${fake_bin}:${PATH}" \
    OFFSITE_SELF_TEST_RSYNC_LOG="${rsync_log}" \
    BACKUP_DIR="${self_test_dir}/backup" \
    OFFSITE_BACKUP_VERIFY=false \
    OFFSITE_BACKUP_RSYNC_BIN="${fake_bin}/rsync" \
    OFFSITE_BACKUP_DESTINATION="${self_test_dir}/remote" \
    OFFSITE_BACKUP_RECEIPT_FILE="${receipt_file}" \
      run_sync
  )"

  [[ -f "${self_test_dir}/remote/backup-001/manifest.json" ]] || {
    printf 'offsite-backup-self-test result=fail reason=backup_not_copied\n' >&2
    return 1
  }
  [[ -f "${receipt_file}" ]] || {
    printf 'offsite-backup-self-test result=fail reason=receipt_missing\n' >&2
    return 1
  }
  grep -q 'backup-001' "${receipt_file}" || {
    printf 'offsite-backup-self-test result=fail reason=receipt_backup_id_missing\n' >&2
    return 1
  }
  grep -q 'backupManifestSha256' "${receipt_file}" || {
    printf 'offsite-backup-self-test result=fail reason=receipt_manifest_sha_missing\n' >&2
    return 1
  }
  grep -q 'postSyncVerify' "${receipt_file}" || {
    printf 'offsite-backup-self-test result=fail reason=receipt_post_verify_missing\n' >&2
    return 1
  }
  grep -q -- '--checksum' "${rsync_log}" || {
    printf 'offsite-backup-self-test result=fail reason=post_verify_checksum_missing\n' >&2
    return 1
  }
  grep -q -- '--delete' "${rsync_log}" || {
    printf 'offsite-backup-self-test result=fail reason=post_verify_delete_missing\n' >&2
    return 1
  }
  printf 'tampered\n' >"${self_test_dir}/remote/backup-001/postgres.dump"
  if (
    OFFSITE_SELF_TEST_RSYNC_LOG="${rsync_log}"
    export OFFSITE_SELF_TEST_RSYNC_LOG
    OFFSITE_BACKUP_RSYNC_BIN="${fake_bin}/rsync"
    parse_rsync_extra_args
    run_post_sync_verify "${self_test_dir}/backup" "${self_test_dir}/remote/backup-001"
  ) 2>"${self_test_dir}/drift.err"; then
    printf 'offsite-backup-self-test result=fail reason=post_verify_drift_accepted\n' >&2
    return 1
  fi
  grep -q 'drift-detected' "${self_test_dir}/drift.err" || {
    printf 'offsite-backup-self-test result=fail reason=post_verify_drift_reason_missing\n' >&2
    return 1
  }
  grep -q 'offsite-backup result=pass' <<<"${output}" || {
    printf 'offsite-backup-self-test result=fail reason=pass_output_missing output=%s\n' "${output}" >&2
    return 1
  }
  if validate_offsite_destination "relative/path" 2>"${self_test_dir}/relative.err"; then
    printf 'offsite-backup-self-test result=fail reason=relative_destination_accepted\n' >&2
    return 1
  fi
  if validate_offsite_destination "/" 2>"${self_test_dir}/root.err"; then
    printf 'offsite-backup-self-test result=fail reason=root_destination_accepted\n' >&2
    return 1
  fi
  printf 'offsite-backup-self-test result=pass\n'
}

if bool_enabled "${OFFSITE_BACKUP_SYNC_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root
run_sync
