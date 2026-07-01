#!/usr/bin/env bash
set -euo pipefail
if [[ -f /opt/swiftly/env.sh ]]; then
  # Swiftly may be installed under /opt for non-interactive root scripts.
  # shellcheck source=/dev/null
  source /opt/swiftly/env.sh
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

INSTALL_DEPENDENCIES_SELF_TEST="${INSTALL_DEPENDENCIES_SELF_TEST:-false}"
SWIFTLY_VERSION="${SWIFTLY_VERSION:-1.1.2}"
SWIFTLY_ARCHIVE_MEMBER_MAX_BYTES="${SWIFTLY_ARCHIVE_MEMBER_MAX_BYTES:-67108864}"
SWIFTLY_ARCHIVE_TOTAL_MAX_BYTES="${SWIFTLY_ARCHIVE_TOTAL_MAX_BYTES:-268435456}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

verify_swiftly_archive_signature() {
  local archive_path="$1"
  local signature_path="$2"
  local keys_path="$3"
  local gpg_home import_log verify_log

  if ! command -v gpg >/dev/null 2>&1; then
    printf 'install_dependencies result=fail reason=swiftly_signature_gpg_missing\n' >&2
    return 1
  fi

  gpg_home="$(mktemp -d)"
  import_log="${gpg_home}/import.log"
  verify_log="${gpg_home}/verify.log"
  chmod 700 "${gpg_home}"

  if ! GNUPGHOME="${gpg_home}" gpg --batch --import "${keys_path}" >"${import_log}" 2>&1; then
    sed 's/^/install_dependencies gpg_import: /' "${import_log}" >&2 || true
    rm -rf "${gpg_home}"
    printf 'install_dependencies result=fail reason=swiftly_signature_key_import_failed\n' >&2
    return 1
  fi

  if ! GNUPGHOME="${gpg_home}" gpg --batch --verify "${signature_path}" "${archive_path}" >"${verify_log}" 2>&1; then
    sed 's/^/install_dependencies gpg_verify: /' "${verify_log}" >&2 || true
    rm -rf "${gpg_home}"
    printf 'install_dependencies result=fail reason=swiftly_signature_verify_failed\n' >&2
    return 1
  fi

  rm -rf "${gpg_home}"
  printf 'install_dependencies step=swiftly_signature result=pass\n'
}

safe_extract_swiftly_archive() {
  local archive_path="$1"
  local output_dir="$2"
  python3 - "${archive_path}" "${output_dir}" "${SWIFTLY_ARCHIVE_MEMBER_MAX_BYTES}" "${SWIFTLY_ARCHIVE_TOTAL_MAX_BYTES}" <<'PY'
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

archive_path, output_dir, max_member_raw, max_total_raw = sys.argv[1:5]
root = Path(output_dir).resolve()
max_member_bytes = int(max_member_raw)
max_total_bytes = int(max_total_raw)
seen = set()
total = 0
try:
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise SystemExit("install_dependencies result=fail reason=swiftly_archive_empty")
        for member in members:
            name = str(member.name or "")
            path = PurePosixPath(name)
            normalized = path.as_posix()
            if not name or name.startswith("/") or "\\" in name or path.is_absolute():
                raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_member_path_unsafe path={name or '-'}")
            if any(part in {"", ".", ".."} for part in path.parts):
                raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_member_path_unsafe path={name}")
            if normalized in seen:
                raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_member_duplicate path={name}")
            if member.issym() or member.islnk():
                raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_member_link path={name}")
            if not (member.isfile() or member.isdir()):
                raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_member_unsupported path={name}")
            if member.size < 0:
                raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_member_size_invalid path={name} size={member.size}")
            if member.size > max_member_bytes:
                raise SystemExit(
                    "install_dependencies result=fail "
                    f"reason=swiftly_archive_member_too_large path={name} size={member.size} max={max_member_bytes}"
                )
            total += member.size
            if total > max_total_bytes:
                raise SystemExit(
                    "install_dependencies result=fail "
                    f"reason=swiftly_archive_total_too_large size={total} max={max_total_bytes}"
                )
            target = (root / normalized).resolve()
            try:
                target.relative_to(root)
            except ValueError as exc:
                raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_member_path_unsafe path={name}") from exc
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(member.mode & 0o777)
                seen.add(normalized)
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_member_read_failed path={name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)
            seen.add(normalized)
except tarfile.TarError as exc:
    raise SystemExit(f"install_dependencies result=fail reason=swiftly_archive_invalid error={exc}")
if "swiftly" not in seen:
    raise SystemExit("install_dependencies result=fail reason=swiftly_archive_missing_binary")
print(f"install_dependencies step=swiftly_archive_safety result=pass members={len(seen)}")
PY
}

run_self_test() {
  local tmpdir archive signature keys gpg_home
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  mkdir -p "${tmpdir}/stage"
  printf '#!/usr/bin/env bash\n' >"${tmpdir}/stage/swiftly"
  chmod +x "${tmpdir}/stage/swiftly"
  archive="${tmpdir}/swiftly.tar.gz"
  signature="${archive}.sig"
  keys="${tmpdir}/swift-org-all-keys.asc"
  (cd "${tmpdir}/stage" && COPYFILE_DISABLE=1 tar -czf "${archive}" swiftly)
  if command -v gpg >/dev/null 2>&1; then
    gpg_home="${tmpdir}/signing-gpg"
    mkdir -p "${gpg_home}"
    chmod 700 "${gpg_home}"
    cat >"${tmpdir}/gpg-batch" <<'EOF'
Key-Type: default
Subkey-Type: default
Name-Real: Swiftly Install Self Test
Name-Email: swiftly-install-self-test@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF
    GNUPGHOME="${gpg_home}" gpg --batch --generate-key "${tmpdir}/gpg-batch" >/dev/null 2>&1
    GNUPGHOME="${gpg_home}" gpg --armor --export >"${keys}"
    GNUPGHOME="${gpg_home}" gpg --batch --yes --armor --detach-sign --output "${signature}" "${archive}" >/dev/null 2>&1
    verify_swiftly_archive_signature "${archive}" "${signature}" "${keys}" >/dev/null
    printf 'invalid-signature\n' >"${tmpdir}/bad.sig"
    if verify_swiftly_archive_signature "${archive}" "${tmpdir}/bad.sig" "${keys}" >"${tmpdir}/bad-signature.log" 2>&1; then
      printf 'install_dependencies_self_test result=fail reason=bad_swiftly_signature_accepted\n' >&2
      return 1
    fi
    grep -q 'swiftly_signature_verify_failed' "${tmpdir}/bad-signature.log" || {
      printf 'install_dependencies_self_test result=fail reason=bad_swiftly_signature_reason_missing\n' >&2
      return 1
    }
  else
    if verify_swiftly_archive_signature "${archive}" "${signature}" "${keys}" >"${tmpdir}/missing-gpg.log" 2>&1; then
      printf 'install_dependencies_self_test result=fail reason=swiftly_signature_without_gpg_accepted\n' >&2
      return 1
    fi
    grep -q 'swiftly_signature_gpg_missing' "${tmpdir}/missing-gpg.log" || {
      printf 'install_dependencies_self_test result=fail reason=swiftly_signature_missing_gpg_reason_missing\n' >&2
      return 1
    }
  fi
  safe_extract_swiftly_archive "${archive}" "${tmpdir}/out" >/dev/null
  [[ -x "${tmpdir}/out/swiftly" ]] || {
    printf 'install_dependencies_self_test result=fail reason=swiftly_binary_not_extracted\n' >&2
    return 1
  }
  python3 - "${tmpdir}/unsafe.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    data = b"unsafe\n"
    info = tarfile.TarInfo("../outside.txt")
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))
PY
  if safe_extract_swiftly_archive "${tmpdir}/unsafe.tar.gz" "${tmpdir}/unsafe-out" >"${tmpdir}/unsafe.log" 2>&1; then
    printf 'install_dependencies_self_test result=fail reason=unsafe_swiftly_archive_accepted\n' >&2
    return 1
  fi
  grep -q 'swiftly_archive_member_path_unsafe' "${tmpdir}/unsafe.log" || {
    printf 'install_dependencies_self_test result=fail reason=unsafe_swiftly_archive_reason_missing\n' >&2
    return 1
  }
  if SWIFTLY_ARCHIVE_MEMBER_MAX_BYTES=1 safe_extract_swiftly_archive "${archive}" "${tmpdir}/oversized-out" >"${tmpdir}/oversized.log" 2>&1; then
    printf 'install_dependencies_self_test result=fail reason=oversized_swiftly_archive_accepted\n' >&2
    return 1
  fi
  grep -q 'swiftly_archive_member_too_large' "${tmpdir}/oversized.log" || {
    printf 'install_dependencies_self_test result=fail reason=oversized_swiftly_archive_reason_missing\n' >&2
    return 1
  }
  printf 'install_dependencies_self_test result=pass\n'
}

if bool_enabled "${INSTALL_DEPENDENCIES_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  build-essential \
  ca-certificates \
  curl \
  clang \
  fail2ban \
  git \
  gnupg \
  python3 \
  libcurl4-openssl-dev \
  libjemalloc-dev \
  libsasl2-dev \
  libssl-dev \
  libxml2-dev \
  libz-dev \
  logrotate \
  netcat-openbsd \
  nginx \
  openssl \
  pkg-config \
  postgresql \
  postgresql-contrib \
  redis-server \
  rsync \
  systemd-timesyncd \
  tar \
  unzip \
  unattended-upgrades \
  ufw \
  uuid-runtime \
  zlib1g-dev

if ! command -v java >/dev/null 2>&1; then
  apt-get install -y openjdk-21-jre-headless
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Installing Swift with Swiftly under /opt/swiftly."
  apt-get install -y binutils libc6-dev libedit-dev libicu-dev libncurses-dev libpython3-dev libsqlite3-dev tzdata
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT
  cd "${tmp_dir}"
  swift_archive="swiftly-${SWIFTLY_VERSION}-$(uname -m).tar.gz"
  swift_archive_url="https://download.swift.org/swiftly/linux/${swift_archive}"
  swift_archive_signature="${swift_archive}.sig"
  swift_org_keys="swift-org-all-keys.asc"
  curl -fsSLO "${swift_archive_url}"
  curl -fsSLo "${swift_archive_signature}" "${swift_archive_url}.sig"
  curl --compressed -fsSLo "${swift_org_keys}" "https://www.swift.org/keys/all-keys.asc"
  verify_swiftly_archive_signature "${swift_archive}" "${swift_archive_signature}" "${swift_org_keys}"
  safe_extract_swiftly_archive "${swift_archive}" "${tmp_dir}"
  export SWIFTLY_HOME_DIR=/opt/swiftly
  export SWIFTLY_BIN_DIR=/usr/local/bin
  ./swiftly init --quiet-shell-followup
  . "${SWIFTLY_HOME_DIR}/env.sh"
  hash -r
fi

swift --version
systemctl enable --now postgresql
systemctl enable --now redis-server

echo "Base dependencies are installed."
