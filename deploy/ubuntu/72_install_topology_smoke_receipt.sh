#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
export COPYFILE_DISABLE="${COPYFILE_DISABLE:-1}"

TOPOLOGY_SMOKE_RECEIPT_SOURCE="${TOPOLOGY_SMOKE_RECEIPT_SOURCE:-${1:-IMServer/reports/latest-production-smoke.json}}"
TOPOLOGY_SMOKE_INSTALL_DIR="${TOPOLOGY_SMOKE_INSTALL_DIR:-/var/lib/imserver/production-smoke}"
TOPOLOGY_SMOKE_LATEST_RECEIPT="${TOPOLOGY_SMOKE_LATEST_RECEIPT:-${TOPOLOGY_SMOKE_INSTALL_DIR}/latest-production-smoke.json}"
TOPOLOGY_SMOKE_MAX_AGE_SECONDS="${TOPOLOGY_SMOKE_MAX_AGE_SECONDS:-86400}"
TOPOLOGY_SMOKE_REQUIRE_ROOT="${TOPOLOGY_SMOKE_REQUIRE_ROOT:-true}"
TOPOLOGY_SMOKE_OWNER="${TOPOLOGY_SMOKE_OWNER:-root}"
TOPOLOGY_SMOKE_GROUP="${TOPOLOGY_SMOKE_GROUP:-root}"
TOPOLOGY_SMOKE_DIR_MODE="${TOPOLOGY_SMOKE_DIR_MODE:-0755}"
TOPOLOGY_SMOKE_FILE_MODE="${TOPOLOGY_SMOKE_FILE_MODE:-0644}"
TOPOLOGY_SMOKE_INSTALL_SELF_TEST="${TOPOLOGY_SMOKE_INSTALL_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

repo_path() {
  local relative="$1"
  printf '%s/%s\n' "$(repo_root)" "${relative}"
}

verify_receipt() {
  local receipt="$1"
  shift
  python3 "$(repo_path "IMServer/scripts/verify_production_smoke.py")" \
    --receipt-json "${receipt}" \
    --require-pass \
    "$@" \
    --max-age-seconds "${TOPOLOGY_SMOKE_MAX_AGE_SECONDS}"
}

install_topology_smoke_receipt() {
  local source_receipt="$1"
  local install_dir="$2"
  local latest_receipt="$3"
  local installed_receipt

  if [[ ! -f "${source_receipt}" ]]; then
    printf 'topology_smoke_receipt_install result=fail reason=source_receipt_missing path=%s\n' "${source_receipt}" >&2
    return 1
  fi

  verify_receipt "${source_receipt}" --require-artifacts-exist >/dev/null || return 1
  install -d -m "${TOPOLOGY_SMOKE_DIR_MODE}" "${install_dir}" "${install_dir}/artifacts" || return 1

  if ! installed_receipt="$(
    python3 - "${source_receipt}" "${install_dir}" "${latest_receipt}" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1]).resolve()
install_dir = Path(sys.argv[2]).resolve()
latest = Path(sys.argv[3]).resolve()
payload = json.loads(source.read_text(encoding="utf-8"))
generated_at = str(payload.get("generatedAt") or "unknown")
release = re.sub(r"[^0-9A-Za-z_.-]+", "-", generated_at).strip("-") or "unknown"
release_dir = install_dir / "artifacts" / release
release_dir.mkdir(parents=True, exist_ok=True)
latest.parent.mkdir(parents=True, exist_ok=True)

artifacts = payload.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit("topology_smoke_receipt_install result=fail reason=artifacts_invalid")

rewritten = {}
used = set()
for key, value in sorted(artifacts.items()):
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(
            "topology_smoke_receipt_install result=fail "
            f"reason=artifact_path_invalid field={key}"
        )
    src = Path(value).resolve()
    if not src.is_file():
        raise SystemExit(
            "topology_smoke_receipt_install result=fail "
            f"reason=artifact_missing field={key} path={value}"
        )
    safe_key = re.sub(r"[^0-9A-Za-z_.-]+", "-", str(key)).strip("-") or "artifact"
    suffix = src.suffix
    name = f"{safe_key}{suffix}"
    index = 1
    while name in used:
        name = f"{safe_key}-{index}{suffix}"
        index += 1
    used.add(name)
    dst = release_dir / name
    shutil.copy2(src, dst)
    rewritten[key] = str(dst)

payload["artifacts"] = rewritten
installed = latest
installed.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(installed)
PY
  )"; then
    return 1
  fi

  find "${install_dir}" -type d -exec chmod "${TOPOLOGY_SMOKE_DIR_MODE}" {} + || return 1
  find "${install_dir}" -type f -exec chmod "${TOPOLOGY_SMOKE_FILE_MODE}" {} + || return 1
  chmod "${TOPOLOGY_SMOKE_FILE_MODE}" "${installed_receipt}" || return 1
  if command -v chown >/dev/null 2>&1; then
    chown -R "${TOPOLOGY_SMOKE_OWNER}:${TOPOLOGY_SMOKE_GROUP}" "${install_dir}" 2>/dev/null || true
  fi

  verify_receipt "${installed_receipt}" --require-artifacts-exist >/dev/null || return 1
  printf 'topology_smoke_receipt_install result=pass source=%s receipt=%s installDir=%s maxAgeSeconds=%s\n' \
    "${source_receipt}" \
    "${installed_receipt}" \
    "${install_dir}" \
    "${TOPOLOGY_SMOKE_MAX_AGE_SECONDS}"
}

write_test_receipt() {
  local receipt="$1"
  local artifact_dir="$2"
  python3 - "${receipt}" "${artifact_dir}" <<'PY'
import json
import sys
import time
from pathlib import Path

receipt = Path(sys.argv[1])
artifact_dir = Path(sys.argv[2])
artifact_dir.mkdir(parents=True, exist_ok=True)
artifacts = {}
for name in ("markdownReport", "stateFile", "composePs", "composeLog", "outboxInspect"):
    artifact = artifact_dir / f"{name}.txt"
    artifact.write_text("ok\n", encoding="utf-8")
    artifacts[name] = str(artifact)
checks = [
    "auth_register_or_login",
    "changes_projection",
    "conversation_create",
    "docker_compose_runtime_roles",
    "http_health",
    "message_write",
    "messages_since",
    "metrics_secret",
    "outbox_recovery",
    "runtime_services_health",
    "summary_projection",
]
payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": "passed",
    "exitCode": 0,
    "environment": "production-smoke",
    "project": "imserver-production-smoke",
    "runtimeEvidence": True,
    "composeFile": "docker-compose.production-smoke.yml",
    "endpoints": {
        "gateway": "http://127.0.0.1:8080",
        "command": "http://127.0.0.1:8081",
        "query": "http://127.0.0.1:8082",
    },
    "conversations": {
        "directConversationID": "direct-1",
        "groupConversationID": "group-1",
    },
    "source": {
        "gitCommit": "abc123",
        "gitBranch": "main",
        "gitDirty": False,
    },
    "artifacts": artifacts,
    "checks": [{"name": name, "status": "passed"} for name in checks],
}
receipt.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

run_self_test() {
  local tmpdir receipt output installed_state
  tmpdir="$(mktemp -d)"
  receipt="${tmpdir}/source/latest-production-smoke.json"
  write_test_receipt "${receipt}" "${tmpdir}/source/artifacts"

  TOPOLOGY_SMOKE_REQUIRE_ROOT=false
  TOPOLOGY_SMOKE_INSTALL_DIR="${tmpdir}/installed"
  TOPOLOGY_SMOKE_LATEST_RECEIPT="${tmpdir}/installed/latest-production-smoke.json"
  TOPOLOGY_SMOKE_MAX_AGE_SECONDS=60
  output="$(install_topology_smoke_receipt "${receipt}" "${TOPOLOGY_SMOKE_INSTALL_DIR}" "${TOPOLOGY_SMOKE_LATEST_RECEIPT}")" || {
    printf 'topology_smoke_receipt_install_self_test result=fail reason=valid_install_failed\n' >&2
    rm -rf "${tmpdir}"
    return 1
  }
  grep -q 'topology_smoke_receipt_install result=pass' <<<"${output}" || {
    printf 'topology_smoke_receipt_install_self_test result=fail reason=pass_output_missing output=%s\n' "${output}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  installed_state="$(
    python3 - "${TOPOLOGY_SMOKE_LATEST_RECEIPT}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["artifacts"]["stateFile"])
PY
  )"
  case "${installed_state}" in
    "${TOPOLOGY_SMOKE_INSTALL_DIR}/artifacts/"*|"/private${TOPOLOGY_SMOKE_INSTALL_DIR}/artifacts/"*) ;;
    *)
    printf 'topology_smoke_receipt_install_self_test result=fail reason=artifact_path_not_rewritten path=%s\n' "${installed_state}" >&2
    rm -rf "${tmpdir}"
    return 1
      ;;
  esac

  python3 - "${receipt}" "${tmpdir}/source/artifacts/missing-compose-log.txt" <<'PY'
import json
import sys
from pathlib import Path

receipt = Path(sys.argv[1])
missing = Path(sys.argv[2])
payload = json.loads(receipt.read_text(encoding="utf-8"))
payload["artifacts"]["composeLog"] = str(missing)
receipt.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  if python3 - "${receipt}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
raise SystemExit(0 if Path(payload["artifacts"]["composeLog"]).is_file() else 1)
PY
  then
    printf 'topology_smoke_receipt_install_self_test result=fail reason=missing_artifact_still_exists\n' >&2
    rm -rf "${tmpdir}"
    return 1
  fi
  if output="$(install_topology_smoke_receipt "${receipt}" "${tmpdir}/missing-installed" "${tmpdir}/missing-installed/latest-production-smoke.json" 2>&1)"; then
    printf 'topology_smoke_receipt_install_self_test result=fail reason=missing_artifact_accepted\n' >&2
    rm -rf "${tmpdir}"
    return 1
  fi
  grep -q 'artifact_missing' <<<"${output}" || {
    printf 'topology_smoke_receipt_install_self_test result=fail reason=missing_artifact_reason_absent output=%s\n' "${output}" >&2
    rm -rf "${tmpdir}"
    return 1
  }

  rm -rf "${tmpdir}"
  printf 'topology_smoke_receipt_install_self_test result=pass\n'
}

if bool_enabled "${TOPOLOGY_SMOKE_INSTALL_SELF_TEST}"; then
  run_self_test
  exit 0
fi

if bool_enabled "${TOPOLOGY_SMOKE_REQUIRE_ROOT}"; then
  require_root
fi

install_topology_smoke_receipt "${TOPOLOGY_SMOKE_RECEIPT_SOURCE}" "${TOPOLOGY_SMOKE_INSTALL_DIR}" "${TOPOLOGY_SMOKE_LATEST_RECEIPT}"
