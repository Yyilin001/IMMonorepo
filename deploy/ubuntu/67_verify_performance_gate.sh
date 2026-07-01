#!/usr/bin/env bash
set -euo pipefail

PERF_PRODUCTION_GATE_JSON="${PERF_PRODUCTION_GATE_JSON:-/var/lib/imserver/performance/production-gate.json}"
PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE:-}"
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS:-604800}"
PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT:-false}"
PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT:-false}"
PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT:-}"
PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET:-}"
PERF_GATE_VERIFY_SELF_TEST="${PERF_GATE_VERIFY_SELF_TEST:-false}"
IMSERVER_ETC_DIR="${IMSERVER_ETC_DIR:-/etc/imserver}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG:-${SCRIPT_DIR}/../../IMServer/LoadTests/perf_production_profiles.json}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

read_env_file_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      found = value
    }
    END {
      if (found != "") {
        print found
      }
    }
  ' "${file}"
}

gate_verify_env_value() {
  local key="$1"
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local value="${!key:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  read_env_file_value "${env_file}" "${key}"
}

gate_verify_app_env() {
  if [[ -n "${APP_ENV:-}" ]]; then
    printf '%s\n' "${APP_ENV}"
    return 0
  fi
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local file_value
  file_value="$(read_env_file_value "${env_file}" "APP_ENV")"
  if [[ -n "${file_value}" ]]; then
    printf '%s\n' "${file_value}"
    return 0
  fi
  printf '%s\n' "${IMSERVER_RUN_ENV:-development}"
}

resolve_gate_verify_production_target_requirement() {
  if [[ -n "${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}"
    return 0
  fi
  case "$(gate_verify_app_env)" in
    production) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

gate_verify_host_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
}

resolve_gate_verify_expect_base_url() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}"
    return 0
  fi
  local value
  value="$(gate_verify_env_value "PUBLIC_BASE_URL")"
  if [[ -z "${value}" ]]; then
    value="$(gate_verify_env_value "IM_PUBLIC_BASE_URL")"
  fi
  printf '%s\n' "${value}"
}

resolve_gate_verify_expect_tcp_host() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}"
    return 0
  fi
  local value
  value="$(gate_verify_env_value "TCP_HOST")"
  if [[ -z "${value}" ]]; then
    value="$(gate_verify_env_value "IM_PUBLIC_HOST")"
  fi
  if [[ -z "${value}" ]]; then
    value="$(gate_verify_host_from_url "$(resolve_gate_verify_expect_base_url)")"
  fi
  printf '%s\n' "${value}"
}

resolve_gate_verify_expect_tcp_port() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}"
    return 0
  fi
  local value
  value="$(gate_verify_env_value "TCP_PORT")"
  if [[ -z "${value}" ]]; then
    value="$(gate_verify_env_value "IM_TCP_PORT")"
  fi
  printf '%s\n' "${value:-9000}"
}

if bool_enabled "${PERF_GATE_VERIFY_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  python3 - "${self_test_dir}/production-gate.json" "${PERF_PRODUCTION_PROFILE_CATALOG}" <<'PY'
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

gate_path, catalog_path = sys.argv[1:3]
now = int(time.time())
repo_root = Path(catalog_path).resolve().parents[2]
try:
    commit = subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=repo_root, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip()
    branch = subprocess.run(["git", "branch", "--show-current"], cwd=repo_root, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain"], cwd=repo_root, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip())
except Exception:
    commit = "self-test"
    branch = "self-test"
    dirty = False
with open(catalog_path, encoding="utf-8") as handle:
    scenarios = (json.load(handle).get("profiles") or {}).get("minimum-smoke") or []
with open(catalog_path, "rb") as handle:
    catalog_sha256 = hashlib.sha256(handle.read()).hexdigest()
payload = {
    "status": "PASS",
    "profile": "minimum-smoke",
    "source": {"repoRoot": str(repo_root), "gitCommit": commit, "gitBranch": branch, "gitDirty": dirty},
    "targetFilter": {"enabled": True, "baseURL": "https://perf.myim-prod.com", "tcpHost": "perf-tcp.myim-prod.com", "tcpPort": "9000"},
    "profileCatalog": {"path": catalog_path, "schemaVersion": 1, "sha256": catalog_sha256},
    "generatedAtEpoch": now,
    "summary": {
        "requiredScenarioCount": len(scenarios),
        "passedScenarioCount": len(scenarios),
        "failedScenarioCount": 0,
        "missingScenarioCount": 0,
        "evidenceOldestMtime": now,
        "evidenceNewestMtime": now,
        "runArtifactMissingCount": 0,
    },
    "requirements": {"runArtifacts": True},
    "requiredScenarios": [
        {
            "scenario": scenario,
            "category": "self-test",
            "requiredStatus": "PASS",
            "latestSLOStatus": "PASS",
            "latestScenarioStatus": "PASS",
            "runCount": 1,
            "latestRunID": "self-test",
            "latestRunDir": "/tmp/self-test",
            "latestMtime": now,
            "runArtifactsVerified": True,
            "runArtifactsOK": True,
            "passed": True,
            "reason": "",
        }
        for scenario in scenarios
    ],
}
Path(gate_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  bad_env_file="${self_test_dir}/bad-common.env"
  good_env_file="${self_test_dir}/good-common.env"
  {
    printf 'PUBLIC_BASE_URL=http://example.test:8080\n'
    printf 'TCP_PORT=9000\n'
  } >"${bad_env_file}"
  {
    printf 'PUBLIC_BASE_URL=https://perf.myim-prod.com\n'
    printf 'TCP_HOST=perf-tcp.myim-prod.com\n'
    printf 'TCP_PORT=9000\n'
  } >"${good_env_file}"
  if PERF_GATE_VERIFY_SELF_TEST=false \
    PERF_PRODUCTION_GATE_JSON="${self_test_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    ENV_FILE="${bad_env_file}" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/bad-target.log" 2>&1; then
    printf 'performance_gate_verify_self_test result=fail reason=bad_env_target_passed\n' >&2
    exit 1
  fi
  grep -q 'target_filter_mismatch' "${self_test_dir}/bad-target.log" || {
    printf 'performance_gate_verify_self_test result=fail reason=bad_env_target_reason_missing\n' >&2
    exit 1
  }
  PERF_GATE_VERIFY_SELF_TEST=false \
    PERF_PRODUCTION_GATE_JSON="${self_test_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    ENV_FILE="${good_env_file}" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/good-target.log"
  grep -q 'base_url=https://perf.myim-prod.com tcp_host=perf-tcp.myim-prod.com tcp_port=9000' "${self_test_dir}/good-target.log" || {
    printf 'performance_gate_verify_self_test result=fail reason=good_target_summary_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/production-gate.json" "${self_test_dir}/loopback-target-gate.json" <<'PY'
import json
import sys

source_path, target_path = sys.argv[1:3]
with open(source_path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["targetFilter"] = {
    "enabled": True,
    "baseURL": "http://127.0.0.1:8080",
    "tcpHost": "127.0.0.1",
    "tcpPort": "9000",
}
with open(target_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  loopback_env_file="${self_test_dir}/loopback-common.env"
  {
    printf 'PUBLIC_BASE_URL=http://127.0.0.1:8080\n'
    printf 'TCP_HOST=127.0.0.1\n'
    printf 'TCP_PORT=9000\n'
  } >"${loopback_env_file}"
  if PERF_GATE_VERIFY_SELF_TEST=false \
    PERF_PRODUCTION_GATE_JSON="${self_test_dir}/loopback-target-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=true \
    ENV_FILE="${loopback_env_file}" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/bad-production-target.log" 2>&1; then
    printf 'performance_gate_verify_self_test result=fail reason=loopback_production_target_passed\n' >&2
    exit 1
  fi
  grep -q 'production_target_base_url_https_required' "${self_test_dir}/bad-production-target.log" || {
    printf 'performance_gate_verify_self_test result=fail reason=loopback_production_target_reason_missing output=%s\n' "$(cat "${self_test_dir}/bad-production-target.log")" >&2
    exit 1
  }
  python3 - "${self_test_dir}/production-gate.json" "${self_test_dir}/production-target-gate.json" <<'PY'
import json
import sys

source_path, target_path = sys.argv[1:3]
with open(source_path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["targetFilter"] = {
    "enabled": True,
    "baseURL": "https://perf.myim-prod.com",
    "tcpHost": "perf-tcp.myim-prod.com",
    "tcpPort": "9000",
}
with open(target_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  prod_env_file="${self_test_dir}/prod-common.env"
  {
    printf 'APP_ENV=production\n'
    printf 'PUBLIC_BASE_URL=https://perf.myim-prod.com\n'
    printf 'TCP_HOST=perf-tcp.myim-prod.com\n'
    printf 'TCP_PORT=9000\n'
  } >"${prod_env_file}"
  PERF_GATE_VERIFY_SELF_TEST=false \
    PERF_PRODUCTION_GATE_JSON="${self_test_dir}/production-target-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    ENV_FILE="${prod_env_file}" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/prod-target.log"
  grep -q 'requireProductionTarget=true' "${self_test_dir}/prod-target.log" || {
    printf 'performance_gate_verify_self_test result=fail reason=production_target_summary_missing output=%s\n' "$(cat "${self_test_dir}/prod-target.log")" >&2
    exit 1
  }
  python3 - "${self_test_dir}/production-gate.json" "${self_test_dir}/bad-pass-failure-kinds.json" <<'PY'
import json
import sys

source_path, target_path = sys.argv[1:3]
with open(source_path, encoding="utf-8") as handle:
    payload = json.load(handle)
summary = payload.get("summary") or {}
summary["failureKindCounts"] = {"missing_runtime_evidence": 1}
with open(target_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if PERF_GATE_VERIFY_SELF_TEST=false \
    PERF_PRODUCTION_GATE_JSON="${self_test_dir}/bad-pass-failure-kinds.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    ENV_FILE="${good_env_file}" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/bad-pass-failure-kinds.log" 2>&1; then
    printf 'performance_gate_verify_self_test result=fail reason=bad_pass_failure_kinds_passed\n' >&2
    exit 1
  fi
  grep -q 'failure_kind_count_mismatch' "${self_test_dir}/bad-pass-failure-kinds.log" || {
    printf 'performance_gate_verify_self_test result=fail reason=bad_pass_failure_kinds_reason_missing output=%s\n' "$(cat "${self_test_dir}/bad-pass-failure-kinds.log")" >&2
    exit 1
  }
  python3 - "${self_test_dir}/production-gate.json" "${self_test_dir}/failed-production-gate.json" <<'PY'
import json
import sys

source_path, target_path = sys.argv[1:3]
with open(source_path, encoding="utf-8") as handle:
    payload = json.load(handle)
summary = payload.get("summary") or {}
summary["passedScenarioCount"] = 0
summary["failedScenarioCount"] = int(summary.get("requiredScenarioCount") or 0)
summary["failureKindCounts"] = {"missing_runtime_evidence": summary["failedScenarioCount"]}
payload["status"] = "FAIL"
with open(target_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if PERF_GATE_VERIFY_SELF_TEST=false \
    PERF_PRODUCTION_GATE_JSON="${self_test_dir}/failed-production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    ENV_FILE="${good_env_file}" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/failed-target.log" 2>&1; then
    printf 'performance_gate_verify_self_test result=fail reason=failed_gate_passed\n' >&2
    exit 1
  fi
  grep -q 'failureKinds=missing_runtime_evidence=' "${self_test_dir}/failed-target.log" || {
    printf 'performance_gate_verify_self_test result=fail reason=failure_kinds_missing output=%s\n' "$(cat "${self_test_dir}/failed-target.log")" >&2
    exit 1
  }
  printf 'performance_gate_verify_self_test result=pass\n'
  exit 0
fi

if [[ ! -f "${PERF_PRODUCTION_GATE_JSON}" ]]; then
  printf 'performance_gate result=fail reason=missing_file path=%s\n' "${PERF_PRODUCTION_GATE_JSON}" >&2
  exit 1
fi

PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE="$(resolve_gate_verify_expect_base_url)"
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE="$(resolve_gate_verify_expect_tcp_host)"
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE="$(resolve_gate_verify_expect_tcp_port)"
PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET_EFFECTIVE="$(resolve_gate_verify_production_target_requirement)"

PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL_EFFECTIVE}" \
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST_EFFECTIVE}" \
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT_EFFECTIVE}" \
PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET_EFFECTIVE}" \
python3 - "${PERF_PRODUCTION_GATE_JSON}" "${PERF_PRODUCTION_GATE_PROFILE}" "${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" "${PERF_PRODUCTION_PROFILE_CATALOG}" "${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT}" "${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT}" <<'PY'
import hashlib
import ipaddress
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

path, expected_profile, max_age_raw, profile_catalog_path, require_current_git_raw, require_clean_git_raw = sys.argv[1:7]
require_current_git = require_current_git_raw.lower() in {"1", "true", "yes", "on"}
require_clean_git = require_clean_git_raw.lower() in {"1", "true", "yes", "on"}

def sha256_file(file_path):
    digest = hashlib.sha256()
    with open(file_path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

try:
    max_age = int(max_age_raw)
except ValueError:
    raise SystemExit(f"performance_gate result=fail reason=invalid_max_age value={max_age_raw}")
if max_age < 0:
    raise SystemExit(f"performance_gate result=fail reason=invalid_max_age value={max_age}")

try:
    with open(path) as handle:
        payload = json.load(handle)
except Exception as exc:
    raise SystemExit(f"performance_gate result=fail reason=invalid_json path={path} error={exc}")

try:
    with open(profile_catalog_path) as handle:
        catalog = json.load(handle)
except Exception as exc:
    raise SystemExit(f"performance_gate result=fail reason=invalid_profile_catalog path={profile_catalog_path} error={exc}")

if int(catalog.get("schemaVersion") or 0) != 1:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=invalid_profile_catalog_schema path={profile_catalog_path}"
    )
catalog_profiles = catalog.get("profiles") or {}
if not isinstance(catalog_profiles, dict) or not catalog_profiles:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=invalid_profile_catalog_profiles path={profile_catalog_path}"
    )

status = str(payload.get("status") or "")
profile = str(payload.get("profile") or "")
payload_catalog = payload.get("profileCatalog") or {}
payload_catalog_sha256 = str(payload_catalog.get("sha256") or "")
actual_catalog_sha256 = sha256_file(profile_catalog_path)
target_filter = payload.get("targetFilter") or {}
expected_base_url = os.environ.get("PERF_PRODUCTION_GATE_EXPECT_BASE_URL", "").rstrip("/")
expected_tcp_host = os.environ.get("PERF_PRODUCTION_GATE_EXPECT_TCP_HOST", "").strip()
expected_tcp_port = os.environ.get("PERF_PRODUCTION_GATE_EXPECT_TCP_PORT", "").strip()
require_production_target = os.environ.get("PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET", "").lower() in {"1", "true", "yes", "on"}
if expected_base_url and not expected_tcp_host:
    expected_tcp_host = urlsplit(expected_base_url).hostname or ""
source = payload.get("source") or {}
source_commit = str(source.get("gitCommit") or "")
source_branch = str(source.get("gitBranch") or "")
source_dirty = bool(source.get("gitDirty"))
summary = payload.get("summary") or {}
requirements = payload.get("requirements") or {}
required = int(summary.get("requiredScenarioCount") or 0)
passed = int(summary.get("passedScenarioCount") or 0)
failed = int(summary.get("failedScenarioCount") or 0)
missing = int(summary.get("missingScenarioCount") or 0)
run_artifact_missing = int(summary.get("runArtifactMissingCount") or 0)
required_scenarios = payload.get("requiredScenarios")
future_skew_seconds = 300

def format_failure_kinds(summary):
    counts = summary.get("failureKindCounts") or {}
    if not isinstance(counts, dict) or not counts:
        return "-"
    return ",".join(f"{key}={counts[key]}" for key in sorted(counts))

def total_failure_kind_count(summary):
    counts = summary.get("failureKindCounts") or {}
    if not isinstance(counts, dict):
        return 0
    total = 0
    for value in counts.values():
        try:
            total += int(value or 0)
        except (TypeError, ValueError):
            return -1
    return total

def public_host_policy_reason(host):
    normalized = (host or "").strip().strip("[]").lower()
    if not normalized:
        return "missing_host"
    if normalized in {"localhost", "ip6-localhost"} or normalized.endswith(".local"):
        return "local_host"
    try:
        ipaddress.ip_address(normalized)
    except ValueError:
        pass
    else:
        return "ip_literal"
    if "." not in normalized:
        return "single_label"
    placeholder_hosts = {"example.com", "example.net", "example.org", "yourdomain.com"}
    placeholder_suffixes = (
        ".example.com",
        ".example.net",
        ".example.org",
        ".yourdomain.com",
        ".test",
        ".invalid",
    )
    if normalized in placeholder_hosts or any(normalized.endswith(suffix) for suffix in placeholder_suffixes):
        return "placeholder_domain"
    return "ok"

def validate_production_target(base_url, tcp_host, label):
    parsed = urlsplit(str(base_url or ""))
    if parsed.scheme != "https":
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=production_target_base_url_https_required label={label} baseURL={base_url or '-'}"
        )
    base_host = parsed.hostname or ""
    base_reason = public_host_policy_reason(base_host)
    if base_reason != "ok":
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=production_target_base_url_domain_required label={label} "
            f"baseURL={base_url or '-'} host={base_host or '-'} hostReason={base_reason}"
        )
    tcp_reason = public_host_policy_reason(str(tcp_host or ""))
    if tcp_reason != "ok":
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=production_target_tcp_host_domain_required label={label} "
            f"tcpHost={tcp_host or '-'} hostReason={tcp_reason}"
        )

failure_kinds = format_failure_kinds(summary)
failure_kind_total = total_failure_kind_count(summary)

if status != "PASS":
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=status_not_pass status={status or 'UNKNOWN'} profile={profile or '-'} "
        f"required={required} passed={passed} failed={failed} missing={missing} "
        f"failureKinds={failure_kinds}"
    )

if expected_profile and profile != expected_profile:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=profile_mismatch expected={expected_profile} actual={profile or '-'}"
    )

if not source_commit or source_commit == "unknown":
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=source_git_commit_missing profile={profile or '-'}"
    )

if require_clean_git and source_dirty:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=source_git_dirty profile={profile or '-'} commit={source_commit[:12]}"
    )

if require_current_git:
    repo_root = Path(profile_catalog_path).resolve().parents[2]
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=repo_root,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        current_commit = completed.stdout.strip()
    except Exception as exc:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=current_git_commit_unavailable repo={repo_root} error={exc}"
        )
    if current_commit != source_commit:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=source_git_commit_mismatch expected={source_commit} actual={current_commit} repo={repo_root}"
        )

if not payload_catalog_sha256:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=profile_catalog_sha_missing profile={profile or '-'} catalog={profile_catalog_path}"
    )

if payload_catalog_sha256 != actual_catalog_sha256:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=profile_catalog_sha_mismatch profile={profile or '-'} "
        f"expected={payload_catalog_sha256} actual={actual_catalog_sha256} catalog={profile_catalog_path}"
    )

if profile not in catalog_profiles:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=unknown_profile profile={profile or '-'} catalog={profile_catalog_path}"
    )

expected_required_scenarios = list(catalog_profiles.get(profile) or [])
if not expected_required_scenarios:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=profile_has_no_required_scenarios profile={profile}"
    )

if required <= 0:
    raise SystemExit("performance_gate result=fail reason=no_required_scenarios")

if passed != required or failed != 0 or missing != 0:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=inconsistent_summary required={required} passed={passed} failed={failed} "
        f"missing={missing} failureKinds={failure_kinds}"
    )

if failure_kind_total < 0:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=invalid_failure_kind_counts failureKinds={failure_kinds}"
    )

if failure_kind_total != failed:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=failure_kind_count_mismatch failed={failed} failureKindTotal={failure_kind_total} "
        f"failureKinds={failure_kinds}"
    )

if requirements.get("runArtifacts") is not True:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=run_artifacts_requirement_missing profile={profile or '-'}"
    )

if target_filter.get("enabled") is not True:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=target_filter_disabled profile={profile or '-'}"
    )

for target_field in ("baseURL", "tcpHost", "tcpPort"):
    if not str(target_filter.get(target_field) or "").strip():
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=target_filter_field_missing field={target_field} profile={profile or '-'}"
        )

expected_targets = {
    "baseURL": expected_base_url,
    "tcpHost": expected_tcp_host,
    "tcpPort": expected_tcp_port,
}
for target_field, expected_value in expected_targets.items():
    if not expected_value:
        continue
    actual_value = str(target_filter.get(target_field) or "").strip()
    if target_field == "baseURL":
        actual_value = actual_value.rstrip("/")
    if actual_value != expected_value:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=target_filter_mismatch field={target_field} expected={expected_value} "
            f"actual={actual_value or '-'} failureKinds={failure_kinds}"
        )

if require_production_target:
    validate_production_target(
        str(target_filter.get("baseURL") or "").strip(),
        str(target_filter.get("tcpHost") or "").strip(),
        "targetFilter",
    )
    if expected_base_url or expected_tcp_host:
        validate_production_target(expected_base_url, expected_tcp_host, "expectedTarget")

if run_artifact_missing != 0:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=run_artifacts_missing_count count={run_artifact_missing}"
    )

if not isinstance(required_scenarios, list):
    raise SystemExit("performance_gate result=fail reason=required_scenarios_missing")

if len(required_scenarios) != required:
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=required_scenarios_count_mismatch required={required} actual={len(required_scenarios)}"
    )

seen = set()
actual_required_scenarios = []
evidence_mtimes = []
for index, row in enumerate(required_scenarios):
    if not isinstance(row, dict):
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=invalid_required_scenario_row index={index}"
        )
    scenario = str(row.get("scenario") or "")
    latest_slo_status = str(row.get("latestSLOStatus") or "")
    latest_run_id = str(row.get("latestRunID") or "")
    latest_run_dir = str(row.get("latestRunDir") or "")
    try:
        run_count = int(row.get("runCount") or 0)
    except (TypeError, ValueError):
        run_count = 0
    try:
        latest_mtime = float(row.get("latestMtime") or 0)
    except (TypeError, ValueError):
        latest_mtime = 0.0
    if not scenario:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=required_scenario_missing_name index={index}"
        )
    if scenario in seen:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=duplicate_required_scenario scenario={scenario}"
        )
    seen.add(scenario)
    actual_required_scenarios.append(scenario)
    if row.get("passed") is not True:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=required_scenario_not_passed scenario={scenario}"
        )
    if latest_slo_status != "PASS":
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=required_scenario_slo_not_pass scenario={scenario} status={latest_slo_status or 'UNKNOWN'}"
        )
    if run_count <= 0 or not latest_run_id:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=required_scenario_missing_runtime_evidence scenario={scenario} runCount={run_count}"
        )
    if not latest_run_dir:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=required_scenario_missing_run_dir scenario={scenario}"
        )
    if row.get("runArtifactsVerified") is not True:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=required_scenario_run_artifacts_not_verified scenario={scenario}"
        )
    if row.get("runArtifactsOK") is not True:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=required_scenario_run_artifacts_not_ok scenario={scenario}"
        )
    if latest_mtime <= 0:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=required_scenario_missing_evidence_time scenario={scenario}"
        )
    evidence_mtimes.append(latest_mtime)

if actual_required_scenarios != expected_required_scenarios:
    missing_from_gate = [item for item in expected_required_scenarios if item not in seen]
    extra_in_gate = [item for item in actual_required_scenarios if item not in set(expected_required_scenarios)]
    detail = ""
    if missing_from_gate:
        detail += f" missing={','.join(missing_from_gate[:5])}"
    if extra_in_gate:
        detail += f" extra={','.join(extra_in_gate[:5])}"
    raise SystemExit(
        "performance_gate result=fail "
        f"reason=profile_required_scenarios_mismatch profile={profile} "
        f"expected={len(expected_required_scenarios)} actual={len(actual_required_scenarios)}{detail}"
    )

if max_age > 0:
    now = time.time()
    newest_evidence_mtime = max(evidence_mtimes)
    if newest_evidence_mtime > now + future_skew_seconds:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=evidence_time_in_future newest_evidence_mtime={int(newest_evidence_mtime)}"
        )
    oldest_evidence_mtime = min(evidence_mtimes)
    age = int(now - oldest_evidence_mtime)
    if age > max_age:
        raise SystemExit(
            "performance_gate result=fail "
            f"reason=stale_evidence age_seconds={age} max_age_seconds={max_age} path={path}"
        )
else:
    age = -1

age_text = "disabled" if age < 0 else str(age)
print(
    "performance_gate result=pass "
    f"path={path} profile={profile or '-'} required={required} passed={passed} "
    f"evidence_age_seconds={age_text} catalog={profile_catalog_path} "
    f"base_url={str(target_filter.get('baseURL') or '-')} "
    f"tcp_host={str(target_filter.get('tcpHost') or '-')} "
    f"tcp_port={str(target_filter.get('tcpPort') or '-')} "
    f"requireProductionTarget={str(require_production_target).lower()} "
    f"failureKinds={failure_kinds} "
    f"catalog_sha256={actual_catalog_sha256[:12]} "
    f"source_commit={source_commit[:12]} source_branch={source_branch or '-'} source_dirty={str(source_dirty).lower()} "
    f"catalog_profiles={len(catalog_profiles)} expected_required={len(expected_required_scenarios)}"
)
PY
