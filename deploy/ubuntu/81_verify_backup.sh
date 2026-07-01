#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

BACKUP_VERIFY_SELF_TEST="${BACKUP_VERIFY_SELF_TEST:-false}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/imserver}"
BACKUP_DIR="${BACKUP_DIR:-${BACKUP_ROOT}/latest}"
BACKUP_VERIFY_MANIFEST_MAX_BYTES="${BACKUP_VERIFY_MANIFEST_MAX_BYTES:-4194304}"
BACKUP_VERIFY_ETC_ARCHIVE_MEMBER_MAX_BYTES="${BACKUP_VERIFY_ETC_ARCHIVE_MEMBER_MAX_BYTES:-67108864}"
BACKUP_VERIFY_ETC_ARCHIVE_TOTAL_MAX_BYTES="${BACKUP_VERIFY_ETC_ARCHIVE_TOTAL_MAX_BYTES:-268435456}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_backup_file_reference() {
  local reference="$1"
  local label="$2"
  if [[ -z "${reference}" ]]; then
    echo "Backup manifest ${label} file reference is empty" >&2
    return 1
  fi
  case "${reference}" in
    /*|*..*|*/*)
      echo "Backup manifest ${label} file reference is unsafe: ${reference}" >&2
      return 1
      ;;
  esac
  return 0
}

validate_checksum_file() {
  local backup_dir="$1"
  local checksum_file="$2"
  python3 - "${backup_dir}" "${checksum_file}" <<'PY'
import os
import posixpath
import re
import sys

backup_dir, checksum_file = sys.argv[1:3]
digest_re = re.compile(r"^[0-9a-fA-F]{64}$")
seen = set()
count = 0

with open(checksum_file, encoding="utf-8") as handle:
    for lineno, raw in enumerate(handle, start=1):
        line = raw.rstrip("\n")
        if not line:
            raise SystemExit(f"Backup checksum file has empty line: line={lineno}")
        if line.startswith("\\"):
            raise SystemExit(f"Backup checksum file uses escaped filename syntax: line={lineno}")
        if len(line) < 67 or line[64] != " " or line[65] not in (" ", "*"):
            raise SystemExit(f"Backup checksum file has invalid line format: line={lineno}")
        digest = line[:64]
        name = line[66:]
        if not digest_re.match(digest):
            raise SystemExit(f"Backup checksum file has invalid digest: line={lineno}")
        normalized = posixpath.normpath(name)
        if not name or name.startswith("/") or "/" in name or normalized == ".." or normalized.startswith("../") or ".." in name:
            raise SystemExit(f"Backup checksum file has unsafe file reference: line={lineno} file={name}")
        if name in seen:
            raise SystemExit(f"Backup checksum file has duplicate file reference: file={name}")
        seen.add(name)
        path = os.path.join(backup_dir, name)
        if not os.path.isfile(path):
            raise SystemExit(f"Backup checksum file references missing file: file={name}")
        count += 1

if count == 0:
    raise SystemExit("Backup checksum file has no entries")

print(f"backup-verify step=checksum_file_safety result=pass count={count}")
PY
}

validate_tar_archive() {
  local archive="$1"
  local label="$2"
  local max_member_bytes="${3:-0}"
  local max_total_bytes="${4:-0}"
  python3 - "${archive}" "${label}" "${max_member_bytes}" "${max_total_bytes}" <<'PY'
import posixpath
import sys
import tarfile

archive_path, label, max_member_bytes_raw, max_total_bytes_raw = sys.argv[1:5]


def parse_limit(value: str, name: str) -> int:
    try:
        parsed = int(value)
    except ValueError:
        raise SystemExit(f"Backup {label} archive {name} limit must be an integer")
    if parsed < 0:
        raise SystemExit(f"Backup {label} archive {name} limit must be non-negative")
    return parsed


max_member_bytes = parse_limit(max_member_bytes_raw, "member")
max_total_bytes = parse_limit(max_total_bytes_raw, "total")

try:
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
except tarfile.TarError as exc:
    raise SystemExit(f"Backup {label} archive is invalid: {exc}")

if not members:
    raise SystemExit(f"Backup {label} archive is empty")

total_size = 0
for member in members:
    name = member.name
    normalized = posixpath.normpath(name)
    if name.startswith("/") or normalized == ".." or normalized.startswith("../") or "/../" in name:
        raise SystemExit(f"Backup {label} archive has unsafe member path: {name}")
    if member.issym() or member.islnk():
        raise SystemExit(f"Backup {label} archive has unsafe link member: {name}")
    if not (member.isfile() or member.isdir()):
        raise SystemExit(f"Backup {label} archive has unsupported member type: {name}")
    if member.size < 0:
        raise SystemExit(f"Backup {label} archive has invalid negative member size: {name}")
    if member.isfile():
        if max_member_bytes and member.size > max_member_bytes:
            raise SystemExit(
                f"Backup {label} archive member too large: {name} size={member.size} max={max_member_bytes}"
            )
        total_size += member.size
        if max_total_bytes and total_size > max_total_bytes:
            raise SystemExit(f"Backup {label} archive total size too large: size={total_size} max={max_total_bytes}")
PY
	}

validate_manifest_artifacts() {
  local backup_dir="$1"
  local manifest_file="$2"
  python3 - "${backup_dir}" "${manifest_file}" "${BACKUP_VERIFY_MANIFEST_MAX_BYTES}" <<'PY'
import hashlib
import json
import os
import posixpath
import sys

backup_dir, manifest_file, manifest_max_bytes_raw = sys.argv[1:4]


def parse_manifest_limit(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError:
        raise SystemExit("backup manifest max bytes must be an integer")
    if parsed <= 0:
        raise SystemExit("backup manifest max bytes must be positive")
    return parsed


manifest_max_bytes = parse_manifest_limit(manifest_max_bytes_raw)
manifest_size = os.path.getsize(manifest_file)
if manifest_size > manifest_max_bytes:
    raise SystemExit(f"backup manifest is too large: size={manifest_size} max={manifest_max_bytes}")
with open(manifest_file, encoding="utf-8") as handle:
    manifest = json.load(handle)

artifacts = manifest.get("artifacts")
if not isinstance(artifacts, dict) or not artifacts:
    raise SystemExit("manifest artifacts must be a non-empty object")

required = {
    "postgres.dump",
    "imserver-etc.tgz",
    "runtime-state.txt",
}
media_file = (manifest.get("media") or {}).get("file") or ""
if media_file:
    required.add(media_file)


def validate_reference(name: str, label: str) -> None:
    normalized = posixpath.normpath(name)
    if not name or name.startswith("/") or "/" in name or normalized == ".." or normalized.startswith("../") or ".." in name:
        raise SystemExit(f"manifest artifacts {label} reference is unsafe: {name}")


def file_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_artifact_record(name: str, required_record: bool) -> None:
    validate_reference(name, name)
    record = artifacts.get(name)
    if not isinstance(record, dict):
        if required_record:
            raise SystemExit(f"manifest artifacts missing required record: {name}")
        raise SystemExit(f"manifest artifacts {name} record must be an object")
    if record.get("file") != name:
        raise SystemExit(f"manifest artifacts {name} file must match record key")
    path = os.path.join(backup_dir, name)
    if not os.path.isfile(path):
        raise SystemExit(f"manifest artifacts {name} file is missing")
    expected_size = record.get("sizeBytes")
    if not isinstance(expected_size, int) or expected_size < 0:
        raise SystemExit(f"manifest artifacts {name} sizeBytes must be a non-negative integer")
    actual_size = os.path.getsize(path)
    if expected_size != actual_size:
        raise SystemExit(f"manifest artifacts {name} sizeBytes mismatch: expected {expected_size}, got {actual_size}")
    expected_sha = record.get("sha256")
    if not isinstance(expected_sha, str) or len(expected_sha) != 64:
        raise SystemExit(f"manifest artifacts {name} sha256 must be a hex digest")
    actual_sha = file_sha256(path)
    if expected_sha.lower() != actual_sha:
        raise SystemExit(f"manifest artifacts {name} sha256 mismatch")


for name in required:
    validate_artifact_record(name, required_record=True)

for name, record in artifacts.items():
    validate_reference(name, name)
    validate_artifact_record(name, required_record=False)

print(f"backup-verify step=manifest_artifacts result=pass count={len(artifacts)}")
PY
}

if bool_enabled "${BACKUP_VERIFY_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  mkdir -p "${self_test_dir}/safe/imserver"
  printf 'APP_ENV=production\n' >"${self_test_dir}/safe/imserver/common.env"
  tar -C "${self_test_dir}/safe" -czf "${self_test_dir}/safe.tgz" imserver
  validate_tar_archive "${self_test_dir}/safe.tgz" "safe" || {
    printf 'backup_verify_self_test result=fail reason=safe_archive_rejected\n' >&2
    exit 1
  }
  validate_tar_archive "${self_test_dir}/safe.tgz" "safe-bounded" 1024 4096 || {
    printf 'backup_verify_self_test result=fail reason=safe_bounded_archive_rejected\n' >&2
    exit 1
  }
  validate_backup_file_reference "media.tgz" "media" || {
    printf 'backup_verify_self_test result=fail reason=safe_reference_rejected\n' >&2
    exit 1
  }
  printf '%064x  manifest.json\n' 1 >"${self_test_dir}/safe-checksums"
  printf 'manifest\n' >"${self_test_dir}/manifest.json"
  validate_checksum_file "${self_test_dir}" "${self_test_dir}/safe-checksums" >/dev/null || {
    printf 'backup_verify_self_test result=fail reason=safe_checksum_file_rejected\n' >&2
    exit 1
  }
  printf '%064x  ../outside\n' 1 >"${self_test_dir}/unsafe-checksums"
  if validate_checksum_file "${self_test_dir}" "${self_test_dir}/unsafe-checksums" 2>"${self_test_dir}/unsafe-checksums.log"; then
    printf 'backup_verify_self_test result=fail reason=unsafe_checksum_file_passed\n' >&2
    exit 1
  fi
  grep -q 'unsafe file reference' "${self_test_dir}/unsafe-checksums.log" || {
    printf 'backup_verify_self_test result=fail reason=unsafe_checksum_file_reason_missing\n' >&2
    exit 1
  }
  printf 'not-a-sha  manifest.json\n' >"${self_test_dir}/bad-digest-checksums"
  if validate_checksum_file "${self_test_dir}" "${self_test_dir}/bad-digest-checksums" 2>"${self_test_dir}/bad-digest-checksums.log"; then
    printf 'backup_verify_self_test result=fail reason=bad_digest_checksum_file_passed\n' >&2
    exit 1
  fi
  grep -q 'invalid line format' "${self_test_dir}/bad-digest-checksums.log" || {
    printf 'backup_verify_self_test result=fail reason=bad_digest_checksum_file_reason_missing\n' >&2
    exit 1
  }
  {
    printf '%064x  manifest.json\n' 1
    printf '%064x  manifest.json\n' 1
  } >"${self_test_dir}/duplicate-checksums"
  if validate_checksum_file "${self_test_dir}" "${self_test_dir}/duplicate-checksums" 2>"${self_test_dir}/duplicate-checksums.log"; then
    printf 'backup_verify_self_test result=fail reason=duplicate_checksum_file_passed\n' >&2
    exit 1
  fi
  grep -q 'duplicate file reference' "${self_test_dir}/duplicate-checksums.log" || {
    printf 'backup_verify_self_test result=fail reason=duplicate_checksum_file_reason_missing\n' >&2
    exit 1
  }
  if validate_backup_file_reference "../media.tgz" "media" 2>"${self_test_dir}/unsafe-reference.log"; then
    printf 'backup_verify_self_test result=fail reason=unsafe_reference_passed\n' >&2
    exit 1
  fi
  python3 - "${self_test_dir}/unsafe.tgz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    data = b"unsafe"
    info = tarfile.TarInfo("../outside.txt")
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))
PY
  if validate_tar_archive "${self_test_dir}/unsafe.tgz" "unsafe" 2>"${self_test_dir}/unsafe-archive.log"; then
    printf 'backup_verify_self_test result=fail reason=unsafe_archive_passed\n' >&2
    exit 1
  fi
  grep -q 'unsafe member path' "${self_test_dir}/unsafe-archive.log" || {
    printf 'backup_verify_self_test result=fail reason=unsafe_archive_reason_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/link.tgz" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    info = tarfile.TarInfo("imserver/common.env.link")
    info.type = tarfile.SYMTYPE
    info.linkname = "/etc/passwd"
    archive.addfile(info)
PY
  if validate_tar_archive "${self_test_dir}/link.tgz" "link" 2>"${self_test_dir}/link-archive.log"; then
    printf 'backup_verify_self_test result=fail reason=link_archive_passed\n' >&2
    exit 1
  fi
  grep -q 'unsafe link member' "${self_test_dir}/link-archive.log" || {
    printf 'backup_verify_self_test result=fail reason=link_archive_reason_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/oversized.tgz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    data = b"x" * 2048
    info = tarfile.TarInfo("imserver/large.env")
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))
PY
  if validate_tar_archive "${self_test_dir}/oversized.tgz" "oversized" 1024 4096 2>"${self_test_dir}/oversized-archive.log"; then
    printf 'backup_verify_self_test result=fail reason=oversized_archive_passed\n' >&2
    exit 1
  fi
  grep -q 'archive member too large' "${self_test_dir}/oversized-archive.log" || {
    printf 'backup_verify_self_test result=fail reason=oversized_archive_reason_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/total-too-large.tgz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    for index in range(3):
        data = b"payload"
        info = tarfile.TarInfo(f"imserver/file-{index}.env")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
PY
  if validate_tar_archive "${self_test_dir}/total-too-large.tgz" "total-too-large" 1024 12 2>"${self_test_dir}/total-too-large-archive.log"; then
    printf 'backup_verify_self_test result=fail reason=total_too_large_archive_passed\n' >&2
    exit 1
  fi
  grep -q 'archive total size too large' "${self_test_dir}/total-too-large-archive.log" || {
    printf 'backup_verify_self_test result=fail reason=total_too_large_archive_reason_missing\n' >&2
    exit 1
  }
  manifest_dir="${self_test_dir}/manifest-artifacts"
  mkdir -p "${manifest_dir}"
  printf 'dump\n' >"${manifest_dir}/postgres.dump"
  printf 'etc\n' >"${manifest_dir}/imserver-etc.tgz"
  printf 'runtime\n' >"${manifest_dir}/runtime-state.txt"
  python3 - "${manifest_dir}" "${manifest_dir}/manifest.json" <<'PY'
import hashlib
import json
import os
import sys

backup_dir, manifest_file = sys.argv[1:3]
artifacts = {}
for name in ("postgres.dump", "imserver-etc.tgz", "runtime-state.txt"):
    path = os.path.join(backup_dir, name)
    with open(path, "rb") as handle:
        data = handle.read()
    artifacts[name] = {
        "file": name,
        "sha256": hashlib.sha256(data).hexdigest(),
        "sizeBytes": len(data),
    }
manifest = {
    "backupID": "self-test",
    "createdAt": "2026-01-01T00:00:00+00:00",
    "database": {"file": "postgres.dump", "format": "pg_dump_custom"},
    "configuration": {"file": "imserver-etc.tgz"},
    "media": {"file": ""},
    "runtimeState": "runtime-state.txt",
    "artifacts": artifacts,
}
with open(manifest_file, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
    handle.write("\n")
PY
  validate_manifest_artifacts "${manifest_dir}" "${manifest_dir}/manifest.json" >/dev/null || {
    printf 'backup_verify_self_test result=fail reason=manifest_artifacts_rejected\n' >&2
    exit 1
  }
  BACKUP_VERIFY_MANIFEST_MAX_BYTES=2
  if validate_manifest_artifacts "${manifest_dir}" "${manifest_dir}/manifest.json" 2>"${self_test_dir}/manifest-too-large.log"; then
    printf 'backup_verify_self_test result=fail reason=manifest_too_large_accepted\n' >&2
    exit 1
  fi
  grep -q 'backup manifest is too large' "${self_test_dir}/manifest-too-large.log" || {
    printf 'backup_verify_self_test result=fail reason=manifest_too_large_reason_missing\n' >&2
    exit 1
  }
  BACKUP_VERIFY_MANIFEST_MAX_BYTES=4194304
  python3 - "${manifest_dir}/manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["artifacts"]["postgres.dump"]["sha256"] = "0" * 64
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
    handle.write("\n")
PY
  if validate_manifest_artifacts "${manifest_dir}" "${manifest_dir}/manifest.json" 2>"${self_test_dir}/manifest-artifacts-bad-sha.log"; then
    printf 'backup_verify_self_test result=fail reason=manifest_artifacts_bad_sha_accepted\n' >&2
    exit 1
  fi
  grep -q 'sha256 mismatch' "${self_test_dir}/manifest-artifacts-bad-sha.log" || {
    printf 'backup_verify_self_test result=fail reason=manifest_artifacts_bad_sha_reason_missing\n' >&2
    exit 1
  }
  printf 'extra\n' >"${manifest_dir}/extra.txt"
  python3 - "${manifest_dir}" "${manifest_dir}/manifest.json" <<'PY'
import hashlib
import json
import os
import sys

backup_dir, manifest_file = sys.argv[1:3]
with open(manifest_file, encoding="utf-8") as handle:
    manifest = json.load(handle)
path = os.path.join(backup_dir, "extra.txt")
with open(path, "rb") as handle:
    data = handle.read()
digest = hashlib.sha256()
with open(os.path.join(backup_dir, "postgres.dump"), "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
manifest["artifacts"]["postgres.dump"]["sha256"] = digest.hexdigest()
manifest["artifacts"]["extra.txt"] = {
    "file": "extra.txt",
    "sha256": "0" * 64,
    "sizeBytes": len(data),
}
with open(manifest_file, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
    handle.write("\n")
PY
  if validate_manifest_artifacts "${manifest_dir}" "${manifest_dir}/manifest.json" 2>"${self_test_dir}/manifest-artifacts-extra-bad-sha.log"; then
    printf 'backup_verify_self_test result=fail reason=manifest_artifacts_extra_bad_sha_accepted\n' >&2
    exit 1
  fi
  grep -q 'extra.txt sha256 mismatch' "${self_test_dir}/manifest-artifacts-extra-bad-sha.log" || {
    printf 'backup_verify_self_test result=fail reason=manifest_artifacts_extra_bad_sha_reason_missing\n' >&2
    exit 1
  }
  printf 'backup_verify_self_test result=pass\n'
  exit 0
fi

if [[ ! -d "${BACKUP_DIR}" ]]; then
  echo "Backup directory not found: ${BACKUP_DIR}" >&2
  exit 1
fi

required_files=(manifest.json postgres.dump imserver-etc.tgz SHA256SUMS)
for file in "${required_files[@]}"; do
  if [[ ! -f "${BACKUP_DIR}/${file}" ]]; then
    echo "Backup is missing required file: ${file}" >&2
    exit 1
  fi
done

validate_checksum_file "${BACKUP_DIR}" "${BACKUP_DIR}/SHA256SUMS"
(
  cd "${BACKUP_DIR}"
  sha256sum -c SHA256SUMS >/dev/null
)
printf 'backup-verify step=checksum result=pass\n'

validate_manifest_artifacts "${BACKUP_DIR}" "${BACKUP_DIR}/manifest.json"

pg_restore --list "${BACKUP_DIR}/postgres.dump" >/dev/null
printf 'backup-verify step=postgres_dump result=pass\n'

validate_tar_archive \
  "${BACKUP_DIR}/imserver-etc.tgz" \
  "imserver_etc" \
  "${BACKUP_VERIFY_ETC_ARCHIVE_MEMBER_MAX_BYTES}" \
  "${BACKUP_VERIFY_ETC_ARCHIVE_TOTAL_MAX_BYTES}"
printf 'backup-verify step=imserver_etc_archive result=pass\n'

media_file="$(
  python3 - "${BACKUP_DIR}/manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print(data.get("media", {}).get("file") or "")
PY
)"
if [[ -n "${media_file}" ]]; then
  validate_backup_file_reference "${media_file}" "media"
  if [[ ! -f "${BACKUP_DIR}/${media_file}" ]]; then
    echo "Backup manifest references missing media archive: ${media_file}" >&2
    exit 1
  fi
  validate_tar_archive "${BACKUP_DIR}/${media_file}" "media"
  printf 'backup-verify step=media_archive result=pass file=%s\n' "${media_file}"
else
  printf 'backup-verify step=media_archive result=skipped reason=non_local_or_missing_media\n'
fi

python3 - "${BACKUP_DIR}/manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
missing = []
for key in ("backupID", "createdAt", "database", "configuration", "runtimeState", "artifacts"):
    if not data.get(key):
        missing.append(key)
if missing:
    raise SystemExit(f"manifest missing required keys: {', '.join(missing)}")
if (data.get("database") or {}).get("file") != "postgres.dump":
    raise SystemExit("manifest database.file must be postgres.dump")
if (data.get("database") or {}).get("format") != "pg_dump_custom":
    raise SystemExit("manifest database.format must be pg_dump_custom")
if (data.get("configuration") or {}).get("file") != "imserver-etc.tgz":
    raise SystemExit("manifest configuration.file must be imserver-etc.tgz")
print(f"backup-verify step=manifest result=pass backupID={data.get('backupID')}")
PY

printf 'backup-verify result=pass dir=%s\n' "${BACKUP_DIR}"
