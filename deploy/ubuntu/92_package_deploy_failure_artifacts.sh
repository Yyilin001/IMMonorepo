#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOY_FAILURE_ARTIFACT_DIR="${DEPLOY_FAILURE_ARTIFACT_DIR:-}"
DEPLOY_FAILURE_ARTIFACT_PACKAGE="${DEPLOY_FAILURE_ARTIFACT_PACKAGE:-}"
DEPLOY_FAILURE_ARTIFACT_PACKAGE_SELF_TEST="${DEPLOY_FAILURE_ARTIFACT_PACKAGE_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

write_verify_script() {
  local verify_script="$1"
  local tarball_name="$2"
  local sha_name="$3"
  local expected_sha="$4"
  local receipt_name="$5"
  cat >"${verify_script}" <<SH
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
TARBALL="\${SCRIPT_DIR}/${tarball_name}"
SHA_FILE="\${SCRIPT_DIR}/${sha_name}"
RECEIPT="\${SCRIPT_DIR}/${receipt_name}"
EXPECTED_SHA="${expected_sha}"
VERIFY_SCRIPT="\$(basename "\${BASH_SOURCE[0]}")"
if [[ ! -f "\${TARBALL}" ]]; then
  printf 'deploy_failure_artifact_package_verify result=fail reason=tarball_missing path=%s\\n' "\${TARBALL}" >&2
  exit 1
fi
if [[ ! -f "\${SHA_FILE}" ]]; then
  printf 'deploy_failure_artifact_package_verify result=fail reason=sha_file_missing path=%s\\n' "\${SHA_FILE}" >&2
  exit 1
fi
if [[ ! -f "\${RECEIPT}" ]]; then
  printf 'deploy_failure_artifact_package_verify result=fail reason=receipt_missing path=%s\\n' "\${RECEIPT}" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual_sha="\$(sha256sum "\${TARBALL}" | awk '{print \$1}')"
else
  actual_sha="\$(shasum -a 256 "\${TARBALL}" | awk '{print \$1}')"
fi
sha_file_value="\$(awk '{print \$1}' "\${SHA_FILE}")"
if [[ "\${sha_file_value}" != "\${EXPECTED_SHA}" ]]; then
  printf 'deploy_failure_artifact_package_verify result=fail reason=sha_file_expected_mismatch expected=%s actual=%s\\n' "\${EXPECTED_SHA}" "\${sha_file_value}" >&2
  exit 1
fi
if [[ "\${actual_sha}" != "\${EXPECTED_SHA}" ]]; then
  printf 'deploy_failure_artifact_package_verify result=fail reason=tarball_expected_mismatch expected=%s actual=%s\\n' "\${EXPECTED_SHA}" "\${actual_sha}" >&2
  exit 1
fi
python3 - "\${RECEIPT}" "\$(basename "\${TARBALL}")" "\$(basename "\${SHA_FILE}")" "\${VERIFY_SCRIPT}" "\${EXPECTED_SHA}" <<'PY'
import json
import sys
from pathlib import Path

receipt_path, tarball_name, sha_file_name, verify_script_name, expected_sha = sys.argv[1:6]
try:
    payload = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=receipt_invalid error={exc}")

if payload.get("schemaVersion") != 1:
    raise SystemExit("deploy_failure_artifact_package_verify result=fail reason=receipt_schema_invalid")
package = payload.get("package")
if not isinstance(package, dict):
    raise SystemExit("deploy_failure_artifact_package_verify result=fail reason=receipt_package_missing")
if package.get("tarball") != tarball_name:
    raise SystemExit(
        "deploy_failure_artifact_package_verify result=fail "
        f"reason=receipt_tarball_mismatch expected={tarball_name} actual={package.get('tarball')}"
    )
if package.get("sha256File") != sha_file_name:
    raise SystemExit(
        "deploy_failure_artifact_package_verify result=fail "
        f"reason=receipt_sha_file_mismatch expected={sha_file_name} actual={package.get('sha256File')}"
    )
if package.get("verifyScript") != verify_script_name:
    raise SystemExit(
        "deploy_failure_artifact_package_verify result=fail "
        f"reason=receipt_verify_script_mismatch expected={verify_script_name} actual={package.get('verifyScript')}"
    )
if package.get("sha256") != expected_sha:
    raise SystemExit(
        "deploy_failure_artifact_package_verify result=fail "
        f"reason=receipt_sha_mismatch expected={expected_sha} actual={package.get('sha256')}"
    )
if payload.get("firstCommand") != f"./{verify_script_name}":
    raise SystemExit(
        "deploy_failure_artifact_package_verify result=fail "
        f"reason=receipt_first_command_invalid expected=./{verify_script_name} actual={payload.get('firstCommand')}"
    )
PY
tmp_dir="\$(mktemp -d)"
trap 'rm -rf "\${tmp_dir}"' EXIT
safe_extract_archive() {
  local output_dir="\$1"
  python3 - "\${TARBALL}" "\${output_dir}" <<'PY'
import os
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

archive_path = Path(sys.argv[1])
extract_dir = Path(sys.argv[2])
max_member_bytes = int(os.environ.get("DEPLOY_FAILURE_ARTIFACT_ARCHIVE_MEMBER_MAX_BYTES", str(64 * 1024 * 1024)))
max_total_bytes = int(os.environ.get("DEPLOY_FAILURE_ARTIFACT_ARCHIVE_TOTAL_MAX_BYTES", str(256 * 1024 * 1024)))
root = extract_dir.resolve()
seen = set()
total = 0
try:
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise SystemExit("deploy_failure_artifact_package_verify result=fail reason=archive_empty")
        for member in members:
            name = str(member.name or "")
            path = PurePosixPath(name)
            normalized = path.as_posix()
            if not name or name.startswith("/") or "\\\\" in name or path.is_absolute():
                raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_unsafe_member path={name or '-'}")
            if any(part in {"", ".", ".."} for part in path.parts):
                raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_unsafe_member path={name}")
            if normalized in seen:
                raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_duplicate_member path={name}")
            if member.issym() or member.islnk():
                raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_unsafe_link path={name}")
            if not (member.isfile() or member.isdir()):
                raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_unsupported_member path={name}")
            if member.size < 0:
                raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_member_size_invalid path={name} size={member.size}")
            if member.size > max_member_bytes:
                raise SystemExit(
                    "deploy_failure_artifact_package_verify result=fail "
                    f"reason=archive_member_too_large path={name} size={member.size} max={max_member_bytes}"
                )
            total += member.size
            if total > max_total_bytes:
                raise SystemExit(
                    "deploy_failure_artifact_package_verify result=fail "
                    f"reason=archive_total_too_large size={total} max={max_total_bytes}"
                )
            target = (root / normalized).resolve()
            try:
                target.relative_to(root)
            except ValueError as exc:
                raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_unsafe_member path={name}") from exc
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(member.mode & 0o777)
                seen.add(normalized)
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_member_read_failed path={name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)
            seen.add(normalized)
except tarfile.TarError as exc:
    raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=archive_invalid error={exc}")
print(f"deploy_failure_artifact_package_verify step=archive_safety result=pass members={len(seen)}")
PY
}
safe_extract_archive "\${tmp_dir}"
extracted_count="\$(find "\${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [[ "\${extracted_count}" != "1" ]]; then
  printf 'deploy_failure_artifact_package_verify result=fail reason=archive_extract_unexpected_dir_count count=%s\\n' "\${extracted_count}" >&2
  exit 1
fi
artifact_dir="\$(find "\${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [[ ! -f "\${artifact_dir}/failure-manifest.json" ]]; then
  printf 'deploy_failure_artifact_package_verify result=fail reason=manifest_missing_after_extract\\n' >&2
  exit 1
fi
python3 - "\${artifact_dir}" <<'PY'
import json
import sys
from pathlib import Path

artifact_dir = Path(sys.argv[1]).resolve()
manifest = artifact_dir / "failure-manifest.json"
payload = json.loads(manifest.read_text(encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("deploy_failure_artifact_package_verify result=fail reason=manifest_schema_invalid")
if not payload.get("deployID") or not payload.get("phase"):
    raise SystemExit("deploy_failure_artifact_package_verify result=fail reason=manifest_identity_missing")
required = [
    "summary.txt",
    "entrypoint-diagnose.log",
    "diagnostics-bundle.log",
    "node-access-rescue-artifact.log",
    "failure-artifacts-verify.log",
]
for name in required:
    if not (artifact_dir / name).is_file():
        raise SystemExit(f"deploy_failure_artifact_package_verify result=fail reason=required_file_missing file={name}")
PY
printf 'deploy_failure_artifact_package_verify result=pass tarball=%s\\n' "\${TARBALL}"
SH
  chmod +x "${verify_script}"
}

package_artifacts() {
  local artifact_dir="$1"
  local output_tarball="${2:-}"
  local parent base tarball sha_file verify_script receipt readme expected_sha

  if [[ ! -d "${artifact_dir}" ]]; then
    printf 'deploy_failure_artifact_package result=fail reason=artifact_dir_missing dir=%s\n' "${artifact_dir}" >&2
    return 1
  fi
  DEPLOY_FAILURE_ARTIFACT_DIR="${artifact_dir}" \
    DEPLOY_FAILURE_ARTIFACTS_REQUIRE_DIAGNOSTICS_BUNDLE=false \
    DEPLOY_FAILURE_ARTIFACTS_REQUIRE_RESCUE=false \
    bash "${SCRIPT_DIR}/91_verify_deploy_failure_artifacts.sh" >/dev/null

  artifact_dir="$(cd "${artifact_dir}" && pwd)"
  parent="$(dirname "${artifact_dir}")"
  base="$(basename "${artifact_dir}")"
  tarball="${output_tarball:-${artifact_dir}.tar.gz}"
  sha_file="${tarball}.sha256"
  verify_script="${tarball}.verify.sh"
  receipt="${tarball}.receipt.json"
  readme="${tarball}.README.md"
  rm -f "${tarball}" "${sha_file}" "${verify_script}" "${receipt}" "${readme}"
  (cd "${parent}" && tar -czf "${tarball}" "${base}")
  expected_sha="$(sha256_file "${tarball}")"
  printf '%s  %s\n' "${expected_sha}" "$(basename "${tarball}")" >"${sha_file}"
  write_verify_script "${verify_script}" "$(basename "${tarball}")" "$(basename "${sha_file}")" "${expected_sha}" "$(basename "${receipt}")"
  python3 - "${artifact_dir}" "${tarball}" "${sha_file}" "${verify_script}" "${receipt}" <<'PY'
import json
import sys
import time
from pathlib import Path

artifact_dir, tarball, sha_file, verify_script, receipt = map(Path, sys.argv[1:6])
payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "artifactDir": str(artifact_dir),
    "package": {
        "tarball": tarball.name,
        "sha256": sha_file.read_text(encoding="utf-8").split()[0],
        "sha256File": sha_file.name,
        "verifyScript": verify_script.name,
    },
    "firstCommand": f"./{verify_script.name}",
}
receipt.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  cat >"${readme}" <<EOF
# Deploy Failure Artifact Package

Run the verifier before extracting or sharing this package:

\`\`\`bash
./$(basename "${verify_script}")
\`\`\`

- archive: \`$(basename "${tarball}")\`
- sha256: \`${expected_sha}\`
- receipt: \`$(basename "${receipt}")\`
EOF
  "${verify_script}" >/dev/null
  printf 'deploy_failure_artifact_package result=pass tarball=%s sha256=%s verify=%s receipt=%s\n' \
    "${tarball}" "${sha_file}" "${verify_script}" "${receipt}"
}

run_self_test() {
  local tmpdir artifact_dir tarball
  tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" EXIT
  artifact_dir="${tmpdir}/failure"
  mkdir -p "${artifact_dir}/diagnostics"
  printf 'summary\n' >"${artifact_dir}/summary.txt"
  printf 'entrypoint\n' >"${artifact_dir}/entrypoint-diagnose.log"
  printf 'diagnostics\n' >"${artifact_dir}/diagnostics-bundle.log"
  printf 'rescue\n' >"${artifact_dir}/node-access-rescue-artifact.log"
  printf 'verify\n' >"${artifact_dir}/failure-artifacts-verify.log"
  printf 'bundle\n' >"${artifact_dir}/diagnostics/imserver-diagnostics-self-test.tar.gz"
  python3 - "${artifact_dir}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

artifact_dir = Path(sys.argv[1]).resolve()

def entry(path: Path) -> dict:
    return {
        "path": str(path),
        "present": path.exists(),
        "bytes": path.stat().st_size if path.is_file() else 0,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "",
    }

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "deployID": "self-test",
    "phase": "self-test-phase",
    "publicBaseURL": "http://deploy-self-test.local:8080",
    "artifactDir": str(artifact_dir),
    "files": {
        "summary": entry(artifact_dir / "summary.txt"),
        "entrypointDiagnoseLog": entry(artifact_dir / "entrypoint-diagnose.log"),
        "diagnosticsBundleLog": entry(artifact_dir / "diagnostics-bundle.log"),
        "nodeAccessRescueLog": entry(artifact_dir / "node-access-rescue-artifact.log"),
    },
    "diagnosticsBundles": [entry(artifact_dir / "diagnostics/imserver-diagnostics-self-test.tar.gz")],
    "nodeAccessRescue": {
        "present": False,
        "summary": {"path": str(artifact_dir / "current-node-access-rescue/summary.txt"), "present": False, "bytes": 0, "sha256": ""},
        "plan": {"path": str(artifact_dir / "current-node-access-rescue/entrypoint-rescue-plan.json"), "present": False, "bytes": 0, "sha256": ""},
        "archive": {"path": str(artifact_dir / "current-node-access-rescue.tar.gz"), "present": False, "bytes": 0, "sha256": ""},
    },
    "verification": {
        "verifier": "91_verify_deploy_failure_artifacts.sh",
        "log": str(artifact_dir / "failure-artifacts-verify.log"),
        "logPresent": True,
        "logBytes": (artifact_dir / "failure-artifacts-verify.log").stat().st_size,
        "logChecksummed": False,
        "note": "self-test",
    },
}
(artifact_dir / "failure-manifest.json").write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  tarball="${tmpdir}/failure.tar.gz"
  package_artifacts "${artifact_dir}" "${tarball}" >/dev/null
  [[ -f "${tarball}" && -f "${tarball}.sha256" && -x "${tarball}.verify.sh" && -f "${tarball}.receipt.json" && -f "${tarball}.README.md" ]] || {
    printf 'deploy_failure_artifact_package_self_test result=fail reason=package_sidecars_missing\n' >&2
    return 1
  }
  "${tarball}.verify.sh" >"${tmpdir}/verify.log"
  grep -q 'deploy_failure_artifact_package_verify result=pass' "${tmpdir}/verify.log" || {
    printf 'deploy_failure_artifact_package_self_test result=fail reason=verify_script_failed\n' >&2
    return 1
  }
  cp "${tarball}.receipt.json" "${tmpdir}/receipt.good.json"
  python3 - "${tarball}.receipt.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["package"]["sha256"] = "bad"
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if "${tarball}.verify.sh" >"${tmpdir}/tampered-receipt.log" 2>&1; then
    printf 'deploy_failure_artifact_package_self_test result=fail reason=tampered_receipt_passed\n' >&2
    return 1
  fi
  grep -q 'receipt_sha_mismatch' "${tmpdir}/tampered-receipt.log" || {
    printf 'deploy_failure_artifact_package_self_test result=fail reason=tampered_receipt_reason_missing\n' >&2
    return 1
  }
  cp "${tmpdir}/receipt.good.json" "${tarball}.receipt.json"
  printf 'tampered\n' >>"${tarball}.sha256"
  if "${tarball}.verify.sh" >"${tmpdir}/tampered.log" 2>&1; then
    printf 'deploy_failure_artifact_package_self_test result=fail reason=tampered_sha_passed\n' >&2
    return 1
  fi
  grep -q 'sha_file_expected_mismatch' "${tmpdir}/tampered.log" || {
    printf 'deploy_failure_artifact_package_self_test result=fail reason=tampered_sha_reason_missing\n' >&2
    return 1
  }
  printf '%s  failure.tar.gz\n' "$(sha256_file "${tarball}")" >"${tarball}.sha256"
  if DEPLOY_FAILURE_ARTIFACT_ARCHIVE_MEMBER_MAX_BYTES=1 "${tarball}.verify.sh" >"${tmpdir}/oversized-member.log" 2>&1; then
    printf 'deploy_failure_artifact_package_self_test result=fail reason=oversized_archive_member_accepted\n' >&2
    return 1
  fi
  grep -q 'archive_member_too_large' "${tmpdir}/oversized-member.log" || {
    printf 'deploy_failure_artifact_package_self_test result=fail reason=oversized_archive_member_reason_missing\n' >&2
    return 1
  }
  if DEPLOY_FAILURE_ARTIFACT_ARCHIVE_MEMBER_MAX_BYTES=1048576 DEPLOY_FAILURE_ARTIFACT_ARCHIVE_TOTAL_MAX_BYTES=1 "${tarball}.verify.sh" >"${tmpdir}/oversized-total.log" 2>&1; then
    printf 'deploy_failure_artifact_package_self_test result=fail reason=oversized_archive_total_accepted\n' >&2
    return 1
  fi
  grep -q 'archive_total_too_large' "${tmpdir}/oversized-total.log" || {
    printf 'deploy_failure_artifact_package_self_test result=fail reason=oversized_archive_total_reason_missing\n' >&2
    return 1
  }
  local unsafe_dir unsafe_sha
  unsafe_dir="${tmpdir}/unsafe"
  mkdir -p "${unsafe_dir}"
  python3 - "${unsafe_dir}/failure.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    data = b"unsafe"
    info = tarfile.TarInfo("../outside.txt")
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))
PY
  unsafe_sha="$(sha256_file "${unsafe_dir}/failure.tar.gz")"
  printf '%s  failure.tar.gz\n' "${unsafe_sha}" >"${unsafe_dir}/failure.tar.gz.sha256"
  python3 - "${unsafe_dir}/failure.tar.gz.receipt.json" "${unsafe_sha}" <<'PY'
import json
import sys
from pathlib import Path

receipt_path = Path(sys.argv[1])
sha = sys.argv[2]
payload = {
    "schemaVersion": 1,
    "package": {
        "tarball": "failure.tar.gz",
        "sha256": sha,
        "sha256File": "failure.tar.gz.sha256",
        "verifyScript": "failure.tar.gz.verify.sh",
    },
    "firstCommand": "./failure.tar.gz.verify.sh",
}
receipt_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  write_verify_script "${unsafe_dir}/failure.tar.gz.verify.sh" "failure.tar.gz" "failure.tar.gz.sha256" "${unsafe_sha}" "failure.tar.gz.receipt.json"
  if "${unsafe_dir}/failure.tar.gz.verify.sh" >"${tmpdir}/unsafe.log" 2>&1; then
    printf 'deploy_failure_artifact_package_self_test result=fail reason=unsafe_archive_passed\n' >&2
    return 1
  fi
  grep -q 'archive_unsafe_member' "${tmpdir}/unsafe.log" || {
    printf 'deploy_failure_artifact_package_self_test result=fail reason=unsafe_archive_reason_missing\n' >&2
    return 1
  }
  printf 'deploy_failure_artifact_package_self_test result=pass\n'
}

if bool_enabled "${DEPLOY_FAILURE_ARTIFACT_PACKAGE_SELF_TEST}"; then
  run_self_test
  exit 0
fi

if [[ -z "${DEPLOY_FAILURE_ARTIFACT_DIR}" ]]; then
  printf 'deploy_failure_artifact_package result=fail reason=artifact_dir_env_missing\n' >&2
  exit 1
fi

package_artifacts "${DEPLOY_FAILURE_ARTIFACT_DIR}" "${DEPLOY_FAILURE_ARTIFACT_PACKAGE}"
