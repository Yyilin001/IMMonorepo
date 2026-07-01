#!/usr/bin/env bash
set -euo pipefail

ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST:-false}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED:-false}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED:-false}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-0}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_PUBLIC_CLIENT_PORTS="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_PUBLIC_CLIENT_PORTS:-80 443 9000}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_PORTS="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_PORTS:-22}"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_DENY_PUBLIC_PORTS="${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

verify_receipt() {
  local receipt="$1"
  if [[ -z "${receipt}" ]]; then
    printf 'aliyun-security-group-repair-receipt-verify result=fail reason=receipt_required action=set_ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON\n' >&2
    return 2
  fi
  if [[ ! -f "${receipt}" ]]; then
    printf 'aliyun-security-group-repair-receipt-verify result=fail reason=receipt_missing path=%s\n' "${receipt}" >&2
    return 2
  fi

  python3 - \
    "${receipt}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_PUBLIC_CLIENT_PORTS}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_PORTS}" \
    "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_DENY_PUBLIC_PORTS}" <<'PY'
import hashlib
import ipaddress
import json
import re
import sys
import time
from pathlib import Path
from typing import Any, Optional

(
    receipt_path_raw,
    require_applied_raw,
    require_verified_raw,
    max_age_raw,
    expect_security_group_id,
    expect_region_id,
    expect_admin_cidr,
    expect_public_client_ports_raw,
    expect_admin_ports_raw,
    expect_deny_public_ports_raw,
) = sys.argv[1:11]

receipt_path = Path(receipt_path_raw).resolve()
require_applied = require_applied_raw.lower() in {"1", "true", "yes", "on"}
require_verified = require_verified_raw.lower() in {"1", "true", "yes", "on"}
max_age = int(max_age_raw or "0")


def fail(reason: str, **fields: object) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"aliyun-security-group-repair-receipt-verify result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def load_json(path: Path, name: str) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        fail(f"{name}_json_invalid", path=path, error=exc)
    if not isinstance(payload, dict):
        fail(f"{name}_json_not_object", path=path)
    return payload


def sha256(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def parse_ports(raw: str, label: str) -> set[int]:
    ports: set[int] = set()
    for token in raw.split():
        text = token.strip()
        if not text:
            continue
        try:
            port = int(text)
        except ValueError:
            fail("expected_ports_invalid", label=label, value=text)
        if port <= 0 or port > 65535:
            fail("expected_ports_invalid", label=label, value=text)
        ports.add(port)
    return ports


def plan_ports(plan: dict[str, Any], field: str) -> set[int]:
    value = plan.get(field)
    if not isinstance(value, list):
        fail("plan_port_field_invalid", field=field)
    ports: set[int] = set()
    for item in value:
        try:
            port = int(item)
        except Exception:
            fail("plan_port_field_invalid", field=field, value=item)
        if port <= 0 or port > 65535:
            fail("plan_port_field_invalid", field=field, value=item)
        ports.add(port)
    return ports


def normalize_protocol(raw: object) -> str:
    text = str(raw or "").strip().upper()
    if text in {"", "ALL", "ANY", "-1"}:
        return "ALL"
    if "TCP" in text:
        return "TCP"
    if "ICMP" in text:
        return "ICMP"
    if "UDP" in text:
        return "UDP"
    return text


def parse_port_ranges(raw: object) -> list[tuple[int, int]]:
    text = str(raw or "").strip()
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


def range_contains(ranges: list[tuple[int, int]], port: int) -> bool:
    return any(start <= port <= end for start, end in ranges)


def public_source(value: object) -> bool:
    raw = str(value or "").strip().lower()
    if raw in {"any", "anywhere", "internet", "0.0.0.0/0", "::/0", "*"}:
        return True
    try:
        network = ipaddress.ip_network(raw, strict=False)
    except ValueError:
        return False
    return network.is_global and (
        (network.version == 4 and network.prefixlen <= 8)
        or (network.version == 6 and network.prefixlen <= 16)
    )


def validate_admin_cidr(admin_cidr: str) -> None:
    if not admin_cidr:
        fail("admin_cidr_missing")
    try:
        network = ipaddress.ip_network(admin_cidr, strict=False)
    except ValueError:
        fail("admin_cidr_invalid", value=admin_cidr)
    if network.prefixlen == 0 or network.network_address.is_unspecified:
        fail("admin_cidr_public_anywhere", value=admin_cidr)
    if network.is_global and network.version == 4 and network.prefixlen < 32:
        fail("admin_cidr_not_specific_enough", value=admin_cidr, requiredPrefix=32)
    if network.is_global and network.version == 6 and network.prefixlen < 128:
        fail("admin_cidr_not_specific_enough", value=admin_cidr, requiredPrefix=128)


def validate_plan_policy(plan: dict[str, Any], admin_cidr: str) -> None:
    expected_public_ports = parse_ports(expect_public_client_ports_raw, "publicClientPorts")
    expected_admin_ports = parse_ports(expect_admin_ports_raw, "adminPorts")
    expected_deny_ports = parse_ports(expect_deny_public_ports_raw, "denyPublicPorts")
    actual_public_ports = plan_ports(plan, "publicClientPorts")
    actual_admin_ports = plan_ports(plan, "adminPorts")
    actual_deny_ports = plan_ports(plan, "denyPublicPorts")
    if actual_public_ports != expected_public_ports:
        fail(
            "plan_public_client_ports_mismatch",
            expected=",".join(map(str, sorted(expected_public_ports))),
            actual=",".join(map(str, sorted(actual_public_ports))),
        )
    if actual_admin_ports != expected_admin_ports:
        fail(
            "plan_admin_ports_mismatch",
            expected=",".join(map(str, sorted(expected_admin_ports))),
            actual=",".join(map(str, sorted(actual_admin_ports))),
        )
    missing_deny_ports = sorted(expected_deny_ports - actual_deny_ports)
    if missing_deny_ports:
        fail("plan_deny_public_ports_missing", ports=",".join(map(str, missing_deny_ports)))
    forbidden_public_ports = sorted(actual_public_ports & ({22, 3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080} | actual_admin_ports))
    if forbidden_public_ports:
        fail("plan_public_client_ports_forbidden", ports=",".join(map(str, forbidden_public_ports)))
    validate_admin_cidr(admin_cidr)
    actions = plan.get("actions")
    if not isinstance(actions, list):
        fail("plan_actions_invalid")
    for index, action in enumerate(actions):
        if not isinstance(action, dict):
            fail("plan_action_invalid", index=index)
        if str(action.get("kind") or "") != "authorize":
            continue
        protocol = normalize_protocol(action.get("ipProtocol"))
        if protocol not in {"TCP", "ALL"}:
            continue
        source_value = str(action.get("sourceValue") or "")
        ranges = parse_port_ranges(action.get("portRange"))
        if any(range_contains(ranges, port) for port in actual_admin_ports):
            if source_value != admin_cidr:
                fail("plan_admin_authorize_source_mismatch", index=index, expected=admin_cidr, actual=source_value or "-")
        if public_source(source_value):
            unauthorized = sorted(
                port
                for port in ({22, 3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080} | actual_admin_ports | actual_deny_ports)
                if range_contains(ranges, port)
            )
            if unauthorized:
                fail("plan_public_authorize_disallowed_port", index=index, ports=",".join(map(str, unauthorized)))


def verify_artifact(name: str, entry: object, required: bool) -> Optional[Path]:
    if not isinstance(entry, dict):
        if required:
            fail("artifact_entry_invalid", name=name)
        return None
    raw_path = str(entry.get("path") or "")
    present = bool(entry.get("present"))
    if not raw_path:
        if required:
            fail("artifact_path_missing", name=name)
        return None
    path = Path(raw_path).resolve()
    if not present:
        if required:
            fail("artifact_not_present", name=name, path=path)
        return None
    if not path.is_file():
        fail("artifact_file_missing", name=name, path=path)
    expected_bytes = int(entry.get("bytes") or 0)
    actual_bytes = path.stat().st_size
    if expected_bytes != actual_bytes:
        fail("artifact_size_mismatch", name=name, expected=expected_bytes, actual=actual_bytes)
    expected_sha = str(entry.get("sha256") or "")
    if not expected_sha:
        fail("artifact_sha256_missing", name=name, path=path)
    actual_sha = sha256(path)
    if expected_sha != actual_sha:
        fail("artifact_sha256_mismatch", name=name, expected=expected_sha, actual=actual_sha)
    return path


receipt = load_json(receipt_path, "receipt")
if receipt.get("schemaVersion") != 1:
    fail("schema_version_invalid", value=receipt.get("schemaVersion"))

status = str(receipt.get("status") or "")
valid_statuses = {"DRY_RUN", "APPLIED_VERIFIED", "APPLIED_UNVERIFIED"}
if status not in valid_statuses:
    fail("status_invalid", status=status)

generated_at = int(receipt.get("generatedAtEpoch") or 0)
if generated_at <= 0:
    fail("generated_at_invalid", value=generated_at)
if max_age > 0 and int(time.time()) - generated_at > max_age:
    fail("receipt_stale", maxAgeSeconds=max_age, generatedAtEpoch=generated_at)

security_group_id = str(receipt.get("securityGroupId") or "")
if not security_group_id:
    fail("security_group_id_missing")
if expect_security_group_id and security_group_id != expect_security_group_id:
    fail("security_group_id_mismatch", expected=expect_security_group_id, actual=security_group_id)

region_id = str(receipt.get("regionId") or "")
if expect_region_id and region_id != expect_region_id:
    fail("region_id_mismatch", expected=expect_region_id, actual=region_id)

admin_cidr = str(receipt.get("adminCidr") or "")
if expect_admin_cidr and admin_cidr != expect_admin_cidr:
    fail("admin_cidr_mismatch", expected=expect_admin_cidr, actual=admin_cidr)

applied = bool(receipt.get("applied"))
verified = bool(receipt.get("verified"))
if require_applied and not applied:
    fail("applied_required", status=status)
if require_verified and not verified:
    fail("verified_required", status=status)
if status == "DRY_RUN" and applied:
    fail("dry_run_marked_applied")
if status == "APPLIED_VERIFIED" and not (applied and verified):
    fail("applied_verified_status_inconsistent", applied=applied, verified=verified)
if status == "APPLIED_UNVERIFIED" and not applied:
    fail("applied_unverified_status_inconsistent", applied=applied, verified=verified)
if status == "APPLIED_UNVERIFIED" and verified:
    fail("applied_unverified_marked_verified")

artifacts = receipt.get("artifacts")
if not isinstance(artifacts, dict):
    fail("artifacts_missing")

plan_path = verify_artifact("plan", artifacts.get("plan"), required=True)
snapshot_path = verify_artifact("snapshot", artifacts.get("snapshot"), required=True)
post_apply_path = verify_artifact("postApplySnapshot", artifacts.get("postApplySnapshot"), required=verified or require_verified)

if str(Path(str(receipt.get("plan") or "")).resolve()) != str(plan_path):
    fail("plan_path_mismatch", receipt=receipt.get("plan"), artifact=plan_path)
if str(Path(str(receipt.get("snapshot") or "")).resolve()) != str(snapshot_path):
    fail("snapshot_path_mismatch", receipt=receipt.get("snapshot"), artifact=snapshot_path)
if post_apply_path is not None and str(Path(str(receipt.get("postApplySnapshot") or "")).resolve()) != str(post_apply_path):
    fail("post_apply_snapshot_path_mismatch", receipt=receipt.get("postApplySnapshot"), artifact=post_apply_path)

plan = load_json(plan_path, "plan")
if plan.get("schemaVersion") != 1:
    fail("plan_schema_version_invalid", value=plan.get("schemaVersion"))
if str(plan.get("securityGroupId") or "") != security_group_id:
    fail("plan_security_group_id_mismatch", plan=plan.get("securityGroupId"), receipt=security_group_id)
if str(plan.get("adminCidr") or "") != admin_cidr:
    fail("plan_admin_cidr_mismatch", plan=plan.get("adminCidr"), receipt=admin_cidr)
validate_plan_policy(plan, admin_cidr)
if str(Path(str(plan.get("snapshot") or "")).resolve()) != str(snapshot_path):
    fail("plan_snapshot_path_mismatch", plan=plan.get("snapshot"), artifact=snapshot_path)

plan_status = str(plan.get("status") or "")
if plan_status not in {"CHANGE_REQUIRED", "NOOP"}:
    fail("plan_status_invalid", status=plan_status)
if str(receipt.get("planStatus") or "") != plan_status:
    fail("receipt_plan_status_mismatch", receipt=receipt.get("planStatus"), plan=plan_status)

actions = plan.get("actions")
if not isinstance(actions, list):
    fail("plan_actions_invalid")
summary = plan.get("summary")
receipt_summary = receipt.get("summary")
if not isinstance(summary, dict) or not isinstance(receipt_summary, dict):
    fail("summary_invalid")
expected_summary = {
    "actionCount": len(actions),
    "authorizeCount": sum(1 for action in actions if isinstance(action, dict) and action.get("kind") == "authorize"),
    "revokeCount": sum(1 for action in actions if isinstance(action, dict) and action.get("kind") == "revoke"),
}
for key, expected in expected_summary.items():
    if int(summary.get(key) or 0) != expected:
        fail("plan_summary_mismatch", key=key, expected=expected, actual=summary.get(key))
    if int(receipt_summary.get(key) or 0) != expected:
        fail("receipt_summary_mismatch", key=key, expected=expected, actual=receipt_summary.get(key))
if plan_status == "NOOP" and expected_summary["actionCount"] != 0:
    fail("noop_plan_has_actions", actions=expected_summary["actionCount"])
if plan_status == "CHANGE_REQUIRED" and expected_summary["actionCount"] <= 0:
    fail("change_required_plan_has_no_actions")

print(
    "aliyun-security-group-repair-receipt-verify "
    f"result=pass status={status} planStatus={plan_status} "
    f"actions={expected_summary['actionCount']} receipt={receipt_path}"
)
PY
}

run_self_test() {
  local tmpdir snapshot plan receipt bad_receipt log
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  snapshot="${tmpdir}/snapshot.json"
  plan="${tmpdir}/plan.json"
  receipt="${tmpdir}/receipt.json"
  bad_receipt="${tmpdir}/bad-receipt.json"
  log="${tmpdir}/verify.log"

  cat >"${snapshot}" <<'JSON'
[
  {"protocol":"tcp","port":"80/80","source":"0.0.0.0/0","action":"allow"}
]
JSON

  python3 - "${snapshot}" "${plan}" "${receipt}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

snapshot_path, plan_path, receipt_path = map(Path, sys.argv[1:4])
plan = {
    "schemaVersion": 1,
    "securityGroupId": "sg-selftest",
    "snapshot": str(snapshot_path.resolve()),
    "adminCidr": "198.51.100.10/32",
    "publicClientPorts": [80, 443, 9000],
    "adminPorts": [22],
    "denyPublicPorts": [22, 3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080],
    "status": "CHANGE_REQUIRED",
    "actions": [
        {
            "kind": "authorize",
            "reason": "required_public_client_port:443",
            "ipProtocol": "TCP",
            "portRange": "443/443",
            "sourceKey": "SourceCidrIp",
            "sourceValue": "0.0.0.0/0",
            "policy": "accept",
        },
        {
            "kind": "revoke",
            "reason": "public_disallowed_ports:22",
            "ipProtocol": "TCP",
            "portRange": "22/22",
            "sourceKey": "SourceCidrIp",
            "sourceValue": "0.0.0.0/0",
            "policy": "accept",
            "nicType": "",
            "securityGroupRuleId": "sgr-public-ssh",
        },
    ],
    "summary": {
        "actionCount": 2,
        "authorizeCount": 1,
        "revokeCount": 1,
    },
}
plan_path.write_text(json.dumps(plan, indent=2, sort_keys=True), encoding="utf-8")

def file_record(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    return {
        "path": str(path.resolve()),
        "present": True,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }

receipt = {
    "schemaVersion": 1,
    "status": "APPLIED_UNVERIFIED",
    "generatedAtEpoch": int(time.time()),
    "securityGroupId": "sg-selftest",
    "regionId": "cn-shenzhen",
    "adminCidr": "198.51.100.10/32",
    "applyRequested": True,
    "applied": True,
    "verifyRequested": False,
    "verified": False,
    "snapshot": str(snapshot_path.resolve()),
    "postApplySnapshot": "",
    "plan": str(plan_path.resolve()),
    "planStatus": "CHANGE_REQUIRED",
    "summary": plan["summary"],
    "artifacts": {
        "snapshot": file_record(snapshot_path),
        "postApplySnapshot": {
            "path": "",
            "present": False,
            "bytes": 0,
            "sha256": "",
        },
        "plan": file_record(plan_path),
    },
}
receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
PY

  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST=false \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${receipt}" \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-selftest \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=198.51.100.10/32 \
    bash "${BASH_SOURCE[0]}" >"${log}"
  grep -q 'result=pass' "${log}"
  grep -q 'status=APPLIED_UNVERIFIED' "${log}"

  cp "${receipt}" "${bad_receipt}"
  python3 - "${bad_receipt}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

receipt_path = Path(sys.argv[1])
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
plan_path = Path(receipt["plan"])
plan = json.loads(plan_path.read_text(encoding="utf-8"))
plan["publicClientPorts"] = [80, 443, 9000, 8080]
bad_plan_path = receipt_path.with_name("bad-policy-plan.json")
bad_plan_path.write_text(json.dumps(plan, indent=2, sort_keys=True), encoding="utf-8")
data = bad_plan_path.read_bytes()
receipt["plan"] = str(bad_plan_path.resolve())
receipt["artifacts"]["plan"]["path"] = str(bad_plan_path.resolve())
receipt["artifacts"]["plan"]["bytes"] = len(data)
receipt["artifacts"]["plan"]["sha256"] = hashlib.sha256(data).hexdigest()
receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
PY
  if ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST=false \
      ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${bad_receipt}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-repair-receipt-verify-self-test result=fail reason=bad_public_8080_policy_passed\n' >&2
    return 1
  fi
  grep -q 'plan_public_client_ports_mismatch' "${log}"

  cp "${receipt}" "${bad_receipt}"
  python3 - "${bad_receipt}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["artifacts"]["plan"]["sha256"] = "bad"
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST=false \
      ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${bad_receipt}" \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-repair-receipt-verify-self-test result=fail reason=bad_sha256_passed\n' >&2
    return 1
  fi
  grep -q 'artifact_sha256_mismatch' "${log}"

  if ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST=false \
      ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${receipt}" \
      ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'aliyun-security-group-repair-receipt-verify-self-test result=fail reason=missing_verified_passed\n' >&2
    return 1
  fi
  grep -q 'verified_required' "${log}"

  printf 'aliyun-security-group-repair-receipt-verify-self-test result=pass\n'
}

if bool_enabled "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST}"; then
  run_self_test
  exit 0
fi

verify_receipt "${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON}"
