#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST="${ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST:-false}"
ALIYUN_SECURITY_GROUP_REPAIR_APPLY="${ALIYUN_SECURITY_GROUP_REPAIR_APPLY:-false}"
ALIYUN_SECURITY_GROUP_REPAIR_VERIFY_AFTER_APPLY="${ALIYUN_SECURITY_GROUP_REPAIR_VERIFY_AFTER_APPLY:-true}"
ALIYUN_SECURITY_GROUP_ID="${ALIYUN_SECURITY_GROUP_ID:-${1:-}}"
ALIYUN_REGION_ID="${ALIYUN_REGION_ID:-}"
ALIYUN_PROFILE="${ALIYUN_PROFILE:-}"
ALIYUN_CLI_BIN="${ALIYUN_CLI_BIN:-aliyun}"
ALIYUN_SECURITY_GROUP_ADMIN_CIDR="${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}"
ALIYUN_SECURITY_GROUP_REPAIR_ID="${ALIYUN_SECURITY_GROUP_REPAIR_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR="${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR:-}"
default_repair_snapshot="/tmp/imserver-cloud-security-group-current.json"
default_repair_plan="/tmp/imserver-cloud-security-group-repair-plan.json"
default_repair_receipt="/tmp/imserver-cloud-security-group-repair-receipt.json"
default_latest_snapshot_link=""
default_latest_plan_link=""
default_latest_receipt_link=""
if [[ -n "${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR}" ]]; then
  default_repair_snapshot="${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR}/snapshots/imserver-cloud-security-group-${ALIYUN_SECURITY_GROUP_REPAIR_ID}.json"
  default_repair_plan="${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR}/repairs/imserver-cloud-security-group-repair-plan-${ALIYUN_SECURITY_GROUP_REPAIR_ID}.json"
  default_repair_receipt="${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR}/repairs/imserver-cloud-security-group-repair-receipt-${ALIYUN_SECURITY_GROUP_REPAIR_ID}.json"
  default_latest_snapshot_link="${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR}/snapshots/latest-snapshot.json"
  default_latest_plan_link="${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR}/repairs/latest-repair-plan.json"
  default_latest_receipt_link="${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR}/repairs/latest-repair-receipt.json"
fi
ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT="${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT:-${default_repair_snapshot}}"
ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON="${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON:-${default_repair_plan}}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-${default_repair_receipt}}"
ALIYUN_SECURITY_GROUP_REPAIR_LATEST_SNAPSHOT_LINK="${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_SNAPSHOT_LINK:-${default_latest_snapshot_link}}"
ALIYUN_SECURITY_GROUP_REPAIR_LATEST_PLAN_LINK="${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_PLAN_LINK:-${default_latest_plan_link}}"
ALIYUN_SECURITY_GROUP_REPAIR_LATEST_RECEIPT_LINK="${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_RECEIPT_LINK:-${default_latest_receipt_link}}"
ALIYUN_SECURITY_GROUP_REPAIR_UPDATE_LATEST_LINKS="${ALIYUN_SECURITY_GROUP_REPAIR_UPDATE_LATEST_LINKS:-}"
if [[ -z "${ALIYUN_SECURITY_GROUP_REPAIR_UPDATE_LATEST_LINKS}" ]]; then
  if [[ -n "${ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR}" ]]; then
    ALIYUN_SECURITY_GROUP_REPAIR_UPDATE_LATEST_LINKS=true
  else
    ALIYUN_SECURITY_GROUP_REPAIR_UPDATE_LATEST_LINKS=false
  fi
fi
ALIYUN_SECURITY_GROUP_REPAIR_FETCH="${ALIYUN_SECURITY_GROUP_REPAIR_FETCH:-true}"

CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_file_parent_dir() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  mkdir -p "$(dirname "${path}")"
}

update_latest_link() {
  local target="$1"
  local link="$2"
  [[ -n "${target}" && -n "${link}" ]] || return 0
  ensure_file_parent_dir "${link}"
  rm -f "${link}"
  ln -s "${target}" "${link}"
}

update_latest_links_if_verified() {
  local status="$1"
  local post_apply_snapshot="${2:-}"
  if ! bool_enabled "${ALIYUN_SECURITY_GROUP_REPAIR_UPDATE_LATEST_LINKS}"; then
    return 0
  fi
  if [[ "${status}" != "APPLIED_VERIFIED" ]]; then
    printf 'aliyun-security-group-repair latest-links result=skip reason=repair_not_applied_verified status=%s\n' "${status}"
    return 0
  fi
  update_latest_link "${post_apply_snapshot:-${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT}}" "${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_SNAPSHOT_LINK}"
  update_latest_link "${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON}" "${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_PLAN_LINK}"
  update_latest_link "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" "${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_RECEIPT_LINK}"
  printf 'aliyun-security-group-repair latest-links result=pass snapshot=%s plan=%s receipt=%s\n' \
    "${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_SNAPSHOT_LINK:-}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_PLAN_LINK:-}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_LATEST_RECEIPT_LINK:-}"
}

usage() {
  cat <<'EOF'
Usage:
  ALIYUN_SECURITY_GROUP_ID=sg-... \
  ALIYUN_REGION_ID=cn-shenzhen \
  ALIYUN_SECURITY_GROUP_ADMIN_CIDR=<your-admin-public-ip>/32 \
    bash deploy/ubuntu/30_repair_aliyun_security_group.sh

Apply the generated plan:
  ALIYUN_SECURITY_GROUP_REPAIR_APPLY=true \
  ALIYUN_SECURITY_GROUP_ID=sg-... \
  ALIYUN_REGION_ID=cn-shenzhen \
  ALIYUN_SECURITY_GROUP_ADMIN_CIDR=<your-admin-public-ip>/32 \
    bash deploy/ubuntu/30_repair_aliyun_security_group.sh

Purpose:
  Plan, and optionally apply, the long-term IMServer Aliyun ECS security group
  posture:
    - allow public tcp 80, 443, and 9000 from 0.0.0.0/0
    - allow SSH only from the supplied admin CIDR
    - revoke public 22, 3389, 8080, 5432, 6379, 9092, 8081, 8082, and 18080

This script is dry-run by default. It modifies cloud rules only when
ALIYUN_SECURITY_GROUP_REPAIR_APPLY=true.

Artifacts:
  ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON=/tmp/imserver-cloud-security-group-repair-plan.json
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON=/tmp/imserver-cloud-security-group-repair-receipt.json
  ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR=/var/lib/imserver/cloud-security-group

When ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR is set, snapshot, plan, and
receipt artifacts are written under that directory. latest-* symlinks are
updated only after an applied repair also passes post-apply verification.
EOF
}

validate_inputs() {
  if [[ -z "${ALIYUN_SECURITY_GROUP_ID}" ]]; then
    printf 'aliyun-security-group-repair result=fail reason=security_group_id_required action=set_ALIYUN_SECURITY_GROUP_ID\n' >&2
    return 2
  fi
  if [[ -z "${ALIYUN_SECURITY_GROUP_ADMIN_CIDR}" && -n "${CLOUD_SECURITY_GROUP_ADMIN_PORTS}" ]]; then
    printf 'aliyun-security-group-repair result=fail reason=admin_cidr_required action=set_ALIYUN_SECURITY_GROUP_ADMIN_CIDR=<your-admin-public-ip>/32\n' >&2
    return 2
  fi
  if ! command -v "${ALIYUN_CLI_BIN}" >/dev/null 2>&1; then
    printf 'aliyun-security-group-repair result=fail reason=aliyun_cli_missing bin=%s action=install_and_configure_aliyun_cli\n' "${ALIYUN_CLI_BIN}" >&2
    return 2
  fi
}

fetch_snapshot_if_needed() {
  ensure_file_parent_dir "${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT}"
  if ! bool_enabled "${ALIYUN_SECURITY_GROUP_REPAIR_FETCH}"; then
    [[ -f "${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT}" ]] || {
      printf 'aliyun-security-group-repair result=fail reason=snapshot_missing path=%s\n' "${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT}" >&2
      return 2
    }
    return 0
  fi

  ALIYUN_SECURITY_GROUP_ID="${ALIYUN_SECURITY_GROUP_ID}" \
    ALIYUN_REGION_ID="${ALIYUN_REGION_ID}" \
    ALIYUN_PROFILE="${ALIYUN_PROFILE}" \
    ALIYUN_CLI_BIN="${ALIYUN_CLI_BIN}" \
    ALIYUN_SECURITY_GROUP_OUTPUT="${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT}" \
    ALIYUN_SECURITY_GROUP_AUDIT=false \
      bash "${SCRIPT_DIR}/29_fetch_aliyun_security_group_snapshot.sh" >/dev/null
}

write_plan() {
  ensure_file_parent_dir "${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON}"
  python3 - \
    "${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON}" \
    "${ALIYUN_SECURITY_GROUP_ID}" \
    "${ALIYUN_SECURITY_GROUP_ADMIN_CIDR}" \
    "${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    "${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
    "${CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
    "${CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" <<'PY'
import ipaddress
import json
import re
import sys
from pathlib import Path
from typing import Any

snapshot_path, plan_path, security_group_id, admin_cidr_raw, public_ports_raw, deny_ports_raw, admin_ports_raw, allow_icmp_raw = sys.argv[1:9]

def parse_ports(raw: str) -> list[int]:
    return sorted({int(token) for token in raw.split() if token.strip()})

def discover_rules(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if not isinstance(value, dict):
        return []
    for path in [
        ("rules",),
        ("Rules",),
        ("permissions",),
        ("Permissions",),
        ("SecurityGroupRules",),
        ("securityGroupRules",),
        ("SecurityGroupRules", "SecurityGroupRule"),
        ("Permissions", "Permission"),
        ("permissions", "permission"),
    ]:
        current: Any = value
        for key in path:
            current = current.get(key) if isinstance(current, dict) else None
        rules = discover_rules(current)
        if rules:
            return rules
    nested: list[dict[str, Any]] = []
    for child in value.values():
        nested.extend(discover_rules(child))
    return nested

def first(rule: dict[str, Any], names: list[str], default: str = "") -> str:
    lowered = {str(key).lower(): value for key, value in rule.items()}
    for name in names:
        if name in rule and rule[name] is not None:
            return str(rule[name])
        value = lowered.get(name.lower())
        if value is not None:
            return str(value)
    return default

def protocol(raw: str) -> str:
    text = raw.strip().lower()
    if text in {"", "all", "any", "-1"}:
        return "ALL"
    if "icmp" in text:
        return "ICMP"
    if "tcp" in text:
        return "TCP"
    if "udp" in text:
        return "UDP"
    return text.upper()

def parse_ranges(raw: str) -> list[tuple[int, int]]:
    text = raw.strip()
    if not text or text in {"*", "all", "ALL", "-1", "-1/-1"}:
        return [(0, 65535)]
    ranges: list[tuple[int, int]] = []
    for part in re.split(r"[,;\s]+", text):
        match = re.match(r"^(-?\d+)(?:\s*[-/]\s*(-?\d+))?$", part.strip())
        if not match:
            continue
        start = int(match.group(1))
        end = int(match.group(2) or match.group(1))
        if start < 0 or end < 0:
            ranges.append((0, 65535))
        else:
            ranges.append((min(start, end), max(start, end)))
    return ranges or [(0, 65535)]

def contains(ranges: list[tuple[int, int]], port: int) -> bool:
    return any(start <= port <= end for start, end in ranges)

def exact_port_range(raw: str, port: int) -> bool:
    return raw.strip() == f"{port}/{port}"

def allow(rule: dict[str, Any]) -> bool:
    action = first(rule, ["action", "policy", "authorizationPolicy", "access"], "accept").lower()
    return action in {"accept", "allow", "permit", "true"} or "accept" in action or "allow" in action

def ingress(rule: dict[str, Any]) -> bool:
    direction = first(rule, ["direction", "Direction", "ruleType"], "ingress").lower()
    return direction not in {"egress", "out", "outbound"}

def source_entries(rule: dict[str, Any]) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for key in ["SourceCidrIp", "sourceCidrIp", "source", "sourceCidr", "cidr", "cidrIp", "CidrIp"]:
        value = first(rule, [key])
        if value:
            entries.extend(("SourceCidrIp", part) for part in re.split(r"[,;\s]+", value) if part)
    for key in ["Ipv6SourceCidrIp", "SourceCidrIpv6", "sourceCidrIpv6", "SourceCidrIPv6", "ipv6CidrBlock"]:
        value = first(rule, [key])
        if value:
            entries.extend(("Ipv6SourceCidrIp", part) for part in re.split(r"[,;\s]+", value) if part)
    return entries or [("SourceCidrIp", "0.0.0.0/0")]

def public_source(value: str) -> bool:
    lowered = value.lower()
    if lowered in {"any", "anywhere", "internet", "0.0.0.0/0", "::/0", "*"}:
        return True
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return False
    return network.is_global and ((network.version == 4 and network.prefixlen <= 8) or (network.version == 6 and network.prefixlen <= 16))

def normalize_cidr(raw: str) -> str:
    if not raw.strip():
        return ""
    if "/" in raw:
        return str(ipaddress.ip_network(raw, strict=False))
    address = ipaddress.ip_address(raw)
    return str(ipaddress.ip_network(f"{address}/32" if address.version == 4 else f"{address}/128", strict=False))

payload = json.loads(Path(snapshot_path).read_text(encoding="utf-8"))
public_ports = parse_ports(public_ports_raw)
deny_ports = parse_ports(deny_ports_raw)
admin_ports = parse_ports(admin_ports_raw)
admin_cidr = normalize_cidr(admin_cidr_raw)
if admin_cidr:
    admin_network = ipaddress.ip_network(admin_cidr, strict=False)
    if admin_network.prefixlen == 0 or admin_network.network_address.is_unspecified:
        raise SystemExit(f"aliyun-security-group-repair result=fail reason=admin_cidr_public_anywhere value={admin_cidr}")
    if admin_network.is_multicast:
        raise SystemExit(f"aliyun-security-group-repair result=fail reason=admin_cidr_invalid_multicast value={admin_cidr}")
    if admin_network.is_reserved:
        raise SystemExit(f"aliyun-security-group-repair result=fail reason=admin_cidr_invalid_reserved value={admin_cidr}")
    if admin_network.version == 4 and admin_network.is_global and admin_network.prefixlen < 32:
        raise SystemExit(f"aliyun-security-group-repair result=fail reason=admin_cidr_not_specific_enough value={admin_cidr} requiredPrefix=32")
    if admin_network.version == 6 and admin_network.is_global and admin_network.prefixlen < 128:
        raise SystemExit(f"aliyun-security-group-repair result=fail reason=admin_cidr_not_specific_enough value={admin_cidr} requiredPrefix=128")

rules = []
for raw in discover_rules(payload):
    if not allow(raw) or not ingress(raw):
        continue
    proto = protocol(first(raw, ["IpProtocol", "ipProtocol", "protocol"], "tcp"))
    port_range = first(raw, ["PortRange", "portRange", "port", "ports"], "")
    if not port_range:
        port_range = "-1/-1" if proto in {"ALL", "ICMP"} else ""
    ranges = parse_ranges(port_range)
    rules.append({
        "raw": raw,
        "securityGroupRuleId": first(raw, ["SecurityGroupRuleId", "securityGroupRuleId", "SecurityGroupRuleID", "ruleId"], ""),
        "ipProtocol": proto,
        "portRange": port_range,
        "ranges": ranges,
        "sources": source_entries(raw),
        "nicType": first(raw, ["NicType", "nicType"], ""),
        "policy": first(raw, ["Policy", "policy", "action"], "accept").lower(),
    })

actions: list[dict[str, Any]] = []
seen: set[tuple[Any, ...]] = set()

def add_action(action: dict[str, Any]) -> None:
    key = tuple(sorted((k, str(v)) for k, v in action.items() if k not in {"reason"}))
    if key in seen:
        return
    seen.add(key)
    actions.append(action)

def exact_rule_exists(port: int, source_key: str, source_value: str) -> bool:
    for rule in rules:
        if rule["ipProtocol"] != "TCP" or not exact_port_range(rule["portRange"], port):
            continue
        if any(key == source_key and value == source_value for key, value in rule["sources"]):
            return True
    return False

for port in public_ports:
    if not exact_rule_exists(port, "SourceCidrIp", "0.0.0.0/0"):
        add_action({
            "kind": "authorize",
            "reason": f"required_public_client_port:{port}",
            "ipProtocol": "TCP",
            "portRange": f"{port}/{port}",
            "sourceKey": "SourceCidrIp",
            "sourceValue": "0.0.0.0/0",
            "policy": "accept",
        })

if admin_cidr:
    admin_key = "Ipv6SourceCidrIp" if ipaddress.ip_network(admin_cidr, strict=False).version == 6 else "SourceCidrIp"
    for port in admin_ports:
        if not exact_rule_exists(port, admin_key, admin_cidr):
            add_action({
                "kind": "authorize",
                "reason": f"required_admin_port:{port}",
                "ipProtocol": "TCP",
                "portRange": f"{port}/{port}",
                "sourceKey": admin_key,
                "sourceValue": admin_cidr,
                "policy": "accept",
            })

revoke_ports = sorted(set(deny_ports) | set(admin_ports))
for rule in rules:
    if rule["ipProtocol"] == "ICMP" and allow_icmp_raw.lower() in {"1", "true", "yes", "on"}:
        continue
    if rule["ipProtocol"] not in {"TCP", "ALL"}:
        continue
    for source_key, source_value in rule["sources"]:
        if not public_source(source_value):
            continue
        matching_ports = [port for port in revoke_ports if contains(rule["ranges"], port)]
        if not matching_ports:
            continue
        add_action({
            "kind": "revoke",
            "reason": "public_disallowed_ports:" + ",".join(map(str, matching_ports)),
            "ipProtocol": rule["ipProtocol"],
            "portRange": rule["portRange"] or ("-1/-1" if rule["ipProtocol"] == "ALL" else ""),
            "sourceKey": source_key,
            "sourceValue": source_value,
            "policy": rule["policy"] or "accept",
            "nicType": rule["nicType"],
            "securityGroupRuleId": rule["securityGroupRuleId"],
        })

plan = {
    "schemaVersion": 1,
    "securityGroupId": security_group_id,
    "snapshot": str(Path(snapshot_path).resolve()),
    "adminCidr": admin_cidr,
    "publicClientPorts": public_ports,
    "adminPorts": admin_ports,
    "denyPublicPorts": deny_ports,
    "status": "CHANGE_REQUIRED" if actions else "NOOP",
    "actions": actions,
    "summary": {
        "actionCount": len(actions),
        "authorizeCount": sum(1 for action in actions if action["kind"] == "authorize"),
        "revokeCount": sum(1 for action in actions if action["kind"] == "revoke"),
    },
}
Path(plan_path).write_text(json.dumps(plan, indent=2, sort_keys=True), encoding="utf-8")
print(f"aliyun-security-group-repair-plan result=pass status={plan['status']} actions={len(actions)} output={plan_path}")
PY
}

print_plan_summary() {
  python3 - "${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON}" <<'PY'
import json
import sys
from pathlib import Path

plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(
    f"aliyun-security-group-repair result=plan status={plan['status']} "
    f"actions={plan['summary']['actionCount']} authorize={plan['summary']['authorizeCount']} revoke={plan['summary']['revokeCount']}"
)
for index, action in enumerate(plan["actions"], start=1):
    print(
        f"  {index}. {action['kind']} reason={action['reason']} "
        f"protocol={action['ipProtocol']} portRange={action['portRange']} "
        f"{action['sourceKey']}={action['sourceValue']}"
    )
PY
}

apply_plan() {
  python3 - \
    "${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON}" \
    "${ALIYUN_CLI_BIN}" \
    "${ALIYUN_REGION_ID}" \
    "${ALIYUN_PROFILE}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

plan_path, cli_bin, region_id, profile = sys.argv[1:5]
plan = json.loads(Path(plan_path).read_text(encoding="utf-8"))
base = [cli_bin, "ecs"]
common = ["--SecurityGroupId", plan["securityGroupId"]]
if region_id:
    common.extend(["--RegionId", region_id])
if profile:
    common.extend(["--profile", profile])

for action in plan["actions"]:
    operation = "AuthorizeSecurityGroup" if action["kind"] == "authorize" else "RevokeSecurityGroup"
    rule_id = action.get("securityGroupRuleId") or ""
    if action["kind"] == "revoke" and rule_id:
        cmd = base + [operation] + common + ["--SecurityGroupRuleId.1", rule_id]
    else:
        cmd = base + [operation] + common + [
            "--IpProtocol", action["ipProtocol"],
            "--PortRange", action["portRange"],
            f"--{action['sourceKey']}", action["sourceValue"],
            "--Policy", action.get("policy") or "accept",
        ]
        if action["kind"] == "revoke" and action.get("nicType"):
            cmd.extend(["--NicType", action["nicType"]])
    print("aliyun-security-group-repair apply command=" + " ".join(cmd))
    subprocess.run(cmd, check=True)
print(f"aliyun-security-group-repair apply result=pass actions={len(plan['actions'])}")
PY
}

write_repair_receipt() {
  local status="$1"
  local applied="$2"
  local verified="$3"
  local post_apply_snapshot="${4:-}"
  ensure_file_parent_dir "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON}"
  python3 - \
    "${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
    "${status}" \
    "${applied}" \
    "${verified}" \
    "${post_apply_snapshot}" \
    "${ALIYUN_SECURITY_GROUP_ID}" \
    "${ALIYUN_REGION_ID}" \
    "${ALIYUN_SECURITY_GROUP_ADMIN_CIDR}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_APPLY}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_VERIFY_AFTER_APPLY}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

(
    plan_path,
    receipt_path,
    status,
    applied,
    verified,
    post_apply_snapshot,
    security_group_id,
    region_id,
    admin_cidr,
    snapshot_path,
    apply_requested,
    verify_requested,
) = sys.argv[1:13]

def file_record(raw_path: str) -> dict[str, object]:
    if not raw_path:
        return {
            "path": "",
            "present": False,
            "bytes": 0,
            "sha256": "",
        }
    path = Path(raw_path).resolve()
    if not path.is_file():
        return {
            "path": str(path),
            "present": False,
            "bytes": 0,
            "sha256": "",
        }
    data = path.read_bytes()
    return {
        "path": str(path),
        "present": True,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }

plan = json.loads(Path(plan_path).read_text(encoding="utf-8"))
receipt = {
    "schemaVersion": 1,
    "status": status,
    "generatedAtEpoch": int(time.time()),
    "securityGroupId": security_group_id,
    "regionId": region_id,
    "adminCidr": admin_cidr,
    "applyRequested": apply_requested.lower() in {"1", "true", "yes", "on"},
    "applied": applied.lower() in {"1", "true", "yes", "on"},
    "verifyRequested": verify_requested.lower() in {"1", "true", "yes", "on"},
    "verified": verified.lower() in {"1", "true", "yes", "on"},
    "snapshot": str(Path(snapshot_path).resolve()),
    "postApplySnapshot": str(Path(post_apply_snapshot).resolve()) if post_apply_snapshot else "",
    "plan": str(Path(plan_path).resolve()),
    "planStatus": plan.get("status", ""),
    "summary": plan.get("summary", {}),
    "artifacts": {
        "snapshot": file_record(snapshot_path),
        "postApplySnapshot": file_record(post_apply_snapshot),
        "plan": file_record(plan_path),
    },
}
Path(receipt_path).write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
print(f"aliyun-security-group-repair receipt result=pass status={status} path={receipt_path}")
PY
}

verify_after_apply() {
  local verify_snapshot
  verify_snapshot="${ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT}.post-apply"
  ALIYUN_SECURITY_GROUP_ID="${ALIYUN_SECURITY_GROUP_ID}" \
    ALIYUN_REGION_ID="${ALIYUN_REGION_ID}" \
    ALIYUN_PROFILE="${ALIYUN_PROFILE}" \
    ALIYUN_CLI_BIN="${ALIYUN_CLI_BIN}" \
    ALIYUN_SECURITY_GROUP_OUTPUT="${verify_snapshot}" \
    ALIYUN_SECURITY_GROUP_AUDIT=true \
    CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
    CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
      bash "${SCRIPT_DIR}/29_fetch_aliyun_security_group_snapshot.sh" >/dev/null
  printf 'aliyun-security-group-repair verify result=pass snapshot=%s\n' "${verify_snapshot}" >&2
  printf '%s\n' "${verify_snapshot}"
}

run() {
  validate_inputs
  fetch_snapshot_if_needed
  write_plan
  print_plan_summary
  if ! bool_enabled "${ALIYUN_SECURITY_GROUP_REPAIR_APPLY}"; then
    write_repair_receipt "DRY_RUN" false false ""
    printf 'aliyun-security-group-repair result=dry-run apply=false plan=%s\n' "${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON}"
    return 0
  fi
  apply_plan
  post_apply_snapshot=""
  if bool_enabled "${ALIYUN_SECURITY_GROUP_REPAIR_VERIFY_AFTER_APPLY}"; then
    post_apply_snapshot="$(verify_after_apply)"
    write_repair_receipt "APPLIED_VERIFIED" true true "${post_apply_snapshot}"
    update_latest_links_if_verified "APPLIED_VERIFIED" "${post_apply_snapshot}"
  else
    write_repair_receipt "APPLIED_UNVERIFIED" true false ""
    update_latest_links_if_verified "APPLIED_UNVERIFIED" ""
  fi
  printf 'aliyun-security-group-repair result=pass apply=true plan=%s\n' "${ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON}"
}

run_self_test() {
  local tmpdir bindir fake args snapshot plan receipt log
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  bindir="${tmpdir}/bin"
  mkdir -p "${bindir}"
  fake="${bindir}/aliyun"
  args="${tmpdir}/aliyun-args.log"
  snapshot="${tmpdir}/evidence/snapshots/snapshot.json"
  plan="${tmpdir}/evidence/repairs/plan.json"
  receipt="${tmpdir}/evidence/repairs/receipt.json"
  log="${tmpdir}/repair.log"

  cat >"${fake}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${ALIYUN_FAKE_ARGS_FILE}"
case "$*" in
  *DescribeSecurityGroupAttribute*)
    fetch_count=1
    if [[ -n "${ALIYUN_FAKE_FETCH_COUNT_FILE:-}" ]]; then
      if [[ -f "${ALIYUN_FAKE_FETCH_COUNT_FILE}" ]]; then
        fetch_count="$(($(cat "${ALIYUN_FAKE_FETCH_COUNT_FILE}") + 1))"
      fi
      printf '%s\n' "${fetch_count}" >"${ALIYUN_FAKE_FETCH_COUNT_FILE}"
    fi
    if [[ -n "${ALIYUN_FAKE_FETCH_COUNT_FILE:-}" && "${fetch_count}" -ge 2 ]]; then
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
      exit 0
    fi
    cat <<'JSON'
{
  "Permissions": {
    "Permission": [
      {"IpProtocol": "tcp", "PortRange": "80/80", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"SecurityGroupRuleId": "sgr-public-ssh", "IpProtocol": "tcp", "PortRange": "22/22", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "3389/3389", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "8080/8080", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"}
    ]
  }
}
JSON
    ;;
  *)
    cat <<'JSON'
{"RequestId": "self-test"}
JSON
    ;;
esac
SH
  chmod +x "${fake}"

  PATH="${bindir}:${PATH}" \
  ALIYUN_FAKE_ARGS_FILE="${args}" \
  ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST=false \
  ALIYUN_SECURITY_GROUP_ID=sg-selftest \
  ALIYUN_REGION_ID=cn-shenzhen \
  ALIYUN_SECURITY_GROUP_ADMIN_CIDR=203.0.113.10/32 \
  ALIYUN_CLI_BIN="${fake}" \
  ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT="${snapshot}" \
  ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON="${plan}" \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${receipt}" \
    bash "${BASH_SOURCE[0]}" >"${log}"
  grep -q 'result=dry-run' "${log}"
  grep -q '"status": "DRY_RUN"' "${receipt}"
  grep -q '"applied": false' "${receipt}"
  grep -q '"verified": false' "${receipt}"
  grep -q '"artifacts": {' "${receipt}"
  grep -q '"sha256":' "${receipt}"
  grep -q '"present": true' "${receipt}"
  grep -q 'required_public_client_port:443' "${plan}"
  grep -q 'required_public_client_port:9000' "${plan}"
  grep -q 'required_admin_port:22' "${plan}"
  grep -q 'public_disallowed_ports:22' "${plan}"
  grep -q '"securityGroupRuleId": "sgr-public-ssh"' "${plan}"
  grep -q 'public_disallowed_ports:3389' "${plan}"
  grep -q 'public_disallowed_ports:8080' "${plan}"
  ! grep -q 'AuthorizeSecurityGroup' "${args}" || {
    printf 'aliyun-security-group-repair-self-test result=fail reason=dry_run_applied\n' >&2
    return 1
  }

  : >"${args}"
  PATH="${bindir}:${PATH}" \
  ALIYUN_FAKE_ARGS_FILE="${args}" \
  ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST=false \
  ALIYUN_SECURITY_GROUP_REPAIR_APPLY=true \
  ALIYUN_SECURITY_GROUP_REPAIR_VERIFY_AFTER_APPLY=false \
  ALIYUN_SECURITY_GROUP_ID=sg-selftest \
  ALIYUN_REGION_ID=cn-shenzhen \
  ALIYUN_SECURITY_GROUP_ADMIN_CIDR=203.0.113.10/32 \
  ALIYUN_CLI_BIN="${fake}" \
  ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT="${snapshot}" \
  ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON="${plan}" \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${receipt}" \
    bash "${BASH_SOURCE[0]}" >"${log}"
  grep -q 'apply result=pass' "${log}"
  grep -q '"status": "APPLIED_UNVERIFIED"' "${receipt}"
  grep -q '"applied": true' "${receipt}"
  grep -q '"verified": false' "${receipt}"
  grep -q '"artifacts": {' "${receipt}"
  grep -q '"sha256":' "${receipt}"
  grep -q '"present": true' "${receipt}"
  grep -q 'AuthorizeSecurityGroup' "${args}"
  grep -q 'RevokeSecurityGroup' "${args}"
  grep -q -- '--SecurityGroupRuleId.1 sgr-public-ssh' "${args}"
  grep -q -- '--PortRange 443/443' "${args}"
  grep -q -- '--PortRange 3389/3389' "${args}"

  if ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST=false \
    ALIYUN_CLI_BIN="${fake}" \
    ALIYUN_SECURITY_GROUP_ID=sg-selftest \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-repair-self-test result=fail reason=missing_admin_cidr_passed\n' >&2
    return 1
  fi
  grep -q 'admin_cidr_required' "${log}"

  if PATH="${bindir}:${PATH}" \
    ALIYUN_FAKE_ARGS_FILE="${args}" \
    ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST=false \
    ALIYUN_SECURITY_GROUP_ID=sg-selftest \
    ALIYUN_REGION_ID=cn-shenzhen \
    ALIYUN_SECURITY_GROUP_ADMIN_CIDR=0.0.0.0/0 \
    ALIYUN_CLI_BIN="${fake}" \
    ALIYUN_SECURITY_GROUP_REPAIR_SNAPSHOT="${snapshot}" \
    ALIYUN_SECURITY_GROUP_REPAIR_PLAN_JSON="${plan}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${receipt}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-repair-self-test result=fail reason=public_anywhere_admin_cidr_passed\n' >&2
    return 1
  fi
  grep -q 'admin_cidr_public_anywhere' "${log}"

  : >"${args}"
  rm -f "${tmpdir}/fetch-count"
  PATH="${bindir}:${PATH}" \
  ALIYUN_FAKE_ARGS_FILE="${args}" \
  ALIYUN_FAKE_FETCH_COUNT_FILE="${tmpdir}/fetch-count" \
  ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST=false \
  ALIYUN_SECURITY_GROUP_REPAIR_APPLY=true \
  ALIYUN_SECURITY_GROUP_ID=sg-selftest \
  ALIYUN_REGION_ID=cn-shenzhen \
  ALIYUN_SECURITY_GROUP_ADMIN_CIDR=203.0.113.10/32 \
  ALIYUN_CLI_BIN="${fake}" \
  ALIYUN_SECURITY_GROUP_REPAIR_ID=selftest \
  ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR="${tmpdir}/persistent-evidence" \
    bash "${BASH_SOURCE[0]}" >"${log}"
  grep -q 'latest-links result=pass' "${log}"
  grep -q '"status": "APPLIED_VERIFIED"' "${tmpdir}/persistent-evidence/repairs/imserver-cloud-security-group-repair-receipt-selftest.json"
  [[ -L "${tmpdir}/persistent-evidence/snapshots/latest-snapshot.json" ]] || {
    printf 'aliyun-security-group-repair-self-test result=fail reason=latest_snapshot_link_missing\n' >&2
    return 1
  }
  [[ -L "${tmpdir}/persistent-evidence/repairs/latest-repair-plan.json" ]] || {
    printf 'aliyun-security-group-repair-self-test result=fail reason=latest_plan_link_missing\n' >&2
    return 1
  }
  [[ -L "${tmpdir}/persistent-evidence/repairs/latest-repair-receipt.json" ]] || {
    printf 'aliyun-security-group-repair-self-test result=fail reason=latest_receipt_link_missing\n' >&2
    return 1
  }
  grep -q '203.0.113.10/32' "${tmpdir}/persistent-evidence/snapshots/latest-snapshot.json"
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST=false \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${tmpdir}/persistent-evidence/repairs/latest-repair-receipt.json" \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-selftest \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
    bash "${SCRIPT_DIR}/31_verify_aliyun_security_group_repair_receipt.sh" >/tmp/im-cloud-sg-repair-receipt-self-test.log
  grep -q 'result=pass' /tmp/im-cloud-sg-repair-receipt-self-test.log

  printf 'aliyun-security-group-repair-self-test result=pass\n'
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
    printf 'aliyun-security-group-repair result=fail reason=unknown_argument arg=%s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

if bool_enabled "${ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST}"; then
  run_self_test
  exit 0
fi

run
