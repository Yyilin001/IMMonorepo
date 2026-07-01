#!/usr/bin/env bash
set -euo pipefail
if [[ -f /opt/swiftly/env.sh ]]; then
  # Swiftly installs the toolchain for root during dependency setup. Non-login
  # scripts do not automatically inherit that environment.
  # shellcheck source=/dev/null
  source /opt/swiftly/env.sh
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

BUILD_IMSERVER_SELF_TEST="${BUILD_IMSERVER_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_release_id() {
  local release_id="$1"
  if [[ ! "${release_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]]; then
    printf 'build_imserver result=fail reason=release_id_invalid value=%s\n' "${release_id}" >&2
    return 2
  fi
  if [[ "${release_id}" == *..* ]]; then
    printf 'build_imserver result=fail reason=release_id_traversal value=%s\n' "${release_id}" >&2
    return 2
  fi
}

resolve_release_dir() {
  local releases_dir="$1"
  local release_id="$2"
  validate_release_id "${release_id}" || return $?
  python3 - "${releases_dir}" "${release_id}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=False)
release_id = sys.argv[2]
target = (root / release_id).resolve(strict=False)
try:
    target.relative_to(root)
except ValueError:
    raise SystemExit(f"build_imserver result=fail reason=release_dir_outside_releases path={target}")
if target == root:
    raise SystemExit(f"build_imserver result=fail reason=release_dir_is_releases_root path={target}")
print(target)
PY
}

run_self_test() {
  local tmpdir resolved expected_release_dir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  mkdir -p "${tmpdir}/releases"

  validate_release_id "20260101T000000Z" >/dev/null
  validate_release_id "release_1.2-rc1" >/dev/null

  if validate_release_id "../outside" >"${tmpdir}/bad-slash.log" 2>&1; then
    printf 'build_imserver_self_test result=fail reason=unsafe_release_id_slash_accepted\n' >&2
    return 1
  fi
  grep -q 'release_id_invalid' "${tmpdir}/bad-slash.log" || {
    printf 'build_imserver_self_test result=fail reason=unsafe_release_id_slash_reason_missing\n' >&2
    return 1
  }

  if validate_release_id "safe..outside" >"${tmpdir}/bad-dotdot.log" 2>&1; then
    printf 'build_imserver_self_test result=fail reason=unsafe_release_id_dotdot_accepted\n' >&2
    return 1
  fi
  grep -q 'release_id_traversal' "${tmpdir}/bad-dotdot.log" || {
    printf 'build_imserver_self_test result=fail reason=unsafe_release_id_dotdot_reason_missing\n' >&2
    return 1
  }

  if validate_release_id "-bad" >"${tmpdir}/bad-leading-dash.log" 2>&1; then
    printf 'build_imserver_self_test result=fail reason=unsafe_release_id_dash_accepted\n' >&2
    return 1
  fi
  grep -q 'release_id_invalid' "${tmpdir}/bad-leading-dash.log" || {
    printf 'build_imserver_self_test result=fail reason=unsafe_release_id_dash_reason_missing\n' >&2
    return 1
  }

  resolved="$(resolve_release_dir "${tmpdir}/releases" "release-1")"
  expected_release_dir="$(python3 - "${tmpdir}/releases/release-1" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
PY
)"
  [[ "${resolved}" == "${expected_release_dir}" ]] || {
    printf 'build_imserver_self_test result=fail reason=release_dir_resolve_mismatch expected=%s actual=%s\n' \
      "${expected_release_dir}" \
      "${resolved}" >&2
    return 1
  }

  printf 'build_imserver_self_test result=pass\n'
}

if bool_enabled "${BUILD_IMSERVER_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root

ROOT="$(repo_root)"
ensure_user "${IMSERVER_USER}" "${IMSERVER_GROUP}" "${IMSERVER_HOME}"
install -d -o "${IMSERVER_USER}" -g "${IMSERVER_GROUP}" -m 0755 \
  "${IMSERVER_HOME}" \
  "${IMSERVER_BIN_DIR}" \
  "${IMSERVER_RELEASES_DIR}" \
  "${IMSERVER_LOG_DIR}"

cd "${ROOT}"
build_configuration="${IMSERVER_BUILD_CONFIGURATION:-release}"
release_id="${IMSERVER_RELEASE_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
release_dir="$(resolve_release_dir "${IMSERVER_RELEASES_DIR}" "${release_id}")"
installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

swift build -c "${build_configuration}" --package-path IMServer --jobs "${SWIFT_BUILD_JOBS:-1}"

rm -rf "${release_dir}"
install -d -o "${IMSERVER_USER}" -g "${IMSERVER_GROUP}" -m 0755 "${release_dir}" "${release_dir}/bin"
install -o "${IMSERVER_USER}" -g "${IMSERVER_GROUP}" -m 0755 \
  "IMServer/.build/${build_configuration}/IMServer" \
  "${release_dir}/bin/IMServer"

if [[ -L "${IMSERVER_BIN_DIR}/IMServer" ]]; then
  current_target="$(readlink "${IMSERVER_BIN_DIR}/IMServer" || true)"
elif [[ -f "${IMSERVER_BIN_DIR}/IMServer" ]]; then
  legacy_release_dir="${IMSERVER_RELEASES_DIR}/legacy-$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -o "${IMSERVER_USER}" -g "${IMSERVER_GROUP}" -m 0755 "${legacy_release_dir}/bin"
  cp -a "${IMSERVER_BIN_DIR}/IMServer" "${legacy_release_dir}/bin/IMServer"
  chown -R "${IMSERVER_USER}:${IMSERVER_GROUP}" "${legacy_release_dir}"
  current_target="${legacy_release_dir}/bin/IMServer"
else
  current_target=""
fi

swift_runtime_dir="$(swift -print-target-info | sed -n 's/.*\"runtimeLibraryPaths\"[[:space:]]*:[[:space:]]*\\[\"\\([^\"]*\\)\".*/\\1/p' | head -1)"
if [[ -z "${swift_runtime_dir}" || ! -d "${swift_runtime_dir}" ]]; then
  swift_runtime_dir="$(dirname "$(find "${SWIFTLY_TOOLCHAINS_DIR:-/root/.local/share/swiftly/toolchains}" -name libswiftCore.so -print -quit 2>/dev/null)")"
fi
if [[ -n "${swift_runtime_dir}" && -d "${swift_runtime_dir}" ]]; then
  install -d -m 0755 /usr/local/lib/swift/linux
  cp -a "${swift_runtime_dir}"/*.so* /usr/local/lib/swift/linux/
  echo /usr/local/lib/swift/linux > /etc/ld.so.conf.d/swift-runtime.conf
  ldconfig
fi

if [[ -d "IMServer/Public" ]]; then
  rsync -a --delete "IMServer/Public/" "${release_dir}/Public/"
  chown -R "${IMSERVER_USER}:${IMSERVER_GROUP}" "${release_dir}/Public"
  if [[ -e "${IMSERVER_HOME}/Public" && ! -L "${IMSERVER_HOME}/Public" ]]; then
    mv "${IMSERVER_HOME}/Public" "${IMSERVER_HOME}/Public.legacy.$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  ln -sfn "${release_dir}/Public" "${IMSERVER_HOME}/Public"
fi

git_commit="$(git rev-parse --verify HEAD 2>/dev/null || printf 'unknown')"
git_branch="$(git branch --show-current 2>/dev/null || printf 'unknown')"
git_dirty="false"
if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
  git_dirty="true"
fi
swift_version="$(swift --version 2>/dev/null | head -1 || printf 'unknown')"
binary_sha256="$(sha256sum "${release_dir}/bin/IMServer" | awk '{ print $1 }')"

cat > "${release_dir}/release.env" <<EOF
IMSERVER_RELEASE_ID=${release_id}
IMSERVER_BUILD_CONFIGURATION=${build_configuration}
IMSERVER_BUILD_SOURCE=${ROOT}
IMSERVER_INSTALLED_AT=${installed_at}
IMSERVER_PREVIOUS_BINARY=${current_target}
IMSERVER_GIT_COMMIT=${git_commit}
IMSERVER_GIT_BRANCH=${git_branch}
IMSERVER_GIT_DIRTY=${git_dirty}
IMSERVER_BINARY_SHA256=${binary_sha256}
EOF

IMSERVER_RELEASE_ID_VALUE="${release_id}" \
IMSERVER_BUILD_CONFIGURATION_VALUE="${build_configuration}" \
IMSERVER_BUILD_SOURCE_VALUE="${ROOT}" \
IMSERVER_INSTALLED_AT_VALUE="${installed_at}" \
IMSERVER_PREVIOUS_BINARY_VALUE="${current_target}" \
IMSERVER_GIT_COMMIT_VALUE="${git_commit}" \
IMSERVER_GIT_BRANCH_VALUE="${git_branch}" \
IMSERVER_GIT_DIRTY_VALUE="${git_dirty}" \
IMSERVER_SWIFT_VERSION_VALUE="${swift_version}" \
IMSERVER_BINARY_SHA256_VALUE="${binary_sha256}" \
python3 - "${release_dir}/release-manifest.json" <<'PY'
import json
import os
import sys

manifest = {
    "schemaVersion": 1,
    "releaseID": os.environ["IMSERVER_RELEASE_ID_VALUE"],
    "buildConfiguration": os.environ["IMSERVER_BUILD_CONFIGURATION_VALUE"],
    "buildSource": os.environ["IMSERVER_BUILD_SOURCE_VALUE"],
    "installedAt": os.environ["IMSERVER_INSTALLED_AT_VALUE"],
    "previousBinary": os.environ["IMSERVER_PREVIOUS_BINARY_VALUE"],
    "git": {
        "commit": os.environ["IMSERVER_GIT_COMMIT_VALUE"],
        "branch": os.environ["IMSERVER_GIT_BRANCH_VALUE"],
        "dirty": os.environ["IMSERVER_GIT_DIRTY_VALUE"] == "true",
    },
    "swift": {
        "version": os.environ["IMSERVER_SWIFT_VERSION_VALUE"],
    },
    "artifacts": {
        "binary": {
            "path": "bin/IMServer",
            "sha256": os.environ["IMSERVER_BINARY_SHA256_VALUE"],
        },
    },
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\\n")
PY

(cd "${release_dir}" && sha256sum bin/IMServer release.env release-manifest.json > SHA256SUMS)
chown -R "${IMSERVER_USER}:${IMSERVER_GROUP}" "${release_dir}"

ln -sfn "${release_dir}" "${IMSERVER_CURRENT_LINK}"
ln -sfn "${release_dir}/bin/IMServer" "${IMSERVER_BIN_DIR}/IMServer"

echo "Installed IMServer release ${release_id} to ${release_dir}."
echo "Current binary: ${IMSERVER_BIN_DIR}/IMServer -> ${release_dir}/bin/IMServer"
