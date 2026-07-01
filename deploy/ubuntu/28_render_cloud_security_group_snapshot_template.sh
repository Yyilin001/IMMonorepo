#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLOUD_SECURITY_GROUP_TEMPLATE_SELF_TEST="${CLOUD_SECURITY_GROUP_TEMPLATE_SELF_TEST:-false}"
CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT="${CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT:-}"
CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR="${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR:-}"
CLOUD_SECURITY_GROUP_TEMPLATE_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_TEMPLATE_PUBLIC_CLIENT_PORTS:-80 443 9000}"
CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_PORTS="${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_PORTS:-22}"
CLOUD_SECURITY_GROUP_TEMPLATE_ALLOW_PUBLIC_ICMP="${CLOUD_SECURITY_GROUP_TEMPLATE_ALLOW_PUBLIC_ICMP:-true}"
CLOUD_SECURITY_GROUP_TEMPLATE_AUDIT="${CLOUD_SECURITY_GROUP_TEMPLATE_AUDIT:-true}"
CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV4_MIN_PREFIX="${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV4_MIN_PREFIX:-32}"
CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV6_MIN_PREFIX="${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV6_MIN_PREFIX:-128}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage:
  CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR=<admin-ip-or-cidr> \
    deploy/ubuntu/28_render_cloud_security_group_snapshot_template.sh > cloud-security-group.json

Common env:
  CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT=/path/cloud-security-group.json
  CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR=203.0.113.10/32
  CLOUD_SECURITY_GROUP_TEMPLATE_PUBLIC_CLIENT_PORTS="80 443 9000"
  CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_PORTS="22"
  CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV4_MIN_PREFIX=32
  CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV6_MIN_PREFIX=128
  CLOUD_SECURITY_GROUP_TEMPLATE_ALLOW_PUBLIC_ICMP=true|false

Purpose:
  Render a production security-group snapshot template that the local audit,
  production readiness gate, and evidence package can verify. This script does
  not call cloud APIs and does not modify the cloud security group.
EOF
}

normalize_admin_cidr() {
  local value="$1"
  python3 - \
    "${value}" \
    "${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV4_MIN_PREFIX}" \
    "${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV6_MIN_PREFIX}" <<'PY'
import ipaddress
import sys

raw, ipv4_min_raw, ipv6_min_raw = sys.argv[1:4]
raw = raw.strip()
if not raw:
    raise SystemExit("cloud-security-group-template result=fail reason=admin_cidr_required")
try:
    ipv4_min = int(ipv4_min_raw)
    ipv6_min = int(ipv6_min_raw)
except ValueError as exc:
    raise SystemExit(f"cloud-security-group-template result=fail reason=admin_cidr_prefix_invalid detail={exc}")
try:
    if "/" in raw:
        network = ipaddress.ip_network(raw, strict=False)
    else:
        address = ipaddress.ip_address(raw)
        network = ipaddress.ip_network(f"{address}/32" if address.version == 4 else f"{address}/128", strict=False)
except ValueError as exc:
    raise SystemExit(f"cloud-security-group-template result=fail reason=admin_cidr_invalid value={raw} detail={exc}")
if network.version == 4 and network.prefixlen < 24:
    raise SystemExit(f"cloud-security-group-template result=fail reason=admin_cidr_too_broad value={network}")
if network.version == 6 and network.prefixlen < 64:
    raise SystemExit(f"cloud-security-group-template result=fail reason=admin_cidr_too_broad value={network}")
if network.version == 4 and network.is_global and network.prefixlen < ipv4_min:
    raise SystemExit(f"cloud-security-group-template result=fail reason=admin_cidr_not_specific_enough value={network} requiredPrefix={ipv4_min}")
if network.version == 6 and network.is_global and network.prefixlen < ipv6_min:
    raise SystemExit(f"cloud-security-group-template result=fail reason=admin_cidr_not_specific_enough value={network} requiredPrefix={ipv6_min}")
if network.is_unspecified:
    raise SystemExit(f"cloud-security-group-template result=fail reason=admin_cidr_public_anywhere value={network}")
print(str(network))
PY
}

render_template() {
  local admin_cidr="$1"
  python3 - \
    "${admin_cidr}" \
    "${CLOUD_SECURITY_GROUP_TEMPLATE_PUBLIC_CLIENT_PORTS}" \
    "${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_PORTS}" \
    "${CLOUD_SECURITY_GROUP_TEMPLATE_ALLOW_PUBLIC_ICMP}" <<'PY'
import json
import sys

admin_cidr, public_ports_raw, admin_ports_raw, allow_icmp_raw = sys.argv[1:5]

def ports(raw: str) -> list[int]:
    result: list[int] = []
    for token in raw.split():
        if not token:
            continue
        value = int(token)
        if value <= 0 or value > 65535:
            raise SystemExit(f"cloud-security-group-template result=fail reason=invalid_port value={value}")
        result.append(value)
    return result

rules = []
for port in ports(public_ports_raw):
    rules.append({
        "IpProtocol": "tcp",
        "PortRange": f"{port}/{port}",
        "SourceCidrIp": "0.0.0.0/0",
        "Policy": "Accept",
        "Description": f"public client tcp {port}",
    })
for port in ports(admin_ports_raw):
    rules.append({
        "IpProtocol": "tcp",
        "PortRange": f"{port}/{port}",
        "SourceCidrIp": admin_cidr,
        "Policy": "Accept",
        "Description": f"admin tcp {port}",
    })
if allow_icmp_raw.lower() in {"1", "true", "yes", "on"}:
    rules.append({
        "IpProtocol": "icmp",
        "PortRange": "-1/-1",
        "SourceCidrIp": "0.0.0.0/0",
        "Policy": "Accept",
        "Description": "diagnostic icmp",
    })
payload = {
    "schemaVersion": 1,
    "source": "imserver-production-cloud-security-group-template",
    "notes": [
        "Apply equivalent rules in the cloud console before using this snapshot as evidence.",
        "Do not expose tcp 3389, 5432, 6379, 9092, 8080, 8081, 8082, or 18080 publicly.",
    ],
    "SecurityGroupRules": {
        "SecurityGroupRule": rules,
    },
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY
}

audit_template() {
  local path="$1"
  CLOUD_SECURITY_GROUP_RULES_FILE="${path}" \
	  CLOUD_SECURITY_GROUP_PROFILE=production \
	  CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false \
	  CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=0 \
	  CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV4_MIN_PREFIX}" \
	  CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV6_MIN_PREFIX}" \
	    bash "${SCRIPT_DIR}/26_audit_cloud_security_group.sh" >/dev/null
}

run() {
  local admin_cidr rendered tmp
  admin_cidr="$(normalize_admin_cidr "${CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR}")"
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  render_template "${admin_cidr}" >"${tmp}"
  chmod 0600 "${tmp}"
  if bool_enabled "${CLOUD_SECURITY_GROUP_TEMPLATE_AUDIT}"; then
    audit_template "${tmp}"
  fi
  if [[ -n "${CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT}" ]]; then
    mkdir -p "$(dirname "${CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT}")"
    install -m 0600 "${tmp}" "${CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT}"
    printf 'cloud-security-group-template result=pass output=%s adminCidr=%s\n' \
      "${CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT}" \
      "${admin_cidr}" >&2
  else
    cat "${tmp}"
  fi
}

run_self_test() {
  local tmpdir good broad admin_range log
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  good="${tmpdir}/cloud-security-group.json"
  broad="${tmpdir}/broad.json"
  admin_range="${tmpdir}/admin-range.json"
  log="${tmpdir}/render.log"

  CLOUD_SECURITY_GROUP_TEMPLATE_SELF_TEST=false \
  CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR=203.0.113.10 \
  CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT="${good}" \
    bash "${BASH_SOURCE[0]}" >"${log}" 2>&1
  grep -q 'cloud-security-group-template result=pass' "${log}"
  CLOUD_SECURITY_GROUP_RULES_FILE="${good}" \
  CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false \
    bash "${SCRIPT_DIR}/26_audit_cloud_security_group.sh" >/dev/null
  grep -q '"SourceCidrIp": "203.0.113.10/32"' "${good}"
  grep -q '"PortRange": "9000/9000"' "${good}"

  if CLOUD_SECURITY_GROUP_TEMPLATE_SELF_TEST=false \
    CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR=0.0.0.0/0 \
    CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT="${broad}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'cloud-security-group-template-self-test result=fail reason=broad_admin_cidr_accepted\n' >&2
    return 1
  fi
  grep -q 'admin_cidr_too_broad\|admin_cidr_public_anywhere' "${log}"
  [[ ! -f "${broad}" ]] || {
    printf 'cloud-security-group-template-self-test result=fail reason=broad_output_created\n' >&2
    return 1
  }
  if CLOUD_SECURITY_GROUP_TEMPLATE_SELF_TEST=false \
    CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR=47.106.103.0/24 \
    CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT="${admin_range}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'cloud-security-group-template-self-test result=fail reason=admin_range_accepted\n' >&2
    return 1
  fi
  grep -q 'admin_cidr_not_specific_enough' "${log}"
  [[ ! -f "${admin_range}" ]] || {
    printf 'cloud-security-group-template-self-test result=fail reason=admin_range_output_created\n' >&2
    return 1
  }
  CLOUD_SECURITY_GROUP_TEMPLATE_SELF_TEST=false \
    CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR=47.106.103.0/24 \
    CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_IPV4_MIN_PREFIX=24 \
    CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT="${admin_range}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1
  grep -q 'cloud-security-group-template result=pass' "${log}"
  printf 'cloud-security-group-template-self-test result=pass\n'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    printf 'cloud-security-group-template result=fail reason=unknown_argument arg=%s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

if bool_enabled "${CLOUD_SECURITY_GROUP_TEMPLATE_SELF_TEST}"; then
  run_self_test
  exit 0
fi

run
