#!/usr/bin/env bash
set -euo pipefail

CLOUD_SECURITY_GROUP_AUDIT_SELF_TEST="${CLOUD_SECURITY_GROUP_AUDIT_SELF_TEST:-false}"
CLOUD_SECURITY_GROUP_PRINT_POLICY="${CLOUD_SECURITY_GROUP_PRINT_POLICY:-false}"
CLOUD_SECURITY_GROUP_RULES_FILE="${CLOUD_SECURITY_GROUP_RULES_FILE:-}"
CLOUD_SECURITY_GROUP_PROFILE="${CLOUD_SECURITY_GROUP_PROFILE:-production}"
CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}"
CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-}"
CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-}"
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

print_policy() {
  local public_ports admin_ports denied_ports
  public_ports="$(printf '%s\n' "${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" | tr ' ' ',')"
  admin_ports="$(printf '%s\n' "${CLOUD_SECURITY_GROUP_ADMIN_PORTS}" | tr ' ' ',')"
  denied_ports="$(printf '%s\n' "${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" | tr ' ' ',')"

  printf 'cloud-security-group-policy profile=%s\n' "${CLOUD_SECURITY_GROUP_PROFILE}"
  printf 'allow public client tcp ports=%s source=0.0.0.0/0\n' "${public_ports}"
  printf 'allow admin tcp ports=%s source=<admin-public-ip>/32\n' "${admin_ports}"
  printf 'deny public tcp ports=%s source=0.0.0.0/0\n' "${denied_ports}"
  printf 'require admin public tcp sources ipv4Prefix>=%s ipv6Prefix>=%s\n' \
    "${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
    "${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}"
  printf 'notes: keep 8080 public only with CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=true for a short bootstrap window.\n'
  printf 'notes: keep ICMP public only if CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP=true is acceptable for diagnostics.\n'
  printf '\n'
  printf 'Aliyun console target:\n'
  printf '  1. Add/keep tcp 80, 443, 9000 from 0.0.0.0/0.\n'
  printf '  2. Edit tcp 22 source from 0.0.0.0/0 to your admin IP/CIDR.\n'
  printf '  3. Delete tcp 3389 and tcp 8080 public rules.\n'
  printf '  4. Do not expose PostgreSQL 5432, Redis 6379, Kafka 9092, command-api 8081, query-api 8082, or gateway HTTP 18080.\n'
}

audit_rules() {
  local rules_file="$1"
  if [[ -z "${rules_file}" ]]; then
    printf 'cloud-security-group result=fail reason=rules_file_required action=set CLOUD_SECURITY_GROUP_RULES_FILE=<rules.json>\n' >&2
    return 2
  fi
  if [[ ! -f "${rules_file}" ]]; then
    printf 'cloud-security-group result=fail reason=rules_file_missing path=%s\n' "${rules_file}" >&2
    return 2
  fi

  python3 - "${rules_file}" \
    "${CLOUD_SECURITY_GROUP_PROFILE}" \
    "${CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    "${CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
    "${CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
    "${CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
    "${CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    "${CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
    "${CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
    "${CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
    "${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
    "${CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
    "${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
    "${CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" <<'PY'
import ipaddress
import json
import re
import sys
import time
from pathlib import Path
from typing import Any

(
    rules_path,
    profile,
    public_client_ports_raw,
    deny_public_ports_raw,
    admin_ports_raw,
    require_public_client_ports_raw,
    rules_max_age_seconds_raw,
    rules_require_root_owner_raw,
    allow_temp_http_8080_raw,
    allow_public_icmp_raw,
    public_broad_ipv4_max_prefix_raw,
    public_broad_ipv6_max_prefix_raw,
    admin_public_ipv4_min_prefix_raw,
    admin_public_ipv6_min_prefix_raw,
) = sys.argv[1:15]

def bool_enabled(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}

def parse_ports(raw: str) -> set[int]:
    ports: set[int] = set()
    for token in raw.split():
        token = token.strip()
        if not token:
            continue
        ports.add(int(token))
    return ports

def parse_max_age(raw: str, profile_name: str) -> int:
    if not raw.strip():
        return 86400 if profile_name == "production" else 0
    try:
        value = int(raw)
    except ValueError:
        print(
            f"cloud-security-group result=fail reason=invalid_rules_max_age value={raw}",
            file=sys.stderr,
        )
        raise SystemExit(2)
    if value < 0:
        print(
            f"cloud-security-group result=fail reason=invalid_rules_max_age value={raw}",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return value

def parse_prefix_limit(raw: str, label: str, default: int) -> int:
    text = raw.strip()
    if not text:
        return default
    try:
        value = int(text)
    except ValueError:
        print(
            f"cloud-security-group result=fail reason=invalid_public_broad_prefix label={label} value={raw}",
            file=sys.stderr,
        )
        raise SystemExit(2)
    if value < 0:
        print(
            f"cloud-security-group result=fail reason=invalid_public_broad_prefix label={label} value={raw}",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return value

public_client_ports = parse_ports(public_client_ports_raw)
deny_public_ports = parse_ports(deny_public_ports_raw)
admin_ports = parse_ports(admin_ports_raw)
if bool_enabled(allow_temp_http_8080_raw):
    public_client_ports.add(8080)
    deny_public_ports.discard(8080)
require_public_client_ports = (
    bool_enabled(require_public_client_ports_raw)
    if require_public_client_ports_raw.strip()
    else profile == "production"
)
rules_require_root_owner = (
    bool_enabled(rules_require_root_owner_raw)
    if rules_require_root_owner_raw.strip()
    else profile == "production"
)
rules_max_age_seconds = parse_max_age(rules_max_age_seconds_raw, profile)
allow_public_icmp = bool_enabled(allow_public_icmp_raw)
public_broad_ipv4_max_prefix = parse_prefix_limit(public_broad_ipv4_max_prefix_raw, "ipv4", 8)
public_broad_ipv6_max_prefix = parse_prefix_limit(public_broad_ipv6_max_prefix_raw, "ipv6", 16)
admin_public_ipv4_min_prefix = parse_prefix_limit(admin_public_ipv4_min_prefix_raw, "admin_ipv4", 32)
admin_public_ipv6_min_prefix = parse_prefix_limit(admin_public_ipv6_min_prefix_raw, "admin_ipv6", 128)
rules_path_obj = Path(rules_path)
try:
    rules_stat = rules_path_obj.stat()
    rules_age_seconds = max(0, int(time.time() - rules_stat.st_mtime))
except OSError as exc:
    print(f"cloud-security-group result=fail reason=rules_file_stat_failed detail={exc}", file=sys.stderr)
    raise SystemExit(2)
rules_mode = rules_stat.st_mode & 0o777
rules_owner_uid = rules_stat.st_uid
if rules_require_root_owner and rules_owner_uid != 0:
    print(
        f"cloud-security-group result=fail reason=rules_file_not_root_owned "
        f"path={rules_path} ownerUid={rules_owner_uid}",
        file=sys.stderr,
    )
    raise SystemExit(1)
if rules_mode & 0o022:
    print(
        f"cloud-security-group result=fail reason=rules_file_writable_by_group_or_other "
        f"path={rules_path} mode={rules_mode:04o}",
        file=sys.stderr,
    )
    raise SystemExit(1)

try:
    payload = json.loads(rules_path_obj.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"cloud-security-group result=fail reason=invalid_json detail={exc}", file=sys.stderr)
    raise SystemExit(2)

def as_list(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    return []

def discover_rules(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if not isinstance(value, dict):
        return []
    candidate_paths = [
        ("rules",),
        ("Rules",),
        ("permissions",),
        ("Permissions",),
        ("SecurityGroupRules",),
        ("securityGroupRules",),
        ("SecurityGroupRules", "SecurityGroupRule"),
        ("Permissions", "Permission"),
        ("permissions", "permission"),
    ]
    for path in candidate_paths:
        current: Any = value
        for key in path:
            if isinstance(current, dict):
                current = current.get(key)
            else:
                current = None
                break
        rules = discover_rules(current)
        if rules:
            return rules
    nested: list[dict[str, Any]] = []
    for child in value.values():
        rules = discover_rules(child)
        if rules:
            nested.extend(rules)
    return nested

def first_value(rule: dict[str, Any], names: list[str], default: str = "") -> str:
    lower = {str(key).lower(): value for key, value in rule.items()}
    for name in names:
        if name in rule and rule[name] is not None:
            return str(rule[name])
        lowered = name.lower()
        if lowered in lower and lower[lowered] is not None:
            return str(lower[lowered])
    return default

def rule_allows(rule: dict[str, Any]) -> bool:
    action = first_value(rule, ["action", "policy", "authorizationPolicy", "access"], "allow").lower()
    if action in {"drop", "deny", "reject", "false"}:
        return False
    if action in {"accept", "allow", "permit", "true"}:
        return True
    return "allow" in action or "accept" in action

def rule_is_ingress(rule: dict[str, Any]) -> bool:
    direction = first_value(rule, ["direction", "nicType", "ruleType"], "ingress").lower()
    if direction in {"egress", "out", "outbound"}:
        return False
    return True

def normalize_protocol(raw: str) -> str:
    protocol = raw.strip().lower()
    if protocol in {"", "all", "any", "-1"}:
        return "all"
    if "icmp" in protocol:
        return "icmp"
    if "tcp" in protocol:
        return "tcp"
    if "udp" in protocol:
        return "udp"
    return protocol

def parse_port_ranges(raw: str) -> list[tuple[int, int]]:
    text = raw.strip()
    if not text or text in {"*", "all", "ALL", "-1", "-1/-1"}:
        return [(0, 65535)]
    ranges: list[tuple[int, int]] = []
    for part in re.split(r"[,;\s]+", text):
        part = part.strip()
        if not part:
            continue
        match = re.match(r"^(-?\d+)(?:\s*[-/]\s*(-?\d+))?$", part)
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

def source_values(rule: dict[str, Any]) -> list[str]:
    raw_values: list[str] = []
    for name in [
        "source",
        "sourceCidr",
        "sourceCIDR",
        "sourceCidrIp",
        "sourceCidrIpv6",
        "SourceCidrIp",
        "SourceCidrIpv6",
        "cidr",
        "cidrIp",
        "CidrIp",
        "ipv4CidrBlock",
        "ipv6CidrBlock",
    ]:
        value = first_value(rule, [name])
        if value:
            raw_values.append(value)
    if not raw_values:
        raw_values.append("0.0.0.0/0")
    result: list[str] = []
    for raw in raw_values:
        for part in re.split(r"[,;\s]+", raw):
            part = part.strip()
            if part:
                result.append(part)
    return result or ["0.0.0.0/0"]

def is_public_anywhere(cidr: str) -> bool:
    lowered = cidr.lower()
    if lowered in {"any", "anywhere", "internet", "0.0.0.0/0", "::/0", "*"}:
        return True
    try:
        network = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return False
    if network.version == 4:
        if network.prefixlen > public_broad_ipv4_max_prefix:
            return False
        public_probes = (
            ipaddress.ip_address("1.1.1.1"),
            ipaddress.ip_address("8.8.8.8"),
            ipaddress.ip_address("101.6.6.6"),
            ipaddress.ip_address("223.5.5.5"),
        )
        return network.is_global or any(probe in network for probe in public_probes)
    if network.version == 6:
        if network.prefixlen > public_broad_ipv6_max_prefix:
            return False
        public_probes = (
            ipaddress.ip_address("2606:4700:4700::1111"),
            ipaddress.ip_address("2001:4860:4860::8888"),
        )
        return network.is_global or any(probe in network for probe in public_probes)
    return False

def admin_source_too_broad(cidr: str) -> str:
    lowered = cidr.lower()
    if lowered in {"any", "anywhere", "internet", "0.0.0.0/0", "::/0", "*"}:
        return "anywhere"
    try:
        network = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return ""
    if network.version == 4:
        if not network.is_global:
            return ""
        if network.prefixlen < admin_public_ipv4_min_prefix:
            return f"ipv4_prefix:{network.prefixlen}<{admin_public_ipv4_min_prefix}"
    elif network.version == 6:
        if not network.is_global:
            return ""
        if network.prefixlen < admin_public_ipv6_min_prefix:
            return f"ipv6_prefix:{network.prefixlen}<{admin_public_ipv6_min_prefix}"
    return ""

rules = []
for raw_rule in discover_rules(payload):
    if not rule_allows(raw_rule) or not rule_is_ingress(raw_rule):
        continue
    protocol = normalize_protocol(first_value(raw_rule, ["protocol", "ipProtocol", "IpProtocol"], "tcp"))
    port_raw = first_value(raw_rule, ["port", "ports", "portRange", "PortRange", "fromPort"], "")
    to_port = first_value(raw_rule, ["toPort"], "")
    if to_port and port_raw and "/" not in port_raw and "-" not in port_raw:
        port_raw = f"{port_raw}/{to_port}"
    ranges = parse_port_ranges(port_raw)
    sources = source_values(raw_rule)
    rules.append({"protocol": protocol, "ranges": ranges, "sources": sources, "raw": raw_rule})

errors: list[str] = []
warnings: list[str] = []

if profile not in {"bootstrap", "production"}:
    errors.append(f"invalid_profile:{profile}")

if rules_max_age_seconds > 0 and rules_age_seconds > rules_max_age_seconds:
    errors.append(f"rules_file_stale:{rules_age_seconds}>{rules_max_age_seconds}")

for rule in rules:
    protocol = rule["protocol"]
    ranges = rule["ranges"]
    if protocol == "icmp":
        public_sources = [source for source in rule["sources"] if is_public_anywhere(source)]
        if not public_sources:
            continue
        if not allow_public_icmp:
            errors.append("public_icmp_allowed")
        continue

    if protocol not in {"tcp", "all"}:
        continue

    public_sources = [source for source in rule["sources"] if is_public_anywhere(source)]
    if protocol == "all":
        if public_sources:
            errors.append("public_all_protocols_allowed")

    for port in sorted(deny_public_ports):
        if public_sources and range_contains(ranges, port):
            errors.append(f"public_denied_port:{port}")

    for port in sorted(admin_ports):
        if public_sources and range_contains(ranges, port):
            errors.append(f"public_admin_port:{port}")
        if range_contains(ranges, port):
            for source in rule["sources"]:
                broad_reason = admin_source_too_broad(source)
                if broad_reason:
                    errors.append(f"admin_source_too_broad:{port}:{source}:{broad_reason}")

for port in sorted(public_client_ports):
    if not any(
        rule["protocol"] in {"tcp", "all"}
        and range_contains(rule["ranges"], port)
        and any(is_public_anywhere(source) for source in rule["sources"])
        for rule in rules
    ):
        finding = f"public_client_port_not_open:{port}"
        if require_public_client_ports:
            errors.append(finding)
        else:
            warnings.append(finding)

status = "pass" if not errors else "fail"
summary = (
    f"cloud-security-group result={status} profile={profile} "
    f"rules={len(rules)} publicClientPorts={','.join(map(str, sorted(public_client_ports)))} "
    f"adminPorts={','.join(map(str, sorted(admin_ports)))} "
    f"requirePublicClientPorts={str(require_public_client_ports).lower()} "
    f"rulesAgeSeconds={rules_age_seconds} rulesMaxAgeSeconds={rules_max_age_seconds} "
    f"rulesMode={rules_mode:04o} rulesOwnerUid={rules_owner_uid} "
    f"rulesRequireRootOwner={str(rules_require_root_owner).lower()} "
    f"publicBroadIPv4MaxPrefix={public_broad_ipv4_max_prefix} "
    f"publicBroadIPv6MaxPrefix={public_broad_ipv6_max_prefix} "
    f"adminPublicIPv4MinPrefix={admin_public_ipv4_min_prefix} "
    f"adminPublicIPv6MinPrefix={admin_public_ipv6_min_prefix}"
)
if warnings:
    summary += f" warnings={','.join(warnings)}"
if errors:
    summary += f" errors={','.join(errors)}"
    print(summary, file=sys.stderr)
    raise SystemExit(1)
print(summary)
PY
}

run_self_test() {
  local CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false
  local tmp_dir good stale bad_writable bad_public_ssh bad_broad_ssh bad_global_broad_ssh bad_private_broad_ssh bad_public_admin_range bad_rdp bad_8080 bad_all bad_missing_client
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN
  good="${tmp_dir}/good.json"
  stale="${tmp_dir}/stale.json"
  bad_writable="${tmp_dir}/bad-writable.json"
  bad_public_ssh="${tmp_dir}/bad-public-ssh.json"
  bad_broad_ssh="${tmp_dir}/bad-broad-ssh.json"
  bad_global_broad_ssh="${tmp_dir}/bad-global-broad-ssh.json"
  bad_private_broad_ssh="${tmp_dir}/bad-private-broad-ssh.json"
  bad_public_admin_range="${tmp_dir}/bad-public-admin-range.json"
  bad_rdp="${tmp_dir}/bad-rdp.json"
  bad_8080="${tmp_dir}/bad-8080.json"
  bad_all="${tmp_dir}/bad-all.json"
  bad_missing_client="${tmp_dir}/bad-missing-client.json"

  cat >"${good}" <<'JSON'
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
  CLOUD_SECURITY_GROUP_RULES_FILE="${good}" audit_rules "${good}" >/tmp/im-cloud-sg-self-test.log
  grep -q 'result=pass' /tmp/im-cloud-sg-self-test.log
  grep -q 'requirePublicClientPorts=true' /tmp/im-cloud-sg-self-test.log
  grep -q 'rulesMaxAgeSeconds=86400' /tmp/im-cloud-sg-self-test.log
  grep -q 'rulesMode=' /tmp/im-cloud-sg-self-test.log
  grep -q 'rulesRequireRootOwner=false' /tmp/im-cloud-sg-self-test.log
  grep -q 'publicBroadIPv4MaxPrefix=8' /tmp/im-cloud-sg-self-test.log

  CLOUD_SECURITY_GROUP_AUDIT_SELF_TEST=false CLOUD_SECURITY_GROUP_PRINT_POLICY=true bash "${BASH_SOURCE[0]}" >/tmp/im-cloud-sg-self-test.log
  grep -q 'cloud-security-group-policy profile=production' /tmp/im-cloud-sg-self-test.log
  grep -q 'allow public client tcp ports=80,443,9000 source=0.0.0.0/0' /tmp/im-cloud-sg-self-test.log
  grep -q 'Delete tcp 3389 and tcp 8080 public rules' /tmp/im-cloud-sg-self-test.log

  if [[ "$(id -u)" != "0" ]]; then
    if CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=true CLOUD_SECURITY_GROUP_RULES_FILE="${good}" audit_rules "${good}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
      printf 'cloud-security-group-self-test result=fail reason=non_root_owned_rules_unexpectedly_passed\n' >&2
      return 1
    fi
    grep -q 'rules_file_not_root_owned' /tmp/im-cloud-sg-self-test.log
  fi

  cp "${good}" "${bad_writable}"
  chmod 0666 "${bad_writable}"
  if CLOUD_SECURITY_GROUP_RULES_FILE="${bad_writable}" audit_rules "${bad_writable}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=writable_rules_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'rules_file_writable_by_group_or_other' /tmp/im-cloud-sg-self-test.log

  cp "${good}" "${stale}"
  python3 - "${stale}" <<'PY'
import os
import sys
import time

path = sys.argv[1]
old = time.time() - 172800
os.utime(path, (old, old))
PY
  if CLOUD_SECURITY_GROUP_RULES_FILE="${stale}" audit_rules "${stale}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=stale_rules_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'rules_file_stale:' /tmp/im-cloud-sg-self-test.log
  CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=0 CLOUD_SECURITY_GROUP_RULES_FILE="${stale}" audit_rules "${stale}" >/tmp/im-cloud-sg-self-test.log
  grep -q 'result=pass' /tmp/im-cloud-sg-self-test.log
  grep -q 'rulesMaxAgeSeconds=0' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_missing_client}" <<'JSON'
[{"protocol":"tcp","port":"22/22","source":"203.0.113.10/32","action":"allow"}]
JSON
  if CLOUD_SECURITY_GROUP_RULES_FILE="${bad_missing_client}" audit_rules "${bad_missing_client}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=missing_client_ports_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'public_client_port_not_open:443' /tmp/im-cloud-sg-self-test.log
  CLOUD_SECURITY_GROUP_PROFILE=bootstrap CLOUD_SECURITY_GROUP_RULES_FILE="${bad_missing_client}" audit_rules "${bad_missing_client}" >/tmp/im-cloud-sg-self-test.log
  grep -q 'result=pass' /tmp/im-cloud-sg-self-test.log
  grep -q 'requirePublicClientPorts=false' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_public_ssh}" <<'JSON'
[{"protocol":"tcp","port":"22/22","source":"0.0.0.0/0","action":"allow"}]
JSON
  if CLOUD_SECURITY_GROUP_RULES_FILE="${bad_public_ssh}" audit_rules "${bad_public_ssh}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=public_ssh_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'public_admin_port:22' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_broad_ssh}" <<'JSON'
[{"protocol":"tcp","port":"22/22","source":"0.0.0.0/1","action":"allow"}]
JSON
  if CLOUD_SECURITY_GROUP_RULES_FILE="${bad_broad_ssh}" audit_rules "${bad_broad_ssh}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=broad_public_ssh_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'public_admin_port:22' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_global_broad_ssh}" <<'JSON'
[{"protocol":"tcp","port":"22/22","source":"47.0.0.0/8","action":"allow"}]
JSON
  if CLOUD_SECURITY_GROUP_RULES_FILE="${bad_global_broad_ssh}" audit_rules "${bad_global_broad_ssh}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=global_broad_public_ssh_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'public_admin_port:22' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_private_broad_ssh}" <<'JSON'
[{"protocol":"tcp","port":"22/22","source":"10.0.0.0/8","action":"allow"}]
JSON
  CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=false CLOUD_SECURITY_GROUP_RULES_FILE="${bad_private_broad_ssh}" audit_rules "${bad_private_broad_ssh}" >/tmp/im-cloud-sg-self-test.log
  grep -q 'result=pass' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_public_admin_range}" <<'JSON'
[{"protocol":"tcp","port":"22/22","source":"47.106.103.0/24","action":"allow"}]
JSON
  if CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=false CLOUD_SECURITY_GROUP_RULES_FILE="${bad_public_admin_range}" audit_rules "${bad_public_admin_range}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=public_admin_range_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'admin_source_too_broad:22:47.106.103.0/24' /tmp/im-cloud-sg-self-test.log
  CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=false \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX=24 \
    CLOUD_SECURITY_GROUP_RULES_FILE="${bad_public_admin_range}" \
    audit_rules "${bad_public_admin_range}" >/tmp/im-cloud-sg-self-test.log
  grep -q 'result=pass' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_rdp}" <<'JSON'
[{"protocol":"tcp","port":"3389/3389","source":"0.0.0.0/0","action":"allow"}]
JSON
  if CLOUD_SECURITY_GROUP_RULES_FILE="${bad_rdp}" audit_rules "${bad_rdp}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=rdp_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'public_denied_port:3389' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_8080}" <<'JSON'
[{"protocol":"tcp","port":"8080/8080","source":"0.0.0.0/0","action":"allow"}]
JSON
  if CLOUD_SECURITY_GROUP_RULES_FILE="${bad_8080}" audit_rules "${bad_8080}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=http_8080_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'public_denied_port:8080' /tmp/im-cloud-sg-self-test.log
  CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=true CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=false CLOUD_SECURITY_GROUP_RULES_FILE="${bad_8080}" audit_rules "${bad_8080}" >/tmp/im-cloud-sg-self-test.log
  grep -q 'result=pass' /tmp/im-cloud-sg-self-test.log

  cat >"${bad_all}" <<'JSON'
[{"protocol":"all","port":"-1/-1","source":"0.0.0.0/0","action":"allow"}]
JSON
  if CLOUD_SECURITY_GROUP_RULES_FILE="${bad_all}" audit_rules "${bad_all}" >/tmp/im-cloud-sg-self-test.log 2>&1; then
    printf 'cloud-security-group-self-test result=fail reason=all_ports_unexpectedly_passed\n' >&2
    return 1
  fi
  grep -q 'public_all_protocols_allowed' /tmp/im-cloud-sg-self-test.log

  rm -f /tmp/im-cloud-sg-self-test.log
  printf 'cloud-security-group-self-test result=pass\n'
}

if bool_enabled "${CLOUD_SECURITY_GROUP_PRINT_POLICY}"; then
  print_policy
  exit 0
fi

if bool_enabled "${CLOUD_SECURITY_GROUP_AUDIT_SELF_TEST}"; then
  run_self_test
  exit 0
fi

audit_rules "${CLOUD_SECURITY_GROUP_RULES_FILE}"
