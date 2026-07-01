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
CURRENT_PRODUCTION_MAX_AGE_SECONDS="${CURRENT_PRODUCTION_MAX_AGE_SECONDS:-${PERF_CURRENT_PRODUCTION_MAX_AGE_SECONDS:-86400}}"
CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS="${CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS:-${PERF_CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS:-300}}"
PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EXPLICIT=false
if [[ "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON+x}" == "x" ]]; then
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EXPLICIT=true
fi
PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}"
PRODUCTION_EVIDENCE_PACKAGE_EXPLICIT=false
if [[ "${PRODUCTION_EVIDENCE_PACKAGE+x}" == "x" || "${PRODUCTION_ACCEPTANCE_PACKAGE+x}" == "x" ]]; then
  PRODUCTION_EVIDENCE_PACKAGE_EXPLICIT=true
fi
PRODUCTION_EVIDENCE_PACKAGE="${PRODUCTION_EVIDENCE_PACKAGE:-${PRODUCTION_ACCEPTANCE_PACKAGE:-}}"
PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-86400}}"
PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-300}}"
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
PRODUCTION_STATIC_GATE_RECEIPT_JSON_EXPLICIT=false
if [[ "${PRODUCTION_STATIC_GATE_RECEIPT_JSON+x}" == "x" || "${STATIC_GATE_RECEIPT_JSON+x}" == "x" ]]; then
  PRODUCTION_STATIC_GATE_RECEIPT_JSON_EXPLICIT=true
fi
PRODUCTION_STATIC_GATE_RECEIPT_JSON="${PRODUCTION_STATIC_GATE_RECEIPT_JSON:-${STATIC_GATE_RECEIPT_JSON:-}}"
PRODUCTION_STATIC_GATE_VERIFIER="${PRODUCTION_STATIC_GATE_VERIFIER:-${SCRIPT_DIR}/production_static_gate_receipt.py}"
PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS="${PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS:-86400}"
PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS:-300}"

PRODUCTION_READINESS_STATUS_SELF_TEST="${PRODUCTION_READINESS_STATUS_SELF_TEST:-false}"

usage() {
  cat <<'EOF'
Usage:
  BASE_URL=https://chat.prod.company.com \
  TCP_HOST=tcp.prod.company.com \
  TCP_PORT=9000 \
  CURRENT_PRODUCTION_READINESS_JSON=results/.../current-production-readiness.json \
  PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=/var/lib/imserver/readiness/latest.json \
  PRODUCTION_STATIC_GATE_RECEIPT_JSON=results/production-static/latest.json \
  PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=reports/latest-production-smoke.json \
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON=results/.../production-acceptance.json \
  PRODUCTION_EVIDENCE_PACKAGE=results/.../production-evidence.tar.gz \
    ./production_readiness_status.sh

This is an operator-facing preflight for the final production-ready assertion.
It does not run load traffic and does not replace make assert-production-ready.
It reports missing target/evidence inputs before the final assertion is run.
It also applies the same current-readiness and final-acceptance freshness
windows as the strict verifiers: 86400s max age and 300s max future skew by
default.
If evidence paths are not set explicitly, it searches PRODUCTION_READINESS_RESULT_ROOT
(default: IMServer/LoadTests/results) for the newest matching readiness and
acceptance receipts, topology smoke receipt, and deploy readiness receipt, then
binds the evidence package from the acceptance receipt. It also searches for the
latest local production static gate receipt.
When it fails, the summary prints the next command or operator action needed to
produce or repair the missing production evidence.
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

discover_production_readiness_inputs() {
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

  if [[ -z "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}" && "${PRODUCTION_STATIC_GATE_RECEIPT_JSON_EXPLICIT}" != "true" ]]; then
    discovered="$(latest_existing_file \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-static/latest.json" \
      "${PRODUCTION_READINESS_RESULT_ROOT}/production-static/*/latest.json")"
    if [[ -n "${discovered}" ]]; then
      PRODUCTION_STATIC_GATE_RECEIPT_JSON="${discovered}"
    fi
  fi
}

emit_item() {
  local item="$1"
  local status="$2"
  local reason="${3:-}"
  local detail="${4:-}"
  if [[ -n "${detail}" ]]; then
    printf 'production_readiness_status item=%s status=%s reason=%s %s\n' "${item}" "${status}" "${reason}" "${detail}"
  elif [[ -n "${reason}" ]]; then
    printf 'production_readiness_status item=%s status=%s reason=%s\n' "${item}" "${status}" "${reason}"
  else
    printf 'production_readiness_status item=%s status=%s\n' "${item}" "${status}"
  fi
}

target_validation_reason() {
  python3 "${PRODUCTION_TARGET_POLICY}" \
    --base-url "${BASE_URL}" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --reason-only
}

check_target() {
  local validation reason detail
  if validation="$(target_validation_reason 2>&1)"; then
    emit_item "publicTarget" "pass" "" "baseURL=${BASE_URL} tcpHost=${TCP_HOST} tcpPort=${TCP_PORT}"
    return 0
  fi
  reason="${validation%% *}"
  if [[ "${validation}" == "${reason}" ]]; then
    detail=""
  else
    detail="${validation#${reason} }"
  fi
  emit_item "publicTarget" "fail" "${reason}" "${detail}"
  return 1
}

check_required_file() {
  local item="$1"
  local name="$2"
  local path="$3"
  if [[ -z "${path}" ]]; then
    emit_item "${item}" "fail" "missing_env" "name=${name}"
    return 1
  fi
  if [[ ! -f "${path}" ]]; then
    emit_item "${item}" "fail" "file_missing" "name=${name} path=${path}"
    return 1
  fi
  emit_item "${item}" "pass" "" "path=${path}"
  return 0
}

json_target_validation_reason() {
  local path="$1"
  local name="$2"
  python3 - "${path}" "${name}" "${BASE_URL}" "${TCP_HOST}" "${TCP_PORT}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
name, base_url, tcp_host, tcp_port = sys.argv[2:6]
expected = {
    "baseURL": base_url,
    "tcpHost": tcp_host,
    "tcpPort": str(tcp_port),
}

def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"{reason}{suffix}")

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    fail("invalid_json", f"name={name} path={path} error={exc}")

target = payload.get("target") or {}
for field, expected_value in expected.items():
    actual_value = str(target.get(field) or "")
    if not actual_value:
        fail("json_target_field_missing", f"name={name} field={field} path={path}")
    if actual_value != expected_value:
        fail(
            "target_mismatch",
            f"name={name} field={field} expected={expected_value or '-'} actual={actual_value or '-'} path={path}",
        )
PY
}

check_json_target() {
  local item="$1"
  local name="$2"
  local path="$3"
  local validation reason detail
  if validation="$(json_target_validation_reason "${path}" "${name}" 2>&1)"; then
    emit_item "${item}" "pass" "" "name=${name} baseURL=${BASE_URL} tcpHost=${TCP_HOST} tcpPort=${TCP_PORT}"
    return 0
  fi
  reason="${validation%% *}"
  if [[ "${validation}" == "${reason}" ]]; then
    detail=""
  else
    detail="${validation#${reason} }"
  fi
  emit_item "${item}" "fail" "${reason}" "${detail}"
  return 1
}

json_status_validation_reason() {
  local path="$1"
  local name="$2"
  local expected_status="$3"
  python3 - "${path}" "${name}" "${expected_status}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
expected_status = sys.argv[3]

def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"{reason}{suffix}")

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    fail("invalid_json", f"name={name} path={path} error={exc}")

actual_status = str(payload.get("status") or "")
if not actual_status:
    fail("json_status_field_missing", f"name={name} field=status path={path}")
if actual_status != expected_status:
    fail(
        "json_status_mismatch",
        f"name={name} expected={expected_status} actual={actual_status} path={path}",
    )
PY
}

check_json_status() {
  local item="$1"
  local name="$2"
  local path="$3"
  local expected_status="$4"
  local validation reason detail
  if validation="$(json_status_validation_reason "${path}" "${name}" "${expected_status}" 2>&1)"; then
    emit_item "${item}" "pass" "" "name=${name} status=${expected_status}"
    return 0
  fi
  reason="${validation%% *}"
  if [[ "${validation}" == "${reason}" ]]; then
    detail=""
  else
    detail="${validation#${reason} }"
  fi
  emit_item "${item}" "fail" "${reason}" "${detail}"
  return 1
}

deploy_readiness_receipt_validation_reason() {
  local path="$1"
  local output reason token detail
  if output="$(python3 "${PRODUCTION_DEPLOY_READINESS_VERIFIER}" \
      --receipt-json "${path}" \
      --expect-base-url "${BASE_URL}" \
      --expect-tcp-host "${TCP_HOST}" \
      --expect-tcp-port "${TCP_PORT}" \
      --max-age-seconds "${PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS}" \
      --max-future-skew-seconds "${PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS}" 2>&1)"; then
    return 0
  fi

  reason=""
  for token in ${output}; do
    case "${token}" in
      reason=*)
        reason="${token#reason=}"
        break
        ;;
    esac
  done
  if [[ -z "${reason}" ]]; then
    printf '%s\n' "${output:-deploy_readiness_verify_failed}"
  else
    detail="${output#*reason=${reason}}"
    detail="${detail# }"
    printf '%s%s\n' "${reason}" "${detail:+ ${detail}}"
  fi
  return 1
}

check_deploy_readiness_receipt() {
  local path="$1"
  local validation reason detail
  if validation="$(deploy_readiness_receipt_validation_reason "${path}" 2>&1)"; then
    emit_item "deployReadinessReceipt" "pass" "" "path=${path} maxAgeSeconds=${PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS}"
    return 0
  fi
  reason="${validation%% *}"
  if [[ "${validation}" == "${reason}" ]]; then
    detail=""
  else
    detail="${validation#${reason} }"
  fi
  emit_item "deployReadinessReceipt" "fail" "${reason}" "${detail}"
  return 1
}

static_gate_receipt_validation_reason() {
  local path="$1"
  python3 "${PRODUCTION_STATIC_GATE_VERIFIER}" \
    --verify \
    --receipt-json "${path}" \
    --require-completion-status \
    --require-recovery-plan \
    --require-current-git \
    --require-clean-git \
    --max-age-seconds "${PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS}" \
    --future-skew-seconds "${PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS}"
}

static_gate_next_command() {
  local path="$1"
  local validation reason
  if validation="$(static_gate_receipt_validation_reason "${path}" 2>&1)"; then
    printf 'make production-readiness-status'
    return 0
  fi
  reason="$(extract_reason "${validation}" "production_static_gate_receipt_verify_failed")"
  if [[ "${reason}" == "production_static_gate_git_dirty" ]]; then
    printf 'commit or remove local changes, then make validate-production-static && make production-readiness-status'
    return 0
  fi
  if [[ "${reason}" == "git_binding_mismatch" ]]; then
    printf 'commit intended source changes or ignore only generated local artifacts, then make validate-production-static && make production-readiness-status'
    return 0
  fi
  printf 'make validate-production-static && make production-readiness-status'
}

check_static_gate_receipt() {
  local path="$1"
  local validation reason
  if validation="$(static_gate_receipt_validation_reason "${path}" 2>&1)"; then
    emit_item "productionStaticGateReceipt" "pass" "" "path=${path} maxAgeSeconds=${PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS} cleanGit=true"
    return 0
  fi
  reason="$(extract_reason "${validation}" "production_static_gate_receipt_verify_failed")"
  emit_item "productionStaticGateReceipt" "fail" "${reason}" "${validation//$'\n'/ }"
  return 1
}

current_readiness_freshness_validation_reason() {
  local path="$1"
  python3 - "${path}" "${CURRENT_PRODUCTION_MAX_AGE_SECONDS}" "${CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS}" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])

def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"{reason}{suffix}")

try:
    max_age_seconds = int(sys.argv[2])
except Exception:
    fail("readiness_max_age_invalid", f"value={sys.argv[2]}")
try:
    max_future_skew_seconds = int(sys.argv[3])
except Exception:
    fail("readiness_max_future_skew_invalid", f"value={sys.argv[3]}")
if max_age_seconds <= 0:
    fail("readiness_max_age_invalid", f"value={max_age_seconds}")
if max_future_skew_seconds < 0:
    fail("readiness_max_future_skew_invalid", f"value={max_future_skew_seconds}")

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    fail("invalid_json", f"name=CURRENT_PRODUCTION_READINESS_JSON path={path} error={exc}")
try:
    generated_at = int(payload.get("generatedAtEpoch"))
except Exception:
    fail("readiness_generated_at_invalid", f"value={payload.get('generatedAtEpoch')}")
if generated_at <= 0:
    fail("readiness_generated_at_invalid", f"value={generated_at}")

now = int(time.time())
future_skew_seconds = generated_at - now
if future_skew_seconds > max_future_skew_seconds:
    fail(
        "readiness_generated_at_in_future",
        f"skewSeconds={future_skew_seconds} maxFutureSkewSeconds={max_future_skew_seconds} path={path}",
    )
age_seconds = now - generated_at
if age_seconds > max_age_seconds:
    fail(
        "readiness_stale",
        f"ageSeconds={age_seconds} maxAgeSeconds={max_age_seconds} path={path}",
    )
PY
}

check_current_readiness_freshness() {
  local path="$1"
  local validation reason detail
  if validation="$(current_readiness_freshness_validation_reason "${path}" 2>&1)"; then
    emit_item "currentReadinessFreshness" "pass" "" "maxAgeSeconds=${CURRENT_PRODUCTION_MAX_AGE_SECONDS} maxFutureSkewSeconds=${CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS}"
    return 0
  fi
  reason="${validation%% *}"
  if [[ "${validation}" == "${reason}" ]]; then
    detail=""
  else
    detail="${validation#${reason} }"
  fi
  emit_item "currentReadinessFreshness" "fail" "${reason}" "${detail}"
  return 1
}

acceptance_receipt_freshness_validation_reason() {
  local path="$1"
  python3 - "${path}" "${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" "${PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])

def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"{reason}{suffix}")

try:
    max_age_seconds = int(sys.argv[2])
except Exception:
    fail("receipt_max_age_invalid", f"value={sys.argv[2]}")
try:
    max_future_skew_seconds = int(sys.argv[3])
except Exception:
    fail("receipt_max_future_skew_invalid", f"value={sys.argv[3]}")
if max_age_seconds <= 0:
    fail("receipt_max_age_invalid", f"value={max_age_seconds}")
if max_future_skew_seconds < 0:
    fail("receipt_max_future_skew_invalid", f"value={max_future_skew_seconds}")

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    fail("invalid_json", f"name=PRODUCTION_ACCEPTANCE_RECEIPT_JSON path={path} error={exc}")
try:
    generated_at = int(payload.get("generatedAtEpoch"))
except Exception:
    fail("receipt_generated_at_invalid", f"value={payload.get('generatedAtEpoch')}")
if generated_at <= 0:
    fail("receipt_generated_at_invalid", f"value={generated_at}")

now = int(time.time())
future_skew_seconds = generated_at - now
if future_skew_seconds > max_future_skew_seconds:
    fail(
        "receipt_generated_at_in_future",
        f"skewSeconds={future_skew_seconds} maxFutureSkewSeconds={max_future_skew_seconds} path={path}",
    )
age_seconds = now - generated_at
if age_seconds > max_age_seconds:
    fail(
        "receipt_stale",
        f"ageSeconds={age_seconds} maxAgeSeconds={max_age_seconds} path={path}",
    )
PY
}

check_acceptance_receipt_freshness() {
  local path="$1"
  local validation reason detail
  if validation="$(acceptance_receipt_freshness_validation_reason "${path}" 2>&1)"; then
    emit_item "acceptanceReceiptFreshness" "pass" "" "maxAgeSeconds=${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS} maxFutureSkewSeconds=${PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}"
    return 0
  fi
  reason="${validation%% *}"
  if [[ "${validation}" == "${reason}" ]]; then
    detail=""
  else
    detail="${validation#${reason} }"
  fi
  emit_item "acceptanceReceiptFreshness" "fail" "${reason}" "${detail}"
  return 1
}

evidence_package_validation_reason() {
  local path="$1"
  python3 "${SCRIPT_DIR}/perf_production_acceptance_verify.py" \
    --verify-package-archive \
    --package-file "${path}" \
    --expect-base-url "${BASE_URL}" \
    --expect-tcp-host "${TCP_HOST}" \
    --expect-tcp-port "${TCP_PORT}" \
    --reason-only
  return $?
}

check_evidence_package_target() {
  local path="$1"
  local validation reason detail
  if validation="$(evidence_package_validation_reason "${path}" 2>&1)"; then
    emit_item "evidencePackageTarget" "pass" "" "baseURL=${BASE_URL} tcpHost=${TCP_HOST} tcpPort=${TCP_PORT}"
    return 0
  fi
  reason="${validation%% *}"
  if [[ "${validation}" == "${reason}" ]]; then
    detail=""
  else
    detail="${validation#${reason} }"
  fi
  emit_item "evidencePackageTarget" "fail" "${reason}" "${detail}"
  return 1
}

acceptance_package_binding_validation_reason() {
  local receipt_path="$1"
  local package_path="$2"
  python3 - "${receipt_path}" "${package_path}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

receipt_path = Path(sys.argv[1])
package_path = Path(sys.argv[2])

def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"{reason}{suffix}")

try:
    payload = json.loads(receipt_path.read_text(encoding="utf-8"))
except Exception as exc:
    fail("invalid_json", f"name=PRODUCTION_ACCEPTANCE_RECEIPT_JSON path={receipt_path} error={exc}")

artifacts = payload.get("artifacts") or {}
if not isinstance(artifacts, dict):
    fail("acceptance_package_artifacts_missing", f"path={receipt_path}")
if artifacts.get("packagePresent") is not True:
    fail("acceptance_package_present_flag_invalid", f"path={receipt_path}")
try:
    expected_bytes = int(artifacts.get("packageBytes") or 0)
except Exception:
    fail("acceptance_package_bytes_invalid", f"path={receipt_path}")
if expected_bytes <= 0:
    fail("acceptance_package_bytes_missing", f"path={receipt_path}")
expected_sha = str(artifacts.get("packageSha256") or "")
if len(expected_sha) != 64 or any(char not in "0123456789abcdefABCDEF" for char in expected_sha):
    fail("acceptance_package_sha256_missing", f"path={receipt_path}")
try:
    actual_bytes = package_path.stat().st_size
except OSError as exc:
    fail("acceptance_package_read_failed", f"path={package_path} error={exc}")
if actual_bytes != expected_bytes:
    fail(
        "acceptance_package_bytes_mismatch",
        f"expected={expected_bytes} actual={actual_bytes} path={package_path}",
    )
actual_sha = hashlib.sha256(package_path.read_bytes()).hexdigest()
if actual_sha.lower() != expected_sha.lower():
    fail(
        "acceptance_package_sha256_mismatch",
        f"expected={expected_sha} actual={actual_sha} path={package_path}",
    )
PY
}

check_acceptance_package_binding() {
  local receipt_path="$1"
  local package_path="$2"
  local validation reason detail
  if validation="$(acceptance_package_binding_validation_reason "${receipt_path}" "${package_path}" 2>&1)"; then
    emit_item "acceptancePackageBinding" "pass" "" "receipt=${receipt_path} package=${package_path}"
    return 0
  fi
  reason="${validation%% *}"
  if [[ "${validation}" == "${reason}" ]]; then
    detail=""
  else
    detail="${validation#${reason} }"
  fi
  emit_item "acceptancePackageBinding" "fail" "${reason}" "${detail}"
  return 1
}

topology_smoke_validation_reason() {
  local path="$1"
  python3 "${PRODUCTION_TOPOLOGY_SMOKE_VERIFIER}" \
    --receipt-json "${path}" \
    --require-pass \
    --require-artifacts-exist \
    --max-age-seconds "${PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}" \
    --max-future-skew-seconds "${PRODUCTION_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS}"
}

extract_reason() {
  local validation="$1"
  local reason
  if [[ "${validation}" == *"reason="* ]]; then
    reason="${validation#*reason=}"
    reason="${reason%% *}"
    printf '%s' "${reason}"
    return 0
  fi
  printf '%s' "$2"
}

check_topology_smoke_receipt() {
  local path="$1"
  local validation reason
  if validation="$(topology_smoke_validation_reason "${path}" 2>&1)"; then
    emit_item "topologySmokeReceipt" "pass" "" "path=${path} maxAgeSeconds=${PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS}"
    return 0
  fi
  reason="$(extract_reason "${validation}" "topology_smoke_verify_failed")"
  emit_item "topologySmokeReceipt" "fail" "${reason}" "${validation//$'\n'/ }"
  return 1
}

path_missing() {
  local path="$1"
  [[ -z "${path}" || ! -f "${path}" ]]
}

next_command_for_failures() {
  if [[ -z "${BASE_URL}" || -z "${TCP_HOST}" || -z "${TCP_PORT}" ]]; then
    printf 'set BASE_URL/TCP_HOST/TCP_PORT, then make run-production-acceptance'
    return 0
  fi
  if ! target_validation_reason >/dev/null 2>&1; then
    printf 'fix BASE_URL/TCP_HOST/TCP_PORT, then make run-production-acceptance'
    return 0
  fi
  if path_missing "${CURRENT_PRODUCTION_READINESS_JSON}"; then
    printf 'make run-current-production-readiness && make production-readiness-status'
    return 0
  fi
  if ! json_status_validation_reason "${CURRENT_PRODUCTION_READINESS_JSON}" "CURRENT_PRODUCTION_READINESS_JSON" "PASS" >/dev/null 2>&1; then
    printf 'make run-current-production-readiness && make production-readiness-status'
    return 0
  fi
  if ! current_readiness_freshness_validation_reason "${CURRENT_PRODUCTION_READINESS_JSON}" >/dev/null 2>&1; then
    printf 'make run-current-production-readiness && make production-readiness-status'
    return 0
  fi
  if path_missing "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}"; then
    printf 'make run-imserver-production-smoke && make production-readiness-status'
    return 0
  fi
  if ! topology_smoke_validation_reason "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}" >/dev/null 2>&1; then
    printf 'make run-imserver-production-smoke && make production-readiness-status'
    return 0
  fi
  if path_missing "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}"; then
    printf 'sudo -E make run-production-readiness-gate && make production-readiness-status'
    return 0
  fi
  if ! deploy_readiness_receipt_validation_reason "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}" >/dev/null 2>&1; then
    printf 'sudo -E make run-production-readiness-gate && make production-readiness-status'
    return 0
  fi
  if path_missing "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}"; then
    printf 'make validate-production-static && make production-readiness-status'
    return 0
  fi
  if ! static_gate_receipt_validation_reason "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}" >/dev/null 2>&1; then
    static_gate_next_command "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}"
    return 0
  fi
  if path_missing "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" || path_missing "${PRODUCTION_EVIDENCE_PACKAGE}"; then
    printf 'make run-production-acceptance && make production-readiness-status'
    return 0
  fi
  if ! acceptance_receipt_freshness_validation_reason "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" >/dev/null 2>&1; then
    printf 'make run-production-acceptance && make production-readiness-status'
    return 0
  fi
  printf 'make run-production-acceptance && make production-readiness-status'
}

run_status() {
  local failures=0
  local acceptance_receipt_present=false
  local evidence_package_present=false
  local next_command

  check_target || failures=$((failures + 1))
  if check_required_file "currentReadiness" "CURRENT_PRODUCTION_READINESS_JSON" "${CURRENT_PRODUCTION_READINESS_JSON}"; then
    check_json_target "currentReadinessTarget" "CURRENT_PRODUCTION_READINESS_JSON" "${CURRENT_PRODUCTION_READINESS_JSON}" || failures=$((failures + 1))
    check_json_status "currentReadinessStatus" "CURRENT_PRODUCTION_READINESS_JSON" "${CURRENT_PRODUCTION_READINESS_JSON}" "PASS" || failures=$((failures + 1))
    check_current_readiness_freshness "${CURRENT_PRODUCTION_READINESS_JSON}" || failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi
  if check_required_file "topologySmokeReceiptFile" "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON" "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}"; then
    check_topology_smoke_receipt "${PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON}" || failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi
  if check_required_file "deployReadinessReceiptFile" "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON" "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}"; then
    check_deploy_readiness_receipt "${PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON}" || failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi
  if check_required_file "productionStaticGateReceiptFile" "PRODUCTION_STATIC_GATE_RECEIPT_JSON" "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}"; then
    check_static_gate_receipt "${PRODUCTION_STATIC_GATE_RECEIPT_JSON}" || failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi
  if check_required_file "acceptanceReceipt" "PRODUCTION_ACCEPTANCE_RECEIPT_JSON" "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"; then
    acceptance_receipt_present=true
    check_json_target "acceptanceReceiptTarget" "PRODUCTION_ACCEPTANCE_RECEIPT_JSON" "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" || failures=$((failures + 1))
    check_json_status "acceptanceReceiptStatus" "PRODUCTION_ACCEPTANCE_RECEIPT_JSON" "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" "PASS" || failures=$((failures + 1))
    check_acceptance_receipt_freshness "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" || failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi
  if check_required_file "evidencePackage" "PRODUCTION_EVIDENCE_PACKAGE" "${PRODUCTION_EVIDENCE_PACKAGE}"; then
    evidence_package_present=true
    check_evidence_package_target "${PRODUCTION_EVIDENCE_PACKAGE}" || failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi
  if [[ "${acceptance_receipt_present}" == "true" && "${evidence_package_present}" == "true" ]]; then
    check_acceptance_package_binding "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" "${PRODUCTION_EVIDENCE_PACKAGE}" || failures=$((failures + 1))
  fi

  if [[ "${failures}" -eq 0 ]]; then
    printf 'production_readiness_status readyToAssert=true nextCommand="make assert-production-ready"\n'
    return 0
  fi

  next_command="$(next_command_for_failures)"
  printf 'production_readiness_status readyToAssert=false failures=%s nextCommand="%s"\n' "${failures}" "${next_command}"
  return 1
}

run_self_test() {
  local tmpdir readiness stale_readiness topology_receipt deploy_receipt static_receipt receipt package mismatched_package no_checksum_package tampered_package failed_package_status bad_readme_package bad_readiness_md_package stale_manifest_record_package
  local mismatched_receipt_package_sha mismatched_receipt_package_bytes missing_receipt_package_artifacts stale_acceptance_receipt
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  git -C "${tmpdir}" init -q
  git -C "${tmpdir}" config user.email "production-readiness-self-test@example.invalid"
  git -C "${tmpdir}" config user.name "Production Readiness Self Test"
  git -C "${tmpdir}" commit --allow-empty -m "initial self-test state" -q
  printf '*\n' >>"${tmpdir}/.git/info/exclude"
  export PRODUCTION_READINESS_RESULT_ROOT="${tmpdir}/empty-results"
  mkdir -p "${PRODUCTION_READINESS_RESULT_ROOT}"

  readiness="${tmpdir}/current-production-readiness.json"
  stale_readiness="${tmpdir}/stale-current-production-readiness.json"
  topology_receipt="${tmpdir}/latest-production-smoke.json"
  deploy_receipt="${tmpdir}/deploy-readiness-latest.json"
  static_receipt="${tmpdir}/production-static-gate-latest.json"
  receipt="${tmpdir}/production-acceptance.json"
  package="${tmpdir}/production-evidence.tar.gz"
  mismatched_package="${tmpdir}/mismatched-production-evidence.tar.gz"
  no_checksum_package="${tmpdir}/no-checksum-production-evidence.tar.gz"
  tampered_package="${tmpdir}/tampered-production-evidence.tar.gz"
  failed_package_status="${tmpdir}/failed-status-production-evidence.tar.gz"
  bad_readme_package="${tmpdir}/bad-readme-production-evidence.tar.gz"
  bad_readiness_md_package="${tmpdir}/bad-readiness-md-production-evidence.tar.gz"
  stale_manifest_record_package="${tmpdir}/stale-manifest-record-production-evidence.tar.gz"
  mismatched_receipt_package_sha="${tmpdir}/mismatched-package-sha-production-acceptance.json"
  mismatched_receipt_package_bytes="${tmpdir}/mismatched-package-bytes-production-acceptance.json"
  missing_receipt_package_artifacts="${tmpdir}/missing-package-artifacts-production-acceptance.json"
  stale_acceptance_receipt="${tmpdir}/stale-production-acceptance.json"
  python3 - "${readiness}" "${stale_readiness}" <<'PY'
import json
import sys
import time
from pathlib import Path

readiness = Path(sys.argv[1])
stale_readiness = Path(sys.argv[2])
payload = {
    "schemaVersion": 1,
    "status": "PASS",
    "generatedAtEpoch": int(time.time()),
    "target": {
        "baseURL": "https://chat.myim-prod.com",
        "tcpHost": "tcp.myim-prod.com",
        "tcpPort": "9000",
    },
}
readiness.write_text(json.dumps(payload), encoding="utf-8")
stale_payload = json.loads(json.dumps(payload))
stale_payload["generatedAtEpoch"] = int(time.time()) - 90000
stale_readiness.write_text(json.dumps(stale_payload), encoding="utf-8")
PY
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
receipt.write_text(json.dumps(payload), encoding="utf-8")
PY
  export PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}"
  python3 - "${deploy_receipt}" "${topology_receipt}" <<'PY'
import json
import sys
import time
from pathlib import Path

receipt = Path(sys.argv[1])
topology_receipt = Path(sys.argv[2])
payload = {
    "schemaVersion": 1,
    "kind": "imserver-production-readiness-gate",
    "status": "pass",
    "generatedAtEpoch": int(time.time()),
    "appEnv": "production",
    "target": {
        "publicBaseURL": "https://chat.myim-prod.com",
        "httpPort": 443,
        "performanceGateExpectBaseURL": "https://chat.myim-prod.com",
        "performanceGateExpectTCPHost": "tcp.myim-prod.com",
        "performanceGateExpectTCPPort": "9000",
    },
    "policy": {
        "requirePerformanceGate": True,
        "requireSmoke": True,
        "requireBackup": True,
        "verifyBackup": True,
        "requireLatestBackupFreshness": True,
        "latestBackupMaxAgeSeconds": 172800,
        "latestBackupMaxFutureSkewSeconds": 300,
        "requireRestoreDrillFreshness": True,
        "restoreDrillMaxAgeSeconds": 3888000,
        "restoreDrillMaxFutureSkewSeconds": 300,
        "requireOffsiteBackupFreshness": True,
        "offsiteBackupMaxAgeSeconds": 172800,
        "offsiteBackupMaxFutureSkewSeconds": 300,
        "runRestoreDrill": False,
        "requireAuditTimer": True,
        "requireRestoreDrillTimer": True,
        "requireTimeSync": True,
        "requireAlertWebhook": True,
        "requireCloudSecurityGroup": True,
        "requireCloudSecurityGroupRepairReceipt": True,
        "requireNginxConfig": True,
        "nginxRequireSSL": False,
        "requireTopologySmoke": True,
        "topologySmokeMaxAgeSeconds": 86400,
        "topologySmokeRequireArtifacts": True,
        "collectDiagnostics": False,
    },
    "cloudSecurityGroupPolicy": {
        "publicClientPorts": ["80", "443", "9000"],
        "denyPublicPorts": ["3389", "5432", "6379", "9092", "8081", "8082", "18080", "8080"],
        "adminPorts": ["22"],
        "requirePublicClientPorts": True,
    },
    "performanceEvidencePolicy": {
        "gateJSON": "/var/lib/imserver/performance/production-gate.json",
        "gateProfile": "normal-product-baseline",
        "gateMaxAgeSeconds": 604800,
        "gateRequireCurrentGit": False,
        "gateRequireCleanGit": False,
        "evidenceCurrentLink": "/var/lib/imserver/performance/current-evidence",
        "requireProfileArtifacts": True,
        "requireProductPlanArtifacts": True,
        "requireProductCampaignArtifacts": True,
        "requireProductScenarioSuiteArtifacts": True,
        "requireProductScenarioSuiteNoLargeGroup": True,
        "requireValidationInventory": True,
        "requireCurrentReadinessArtifacts": True,
        "requireCloudSecurityGroup": True,
        "requireProductionAcceptance": True,
    },
    "artifacts": {
        "latestBackupDir": "/var/backups/imserver/latest",
        "restoreDrillReceipt": "/var/lib/imserver/restore-drill/latest.json",
        "offsiteBackupReceipt": "/var/lib/imserver/offsite-backup/latest.json",
        "cloudSecurityGroupRulesFile": "/etc/imserver/cloud-security-group.json",
        "cloudSecurityGroupRepairReceipt": "/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json",
        "nginxHTTPConf": "/etc/nginx/conf.d/imserver.conf",
        "nginxLocationsConf": "/etc/nginx/snippets/imserver_locations.conf",
        "nginxSSLConf": "/etc/nginx/conf.d/imserver_ssl.conf",
        "topologySmokeReceipt": str(topology_receipt),
    },
    "steps": [
        {"name": "systemd-units", "status": "pass"},
        {"name": "production-env", "status": "pass"},
        {"name": "entrypoint", "status": "pass"},
        {"name": "application-smoke", "status": "pass"},
        {"name": "topology-smoke-receipt", "status": "pass"},
        {"name": "operational-audit", "status": "pass"},
        {"name": "latest-backup-verify", "status": "pass"},
        {"name": "restore-drill", "status": "skipped"},
        {"name": "diagnostics-redaction-self-test", "status": "pass"},
        {"name": "performance-gate", "status": "pass"},
        {"name": "performance-evidence", "status": "pass"},
        {"name": "diagnostics-bundle", "status": "skipped"},
        {"name": "receipt", "status": "pass"},
    ],
}
receipt.write_text(json.dumps(payload), encoding="utf-8")
PY
  export PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON="${deploy_receipt}"
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
  export PRODUCTION_STATIC_GATE_RECEIPT_JSON="${static_receipt}"
  cat >"${receipt}" <<'JSON'
{"schemaVersion":1,"status":"PASS","target":{"baseURL":"https://chat.myim-prod.com","tcpHost":"tcp.myim-prod.com","tcpPort":"9000"}}
JSON
  python3 - "${package}" "${mismatched_package}" "${no_checksum_package}" "${tampered_package}" "${failed_package_status}" "${bad_readme_package}" "${bad_readiness_md_package}" "${stale_manifest_record_package}" "${SCRIPT_DIR}" <<'PY'
import hashlib
import json
import tarfile
import tempfile
from pathlib import Path
import sys

script_dir = Path(sys.argv[9])
sys.path.insert(0, str(script_dir))
from perf_current_production_readiness_verify import build_readiness_markdown

package = Path(sys.argv[1])
mismatched_package = Path(sys.argv[2])
no_checksum_package = Path(sys.argv[3])
tampered_package = Path(sys.argv[4])
failed_package_status = Path(sys.argv[5])
bad_readme_package = Path(sys.argv[6])
bad_readiness_md_package = Path(sys.argv[7])
stale_manifest_record_package = Path(sys.argv[8])
target = {"baseURL": "https://chat.myim-prod.com", "tcpHost": "tcp.myim-prod.com", "tcpPort": "9000"}

def write_package(
    path: Path,
    package_target: dict[str, str],
    *,
    include_checksums: bool = True,
    tamper_after_checksums: bool = False,
    readiness_status: str = "PASS",
    readme_status = None,
    markdown_status = None,
    stale_manifest_record: bool = False,
) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        readiness_payload = {
            "schemaVersion": 1,
            "status": readiness_status,
            "reason": "entrypoint_and_requested_runs_passed",
            "target": package_target,
            "requestedRuns": {
                "smoke": True,
                "productScenarioSuite": True,
                "baseline": True,
                "fullAcceptance": True,
            },
            "runs": {
                "smokeExitCode": 0,
                "suiteExitCode": 0,
                "baselineExitCode": 0,
                "fullAcceptanceExitCode": 0,
            },
        }
        (root / "current-production-readiness.json").write_text(json.dumps(readiness_payload), encoding="utf-8")
        markdown_status = markdown_status or readiness_status
        if markdown_status == readiness_status:
            readiness_markdown = build_readiness_markdown(readiness_payload)
        else:
            readiness_markdown = "# Current Production Readiness\n\n" f"- status: `{markdown_status}`\n"
        (root / "current-production-readiness.md").write_text(readiness_markdown, encoding="utf-8")
        readme_status = readme_status or readiness_status
        (root / "README.md").write_text(
            "# Production Performance Evidence\n\n"
            "Install on the target server with `69_install_performance_evidence_package.sh`.\n"
            "Do not install only `production-gate.json`.\n\n"
            "- status: `PASS`\n"
            "- profile: `normal-product-baseline`\n"
            "- docsAudit: `PASS`\n"
            "- productProfileGate: `PASS`\n"
            f"- currentReadinessStatus: `{readme_status}`\n"
            "- currentReadinessRequestedSmoke/ProductSuite/Baseline/Full: `True/True/True/True`\n"
            "- currentReadinessExitCodesSmoke/ProductSuite/Baseline/Full: `0/0/0/0`\n\n"
            "Install on the target server:\n\n"
            "```bash\n"
            "sudo bash deploy/ubuntu/69_install_performance_evidence_package.sh \\\n"
            "  /tmp/production-evidence.tar.gz\n"
            "```\n",
            encoding="utf-8",
        )
        (root / "production-gate.json").write_text(
            json.dumps({
                "schemaVersion": 1,
                "status": "PASS",
                "profile": "normal-product-baseline",
            }),
            encoding="utf-8",
        )
        files = []
        for member in sorted(root.iterdir(), key=lambda item: item.name):
            if not member.is_file() or member.name in {
                "production-evidence-manifest.json",
                "SHA256SUMS",
                "production-acceptance.json",
                "production-acceptance-package.tar.gz",
            }:
                continue
            files.append({
                "path": member.name,
                "bytes": member.stat().st_size,
                "sha256": hashlib.sha256(member.read_bytes()).hexdigest(),
            })
        manifest = {
            "schemaVersion": 1,
            "profile": "normal-product-baseline",
            "docsAudit": {"status": "PASS"},
            "productProfileGate": {"status": "PASS"},
            "currentReadiness": {
                "present": True,
                "status": readiness_payload["status"],
                "reason": readiness_payload["reason"],
                "target": package_target,
                "requestedRuns": readiness_payload["requestedRuns"],
                "runs": readiness_payload["runs"],
            },
            "files": files,
        }
        (root / "production-evidence-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        if stale_manifest_record:
            (root / "README.md").write_text(
                (root / "README.md").read_text(encoding="utf-8") + "\nAdditional operator note after manifest generation.\n",
                encoding="utf-8",
            )
        if include_checksums:
            rows = []
            for member in sorted(root.iterdir()):
                if member.name == "SHA256SUMS":
                    continue
                digest = hashlib.sha256(member.read_bytes()).hexdigest()
                rows.append(f"{digest}  ./{member.name}\n")
            (root / "SHA256SUMS").write_text("".join(rows), encoding="utf-8")
        if tamper_after_checksums:
            (root / "current-production-readiness.md").write_text("# Tampered\n", encoding="utf-8")
        with tarfile.open(path, "w:gz") as archive:
            for member in sorted(root.iterdir()):
                archive.add(member, arcname=f"./{member.name}")

write_package(package, target)
bad_target = dict(target)
bad_target["tcpHost"] = "other.myim-prod.com"
write_package(mismatched_package, bad_target)
write_package(no_checksum_package, target, include_checksums=False)
write_package(tampered_package, target, tamper_after_checksums=True)
write_package(failed_package_status, target, readiness_status="FAIL")
write_package(bad_readme_package, target, readme_status="FAIL")
write_package(bad_readiness_md_package, target, markdown_status="FAIL")
write_package(stale_manifest_record_package, target, stale_manifest_record=True)
PY
  python3 - "${receipt}" "${package}" "${mismatched_receipt_package_sha}" "${mismatched_receipt_package_bytes}" "${missing_receipt_package_artifacts}" "${stale_acceptance_receipt}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

receipt = Path(sys.argv[1])
package = Path(sys.argv[2])
mismatched_sha = Path(sys.argv[3])
mismatched_bytes = Path(sys.argv[4])
missing_artifacts = Path(sys.argv[5])
stale_receipt = Path(sys.argv[6])
target = {"baseURL": "https://chat.myim-prod.com", "tcpHost": "tcp.myim-prod.com", "tcpPort": "9000"}
payload = {
    "schemaVersion": 1,
    "status": "PASS",
    "generatedAtEpoch": int(time.time()),
    "target": target,
    "artifacts": {
        "package": str(package),
        "packagePresent": True,
        "packageBytes": package.stat().st_size,
        "packageSha256": hashlib.sha256(package.read_bytes()).hexdigest(),
    },
}
receipt.write_text(json.dumps(payload), encoding="utf-8")

bad_sha = json.loads(json.dumps(payload))
bad_sha["artifacts"]["packageSha256"] = "0" * 64
mismatched_sha.write_text(json.dumps(bad_sha), encoding="utf-8")

bad_bytes = json.loads(json.dumps(payload))
bad_bytes["artifacts"]["packageBytes"] = int(bad_bytes["artifacts"]["packageBytes"]) + 1
mismatched_bytes.write_text(json.dumps(bad_bytes), encoding="utf-8")

missing_artifacts.write_text(
    json.dumps({"schemaVersion": 1, "status": "PASS", "target": target}),
    encoding="utf-8",
)

stale_payload = json.loads(json.dumps(payload))
stale_payload["generatedAtEpoch"] = int(time.time()) - 90000
stale_receipt.write_text(json.dumps(stale_payload), encoding="utf-8")
PY

  if PRODUCTION_READINESS_STATUS_SELF_TEST=false bash "${BASH_SOURCE[0]}" >"${tmpdir}/missing-env.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=missing_env_passed\n' >&2
    exit 1
  fi
  grep -q 'readyToAssert=false' "${tmpdir}/missing-env.log" || {
    printf 'production_readiness_status_self_test result=fail reason=missing_env_summary_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="set BASE_URL/TCP_HOST/TCP_PORT, then make run-production-acceptance"' "${tmpdir}/missing-env.log" || {
    printf 'production_readiness_status_self_test result=fail reason=missing_env_next_command_wrong\n' >&2
    exit 1
  }

  if BASE_URL=http://127.0.0.1:8080 \
    TCP_HOST=127.0.0.1 \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/local-target.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=local_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=base_url_https_required' "${tmpdir}/local-target.log" || {
    printf 'production_readiness_status_self_test result=fail reason=local_target_reason_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="fix BASE_URL/TCP_HOST/TCP_PORT, then make run-production-acceptance"' "${tmpdir}/local-target.log" || {
    printf 'production_readiness_status_self_test result=fail reason=local_target_next_command_wrong\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com/api \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/path-target.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=path_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=base_url_origin_required' "${tmpdir}/path-target.log" || {
    printf 'production_readiness_status_self_test result=fail reason=path_target_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}.missing" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/missing-file.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=missing_file_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=file_missing name=CURRENT_PRODUCTION_READINESS_JSON' "${tmpdir}/missing-file.log" || {
    printf 'production_readiness_status_self_test result=fail reason=missing_file_reason_missing\n' >&2
    exit 1
  }

  cp "${receipt}" "${tmpdir}/mismatched-production-acceptance.json"
  python3 - "${tmpdir}/mismatched-production-acceptance.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["target"]["baseURL"] = "https://other.myim-prod.com"
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${tmpdir}/mismatched-production-acceptance.json" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/mismatched-receipt.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=mismatched_receipt_target_passed\n' >&2
    exit 1
  fi
  grep -q 'item=acceptanceReceiptTarget status=fail reason=target_mismatch' "${tmpdir}/mismatched-receipt.log" || {
    printf 'production_readiness_status_self_test result=fail reason=mismatched_receipt_target_reason_missing\n' >&2
    exit 1
  }

  printf '{"schemaVersion":1}\n' >"${tmpdir}/missing-target-readiness.json"
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${tmpdir}/missing-target-readiness.json" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/missing-target-readiness.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=missing_readiness_target_passed\n' >&2
    exit 1
  fi
  grep -q 'item=currentReadinessTarget status=fail reason=json_target_field_missing' "${tmpdir}/missing-target-readiness.log" || {
    printf 'production_readiness_status_self_test result=fail reason=missing_readiness_target_reason_missing\n' >&2
    exit 1
  }

  cp "${readiness}" "${tmpdir}/failed-current-readiness.json"
  python3 - "${tmpdir}/failed-current-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["status"] = "FAIL"
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${tmpdir}/failed-current-readiness.json" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/failed-current-readiness.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=failed_readiness_status_passed\n' >&2
    exit 1
  fi
  grep -q 'item=currentReadinessStatus status=fail reason=json_status_mismatch' "${tmpdir}/failed-current-readiness.log" || {
    printf 'production_readiness_status_self_test result=fail reason=failed_readiness_status_reason_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="make run-current-production-readiness && make production-readiness-status"' "${tmpdir}/failed-current-readiness.log" || {
    printf 'production_readiness_status_self_test result=fail reason=failed_readiness_status_next_command_wrong\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${stale_readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/stale-current-readiness.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=stale_current_readiness_passed\n' >&2
    exit 1
  fi
  grep -q 'item=currentReadinessFreshness status=fail reason=readiness_stale' "${tmpdir}/stale-current-readiness.log" || {
    printf 'production_readiness_status_self_test result=fail reason=stale_current_readiness_reason_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="make run-current-production-readiness && make production-readiness-status"' "${tmpdir}/stale-current-readiness.log" || {
    printf 'production_readiness_status_self_test result=fail reason=stale_current_readiness_next_command_wrong\n' >&2
    exit 1
  }

  cp "${deploy_receipt}" "${tmpdir}/mismatched-deploy-readiness.json"
  python3 - "${tmpdir}/mismatched-deploy-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["target"]["performanceGateExpectTCPHost"] = "other.myim-prod.com"
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON="${tmpdir}/mismatched-deploy-readiness.json" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/mismatched-deploy-readiness.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=mismatched_deploy_readiness_passed\n' >&2
    exit 1
  fi
  grep -q 'item=deployReadinessReceipt status=fail reason=deploy_readiness_target_mismatch' "${tmpdir}/mismatched-deploy-readiness.log" || {
    printf 'production_readiness_status_self_test result=fail reason=mismatched_deploy_readiness_reason_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="sudo -E make run-production-readiness-gate && make production-readiness-status"' "${tmpdir}/mismatched-deploy-readiness.log" || {
    printf 'production_readiness_status_self_test result=fail reason=mismatched_deploy_readiness_next_command_wrong\n' >&2
    exit 1
  }

  cp "${deploy_receipt}" "${tmpdir}/weakened-deploy-readiness.json"
  python3 - "${tmpdir}/weakened-deploy-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["policy"]["requireRestoreDrillFreshness"] = False
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON="${tmpdir}/weakened-deploy-readiness.json" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/weakened-deploy-readiness.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=weakened_deploy_readiness_passed\n' >&2
    exit 1
  fi
  grep -q 'item=deployReadinessReceipt status=fail reason=deploy_readiness_policy_not_enforced' "${tmpdir}/weakened-deploy-readiness.log" || {
    printf 'production_readiness_status_self_test result=fail reason=weakened_deploy_readiness_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_STATIC_GATE_RECEIPT_JSON="${static_receipt}.missing" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/missing-static-gate.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=missing_static_gate_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=file_missing name=PRODUCTION_STATIC_GATE_RECEIPT_JSON' "${tmpdir}/missing-static-gate.log" || {
    printf 'production_readiness_status_self_test result=fail reason=missing_static_gate_reason_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="make validate-production-static && make production-readiness-status"' "${tmpdir}/missing-static-gate.log" || {
    printf 'production_readiness_status_self_test result=fail reason=missing_static_gate_next_command_wrong\n' >&2
    exit 1
  }

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
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_STATIC_GATE_RECEIPT_JSON="${tmpdir}/dirty-static-gate.json" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/dirty-static-gate.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=dirty_static_gate_passed\n' >&2
    exit 1
  fi
  grep -q 'item=productionStaticGateReceipt status=fail reason=git_binding_mismatch' "${tmpdir}/dirty-static-gate.log" || {
    printf 'production_readiness_status_self_test result=fail reason=dirty_static_gate_reason_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="commit intended source changes or ignore only generated local artifacts, then make validate-production-static && make production-readiness-status"' "${tmpdir}/dirty-static-gate.log" || {
    printf 'production_readiness_status_self_test result=fail reason=dirty_static_gate_next_command_wrong\n' >&2
    exit 1
  }

  cp "${static_receipt}" "${tmpdir}/git-binding-static-gate.json"
  python3 - "${tmpdir}/git-binding-static-gate.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["git"] = {
    **(payload.get("git") or {}),
    "dirtyCount": int((payload.get("git") or {}).get("dirtyCount") or 0) + 1,
}
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_STATIC_GATE_RECEIPT_JSON="${tmpdir}/git-binding-static-gate.json" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/git-binding-static-gate.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=git_binding_static_gate_passed\n' >&2
    exit 1
  fi
  grep -q 'item=productionStaticGateReceipt status=fail reason=git_binding_mismatch' "${tmpdir}/git-binding-static-gate.log" || {
    printf 'production_readiness_status_self_test result=fail reason=git_binding_static_gate_reason_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="commit intended source changes or ignore only generated local artifacts, then make validate-production-static && make production-readiness-status"' "${tmpdir}/git-binding-static-gate.log" || {
    printf 'production_readiness_status_self_test result=fail reason=git_binding_static_gate_next_command_wrong\n' >&2
    exit 1
  }

  cp "${receipt}" "${tmpdir}/failed-production-acceptance.json"
  python3 - "${tmpdir}/failed-production-acceptance.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["status"] = "FAIL"
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${tmpdir}/failed-production-acceptance.json" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/failed-production-acceptance.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=failed_acceptance_status_passed\n' >&2
    exit 1
  fi
  grep -q 'item=acceptanceReceiptStatus status=fail reason=json_status_mismatch' "${tmpdir}/failed-production-acceptance.log" || {
    printf 'production_readiness_status_self_test result=fail reason=failed_acceptance_status_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${stale_acceptance_receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/stale-acceptance-receipt.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=stale_acceptance_receipt_passed\n' >&2
    exit 1
  fi
  grep -q 'item=acceptanceReceiptFreshness status=fail reason=receipt_stale' "${tmpdir}/stale-acceptance-receipt.log" || {
    printf 'production_readiness_status_self_test result=fail reason=stale_acceptance_receipt_reason_missing\n' >&2
    exit 1
  }
  grep -q 'nextCommand="make run-production-acceptance && make production-readiness-status"' "${tmpdir}/stale-acceptance-receipt.log" || {
    printf 'production_readiness_status_self_test result=fail reason=stale_acceptance_receipt_next_command_wrong\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${mismatched_receipt_package_sha}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/mismatched-package-sha.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=mismatched_package_sha_passed\n' >&2
    exit 1
  fi
  grep -q 'item=acceptancePackageBinding status=fail reason=acceptance_package_sha256_mismatch' "${tmpdir}/mismatched-package-sha.log" || {
    printf 'production_readiness_status_self_test result=fail reason=mismatched_package_sha_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${mismatched_receipt_package_bytes}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/mismatched-package-bytes.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=mismatched_package_bytes_passed\n' >&2
    exit 1
  fi
  grep -q 'item=acceptancePackageBinding status=fail reason=acceptance_package_bytes_mismatch' "${tmpdir}/mismatched-package-bytes.log" || {
    printf 'production_readiness_status_self_test result=fail reason=mismatched_package_bytes_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${missing_receipt_package_artifacts}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/missing-package-artifacts.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=missing_package_artifacts_passed\n' >&2
    exit 1
  fi
  grep -q 'item=acceptancePackageBinding status=fail reason=acceptance_package_present_flag_invalid' "${tmpdir}/missing-package-artifacts.log" || {
    printf 'production_readiness_status_self_test result=fail reason=missing_package_artifacts_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${mismatched_package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/mismatched-package.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=mismatched_package_target_passed\n' >&2
    exit 1
  fi
  grep -q 'item=evidencePackageTarget status=fail reason=package_manifest_current_readiness_target_mismatch' "${tmpdir}/mismatched-package.log" || {
    printf 'production_readiness_status_self_test result=fail reason=mismatched_package_target_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${no_checksum_package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/no-checksum-package.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=no_checksum_package_passed\n' >&2
    exit 1
  fi
  grep -q 'item=evidencePackageTarget status=fail reason=package_archive_required_member_missing' "${tmpdir}/no-checksum-package.log" || {
    printf 'production_readiness_status_self_test result=fail reason=no_checksum_package_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${tampered_package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/tampered-package.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=tampered_package_passed\n' >&2
    exit 1
  fi
  grep -q 'item=evidencePackageTarget status=fail reason=package_checksum_mismatch' "${tmpdir}/tampered-package.log" || {
    printf 'production_readiness_status_self_test result=fail reason=tampered_package_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${failed_package_status}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/failed-package-status.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=failed_package_status_passed\n' >&2
    exit 1
  fi
  grep -q 'item=evidencePackageTarget status=fail reason=package_current_readiness_status_mismatch' "${tmpdir}/failed-package-status.log" || {
    printf 'production_readiness_status_self_test result=fail reason=failed_package_status_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${bad_readme_package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/bad-readme-package.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=bad_readme_package_passed\n' >&2
    exit 1
  fi
  grep -q 'item=evidencePackageTarget status=fail reason=package_readme_current_readiness_status_mismatch' "${tmpdir}/bad-readme-package.log" || {
    printf 'production_readiness_status_self_test result=fail reason=bad_readme_package_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${bad_readiness_md_package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/bad-readiness-md-package.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=bad_readiness_md_package_passed\n' >&2
    exit 1
  fi
  grep -q 'item=evidencePackageTarget status=fail reason=package_current_readiness_markdown_mismatch' "${tmpdir}/bad-readiness-md-package.log" || {
    printf 'production_readiness_status_self_test result=fail reason=bad_readiness_md_package_reason_missing\n' >&2
    exit 1
  }

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${stale_manifest_record_package}" \
    PRODUCTION_READINESS_STATUS_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmpdir}/stale-manifest-record-package.log" 2>&1; then
    printf 'production_readiness_status_self_test result=fail reason=stale_manifest_record_package_passed\n' >&2
    exit 1
  fi
  grep -Eq 'item=evidencePackageTarget status=fail reason=package_manifest_file_record_(bytes|sha256)_mismatch' "${tmpdir}/stale-manifest-record-package.log" || {
    printf 'production_readiness_status_self_test result=fail reason=stale_manifest_record_package_reason_missing\n' >&2
    exit 1
  }

  BASE_URL=https://chat.myim-prod.com \
  TCP_HOST=tcp.myim-prod.com \
  TCP_PORT=9000 \
  CURRENT_PRODUCTION_READINESS_JSON="${readiness}" \
  PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON="${topology_receipt}" \
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
  PRODUCTION_EVIDENCE_PACKAGE="${package}" \
  PRODUCTION_READINESS_STATUS_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${tmpdir}/ready.log"
  grep -q 'readyToAssert=true' "${tmpdir}/ready.log" || {
    printf 'production_readiness_status_self_test result=fail reason=ready_summary_missing\n' >&2
    exit 1
  }

  auto_root="${tmpdir}/auto-results"
  mkdir -p "${auto_root}/current-production-readiness-latest" "${auto_root}/production-acceptance/latest" "${auto_root}/production-smoke" "${auto_root}/deploy-readiness" "${auto_root}/production-static"
  cp "${readiness}" "${auto_root}/current-production-readiness-latest/current-production-readiness.json"
  cp "${topology_receipt}" "${auto_root}/production-smoke/latest-production-smoke.json"
  cp "${deploy_receipt}" "${auto_root}/deploy-readiness/latest.json"
  cp "${static_receipt}" "${auto_root}/production-static/latest.json"
  cp "${receipt}" "${auto_root}/production-acceptance/latest/production-acceptance.json"
  env -u PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON -u TOPOLOGY_SMOKE_RECEIPT_JSON -u IMSERVER_PRODUCTION_SMOKE_JSON \
  -u PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON -u DEPLOY_READINESS_RECEIPT_JSON -u READINESS_RECEIPT_JSON \
  -u PRODUCTION_STATIC_GATE_RECEIPT_JSON -u STATIC_GATE_RECEIPT_JSON \
  BASE_URL=https://chat.myim-prod.com \
  TCP_HOST=tcp.myim-prod.com \
  TCP_PORT=9000 \
  PRODUCTION_READINESS_RESULT_ROOT="${auto_root}" \
  PRODUCTION_READINESS_STATUS_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${tmpdir}/auto-discovery-ready.log"
  grep -q 'item=currentReadiness status=pass' "${tmpdir}/auto-discovery-ready.log" || {
    printf 'production_readiness_status_self_test result=fail reason=auto_discovery_readiness_missing\n' >&2
    exit 1
  }
  grep -q 'item=acceptanceReceipt status=pass' "${tmpdir}/auto-discovery-ready.log" || {
    printf 'production_readiness_status_self_test result=fail reason=auto_discovery_receipt_missing\n' >&2
    exit 1
  }
  grep -q 'item=deployReadinessReceipt status=pass' "${tmpdir}/auto-discovery-ready.log" || {
    printf 'production_readiness_status_self_test result=fail reason=auto_discovery_deploy_readiness_missing\n' >&2
    exit 1
  }
  grep -q 'item=productionStaticGateReceipt status=pass' "${tmpdir}/auto-discovery-ready.log" || {
    printf 'production_readiness_status_self_test result=fail reason=auto_discovery_static_gate_missing\n' >&2
    exit 1
  }
  grep -q 'item=evidencePackage status=pass' "${tmpdir}/auto-discovery-ready.log" || {
    printf 'production_readiness_status_self_test result=fail reason=auto_discovery_package_missing\n' >&2
    exit 1
  }
  grep -q 'readyToAssert=true' "${tmpdir}/auto-discovery-ready.log" || {
    printf 'production_readiness_status_self_test result=fail reason=auto_discovery_ready_summary_missing\n' >&2
    exit 1
  }

  printf 'production_readiness_status_self_test result=pass\n'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

if bool_enabled "${PRODUCTION_READINESS_STATUS_SELF_TEST}"; then
  run_self_test
  exit 0
fi

discover_production_readiness_inputs
run_status
