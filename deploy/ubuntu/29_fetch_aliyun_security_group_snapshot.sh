#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST="${ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST:-false}"
ALIYUN_SECURITY_GROUP_ID="${ALIYUN_SECURITY_GROUP_ID:-${1:-}}"
ALIYUN_REGION_ID="${ALIYUN_REGION_ID:-}"
ALIYUN_PROFILE="${ALIYUN_PROFILE:-}"
ALIYUN_CLI_BIN="${ALIYUN_CLI_BIN:-aliyun}"
ALIYUN_SECURITY_GROUP_OUTPUT="${ALIYUN_SECURITY_GROUP_OUTPUT:-/tmp/imserver-cloud-security-group.json}"
ALIYUN_SECURITY_GROUP_AUDIT="${ALIYUN_SECURITY_GROUP_AUDIT:-true}"
ALIYUN_SECURITY_GROUP_OUTPUT_MODE="${ALIYUN_SECURITY_GROUP_OUTPUT_MODE:-0600}"

CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}"
CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}"
CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}"
CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}"
CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}"
CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}"
CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage:
  ALIYUN_SECURITY_GROUP_ID=sg-... ALIYUN_REGION_ID=cn-shenzhen \
    deploy/ubuntu/29_fetch_aliyun_security_group_snapshot.sh

  deploy/ubuntu/29_fetch_aliyun_security_group_snapshot.sh sg-...

Common env:
  ALIYUN_SECURITY_GROUP_ID=sg-...
  ALIYUN_REGION_ID=cn-shenzhen
  ALIYUN_PROFILE=<aliyun-cli-profile>
  ALIYUN_CLI_BIN=aliyun
  ALIYUN_SECURITY_GROUP_OUTPUT=/tmp/imserver-cloud-security-group.json
  ALIYUN_SECURITY_GROUP_AUDIT=true|false

Purpose:
  Fetch the current Aliyun ECS security group attribute JSON and audit it with
  the IMServer production cloud security group policy. This script does not
  modify cloud rules. Install a passing snapshot with:

    sudo CLOUD_SECURITY_GROUP_SOURCE_FILE=/tmp/imserver-cloud-security-group.json \
      bash deploy/ubuntu/27_install_cloud_security_group_snapshot.sh
EOF
}

validate_json() {
  local path="$1"
  python3 - "${path}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"aliyun-security-group-fetch result=fail reason=invalid_json detail={exc}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(payload, (dict, list)):
    print("aliyun-security-group-fetch result=fail reason=json_root_not_object_or_list", file=sys.stderr)
    raise SystemExit(2)
PY
}

audit_snapshot() {
  local path="$1"
  CLOUD_SECURITY_GROUP_RULES_FILE="${path}" \
  CLOUD_SECURITY_GROUP_PROFILE=production \
  CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
  CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
  CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
  CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
  CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=0 \
  CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false \
  CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
  CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
  CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
  CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
  CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
  CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
    bash "${SCRIPT_DIR}/26_audit_cloud_security_group.sh"
}

fetch_snapshot() {
  local security_group_id="$1"
  local output="$2"
  local output_dir tmp
  local -a cmd

  if [[ -z "${security_group_id}" ]]; then
    printf 'aliyun-security-group-fetch result=fail reason=security_group_id_required action=set ALIYUN_SECURITY_GROUP_ID=sg-...\n' >&2
    return 2
  fi
  if ! command -v "${ALIYUN_CLI_BIN}" >/dev/null 2>&1; then
    printf 'aliyun-security-group-fetch result=fail reason=aliyun_cli_missing bin=%s action=install_and_configure_aliyun_cli\n' "${ALIYUN_CLI_BIN}" >&2
    return 2
  fi

  output_dir="$(dirname "${output}")"
  mkdir -p "${output_dir}"
  tmp="$(mktemp "${output_dir}/.aliyun-security-group.XXXXXX")"
  trap 'rm -f "${tmp}"' RETURN

  cmd=("${ALIYUN_CLI_BIN}" ecs DescribeSecurityGroupAttribute --SecurityGroupId "${security_group_id}" --output json)
  if [[ -n "${ALIYUN_REGION_ID}" ]]; then
    cmd+=(--RegionId "${ALIYUN_REGION_ID}")
  fi
  if [[ -n "${ALIYUN_PROFILE}" ]]; then
    cmd+=(--profile "${ALIYUN_PROFILE}")
  fi

  if ! "${cmd[@]}" >"${tmp}"; then
    printf 'aliyun-security-group-fetch result=fail reason=aliyun_cli_failed securityGroupId=%s region=%s output=%s\n' \
      "${security_group_id}" \
      "${ALIYUN_REGION_ID:-default}" \
      "${output}" >&2
    return 1
  fi
  validate_json "${tmp}"
  chmod "${ALIYUN_SECURITY_GROUP_OUTPUT_MODE}" "${tmp}"

  if bool_enabled "${ALIYUN_SECURITY_GROUP_AUDIT}"; then
    audit_snapshot "${tmp}" >/dev/null
  fi

  mv "${tmp}" "${output}"
  chmod "${ALIYUN_SECURITY_GROUP_OUTPUT_MODE}" "${output}"
  printf 'aliyun-security-group-fetch result=pass securityGroupId=%s region=%s output=%s audited=%s mode=%s\n' \
    "${security_group_id}" \
    "${ALIYUN_REGION_ID:-default}" \
    "${output}" \
    "${ALIYUN_SECURITY_GROUP_AUDIT}" \
    "${ALIYUN_SECURITY_GROUP_OUTPUT_MODE}"
}

run_self_test() {
  local tmpdir bindir fake output bad_output log args
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  bindir="${tmpdir}/bin"
  mkdir -p "${bindir}"
  fake="${bindir}/aliyun"
  output="${tmpdir}/cloud-security-group.json"
  bad_output="${tmpdir}/bad.json"
  log="${tmpdir}/fetch.log"
  args="${tmpdir}/args.txt"

  cat >"${fake}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${ALIYUN_FAKE_ARGS_FILE}"
case "${ALIYUN_FAKE_MODE:-good}" in
  good)
    cat <<'JSON'
{
  "Permissions": {
    "Permission": [
      {"IpProtocol": "tcp", "PortRange": "80/80", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "443/443", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "9000/9000", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "22/22", "SourceCidrIp": "203.0.113.10/32", "Policy": "Accept"},
      {"IpProtocol": "icmp", "PortRange": "-1/-1", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"}
    ]
  }
}
JSON
    ;;
  bad-json)
    printf '{bad-json'
    ;;
  bad-policy)
    cat <<'JSON'
[
  {"IpProtocol": "tcp", "PortRange": "22/22", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
  {"IpProtocol": "tcp", "PortRange": "3389/3389", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"}
]
JSON
    ;;
  fail)
    exit 7
    ;;
esac
SH
  chmod +x "${fake}"

  PATH="${bindir}:${PATH}" \
  ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST=false \
  ALIYUN_SECURITY_GROUP_ID=sg-selftest \
  ALIYUN_REGION_ID=cn-shenzhen \
  ALIYUN_PROFILE=selftest \
  ALIYUN_SECURITY_GROUP_OUTPUT="${output}" \
  ALIYUN_FAKE_ARGS_FILE="${args}" \
    bash "${BASH_SOURCE[0]}" >"${log}"
  grep -q 'aliyun-security-group-fetch result=pass' "${log}"
  grep -q -- '--SecurityGroupId sg-selftest' "${args}"
  grep -q -- '--RegionId cn-shenzhen' "${args}"
  grep -q -- '--profile selftest' "${args}"
  grep -q '"PortRange": "9000/9000"' "${output}"
  python3 - "${output}" <<'PY'
import os
import sys

mode = os.stat(sys.argv[1]).st_mode & 0o777
if mode != 0o600:
    print(f"aliyun-security-group-fetch-self-test result=fail reason=mode_invalid mode={mode:04o}", file=sys.stderr)
    raise SystemExit(1)
PY

  if ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST=false \
    ALIYUN_SECURITY_GROUP_ID= \
    ALIYUN_SECURITY_GROUP_OUTPUT="${bad_output}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-fetch-self-test result=fail reason=missing_id_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'security_group_id_required' "${log}"

  if PATH="${bindir}:${PATH}" \
    ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST=false \
    ALIYUN_SECURITY_GROUP_ID=sg-selftest \
    ALIYUN_SECURITY_GROUP_OUTPUT="${bad_output}" \
    ALIYUN_FAKE_ARGS_FILE="${args}" \
    ALIYUN_FAKE_MODE=bad-json \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-fetch-self-test result=fail reason=bad_json_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'invalid_json' "${log}"

  if PATH="${bindir}:${PATH}" \
    ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST=false \
    ALIYUN_SECURITY_GROUP_ID=sg-selftest \
    ALIYUN_SECURITY_GROUP_OUTPUT="${bad_output}" \
    ALIYUN_FAKE_ARGS_FILE="${args}" \
    ALIYUN_FAKE_MODE=bad-policy \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-fetch-self-test result=fail reason=bad_policy_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'public_admin_port:22' "${log}"
  [[ ! -f "${bad_output}" ]] || {
    printf 'aliyun-security-group-fetch-self-test result=fail reason=bad_output_created\n' >&2
    return 1
  }

  if ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST=false \
    ALIYUN_CLI_BIN="${tmpdir}/missing-aliyun" \
    ALIYUN_SECURITY_GROUP_ID=sg-selftest \
    ALIYUN_SECURITY_GROUP_OUTPUT="${bad_output}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-fetch-self-test result=fail reason=missing_cli_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'aliyun_cli_missing' "${log}"

  printf 'aliyun-security-group-fetch-self-test result=pass\n'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  "")
    ;;
  sg-*)
    ;;
  *)
    printf 'aliyun-security-group-fetch result=fail reason=unknown_argument arg=%s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

if bool_enabled "${ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST}"; then
  run_self_test
  exit 0
fi

fetch_snapshot "${ALIYUN_SECURITY_GROUP_ID}" "${ALIYUN_SECURITY_GROUP_OUTPUT}"
