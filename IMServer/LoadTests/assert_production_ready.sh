#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_TARGET_POLICY="${PRODUCTION_TARGET_POLICY:-${SCRIPT_DIR}/production_target_policy.py}"
PRODUCTION_READINESS_RESULT_ROOT="${PRODUCTION_READINESS_RESULT_ROOT:-${RESULT_ROOT:-${SCRIPT_DIR}/results}}"

BASE_URL="${BASE_URL:-${PUBLIC_BASE_URL:-${IM_PUBLIC_BASE_URL:-}}}"
TCP_HOST="${TCP_HOST:-${IM_PUBLIC_HOST:-}}"
TCP_PORT="${TCP_PORT:-${IM_TCP_PORT:-9000}}"

CURRENT_PRODUCTION_READINESS_JSON_EXPLICIT=false
if [[ "${CURRENT_PRODUCTION_READINESS_JSON+x}" == "x" ]]; then
  CURRENT_PRODUCTION_READINESS_JSON_EXPLICIT=true
fi
CURRENT_PRODUCTION_READINESS_JSON="${CURRENT_PRODUCTION_READINESS_JSON:-}"
CURRENT_PRODUCTION_EVIDENCE_DIR="${CURRENT_PRODUCTION_EVIDENCE_DIR:-}"
CURRENT_PRODUCTION_READINESS_VERIFIER="${CURRENT_PRODUCTION_READINESS_VERIFIER:-${SCRIPT_DIR}/perf_current_production_readiness_verify.py}"
CURRENT_PRODUCTION_MAX_AGE_SECONDS="${CURRENT_PRODUCTION_MAX_AGE_SECONDS:-${PERF_CURRENT_PRODUCTION_MAX_AGE_SECONDS:-86400}}"
CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS="${CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS:-${PERF_CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS:-300}}"

PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EXPLICIT=false
if [[ "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON+x}" == "x" ]]; then
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EXPLICIT=true
fi
PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}"
PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-86400}"
PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-300}"
PRODUCTION_EVIDENCE_PACKAGE_EXPLICIT=false
if [[ "${PRODUCTION_EVIDENCE_PACKAGE+x}" == "x" || "${PRODUCTION_ACCEPTANCE_PACKAGE+x}" == "x" ]]; then
  PRODUCTION_EVIDENCE_PACKAGE_EXPLICIT=true
fi
PRODUCTION_EVIDENCE_PACKAGE="${PRODUCTION_EVIDENCE_PACKAGE:-${PRODUCTION_ACCEPTANCE_PACKAGE:-}}"
PRODUCTION_EVIDENCE_DIR="${PRODUCTION_EVIDENCE_DIR:-${PRODUCTION_ACCEPTANCE_EVIDENCE_DIR:-}}"
PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON_EXPLICIT=false
if [[ "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON+x}" == "x" || "${TOPOLOGY_SMOKE_RECEIPT_JSON+x}" == "x" || "${IMSERVER_PRODUCTION_SMOKE_JSON+x}" == "x" ]]; then
  PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON_EXPLICIT=true
fi
PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON:-${TOPOLOGY_SMOKE_RECEIPT_JSON:-${IMSERVER_PRODUCTION_SMOKE_JSON:-}}}"
PRODUCTION_TOPOLOGY_SMOKE_VERIFIER="${PRODUCTION_TOPOLOGY_SMOKE_VERIFIER:-${SCRIPT_DIR}/../scripts/verify_production_smoke.py}"
PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS="${PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS:-${TOPOLOGY_SMOKE_MAX_AGE_SECONDS:-86400}}"
PRODUCTION_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS:-${TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS:-300}}"
PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON_EXPLICIT=false
if [[ "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON+x}" == "x" || "${DEPLOY_READINESS_RECEIPT_JSON+x}" == "x" || "${READINESS_RECEIPT_JSON+x}" == "x" ]]; then
  PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON_EXPLICIT=true
fi
PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON="${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON:-${DEPLOY_READINESS_RECEIPT_JSON:-${READINESS_RECEIPT_JSON:-}}}"
PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS="${PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS:-86400}"
PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS:-300}"
PRODUCTION_DEPLOY_READINESS_VERIFIER="${PRODUCTION_DEPLOY_READINESS_VERIFIER:-${SCRIPT_DIR}/verify_deploy_readiness_receipt.py}"
PRODUCTION_STATIC_GATE_RECEIPT_JSON="${PRODUCTION_STATIC_GATE_RECEIPT_JSON:-${PRODUCTION_READINESS_RESULT_ROOT}/production-static/latest.json}"
PRODUCTION_STATIC_GATE_VERIFIER="${PRODUCTION_STATIC_GATE_VERIFIER:-${SCRIPT_DIR}/production_static_gate_receipt.py}"
PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS="${PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS:-86400}"
PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS:-300}"
PRODUCTION_READINESS_STATUS_SCRIPT="${PRODUCTION_READINESS_STATUS_SCRIPT:-${SCRIPT_DIR}/production_readiness_status.sh}"
PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT:-${SCRIPT_DIR}/verify_production_acceptance.sh}"

ASSERT_PRODUCTION_READY_WRITE_RECEIPT="${ASSERT_PRODUCTION_READY_WRITE_RECEIPT:-true}"
ASSERT_PRODUCTION_READY_RECEIPT_JSON="${ASSERT_PRODUCTION_READY_RECEIPT_JSON:-${PRODUCTION_READINESS_RESULT_ROOT}/production-ready/latest.json}"
ASSERT_PRODUCTION_READY_SELF_TEST="${ASSERT_PRODUCTION_READY_SELF_TEST:-false}"

usage() {
  cat <<'EOF'
Usage:
  BASE_URL=https://chat.prod.company.com \
  TCP_HOST=tcp.prod.company.com \
  TCP_PORT=9000 \
  CURRENT_PRODUCTION_READINESS_JSON=results/.../current-production-readiness.json \
  PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=/var/lib/imserver/readiness/latest.json \
  PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=reports/latest-production-smoke.json \
  PRODUCTION_STATIC_GATE_RECEIPT_JSON=results/production-static/latest.json \
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON=results/.../production-acceptance.json \
  PRODUCTION_EVIDENCE_PACKAGE=results/.../production-evidence.tar.gz \
    ./assert_production_ready.sh

This is the final no-shortcut production-ready assertion. It does not run
traffic. It first runs production_readiness_status.sh as the operator-facing
preflight, then verifies that the topology smoke receipt passes, and that the
current-readiness receipt, deploy readiness receipt, and final production
acceptance receipt/package all match the same real public target and pass their
strict verifiers.
If evidence paths are not set explicitly, it searches PRODUCTION_READINESS_RESULT_ROOT
(default: IMServer/LoadTests/results) for the newest matching readiness and
acceptance receipts, topology smoke receipt, and deploy readiness receipt, then
binds the evidence package from the acceptance receipt.

Override points for tests or wrappers:
  PRODUCTION_READINESS_STATUS_SCRIPT
  CURRENT_PRODUCTION_READINESS_VERIFIER
  PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT
  PRODUCTION_DEPLOY_READINESS_VERIFIER
  PRODUCTION_STATIC_GATE_VERIFIER
  PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS=86400
  PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS=300
  CURRENT_PRODUCTION_MAX_AGE_SECONDS=86400
  CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS=300
  PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS=86400
  PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS=300
  ASSERT_PRODUCTION_READY_RECEIPT_JSON=results/production-ready/latest.json
  ASSERT_PRODUCTION_READY_WRITE_RECEIPT=true
EOF
}

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

latest_existing_file() {
  python3 - "$@" <<'PY'
from __future__ import annotations

import glob
import sys
from pathlib import Path

candidates: list[tuple[float, str]] = []
for pattern in sys.argv[1:]:
    for raw in glob.glob(pattern):
        path = Path(raw).expanduser()
        if not path.is_file():
            continue
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        candidates.append((mtime, str(path)))
if candidates:
    print(sorted(candidates)[-1][1])
PY
}

package_from_acceptance_receipt() {
  local receipt_path="$1"
  python3 - "${receipt_path}" <<'PY'
import json
import sys
from pathlib import Path

try:
    receipt = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
package = str((receipt.get("artifacts") or {}).get("package") or "")
if package and Path(package).expanduser().is_file():
    print(package)
PY
}

discover_production_ready_inputs() {
  local discovered=""
  if [[ -z "${CURRENT_PRODUCTION_READINESS_JSON}" && "${CURRENT_PRODUCTION_READINESS_JSON_EXPLICIT}" != "true" ]]; then
    discovered="$(latest_existing_file \
      "${PRODUCTION_READINESS_RESULT_ROOT}/current-production-readiness*/current-production-readiness.json" \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-acceptance/*/current-production-readiness.json")"
    if [[ -n "${discovered}" ]]; then
      CURRENT_PRODUCTION_READINESS_JSON="${discovered}"
    fi
  fi

  if [[ -z "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" && "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EXPLICIT}" != "true" ]]; then
    discovered="$(latest_existing_file \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-acceptance/*/production-acceptance.json" \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-acceptance*/production-acceptance.json")"
    if [[ -n "${discovered}" ]]; then
      PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${discovered}"
    fi
  fi

  if [[ -z "${PRODUCTION_EVIDENCE_PACKAGE}" && "${PRODUCTION_EVIDENCE_PACKAGE_EXPLICIT}" != "true" && -f "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" ]]; then
    discovered="$(package_from_acceptance_receipt "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}")"
    if [[ -n "${discovered}" ]]; then
      PRODUCTION_EVIDENCE_PACKAGE="${discovered}"
    fi
  fi

  if [[ -z "${PRODUCTION_EVIDENCE_PACKAGE}" && "${PRODUCTION_EVIDENCE_PACKAGE_EXPLICIT}" != "true" ]]; then
    discovered="$(latest_existing_file \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-acceptance/production-evidence/*.tar.gz" \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-evidence/*.tar.gz")"
    if [[ -n "${discovered}" ]]; then
      PRODUCTION_EVIDENCE_PACKAGE="${discovered}"
    fi
  fi

  if [[ -z "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}" && "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON_EXPLICIT}" != "true" ]]; then
    discovered="$(latest_existing_file \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-smoke/latest-production-smoke.json" \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-smoke/*/latest-production-smoke.json" \
      "${SCRIPT_DIR}/../reports/latest-production-smoke.json")"
    if [[ -n "${discovered}" ]]; then
      PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${discovered}"
    fi
  fi

  if [[ -z "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}" && "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON_EXPLICIT}" != "true" ]]; then
    discovered="$(latest_existing_file \
      "${PRODUCTION_READINESS_RESULT_ROOT}/deploy-readiness/latest.json" \
      "${PRODUCTION_READINESS_RESULT_ROOT}/deploy-readiness/*/latest.json" \
      "/var/lib/imserver/readiness/latest.json")"
    if [[ -n "${discovered}" ]]; then
      PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON="${discovered}"
    fi
  fi
}

fail() {
  printf 'assert_production_ready result=fail reason=%s\n' "$1" >&2
  exit 1
}

require_env() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    printf 'assert_production_ready result=fail reason=missing_env name=%s\n' "${name}" >&2
    exit 1
  fi
}

require_file() {
  local name="$1"
  local path="$2"
  if [[ ! -f "${path}" ]]; then
    printf 'assert_production_ready result=fail reason=file_missing name=%s path=%s\n' "${name}" "${path}" >&2
    exit 1
  fi
}

validate_public_target() {
  python3 "${PRODUCTION_TARGET_POLICY}" \
    --base-url "${BASE_URL}" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --result-prefix "assert_production_ready"
}

write_assertion_receipt() {
  if ! bool_enabled "${ASSERT_PRODUCTION_READY_WRITE_RECEIPT}"; then
    return 0
  fi
  python3 - \
    "${ASSERT_PRODUCTION_READY_RECEIPT_JSON}" \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}" \
    "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}" \
    "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}" \
    "${CURRENT_PRODUCTION_READINESS_JSON}" \
    "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
    "${PRODUCTION_EVIDENCE_PACKAGE}" \
    "${CURRENT_PRODUCTION_EVIDENCE_DIR}" \
    "${PRODUCTION_EVIDENCE_DIR}" \
    "${PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}" \
    "${PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS}" \
    "${PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS}" \
    "${CURRENT_PRODUCTION_MAX_AGE_SECONDS}" \
    "${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" \
    <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import socket
import sys
import time
from pathlib import Path
from tempfile import NamedTemporaryFile

(
    receipt_path_raw,
    base_url,
    tcp_host,
    tcp_port,
    topology_smoke_receipt,
    deploy_readiness_receipt,
    static_gate_receipt,
    current_readiness_json,
    acceptance_receipt,
    evidence_package,
    current_evidence_dir,
    acceptance_evidence_dir,
    topology_smoke_max_age_seconds,
    deploy_readiness_max_age_seconds,
    static_gate_max_age_seconds,
    current_readiness_max_age_seconds,
    production_acceptance_max_age_seconds,
) = sys.argv[1:18]


def file_record(path_raw: str) -> dict[str, object]:
    path = Path(path_raw).expanduser().resolve()
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            size += len(chunk)
            digest.update(chunk)
    return {
        "path": str(path),
        "fileName": path.name,
        "bytes": size,
        "sha256": digest.hexdigest(),
    }


def optional_dir(path_raw: str) -> dict[str, object]:
    if not path_raw:
        return {"path": "", "present": False}
    path = Path(path_raw).expanduser().resolve()
    return {"path": str(path), "present": path.is_dir()}


generated_epoch = int(time.time())
payload = {
    "schemaVersion": 1,
    "kind": "imserver-production-ready-assertion",
    "status": "pass",
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(generated_epoch)),
    "generatedAtEpoch": generated_epoch,
    "host": socket.gethostname(),
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": str(tcp_port),
    },
    "productionClaim": {
        "productionReady": True,
        "claimAllowed": True,
        "claimLevel": "production-ready",
        "basis": "verified-final-production-evidence",
        "targetComplete": True,
        "requiredArtifacts": [
            "topologySmokeReceipt",
            "deployReadinessReceipt",
            "productionStaticGateReceipt",
            "currentProductionReadinessJSON",
            "productionAcceptanceReceiptJSON",
            "productionEvidencePackage",
        ],
        "requiredPolicies": [
            "requiresPublicProductionTarget",
            "requiresTopologySmokeReceipt",
            "requiresDeployReadinessReceipt",
            "requiresProductionStaticGateReceipt",
            "requiresCurrentProductionReadiness",
            "requiresProductionAcceptanceReceipt",
            "requiresProductionEvidencePackage",
            "requiresFreshTopologySmokeReceipt",
            "requiresFreshDeployReadinessReceipt",
            "requiresFreshProductionStaticGateReceipt",
            "requiresFreshCurrentProductionReadiness",
            "requiresFreshProductionAcceptanceReceipt",
            "requiresMatchingTarget",
        ],
        "blockers": [],
    },
    "policy": {
        "requiresPublicProductionTarget": True,
        "requiresTopologySmokeReceipt": True,
        "requiresDeployReadinessReceipt": True,
        "requiresProductionStaticGateReceipt": True,
        "requiresCurrentProductionReadiness": True,
        "requiresProductionAcceptanceReceipt": True,
        "requiresProductionEvidencePackage": True,
        "requiresFreshTopologySmokeReceipt": True,
        "requiresFreshDeployReadinessReceipt": True,
        "requiresFreshProductionStaticGateReceipt": True,
        "requiresFreshCurrentProductionReadiness": True,
        "requiresFreshProductionAcceptanceReceipt": True,
        "requiresMatchingTarget": True,
    },
    "freshness": {
        "topologySmokeMaxAgeSeconds": int(topology_smoke_max_age_seconds),
        "deployReadinessMaxAgeSeconds": int(deploy_readiness_max_age_seconds),
        "productionStaticGateMaxAgeSeconds": int(static_gate_max_age_seconds),
        "currentReadinessMaxAgeSeconds": int(current_readiness_max_age_seconds),
        "productionAcceptanceMaxAgeSeconds": int(production_acceptance_max_age_seconds),
    },
    "artifacts": {
        "topologySmokeReceipt": file_record(topology_smoke_receipt),
        "deployReadinessReceipt": file_record(deploy_readiness_receipt),
        "productionStaticGateReceipt": file_record(static_gate_receipt),
        "currentProductionReadinessJSON": file_record(current_readiness_json),
        "productionAcceptanceReceiptJSON": file_record(acceptance_receipt),
        "productionEvidencePackage": file_record(evidence_package),
        "currentProductionEvidenceDir": optional_dir(current_evidence_dir),
        "productionAcceptanceEvidenceDir": optional_dir(acceptance_evidence_dir),
    },
    "verifiedBy": {
        "assertProductionReady": os.environ.get("ASSERT_PRODUCTION_READY_SCRIPT", ""),
        "productionReadinessStatus": os.environ.get("PRODUCTION_READINESS_STATUS_SCRIPT", ""),
        "productionStaticGateVerifier": os.environ.get("PRODUCTION_STATIC_GATE_VERIFIER", ""),
        "productionDeployReadinessVerifier": os.environ.get("PRODUCTION_DEPLOY_READINESS_VERIFIER", ""),
        "currentProductionReadinessVerifier": os.environ.get("CURRENT_PRODUCTION_READINESS_VERIFIER", ""),
        "productionTopologySmokeVerifier": os.environ.get("PRODUCTION_TOPOLOGY_SMOKE_VERIFIER", ""),
        "productionAcceptanceVerifyScript": os.environ.get("PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT", ""),
    },
}

receipt_path = Path(receipt_path_raw).expanduser()
receipt_path.parent.mkdir(parents=True, exist_ok=True)
with NamedTemporaryFile(
    "w",
    encoding="utf-8",
    dir=str(receipt_path.parent),
    prefix=f".{receipt_path.name}.",
    suffix=".tmp",
    delete=False,
) as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    tmp_name = handle.name
os.replace(tmp_name, receipt_path)
print(f"assert_production_ready receipt={receipt_path}")
PY
}

run_self_test() {
  local tmpdir readiness topology_receipt deploy_receipt static_receipt receipt package fake_readiness fake_deploy fake_status fake_acceptance
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  git -C "${tmpdir}" init -q
  git -C "${tmpdir}" config user.email "assert-production-ready-self-test@example.invalid"
  git -C "${tmpdir}" config user.name "Assert Production Ready Self Test"
  git -C "${tmpdir}" commit --allow-empty -m "initial self-test state" -q
  printf '*\n' >>"${tmpdir}/.git/info/exclude"
  export PRODUCTION_READINESS_RESULT_ROOT="${tmpdir}/empty-results"
  mkdir -p "${PRODUCTION_READINESS_RESULT_ROOT}"

  readiness="${tmpdir}/current-production-readiness.json"
  topology_receipt="${tmpdir}/latest-production-smoke.json"
  deploy_receipt="${tmpdir}/deploy-readiness-latest.json"
  static_receipt="${tmpdir}/production-static-gate-latest.json"
  receipt="${tmpdir}/production-acceptance.json"
  package="${tmpdir}/production-evidence.tar.gz"
  fake_readiness="${tmpdir}/fake-current-readiness.py"
  fake_deploy="${tmpdir}/fake-deploy-readiness.py"
  fake_status="${tmpdir}/fake-production-readiness-status.sh"
  fake_acceptance="${tmpdir}/fake-production-acceptance.sh"

  printf '{"schemaVersion":1}\n' >"${readiness}"
  printf '{"schemaVersion":1,"kind":"imserver-production-readiness-gate","status":"pass"}\n' >"${deploy_receipt}"
  python3 - "${SCRIPT_DIR}" "${tmpdir}" <<'PY'
import json
import sys
import time
from pathlib import Path

script_dir = Path(sys.argv[1])
root = Path(sys.argv[2])
sys.path.insert(0, str(script_dir))
import production_completion_status as completion_status_renderer
import production_evidence_recovery_plan as recovery_plan_renderer

support_root = root / "static-support"
support_root.mkdir(parents=True, exist_ok=True)
completion = support_root / "completion-status.json"
completion_markdown = support_root / "completion-status.md"
recovery_plan = support_root / "evidence-recovery-plan.json"
recovery_markdown = support_root / "evidence-recovery-plan.md"
recovery_script = support_root / "evidence-recovery-run.sh"
generated_at = int(time.time())
production_target = {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
    "missingEnv": [],
}
production_claim = {
    "productionReady": False,
    "claimAllowed": False,
    "claimLevel": "not-production-ready",
    "basis": "local-engineering-or-partial-evidence-only",
    "localEngineeringComplete": True,
    "liveEvidenceComplete": False,
    "targetComplete": True,
    "finalAssertionPassed": False,
    "finalAssertionArchivePassed": False,
    "finalAssertionClaimVerified": False,
    "finalAssertionArchiveClaimVerified": False,
    "requiredEvidence": [
        "deploy-readiness",
        "current-readiness",
        "production-acceptance",
        "production-evidence-package",
        "topology-smoke",
        "final-assertion",
        "final-assertion-archive",
    ],
    "blockers": [
        "live-production-evidence-incomplete",
        "final-assertion-not-passed",
        "final-assertion-archive-not-passed",
    ],
}
summary = {
    "localPassed": 36,
    "localTotal": 36,
    "localMissingCount": 0,
    "liveEvidencePassed": 0,
    "liveEvidenceTotal": 7,
    "liveEvidenceMissingCount": 7,
    "missingCount": 7,
    "evidenceRecoveryPlanCount": 7,
}
recovery_steps = [
    {
        "item": f"step-{index}",
        "reason": "missing_env",
        "requiredEnv": ["BASE_URL"],
        "runCommand": "true",
        "verifyCommand": "true",
    }
    for index in range(7)
]
completion_payload = {
    "kind": "imserver-production-completion-status",
    "schemaVersion": 1,
    "repoRoot": str(root),
    "generatedAtEpoch": generated_at,
    "status": "incomplete",
    "localCompletionPercent": 100,
    "liveEvidenceCompletionPercent": 0,
    "productionCompletionPercent": 75,
    "weights": {
        "localEngineering": 75,
        "liveProductionEvidence": 25,
    },
    "summary": summary,
    "productionTarget": production_target,
    "productionClaim": production_claim,
    "readinessTiers": completion_status_renderer.readiness_tiers(
        ready=False,
        claim=production_claim,
        local_pass=summary["localPassed"],
        local_total=summary["localTotal"],
        evidence_pass=summary["liveEvidencePassed"],
        evidence_total=summary["liveEvidenceTotal"],
        local_completion=100,
        live_completion=0,
        production_completion=75,
    ),
    "missing": [{"scope": "evidence", "item": step["item"], "reason": step["reason"]} for step in recovery_steps],
    "evidenceRecoveryPlan": recovery_steps,
    "nextActions": ["Restore a real production target and run make run-current-production-readiness."],
}
completion.write_text(json.dumps(completion_payload), encoding="utf-8")
completion_markdown.write_text(completion_status_renderer.render_markdown(completion_payload), encoding="utf-8")
recovery_payload = {
    "kind": "imserver-production-evidence-recovery-plan",
    "schemaVersion": 1,
    "generatedAtEpoch": generated_at,
    "sourceStatus": "incomplete",
    "sourceStatusJson": str(completion),
    "sourceStatusGeneratedAtEpoch": generated_at,
    "productionTarget": production_target,
    "productionClaim": production_claim,
    "readinessTiers": completion_payload["readinessTiers"],
    "readyToClaimProduction": False,
    "localEngineeringComplete": True,
    "summary": {
        "status": "incomplete",
        "localCompletionPercent": 100,
        "liveEvidenceCompletionPercent": 0,
        "productionCompletionPercent": 75,
        "localPassed": summary["localPassed"],
        "localTotal": summary["localTotal"],
        "liveEvidencePassed": summary["liveEvidencePassed"],
        "liveEvidenceTotal": summary["liveEvidenceTotal"],
        "missingCount": summary["missingCount"],
        "evidenceRecoveryPlanCount": summary["evidenceRecoveryPlanCount"],
    },
    "localMissing": [],
    "evidenceMissing": [{"scope": "evidence", "item": step["item"], "reason": step["reason"]} for step in recovery_steps],
    "steps": recovery_steps,
    "operatorEnvironmentTemplate": [{"name": "BASE_URL", "example": "https://chat.myim-prod.com"}],
    "oneShotRecoveryCommands": [
        command
        for step in recovery_steps
        for command in (f"# {step['item']}", step["runCommand"], step["verifyCommand"])
    ],
    "finalVerificationCommands": [
        "make production-completion-status",
        "make verify-production-completion-status",
    ],
}
recovery_payload["oneShotRecoveryCommands"].insert(0, "set -euo pipefail")
recovery_payload["oneShotRecoveryCommands"].append("# final-verification")
recovery_payload["oneShotRecoveryCommands"].extend(recovery_payload["finalVerificationCommands"])
recovery_plan.write_text(json.dumps(recovery_payload), encoding="utf-8")
recovery_markdown.write_text(recovery_plan_renderer.render_markdown(recovery_payload), encoding="utf-8")
recovery_script.write_text(recovery_plan_renderer.render_shell_script(recovery_payload), encoding="utf-8")
recovery_script.chmod(0o755)
PY
  python3 "${SCRIPT_DIR}/production_static_gate_receipt.py" \
    --repo-root "${tmpdir}" \
    --receipt-json "${static_receipt}" \
    --completion-status-json "${tmpdir}/static-support/completion-status.json" \
    --completion-status-markdown "${tmpdir}/static-support/completion-status.md" \
    --recovery-plan-json "${tmpdir}/static-support/evidence-recovery-plan.json" \
    --recovery-plan-markdown "${tmpdir}/static-support/evidence-recovery-plan.md" \
    --recovery-plan-script "${tmpdir}/static-support/evidence-recovery-run.sh" >/dev/null
  export PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON="${deploy_receipt}"
  export PRODUCTION_STATIC_GATE_RECEIPT_JSON="${static_receipt}"
  python3 - "${topology_receipt}" "${tmpdir}/topology-smoke-artifacts" <<'PY'
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
receipt.write_text(json.dumps({
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
}), encoding="utf-8")
PY
  printf '{"schemaVersion":1,"target":{"baseURL":"https://chat.myim-prod.com","tcpHost":"tcp.myim-prod.com","tcpPort":"9000"}}\n' >"${receipt}"
  printf 'package\n' >"${package}"

  cat >"${fake_readiness}" <<'PY'
#!/usr/bin/env python3
from pathlib import Path
import os
import sys

capture = Path(os.environ["ASSERT_PRODUCTION_READY_CAPTURE_DIR"])
(capture / "readiness.args").write_text("\n".join(sys.argv[1:]), encoding="utf-8")
PY
  chmod +x "${fake_readiness}"

  cat >"${fake_deploy}" <<'PY'
#!/usr/bin/env python3
from pathlib import Path
import os
import sys

capture = Path(os.environ["ASSERT_PRODUCTION_READY_CAPTURE_DIR"])
(capture / "deploy.args").write_text("\n".join(sys.argv[1:]), encoding="utf-8")
PY
  chmod +x "${fake_deploy}"
  export PRODUCTION_DEPLOY_READINESS_VERIFIER="${fake_deploy}"

  cat >"${fake_status}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${ASSERT_PRODUCTION_READY_CAPTURE_DIR:?}"
{
  printf 'BASE_URL=%s\n' "${BASE_URL:-}"
  printf 'TCP_HOST=%s\n' "${TCP_HOST:-}"
  printf 'TCP_PORT=%s\n' "${TCP_PORT:-}"
  printf 'CURRENT_PRODUCTION_READINESS_JSON=%s\n' "${CURRENT_PRODUCTION_READINESS_JSON:-}"
  printf 'PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=%s\n' "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON:-}"
  printf 'PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=%s\n' "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON:-}"
  printf 'PRODUCTION_STATIC_GATE_RECEIPT_JSON=%s\n' "${PRODUCTION_STATIC_GATE_RECEIPT_JSON:-}"
  printf 'PRODUCTION_ACCEPTANCE_RECEIPT_JSON=%s\n' "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}"
  printf 'PRODUCTION_EVIDENCE_PACKAGE=%s\n' "${PRODUCTION_EVIDENCE_PACKAGE:-}"
} >"${ASSERT_PRODUCTION_READY_CAPTURE_DIR}/status.env"
printf 'production_readiness_status readyToAssert=true nextCommand="make assert-production-ready"\n'
SH
  chmod +x "${fake_status}"

  cat >"${fake_acceptance}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${ASSERT_PRODUCTION_READY_CAPTURE_DIR:?}"
{
  printf 'BASE_URL=%s\n' "${BASE_URL:-}"
  printf 'TCP_HOST=%s\n' "${TCP_HOST:-}"
  printf 'TCP_PORT=%s\n' "${TCP_PORT:-}"
  printf 'PRODUCTION_ACCEPTANCE_RECEIPT_JSON=%s\n' "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}"
  printf 'PRODUCTION_EVIDENCE_PACKAGE=%s\n' "${PRODUCTION_EVIDENCE_PACKAGE:-}"
  printf 'PRODUCTION_EVIDENCE_DIR=%s\n' "${PRODUCTION_EVIDENCE_DIR:-}"
} >"${ASSERT_PRODUCTION_READY_CAPTURE_DIR}/acceptance.env"
SH
  chmod +x "${fake_acceptance}"

  ASSERT_PRODUCTION_READY_CAPTURE_DIR="${tmpdir}" \
  ASSERT_PRODUCTION_READY_RECEIPT_JSON="${tmpdir}/production-ready/latest.json" \
  BASE_URL=https://chat.myim-prod.com \
  TCP_HOST=tcp.myim-prod.com \
  TCP_PORT=9000 \
  CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
  CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
  PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
  PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
  PRODUCTION_EVIDENCE_PACKAGE="${package}" \
  PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
  ASSERT_PRODUCTION_READY_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${tmpdir}/good.log"

  [[ -f "${tmpdir}/production-ready/latest.json" ]] || fail "self_test_receipt_missing"
  python3 - "${tmpdir}/production-ready/latest.json" "${package}" <<'PY'
import json
import sys
from pathlib import Path

receipt = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if receipt.get("kind") != "imserver-production-ready-assertion":
    raise SystemExit("self_test_assertion_receipt_kind")
if receipt.get("status") != "pass":
    raise SystemExit("self_test_assertion_receipt_status")
target = receipt.get("target") or {}
if target.get("baseURL") != "https://chat.myim-prod.com":
    raise SystemExit("self_test_assertion_receipt_base_url")
if target.get("tcpHost") != "tcp.myim-prod.com":
    raise SystemExit("self_test_assertion_receipt_tcp_host")
if str(target.get("tcpPort")) != "9000":
    raise SystemExit("self_test_assertion_receipt_tcp_port")
claim = receipt.get("productionClaim") or {}
if claim.get("productionReady") is not True or claim.get("claimAllowed") is not True:
    raise SystemExit("self_test_assertion_receipt_claim_allowed")
if claim.get("claimLevel") != "production-ready":
    raise SystemExit("self_test_assertion_receipt_claim_level")
if claim.get("basis") != "verified-final-production-evidence":
    raise SystemExit("self_test_assertion_receipt_claim_basis")
if claim.get("targetComplete") is not True:
    raise SystemExit("self_test_assertion_receipt_claim_target")
if claim.get("blockers") != []:
    raise SystemExit("self_test_assertion_receipt_claim_blockers")
expected_artifacts = [
    "topologySmokeReceipt",
    "deployReadinessReceipt",
    "productionStaticGateReceipt",
    "currentProductionReadinessJSON",
    "productionAcceptanceReceiptJSON",
    "productionEvidencePackage",
]
expected_policies = [
    "requiresPublicProductionTarget",
    "requiresTopologySmokeReceipt",
    "requiresDeployReadinessReceipt",
    "requiresProductionStaticGateReceipt",
    "requiresCurrentProductionReadiness",
    "requiresProductionAcceptanceReceipt",
    "requiresProductionEvidencePackage",
    "requiresFreshTopologySmokeReceipt",
    "requiresFreshDeployReadinessReceipt",
    "requiresFreshProductionStaticGateReceipt",
    "requiresFreshCurrentProductionReadiness",
    "requiresFreshProductionAcceptanceReceipt",
    "requiresMatchingTarget",
]
if claim.get("requiredArtifacts") != expected_artifacts:
    raise SystemExit("self_test_assertion_receipt_claim_artifacts")
if claim.get("requiredPolicies") != expected_policies:
    raise SystemExit("self_test_assertion_receipt_claim_policies")
freshness = receipt.get("freshness") or {}
if int(freshness.get("productionAcceptanceMaxAgeSeconds") or 0) != 86400:
    raise SystemExit("self_test_assertion_receipt_acceptance_freshness")
artifacts = receipt.get("artifacts") or {}
package_record = artifacts.get("productionEvidencePackage") or {}
if package_record.get("path") != str(Path(sys.argv[2]).resolve()):
    raise SystemExit("self_test_assertion_receipt_package_path")
for key in expected_artifacts:
    record = artifacts.get(key) or {}
    if not record.get("sha256") or int(record.get("bytes") or 0) <= 0:
        raise SystemExit(f"self_test_assertion_receipt_artifact_{key}")
PY
  grep -q 'assert_production_ready receipt=' "${tmpdir}/good.log" || fail "self_test_receipt_log_missing"
  grep -q -- '--readiness-json' "${tmpdir}/readiness.args" || fail "self_test_readiness_json_arg_missing"
  grep -q -- '--expect-base-url' "${tmpdir}/readiness.args" || fail "self_test_expect_base_url_arg_missing"
  grep -q -- '--max-age-seconds' "${tmpdir}/readiness.args" || fail "self_test_readiness_max_age_arg_missing"
  grep -q -- '--max-future-skew-seconds' "${tmpdir}/readiness.args" || fail "self_test_readiness_max_future_skew_arg_missing"
  grep -q -- '--receipt-json' "${tmpdir}/deploy.args" || fail "self_test_deploy_readiness_receipt_arg_missing"
  grep -q -- '--expect-base-url' "${tmpdir}/deploy.args" || fail "self_test_deploy_readiness_base_url_arg_missing"
  grep -q -- '--expect-tcp-host' "${tmpdir}/deploy.args" || fail "self_test_deploy_readiness_tcp_host_arg_missing"
  grep -q -- '--expect-tcp-port' "${tmpdir}/deploy.args" || fail "self_test_deploy_readiness_tcp_port_arg_missing"
  grep -q -- '--max-age-seconds' "${tmpdir}/deploy.args" || fail "self_test_deploy_readiness_max_age_arg_missing"
  grep -q -- '--max-future-skew-seconds' "${tmpdir}/deploy.args" || fail "self_test_deploy_readiness_max_future_skew_arg_missing"
  grep -q 'CURRENT_PRODUCTION_READINESS_JSON=' "${tmpdir}/status.env" || fail "self_test_status_readiness_env_missing"
  grep -q 'PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=' "${tmpdir}/status.env" || fail "self_test_status_topology_smoke_env_missing"
  grep -q 'PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=' "${tmpdir}/status.env" || fail "self_test_status_deploy_readiness_env_missing"
  grep -q 'PRODUCTION_STATIC_GATE_RECEIPT_JSON=' "${tmpdir}/status.env" || fail "self_test_status_static_gate_env_missing"
  grep -q 'PRODUCTION_EVIDENCE_PACKAGE=' "${tmpdir}/status.env" || fail "self_test_status_package_env_missing"
  grep -q 'PRODUCTION_EVIDENCE_PACKAGE=' "${tmpdir}/acceptance.env" || fail "self_test_acceptance_package_env_missing"
  grep -q 'assert_production_ready result=pass' "${tmpdir}/good.log" || fail "self_test_good_result_missing"
  bash "${BASH_SOURCE[0]}" --help >"${tmpdir}/help.log"
  grep -q 'production_readiness_status.sh' "${tmpdir}/help.log" || fail "self_test_help_status_preflight_missing"
  grep -q 'PRODUCTION_READINESS_STATUS_SCRIPT' "${tmpdir}/help.log" || fail "self_test_help_status_override_missing"

  ASSERT_PRODUCTION_READY_CAPTURE_DIR="${tmpdir}" \
  BASE_URL=https://chat.myim-prod.com \
  TCP_HOST=tcp.myim-prod.com \
  TCP_PORT=9000 \
  CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
  CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
  PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
  PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
  PRODUCTION_ACCEPTANCE_PACKAGE="${package}" \
  PRODUCTION_ACCEPTANCE_EVIDENCE_DIR="${tmpdir}/evidence" \
  PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
  ASSERT_PRODUCTION_READY_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${tmpdir}/alias-good.log"

  grep -q "PRODUCTION_EVIDENCE_PACKAGE=${package}" "${tmpdir}/status.env" || fail "self_test_status_package_alias_env_missing"
  grep -q "PRODUCTION_EVIDENCE_PACKAGE=${package}" "${tmpdir}/acceptance.env" || fail "self_test_acceptance_package_alias_env_missing"
  grep -q "PRODUCTION_EVIDENCE_DIR=${tmpdir}/evidence" "${tmpdir}/acceptance.env" || fail "self_test_acceptance_evidence_dir_alias_env_missing"
  grep -q 'assert_production_ready result=pass' "${tmpdir}/alias-good.log" || fail "self_test_alias_good_result_missing"

  auto_root="${tmpdir}/auto-results"
  mkdir -p "${auto_root}/current-production-readiness-latest" "${auto_root}/production-acceptance/latest" "${auto_root}/production-smoke" "${auto_root}/deploy-readiness"
  cp "${readiness}" "${auto_root}/current-production-readiness-latest/current-production-readiness.json"
  cp "${topology_receipt}" "${auto_root}/production-smoke/latest-production-smoke.json"
  cp "${deploy_receipt}" "${auto_root}/deploy-readiness/latest.json"
  python3 - "${receipt}" "${auto_root}/production-acceptance/latest/production-acceptance.json" "${package}" <<'PY'
import json
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
source.setdefault("artifacts", {})["package"] = sys.argv[3]
Path(sys.argv[2]).write_text(json.dumps(source), encoding="utf-8")
PY
  env -u PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON -u TOPOLOGY_SMOKE_RECEIPT_JSON -u IMSERVER_PRODUCTION_SMOKE_JSON \
  -u PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON -u DEPLOY_READINESS_RECEIPT_JSON -u READINESS_RECEIPT_JSON \
  ASSERT_PRODUCTION_READY_CAPTURE_DIR="${tmpdir}" \
  BASE_URL=https://chat.myim-prod.com \
  TCP_HOST=tcp.myim-prod.com \
  TCP_PORT=9000 \
  PRODUCTION_READINESS_RESULT_ROOT="${auto_root}" \
  CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
  PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
  PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
  ASSERT_PRODUCTION_READY_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${tmpdir}/auto-discovery-good.log"

  grep -q "CURRENT_PRODUCTION_READINESS_JSON=${auto_root}/current-production-readiness-latest/current-production-readiness.json" "${tmpdir}/status.env" || fail "self_test_auto_status_readiness_env_missing"
  grep -q "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=${auto_root}/production-smoke/latest-production-smoke.json" "${tmpdir}/status.env" || fail "self_test_auto_status_topology_smoke_env_missing"
  grep -q "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=${auto_root}/deploy-readiness/latest.json" "${tmpdir}/status.env" || fail "self_test_auto_status_deploy_readiness_env_missing"
  grep -q "PRODUCTION_ACCEPTANCE_RECEIPT_JSON=${auto_root}/production-acceptance/latest/production-acceptance.json" "${tmpdir}/status.env" || fail "self_test_auto_status_acceptance_env_missing"
  grep -q "PRODUCTION_EVIDENCE_PACKAGE=${package}" "${tmpdir}/acceptance.env" || fail "self_test_auto_acceptance_package_env_missing"
  grep -q 'assert_production_ready result=pass' "${tmpdir}/auto-discovery-good.log" || fail "self_test_auto_good_result_missing"

  cat >"${tmpdir}/fake-production-readiness-status-fail.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'production_readiness_status readyToAssert=false failures=1 nextCommand="make production-readiness-status"\n' >&2
exit 1
SH
  chmod +x "${tmpdir}/fake-production-readiness-status-fail.sh"
  if ASSERT_PRODUCTION_READY_CAPTURE_DIR="${tmpdir}" \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
    PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
    PRODUCTION_READINESS_STATUS_SCRIPT="${tmpdir}/fake-production-readiness-status-fail.sh" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
    ASSERT_PRODUCTION_READY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/status-fail.log" 2>&1; then
    fail "self_test_status_preflight_failure_passed"
  fi
  grep -q 'readyToAssert=false' "${tmpdir}/status-fail.log" || fail "self_test_status_preflight_failure_reason_missing"

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
    PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
    PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
    ASSERT_PRODUCTION_READY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/missing-package.log" 2>&1; then
    fail "self_test_missing_package_passed"
  fi
  grep -q 'reason=missing_env name=PRODUCTION_EVIDENCE_PACKAGE' "${tmpdir}/missing-package.log" || fail "self_test_missing_package_reason_missing"

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
    PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
    PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON="${deploy_receipt}.missing" \
    PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
    ASSERT_PRODUCTION_READY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/missing-deploy-readiness.log" 2>&1; then
    fail "self_test_missing_deploy_readiness_passed"
  fi
  grep -q 'reason=file_missing name=PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON' "${tmpdir}/missing-deploy-readiness.log" || fail "self_test_missing_deploy_readiness_reason_missing"

  cp "${static_receipt}" "${tmpdir}/dirty-static-gate.json"
  python3 - "${tmpdir}/dirty-static-gate.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["git"] = {
    **(payload.get("git") or {}),
    "dirty": True,
    "dirtyCount": 1,
}
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if ASSERT_PRODUCTION_READY_CAPTURE_DIR="${tmpdir}" \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
    PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
    PRODUCTION_STATIC_GATE_RECEIPT_JSON="${tmpdir}/dirty-static-gate.json" \
    PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
    ASSERT_PRODUCTION_READY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/dirty-static-gate.log" 2>&1; then
    fail "self_test_dirty_static_gate_passed"
  fi
  if ! grep -q 'git_binding_mismatch' "${tmpdir}/dirty-static-gate.log"; then
    cat "${tmpdir}/dirty-static-gate.log" >&2 || true
    fail "self_test_dirty_static_gate_reason_missing"
  fi

  if BASE_URL=http://127.0.0.1:8080 \
    TCP_HOST=127.0.0.1 \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
    PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
    PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
    ASSERT_PRODUCTION_READY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/local-target.log" 2>&1; then
    fail "self_test_local_target_passed"
  fi
  grep -q 'reason=base_url_https_required' "${tmpdir}/local-target.log" || fail "self_test_local_target_reason_missing"

  if BASE_URL=https://chat.myim-prod.com/api \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
    PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
    PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
    ASSERT_PRODUCTION_READY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/path-target.log" 2>&1; then
    fail "self_test_path_target_passed"
  fi
  grep -q 'reason=base_url_origin_required' "${tmpdir}/path-target.log" || fail "self_test_path_target_reason_missing"

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9443 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    CURRENT_PRODUCTION_READINESS_VERIFIER="${fake_readiness}" \
    PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
    PRODUCTION_READINESS_STATUS_SCRIPT="${fake_status}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${fake_acceptance}" \
    ASSERT_PRODUCTION_READY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/bad-port.log" 2>&1; then
    fail "self_test_bad_tcp_port_passed"
  fi
  grep -q 'reason=tcp_port_required' "${tmpdir}/bad-port.log" || fail "self_test_bad_tcp_port_reason_missing"

  printf 'assert_production_ready_self_test result=pass\n'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

if bool_enabled "${ASSERT_PRODUCTION_READY_SELF_TEST}"; then
  run_self_test
  exit 0
fi

discover_production_ready_inputs

require_env "BASE_URL" "${BASE_URL}"
require_env "TCP_HOST" "${TCP_HOST}"
require_env "TCP_PORT" "${TCP_PORT}"
require_env "CURRENT_PRODUCTION_READINESS_JSON" "${CURRENT_PRODUCTION_READINESS_JSON}"
require_env "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON" "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}"
require_env "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON" "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}"
require_env "PRODUCTION_STATIC_GATE_RECEIPT_JSON" "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}"
require_env "PRODUCTION_ACCEPTANCE_RECEIPT_JSON" "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
require_env "PRODUCTION_EVIDENCE_PACKAGE" "${PRODUCTION_EVIDENCE_PACKAGE}"

validate_public_target

require_file "CURRENT_PRODUCTION_READINESS_JSON" "${CURRENT_PRODUCTION_READINESS_JSON}"
require_file "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON" "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}"
require_file "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON" "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}"
require_file "PRODUCTION_STATIC_GATE_RECEIPT_JSON" "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}"
require_file "PRODUCTION_ACCEPTANCE_RECEIPT_JSON" "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
require_file "PRODUCTION_EVIDENCE_PACKAGE" "${PRODUCTION_EVIDENCE_PACKAGE}"
require_file "CURRENT_PRODUCTION_READINESS_VERIFIER" "${CURRENT_PRODUCTION_READINESS_VERIFIER}"
require_file "PRODUCTION_TOPOLOGY_SMOKE_VERIFIER" "${PRODUCTION_TOPOLOGY_SMOKE_VERIFIER}"
require_file "PRODUCTION_DEPLOY_READINESS_VERIFIER" "${PRODUCTION_DEPLOY_READINESS_VERIFIER}"
require_file "PRODUCTION_STATIC_GATE_VERIFIER" "${PRODUCTION_STATIC_GATE_VERIFIER}"
require_file "PRODUCTION_READINESS_STATUS_SCRIPT" "${PRODUCTION_READINESS_STATUS_SCRIPT}"
require_file "PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT" "${PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT}"

readiness_args=(
  "--readiness-json" "${CURRENT_PRODUCTION_READINESS_JSON}"
  "--expect-base-url" "${BASE_URL}"
  "--expect-tcp-host" "${TCP_HOST}"
  "--expect-tcp-port" "${TCP_PORT}"
  "--max-age-seconds" "${CURRENT_PRODUCTION_MAX_AGE_SECONDS}"
  "--max-future-skew-seconds" "${CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS}"
)
if [[ -n "${CURRENT_PRODUCTION_EVIDENCE_DIR}" ]]; then
  readiness_args+=("--evidence-dir" "${CURRENT_PRODUCTION_EVIDENCE_DIR}")
fi

BASE_URL="${BASE_URL}" \
TCP_HOST="${TCP_HOST}" \
TCP_PORT="${TCP_PORT}" \
CURRENT_PRODUCTION_READINESS_JSON="${CURRENT_PRODUCTION_READINESS_JSON}" \
PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}" \
PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON="${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}" \
PRODUCTION_DEPLOY_READINESS_VERIFIER="${PRODUCTION_DEPLOY_READINESS_VERIFIER}" \
PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS="${PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS}" \
PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS}" \
PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
PRODUCTION_EVIDENCE_PACKAGE="${PRODUCTION_EVIDENCE_PACKAGE}" \
  bash "${PRODUCTION_READINESS_STATUS_SCRIPT}"
python3 "${PRODUCTION_TOPOLOGY_SMOKE_VERIFIER}" \
  --receipt-json "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}" \
  --require-pass \
  --require-artifacts-exist \
  --max-age-seconds "${PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}" \
  --max-future-skew-seconds "${PRODUCTION_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS}"
python3 "${PRODUCTION_DEPLOY_READINESS_VERIFIER}" \
  --receipt-json "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}" \
  --expect-base-url "${BASE_URL}" \
  --expect-tcp-host "${TCP_HOST}" \
  --expect-tcp-port "${TCP_PORT}" \
  --max-age-seconds "${PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS}" \
  --max-future-skew-seconds "${PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS}"
python3 "${PRODUCTION_STATIC_GATE_VERIFIER}" \
  --verify \
  --receipt-json "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}" \
  --require-completion-status \
  --require-recovery-plan \
  --require-current-git \
  --require-clean-git \
  --max-age-seconds "${PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS}" \
  --future-skew-seconds "${PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS}"
python3 "${CURRENT_PRODUCTION_READINESS_VERIFIER}" "${readiness_args[@]}"
BASE_URL="${BASE_URL}" \
TCP_HOST="${TCP_HOST}" \
TCP_PORT="${TCP_PORT}" \
PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
PRODUCTION_EVIDENCE_PACKAGE="${PRODUCTION_EVIDENCE_PACKAGE}" \
PRODUCTION_EVIDENCE_DIR="${PRODUCTION_EVIDENCE_DIR}" \
PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" \
PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}" \
  bash "${PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT}"

ASSERT_PRODUCTION_READY_SCRIPT="${BASH_SOURCE[0]}" \
PRODUCTION_READINESS_STATUS_SCRIPT="${PRODUCTION_READINESS_STATUS_SCRIPT}" \
PRODUCTION_STATIC_GATE_VERIFIER="${PRODUCTION_STATIC_GATE_VERIFIER}" \
PRODUCTION_DEPLOY_READINESS_VERIFIER="${PRODUCTION_DEPLOY_READINESS_VERIFIER}" \
CURRENT_PRODUCTION_READINESS_VERIFIER="${CURRENT_PRODUCTION_READINESS_VERIFIER}" \
PRODUCTION_TOPOLOGY_SMOKE_VERIFIER="${PRODUCTION_TOPOLOGY_SMOKE_VERIFIER}" \
PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT="${PRODUCTION_ACCEPTANCE_VERIFY_SCRIPT}" \
  write_assertion_receipt

printf 'assert_production_ready result=pass topologySmoke=%s deployReadiness=%s staticGate=%s readiness=%s acceptance=%s package=%s\n' \
  "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}" \
  "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}" \
  "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}" \
  "${CURRENT_PRODUCTION_READINESS_JSON}" \
  "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
  "${PRODUCTION_EVIDENCE_PACKAGE}"
