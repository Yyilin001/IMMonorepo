#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOY_FAILURE_ARTIFACT_DIR="${DEPLOY_FAILURE_ARTIFACT_DIR:-}"
DEPLOY_FAILURE_ARTIFACTS_REQUIRE_DIAGNOSTICS_BUNDLE="${DEPLOY_FAILURE_ARTIFACTS_REQUIRE_DIAGNOSTICS_BUNDLE:-true}"
DEPLOY_FAILURE_ARTIFACTS_REQUIRE_RESCUE="${DEPLOY_FAILURE_ARTIFACTS_REQUIRE_RESCUE:-false}"
DEPLOY_FAILURE_ARTIFACTS_VERIFY_SELF_TEST="${DEPLOY_FAILURE_ARTIFACTS_VERIFY_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

verify_artifacts() {
  local artifact_dir="$1"
  local manifest="${artifact_dir}/failure-manifest.json"
  if [[ ! -d "${artifact_dir}" ]]; then
    printf 'deploy_failure_artifacts_verify result=fail reason=artifact_dir_missing dir=%s\n' "${artifact_dir}" >&2
    return 1
  fi
  if [[ ! -f "${manifest}" ]]; then
    printf 'deploy_failure_artifacts_verify result=fail reason=manifest_missing path=%s\n' "${manifest}" >&2
    return 1
  fi
  python3 - \
    "${artifact_dir}" \
    "${manifest}" \
    "${DEPLOY_FAILURE_ARTIFACTS_REQUIRE_DIAGNOSTICS_BUNDLE}" \
    "${DEPLOY_FAILURE_ARTIFACTS_REQUIRE_RESCUE}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

artifact_dir = Path(sys.argv[1]).resolve()
manifest = Path(sys.argv[2]).resolve()
require_diagnostics = sys.argv[3].lower() in {"1", "true", "yes", "on"}
require_rescue = sys.argv[4].lower() in {"1", "true", "yes", "on"}


def fail(reason: str, **fields: object) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"deploy_failure_artifacts_verify result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def inside_artifact_dir(path: Path) -> bool:
    try:
        path.resolve().relative_to(artifact_dir)
        return True
    except ValueError:
        return False


def verify_file_entry(name: str, entry: object, required: bool = True) -> bool:
    if not isinstance(entry, dict):
        if required:
            fail("file_entry_invalid", name=name)
        return False
    present = bool(entry.get("present"))
    raw_path = str(entry.get("path") or "")
    if not raw_path:
        if required:
            fail("file_entry_path_missing", name=name)
        return False
    path = Path(raw_path)
    if not path.is_absolute():
        path = artifact_dir / path
    if not inside_artifact_dir(path):
        fail("file_entry_outside_artifact_dir", name=name, path=path)
    if present:
        if not path.is_file():
            fail("file_entry_missing", name=name, path=path)
        expected_bytes = int(entry.get("bytes") or 0)
        actual_bytes = path.stat().st_size
        if expected_bytes != actual_bytes:
            fail("file_entry_size_mismatch", name=name, expected=expected_bytes, actual=actual_bytes)
        expected_sha256 = str(entry.get("sha256") or "")
        if expected_sha256:
            hasher = hashlib.sha256()
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    hasher.update(chunk)
            actual_sha256 = hasher.hexdigest()
            if expected_sha256 != actual_sha256:
                fail("file_entry_sha256_mismatch", name=name, expected=expected_sha256, actual=actual_sha256)
        return True
    if required:
        fail("file_entry_not_present", name=name, path=path)
    return False


with manifest.open(encoding="utf-8") as handle:
    payload = json.load(handle)

if payload.get("schemaVersion") != 1:
    fail("manifest_schema_invalid", value=payload.get("schemaVersion"))
if not str(payload.get("deployID") or ""):
    fail("deploy_id_missing")
if not str(payload.get("phase") or ""):
    fail("phase_missing")
manifest_artifact_dir = Path(str(payload.get("artifactDir") or ""))
if not manifest_artifact_dir:
    fail("artifact_dir_missing_in_manifest")
if manifest_artifact_dir.resolve() != artifact_dir:
    fail("artifact_dir_mismatch", manifest=manifest_artifact_dir, actual=artifact_dir)

files = payload.get("files") or {}
if not isinstance(files, dict):
    fail("files_invalid")
for key in ("summary", "entrypointDiagnoseLog", "diagnosticsBundleLog", "nodeAccessRescueLog"):
    verify_file_entry(key, files.get(key), required=True)

diagnostics = payload.get("diagnosticsBundles") or []
if require_diagnostics and not diagnostics:
    fail("diagnostics_bundle_missing")
for index, entry in enumerate(diagnostics):
    verify_file_entry(f"diagnosticsBundle[{index}]", entry, required=True)

rescue = payload.get("nodeAccessRescue") or {}
if not isinstance(rescue, dict):
    fail("node_access_rescue_invalid")
rescue_present = bool(rescue.get("present"))
if require_rescue and not rescue_present:
    fail("node_access_rescue_missing")
if rescue_present:
    verify_file_entry("nodeAccessRescue.summary", rescue.get("summary"), required=True)
    verify_file_entry("nodeAccessRescue.plan", rescue.get("plan"), required=True)
    verify_file_entry("nodeAccessRescue.archive", rescue.get("archive"), required=False)

verification = payload.get("verification") or {}
if verification:
    if not isinstance(verification, dict):
        fail("verification_invalid")
    if str(verification.get("verifier") or "") != "91_verify_deploy_failure_artifacts.sh":
        fail("verification_verifier_invalid", value=verification.get("verifier") or "-")
    log_path = Path(str(verification.get("log") or ""))
    if not log_path.is_absolute():
        log_path = artifact_dir / log_path
    if not inside_artifact_dir(log_path):
        fail("verification_log_outside_artifact_dir", path=log_path)
    if bool(verification.get("logPresent")) and not log_path.is_file():
        fail("verification_log_missing", path=log_path)
    if bool(verification.get("logPresent")):
        expected_log_bytes = int(verification.get("logBytes") or 0)
        actual_log_bytes = log_path.stat().st_size
        if expected_log_bytes != actual_log_bytes:
            fail("verification_log_size_mismatch", expected=expected_log_bytes, actual=actual_log_bytes)
    if bool(verification.get("logChecksummed")):
        fail("verification_log_must_not_be_self_checksummed")

print(
    "deploy_failure_artifacts_verify result=pass "
    f"dir={artifact_dir} diagnosticsBundles={len(diagnostics)} rescue={str(rescue_present).lower()}"
)
PY
}

run_self_test() {
  local tmpdir artifact_dir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" EXIT
  artifact_dir="${tmpdir}/artifacts"
  mkdir -p "${artifact_dir}/diagnostics"
  printf 'summary\n' >"${artifact_dir}/summary.txt"
  printf 'entrypoint\n' >"${artifact_dir}/entrypoint-diagnose.log"
  printf 'diagnostics\n' >"${artifact_dir}/diagnostics-bundle.log"
  printf 'rescue skipped\n' >"${artifact_dir}/node-access-rescue-artifact.log"
  printf 'bundle\n' >"${artifact_dir}/diagnostics/imserver-diagnostics-self-test.tar.gz"
  python3 - "${artifact_dir}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

artifact_dir = Path(sys.argv[1]).resolve()

def entry(path: Path) -> dict:
    digest = ""
    if path.is_file():
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return {
        "path": str(path),
        "present": path.exists(),
        "bytes": path.stat().st_size if path.is_file() else 0,
        "sha256": digest,
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
        "logBytes": 0,
        "logChecksummed": False,
        "note": "self-test",
    },
}
(artifact_dir / "failure-manifest.json").write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  : >"${artifact_dir}/failure-artifacts-verify.log"
  verify_artifacts "${artifact_dir}" >/dev/null
  printf 'tampered\n' >>"${artifact_dir}/summary.txt"
  if verify_artifacts "${artifact_dir}" >"${tmpdir}/tampered.log" 2>&1; then
    printf 'deploy_failure_artifacts_verify_self_test result=fail reason=tampered_manifest_passed\n' >&2
    return 1
  fi
  grep -q 'file_entry_size_mismatch' "${tmpdir}/tampered.log" || {
    printf 'deploy_failure_artifacts_verify_self_test result=fail reason=tampered_reason_missing\n' >&2
    return 1
  }
  python3 - "${artifact_dir}/failure-manifest.json" "${artifact_dir}/summary.txt" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
payload = json.loads(manifest_path.read_text(encoding="utf-8"))
payload["files"]["summary"]["bytes"] = summary_path.stat().st_size
manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if verify_artifacts "${artifact_dir}" >"${tmpdir}/tampered-sha.log" 2>&1; then
    printf 'deploy_failure_artifacts_verify_self_test result=fail reason=tampered_sha_passed\n' >&2
    return 1
  fi
  grep -q 'file_entry_sha256_mismatch' "${tmpdir}/tampered-sha.log" || {
    printf 'deploy_failure_artifacts_verify_self_test result=fail reason=tampered_sha_reason_missing\n' >&2
    return 1
  }
  printf 'deploy_failure_artifacts_verify_self_test result=pass\n'
}

if bool_enabled "${DEPLOY_FAILURE_ARTIFACTS_VERIFY_SELF_TEST}"; then
  run_self_test
  exit 0
fi

if [[ -z "${DEPLOY_FAILURE_ARTIFACT_DIR}" ]]; then
  printf 'deploy_failure_artifacts_verify result=fail reason=artifact_dir_env_missing\n' >&2
  exit 1
fi

verify_artifacts "${DEPLOY_FAILURE_ARTIFACT_DIR}"
