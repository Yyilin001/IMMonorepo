#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PERF_PRODUCTION_GATE_SOURCE_JSON="${PERF_PRODUCTION_GATE_SOURCE_JSON:-${1:-}}"
PERF_PRODUCTION_GATE_JSON="${PERF_PRODUCTION_GATE_JSON:-/var/lib/imserver/performance/production-gate.json}"
PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE:-normal-product-baseline}"
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS:-604800}"
PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT:-false}"
PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT:-false}"
PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT:-}"
PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET:-}"
PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG:-${SCRIPT_DIR}/../../IMServer/LoadTests/perf_production_profiles.json}"
PERF_PRODUCTION_GATE_OWNER="${PERF_PRODUCTION_GATE_OWNER:-root}"
PERF_PRODUCTION_GATE_GROUP="${PERF_PRODUCTION_GATE_GROUP:-root}"
PERF_PRODUCTION_GATE_DIR_MODE="${PERF_PRODUCTION_GATE_DIR_MODE:-0755}"
PERF_PRODUCTION_GATE_FILE_MODE="${PERF_PRODUCTION_GATE_FILE_MODE:-0644}"
PERF_PRODUCTION_GATE_REQUIRE_ROOT="${PERF_PRODUCTION_GATE_REQUIRE_ROOT:-true}"

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

gate_env_value() {
  local key="$1"
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local value="${!key:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  read_env_file_value "${env_file}" "${key}"
}

gate_host_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
}

resolve_gate_expect_base_url() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}"
    return 0
  fi
  local value
  value="$(gate_env_value "PUBLIC_BASE_URL")"
  if [[ -z "${value}" ]]; then
    value="$(gate_env_value "IM_PUBLIC_BASE_URL")"
  fi
  printf '%s\n' "${value}"
}

resolve_gate_expect_tcp_host() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}"
    return 0
  fi
  local value
  value="$(gate_env_value "TCP_HOST")"
  if [[ -z "${value}" ]]; then
    value="$(gate_env_value "IM_PUBLIC_HOST")"
  fi
  if [[ -z "${value}" ]]; then
    value="$(gate_host_from_url "$(resolve_gate_expect_base_url)")"
  fi
  printf '%s\n' "${value}"
}

resolve_gate_expect_tcp_port() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}"
    return 0
  fi
  local value
  value="$(gate_env_value "TCP_PORT")"
  if [[ -z "${value}" ]]; then
    value="$(gate_env_value "IM_TCP_PORT")"
  fi
  printf '%s\n' "${value:-9000}"
}

install_gate() {
  local source_json="$1"
  local target_json="$2"
  local target_dir tmp_file expect_base_url expect_tcp_host expect_tcp_port gate_output

  if [[ -z "${source_json}" ]]; then
    printf 'usage: PERF_PRODUCTION_GATE_SOURCE_JSON=/path/production-gate.json %s\n' "$0" >&2
    printf '   or: %s /path/production-gate.json\n' "$0" >&2
    return 2
  fi
  if [[ ! -f "${source_json}" ]]; then
    printf 'performance_gate_install result=fail reason=source_missing path=%s\n' "${source_json}" >&2
    return 1
  fi
  expect_base_url="$(resolve_gate_expect_base_url)"
  expect_tcp_host="$(resolve_gate_expect_tcp_host)"
  expect_tcp_port="$(resolve_gate_expect_tcp_port)"

  if ! gate_output="$(
    PERF_PRODUCTION_GATE_JSON="${source_json}" \
    PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT}" \
    PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT}" \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${expect_base_url}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${expect_tcp_host}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${expect_tcp_port}" \
    PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}" \
    PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG}" \
    ENV_FILE="${ENV_FILE:-}" \
      bash "${SCRIPT_DIR}/67_verify_performance_gate.sh" 2>&1
  )"; then
    printf '%s\n' "${gate_output}" >&2
    return 1
  fi

  target_dir="$(dirname "${target_json}")"
  install -d -o "${PERF_PRODUCTION_GATE_OWNER}" -g "${PERF_PRODUCTION_GATE_GROUP}" -m "${PERF_PRODUCTION_GATE_DIR_MODE}" "${target_dir}"
  tmp_file="$(mktemp "${target_dir}/.production-gate.json.tmp.XXXXXX")"
  trap 'rm -f "${tmp_file:-}"' RETURN
  install -m "${PERF_PRODUCTION_GATE_FILE_MODE}" "${source_json}" "${tmp_file}"
  chown "${PERF_PRODUCTION_GATE_OWNER}:${PERF_PRODUCTION_GATE_GROUP}" "${tmp_file}"
  mv -f "${tmp_file}" "${target_json}"
  tmp_file=""

  PERF_PRODUCTION_GATE_JSON="${target_json}" \
  PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
  PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT}" \
  PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT}" \
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${expect_base_url}" \
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${expect_tcp_host}" \
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${expect_tcp_port}" \
  PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}" \
  PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG}" \
  ENV_FILE="${ENV_FILE:-}" \
    bash "${SCRIPT_DIR}/67_verify_performance_gate.sh" || return 1

  printf 'performance_gate_install result=pass source=%s target=%s profile=%s expectBaseURL=%s expectTCPHost=%s expectTCPPort=%s\n' \
    "${source_json}" \
    "${target_json}" \
    "${PERF_PRODUCTION_GATE_PROFILE}" \
    "${expect_base_url:-<unset>}" \
    "${expect_tcp_host:-<unset>}" \
    "${expect_tcp_port}"
}

if [[ "${PERF_GATE_INSTALL_SELF_TEST:-false}" == "true" ]]; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  python3 - "${self_test_dir}/source.json" "${PERF_PRODUCTION_PROFILE_CATALOG}" <<'PY'
import json
import hashlib
import sys
import time
import subprocess
from pathlib import Path

source_path, catalog_path = sys.argv[1:3]
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
    "source": {
        "repoRoot": str(repo_root),
        "gitCommit": commit,
        "gitBranch": branch,
        "gitDirty": dirty,
    },
    "targetFilter": {
        "enabled": True,
        "baseURL": "https://perf.myim-prod.com",
        "tcpHost": "perf-tcp.myim-prod.com",
        "tcpPort": "9000",
    },
    "profileCatalog": {
        "path": catalog_path,
        "schemaVersion": 1,
        "sha256": catalog_sha256,
    },
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
with open(source_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke"
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0
  PERF_PRODUCTION_GATE_OWNER="$(id -un)"
  PERF_PRODUCTION_GATE_GROUP="$(id -gn)"
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/installed/production-gate.json"
  PERF_PRODUCTION_GATE_SOURCE_JSON="${self_test_dir}/source.json"
  PERF_PRODUCTION_GATE_DIR_MODE=0755
  PERF_PRODUCTION_GATE_FILE_MODE=0644
  bad_env_file="${self_test_dir}/bad-common.env"
  good_env_file="${self_test_dir}/good-common.env"
  prod_loopback_env_file="${self_test_dir}/prod-loopback-common.env"
  {
    printf 'PUBLIC_BASE_URL=http://example.test:8080\n'
    printf 'TCP_PORT=9000\n'
  } >"${bad_env_file}"
  {
    printf 'PUBLIC_BASE_URL=https://perf.myim-prod.com\n'
    printf 'TCP_HOST=perf-tcp.myim-prod.com\n'
    printf 'TCP_PORT=9000\n'
  } >"${good_env_file}"
  {
    printf 'APP_ENV=production\n'
    printf 'PUBLIC_BASE_URL=http://127.0.0.1:8080\n'
    printf 'TCP_PORT=9000\n'
  } >"${prod_loopback_env_file}"
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL=""
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=""
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=""
  ENV_FILE="${bad_env_file}"
  if install_gate "${PERF_PRODUCTION_GATE_SOURCE_JSON}" "${PERF_PRODUCTION_GATE_JSON}" >"${self_test_dir}/bad-install.log" 2>&1; then
    printf 'performance_gate_install_self_test result=fail reason=bad_env_target_passed\n' >&2
    exit 1
  fi
  grep -q 'target_filter_mismatch' "${self_test_dir}/bad-install.log" || {
    printf 'performance_gate_install_self_test result=fail reason=bad_env_target_reason_missing\n' >&2
    exit 1
  }
  python3 - "${PERF_PRODUCTION_GATE_SOURCE_JSON}" "${self_test_dir}/loopback-source.json" <<'PY'
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
  ENV_FILE="${prod_loopback_env_file}"
  if install_gate "${self_test_dir}/loopback-source.json" "${PERF_PRODUCTION_GATE_JSON}" >"${self_test_dir}/bad-production-target-install.log" 2>&1; then
    printf 'performance_gate_install_self_test result=fail reason=production_loopback_target_passed\n' >&2
    exit 1
  fi
  grep -q 'production_target_base_url_https_required' "${self_test_dir}/bad-production-target-install.log" || {
    printf 'performance_gate_install_self_test result=fail reason=production_loopback_target_reason_missing output=%s\n' "$(cat "${self_test_dir}/bad-production-target-install.log")" >&2
    exit 1
  }
  ENV_FILE="${good_env_file}"
  install_output="$(install_gate "${PERF_PRODUCTION_GATE_SOURCE_JSON}" "${PERF_PRODUCTION_GATE_JSON}")"
  grep -q 'expectBaseURL=https://perf.myim-prod.com' <<<"${install_output}" || {
    printf 'performance_gate_install_self_test result=fail reason=resolved_base_url_missing output=%s\n' "${install_output}" >&2
    exit 1
  }
  grep -q 'expectTCPHost=perf-tcp.myim-prod.com' <<<"${install_output}" || {
    printf 'performance_gate_install_self_test result=fail reason=resolved_tcp_host_missing output=%s\n' "${install_output}" >&2
    exit 1
  }
  [[ -f "${PERF_PRODUCTION_GATE_JSON}" ]] || {
    printf 'performance_gate_install_self_test result=fail reason=target_missing\n' >&2
    exit 1
  }
  printf 'performance_gate_install_self_test result=pass\n'
  exit 0
fi

if bool_enabled "${PERF_PRODUCTION_GATE_REQUIRE_ROOT}"; then
  require_root
fi
install_gate "${PERF_PRODUCTION_GATE_SOURCE_JSON}" "${PERF_PRODUCTION_GATE_JSON}"
