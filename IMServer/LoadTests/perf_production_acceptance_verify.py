#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import ipaddress
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

import perf_current_production_readiness_verify as current_readiness_verify
from perf_forbidden_artifacts import is_forbidden_runtime_artifact
from run_product_campaign import build_runbook

FAIL_REASON_ONLY = False

EXPECTED_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS = {80, 443, 9000}
EXPECTED_CLOUD_SECURITY_GROUP_ADMIN_PORTS = {22}
EXPECTED_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS = {3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080}
FORBIDDEN_PUBLIC_CLIENT_PORTS = (
    EXPECTED_CLOUD_SECURITY_GROUP_ADMIN_PORTS
    | EXPECTED_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS
)
MAX_PACKAGE_ARCHIVE_MEMBER_BYTES = 512 * 1024 * 1024
MAX_PACKAGE_ARCHIVE_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES = 16 * 1024 * 1024


def fail(reason: str, detail: str = "") -> None:
    if FAIL_REASON_ONLY:
        suffix = f" {detail}" if detail else ""
        raise SystemExit(f"{reason}{suffix}")
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"production_acceptance_verify result=fail reason={reason}{suffix}")


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", f"path={path} detail={exc}")
    return {}


def require_json_int(payload: dict, field: str, reason: str, detail: str = "") -> int:
    value = payload.get(field)
    if not isinstance(value, int) or isinstance(value, bool):
        suffix = f"{detail} " if detail else ""
        fail(reason, f"{suffix}field={field} value={value}")
    return value


def is_real_dns_host(host: str) -> bool:
    return dns_host_reason(host) == ""


def dns_host_reason(host: str) -> str:
    value = host.strip().lower().strip("[]")
    if not value or value in {"localhost", "127.0.0.1", "::1", "0.0.0.0"}:
        return "local" if value else "missing"
    try:
        ipaddress.ip_address(value)
        return "ip"
    except ValueError:
        pass
    if "." not in value:
        return "single_label"
    placeholder_hosts = {"example.com", "example.net", "example.org", "yourdomain.com"}
    placeholder_suffixes = (
        ".example",
        ".example.com",
        ".example.net",
        ".example.org",
        ".yourdomain.com",
        ".test",
        ".invalid",
    )
    if value in placeholder_hosts or any(value.endswith(suffix) for suffix in placeholder_suffixes):
        return "placeholder"
    return ""


def plan_ports(plan: dict, field: str) -> set[int]:
    value = plan.get(field)
    if not isinstance(value, list):
        fail("cloud_security_group_repair_plan_port_field_invalid", f"field={field}")
    ports: set[int] = set()
    for item in value:
        try:
            port = int(item)
        except Exception:
            fail("cloud_security_group_repair_plan_port_field_invalid", f"field={field} value={item}")
        if port <= 0 or port > 65535:
            fail("cloud_security_group_repair_plan_port_field_invalid", f"field={field} value={item}")
        ports.add(port)
    return ports


def normalize_rule_protocol(raw: object) -> str:
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


def parse_rule_port_ranges(raw: object) -> list[tuple[int, int]]:
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


def port_in_ranges(ranges: list[tuple[int, int]], port: int) -> bool:
    return any(start <= port <= end for start, end in ranges)


def public_rule_source(raw: object) -> bool:
    text = str(raw or "").strip().lower()
    if text in {"any", "anywhere", "internet", "0.0.0.0/0", "::/0", "*"}:
        return True
    try:
        network = ipaddress.ip_network(text, strict=False)
    except ValueError:
        return False
    return network.is_global and (
        (network.version == 4 and network.prefixlen <= 8)
        or (network.version == 6 and network.prefixlen <= 16)
    )


def require_specific_admin_cidr(admin_cidr: str) -> None:
    if not admin_cidr:
        fail("cloud_security_group_repair_plan_admin_cidr_missing")
    try:
        network = ipaddress.ip_network(admin_cidr, strict=False)
    except ValueError:
        fail("cloud_security_group_repair_plan_admin_cidr_invalid", f"value={admin_cidr}")
    if network.prefixlen == 0 or network.network_address.is_unspecified:
        fail("cloud_security_group_repair_plan_admin_cidr_public_anywhere", f"value={admin_cidr}")
    if network.is_global and network.version == 4 and network.prefixlen < 32:
        fail("cloud_security_group_repair_plan_admin_cidr_too_broad", f"value={admin_cidr} requiredPrefix=32")
    if network.is_global and network.version == 6 and network.prefixlen < 128:
        fail("cloud_security_group_repair_plan_admin_cidr_too_broad", f"value={admin_cidr} requiredPrefix=128")


def verify_cloud_security_group_repair_plan_policy(
    plan: dict,
    actions: list,
    *,
    expect_admin_cidr: str,
) -> None:
    public_ports = plan_ports(plan, "publicClientPorts")
    admin_ports = plan_ports(plan, "adminPorts")
    deny_ports = plan_ports(plan, "denyPublicPorts")
    if public_ports != EXPECTED_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:
        fail(
            "cloud_security_group_repair_plan_public_client_ports_mismatch",
            f"expected={','.join(map(str, sorted(EXPECTED_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS)))} "
            f"actual={','.join(map(str, sorted(public_ports)))}",
        )
    if admin_ports != EXPECTED_CLOUD_SECURITY_GROUP_ADMIN_PORTS:
        fail(
            "cloud_security_group_repair_plan_admin_ports_mismatch",
            f"expected={','.join(map(str, sorted(EXPECTED_CLOUD_SECURITY_GROUP_ADMIN_PORTS)))} "
            f"actual={','.join(map(str, sorted(admin_ports)))}",
        )
    missing_deny_ports = sorted(EXPECTED_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS - deny_ports)
    if missing_deny_ports:
        fail(
            "cloud_security_group_repair_plan_deny_public_ports_missing",
            f"ports={','.join(map(str, missing_deny_ports))}",
        )
    forbidden_public_ports = sorted(public_ports & FORBIDDEN_PUBLIC_CLIENT_PORTS)
    if forbidden_public_ports:
        fail(
            "cloud_security_group_repair_plan_public_client_ports_forbidden",
            f"ports={','.join(map(str, forbidden_public_ports))}",
        )
    require_specific_admin_cidr(expect_admin_cidr)
    for index, action in enumerate(actions):
        if not isinstance(action, dict):
            fail("cloud_security_group_repair_plan_action_invalid", f"index={index}")
        if str(action.get("kind") or "") != "authorize":
            continue
        protocol = normalize_rule_protocol(action.get("ipProtocol"))
        if protocol not in {"TCP", "ALL"}:
            continue
        source_value = str(action.get("sourceValue") or "")
        ranges = parse_rule_port_ranges(action.get("portRange"))
        if any(port_in_ranges(ranges, port) for port in admin_ports) and source_value != expect_admin_cidr:
            fail(
                "cloud_security_group_repair_plan_admin_authorize_source_mismatch",
                f"index={index} expected={expect_admin_cidr} actual={source_value or '-'}",
            )
        if public_rule_source(source_value):
            unauthorized_ports = sorted(
                port for port in (FORBIDDEN_PUBLIC_CLIENT_PORTS | deny_ports) if port_in_ranges(ranges, port)
            )
            if unauthorized_ports:
                fail(
                    "cloud_security_group_repair_plan_public_authorize_disallowed_port",
                    f"index={index} ports={','.join(map(str, unauthorized_ports))}",
                )


def require_file(value: str, reason: str) -> Path:
    if not value:
        fail(reason)
    path = Path(value)
    if not path.is_file():
        fail(reason, f"path={path}")
    return path


def resolve_artifact_file(
    value: str,
    reason: str,
    *,
    evidence_dir: Path | None = None,
    fallback_name: str = "",
    required: bool = True,
) -> Path | None:
    if value:
        path = Path(value)
        if path.is_file():
            return path
    if evidence_dir is not None and fallback_name:
        fallback = evidence_dir / fallback_name
        if fallback.is_file():
            return fallback
    if required:
        detail = f"path={value}" if value else ""
        if evidence_dir is not None and fallback_name:
            detail = f"{detail} fallback={evidence_dir / fallback_name}".strip()
        fail(reason, detail)
    return None


def resolve_readiness_artifact_file(
    value: str,
    reason: str,
    *,
    readiness_path: Path,
    evidence_dir: Path | None = None,
    fallback_name: str = "",
    required: bool = True,
) -> Path | None:
    if value:
        path = Path(value)
        if path.is_file():
            return path
        if not path.is_absolute():
            relative_to_readiness = readiness_path.parent / path
            if relative_to_readiness.is_file():
                return relative_to_readiness
            if evidence_dir is not None:
                relative_to_evidence = evidence_dir / path
                if relative_to_evidence.is_file():
                    return relative_to_evidence
    if evidence_dir is not None and fallback_name:
        fallback = evidence_dir / fallback_name
        if fallback.is_file():
            return fallback
    if fallback_name:
        fallback = readiness_path.parent / fallback_name
        if fallback.is_file():
            return fallback
    if required:
        detail = f"path={value}" if value else ""
        if fallback_name:
            detail = f"{detail} fallback={fallback_name}".strip()
        fail(reason, detail)
    return None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def archive_member_bytes(
    archive: tarfile.TarFile,
    member: tarfile.TarInfo,
    name: str,
    max_bytes: int = MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES,
) -> bytes:
    if not member.isfile():
        fail("package_archive_member_not_file", f"member={name}")
    if member.size < 0:
        fail("package_archive_member_size_invalid", f"member={name} size={member.size}")
    if member.size > max_bytes:
        fail("package_archive_text_member_too_large", f"member={name} size={member.size} max={max_bytes}")
    handle = archive.extractfile(member)
    if handle is None:
        fail("package_archive_member_read_failed", f"member={name}")
    data = handle.read(max_bytes + 1)
    if len(data) > max_bytes:
        fail("package_archive_text_member_too_large", f"member={name} max={max_bytes}")
    return data


def archive_member_sha256(archive: tarfile.TarFile, member: tarfile.TarInfo, name: str) -> str:
    if not member.isfile():
        fail("package_archive_member_not_file", f"member={name}")
    if member.size < 0:
        fail("package_archive_member_size_invalid", f"member={name} size={member.size}")
    handle = archive.extractfile(member)
    if handle is None:
        fail("package_archive_member_read_failed", f"member={name}")
    digest = hashlib.sha256()
    read_bytes = 0
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        read_bytes += len(chunk)
        digest.update(chunk)
    if read_bytes != member.size:
        fail("package_archive_member_size_mismatch", f"member={name} expected={member.size} actual={read_bytes}")
    return digest.hexdigest()


def is_local_metadata_member(name: str) -> bool:
    base_name = Path(name).name
    return base_name.startswith("._") or base_name == ".DS_Store"


def is_manifest_excluded_member(name: str) -> bool:
    return name in {
        "production-evidence-manifest.json",
        "SHA256SUMS",
        "production-acceptance.json",
        "production-acceptance-package.tar.gz",
    }


def is_forbidden_evidence_artifact(name: str) -> bool:
    return is_forbidden_runtime_artifact(name)


def validate_package_archive_member(
    member: tarfile.TarInfo,
    normalized: str,
    *,
    max_member_bytes: int = MAX_PACKAGE_ARCHIVE_MEMBER_BYTES,
) -> None:
    if member.size < 0:
        fail("package_archive_member_size_invalid", f"name={normalized} size={member.size}")
    if member.size > max_member_bytes:
        fail("package_archive_member_too_large", f"name={normalized} size={member.size} max={max_member_bytes}")


def archive_json(archive: tarfile.TarFile, members: dict[str, tarfile.TarInfo], name: str) -> dict:
    member = members.get(name)
    if member is None:
        fail("package_archive_required_member_missing", f"member={name}")
    try:
        return json.loads(archive_member_bytes(archive, member, name).decode("utf-8"))
    except Exception as exc:
        fail("package_archive_member_invalid_json", f"member={name} detail={exc}")
    return {}


def archive_text(archive: tarfile.TarFile, members: dict[str, tarfile.TarInfo], name: str) -> str:
    member = members.get(name)
    if member is None:
        fail("package_archive_required_member_missing", f"member={name}")
    try:
        return archive_member_bytes(archive, member, name).decode("utf-8")
    except UnicodeDecodeError as exc:
        fail("package_archive_member_invalid_utf8", f"member={name} detail={exc}")
    return ""


def verify_archive_checksums(archive: tarfile.TarFile, members: dict[str, tarfile.TarInfo]) -> None:
    checksum_member = members.get("SHA256SUMS")
    if checksum_member is None:
        fail("package_archive_required_member_missing", "member=SHA256SUMS")
    try:
        checksum_text = archive_member_bytes(archive, checksum_member, "SHA256SUMS").decode("utf-8")
    except UnicodeDecodeError as exc:
        fail("package_checksums_invalid_utf8", f"detail={exc}")
    checksum_rows: dict[str, str] = {}
    for lineno, raw in enumerate(checksum_text.splitlines(), start=1):
        if not raw:
            continue
        if raw.startswith("\\"):
            fail("package_checksum_escaped_path_unsupported", f"line={lineno}")
        if len(raw) < 67 or raw[64] != " " or raw[65] not in {" ", "*"}:
            fail("package_checksum_line_invalid", f"line={lineno}")
        digest = raw[:64]
        if any(char not in "0123456789abcdefABCDEF" for char in digest):
            fail("package_checksum_line_invalid", f"line={lineno}")
        name = raw[66:]
        normalized = name[2:] if name.startswith("./") else name
        parts = Path(normalized).parts
        if (
            not normalized
            or normalized == "."
            or normalized.startswith("/")
            or ".." in parts
            or "/" in normalized
            or normalized == "SHA256SUMS"
            or is_local_metadata_member(normalized)
        ):
            fail("package_checksum_path_unsafe", f"line={lineno} path={name}")
        if normalized in checksum_rows:
            fail("package_checksum_duplicate_path", f"path={normalized}")
        member = members.get(normalized)
        if member is None:
            fail("package_checksum_file_missing", f"line={lineno} path={name}")
        actual = archive_member_sha256(archive, member, normalized)
        if actual.lower() != digest.lower():
            fail("package_checksum_mismatch", f"path={normalized}")
        checksum_rows[normalized] = digest
    expected = {
        name
        for name, member in members.items()
        if member.isfile() and name != "SHA256SUMS"
    }
    missing = sorted(expected - set(checksum_rows))
    if missing:
        fail("package_checksum_member_missing", f"path={missing[0]}")


def require_archive_target(payload: dict, expected: dict[str, str], reason: str) -> None:
    target = payload.get("target") or {}
    if not isinstance(target, dict):
        fail(reason, "field=target")
    for key, expected_value in expected.items():
        actual_value = str(target.get(key) or "")
        if actual_value != expected_value:
            fail(reason, f"field={key} expected={expected_value or '-'} actual={actual_value or '-'}")


def verify_archive_current_readiness_markdown(readiness: dict, markdown: str) -> None:
    expected = current_readiness_verify.build_readiness_markdown(readiness)
    if markdown != expected:
        fail("package_current_readiness_markdown_mismatch")


def verify_archive_readme_summary(readme: str, manifest: dict, gate: dict) -> None:
    def require_snippet(snippet: str, reason: str) -> None:
        if snippet not in readme:
            fail(reason, f"expected={snippet.replace(' ', '_')}")

    require_snippet("69_install_performance_evidence_package.sh", "package_readme_install_command_missing")
    require_snippet("Do not install only `production-gate.json`", "package_readme_gate_only_warning_missing")
    require_snippet(f"- status: `{gate.get('status') or 'UNKNOWN'}`", "package_readme_gate_status_mismatch")
    require_snippet(f"- profile: `{gate.get('profile') or '-'}`", "package_readme_profile_mismatch")

    docs_audit = manifest.get("docsAudit") or {}
    if docs_audit:
        require_snippet(f"- docsAudit: `{docs_audit.get('status') or '-'}`", "package_readme_docs_audit_mismatch")

    profile_gate = manifest.get("productProfileGate") or {}
    if profile_gate:
        require_snippet(
            f"- productProfileGate: `{profile_gate.get('status') or '-'}`",
            "package_readme_product_profile_gate_mismatch",
        )

    campaign = manifest.get("productCampaign") or {}
    if campaign.get("present"):
        require_snippet(f"- productCampaign: `{campaign.get('campaign') or '-'}`", "package_readme_product_campaign_mismatch")
        require_snippet(
            f"- productCampaignStatus: `{campaign.get('finalStatus') or '-'}`",
            "package_readme_product_campaign_status_mismatch",
        )

    current = manifest.get("currentReadiness") or {}
    if current.get("present"):
        require_snippet(
            f"- currentReadinessStatus: `{current.get('status') or '-'}`",
            "package_readme_current_readiness_status_mismatch",
        )
        requested = current.get("requestedRuns") or {}
        runs = current.get("runs") or {}
        require_snippet(
            "- currentReadinessRequestedSmoke/ProductSuite/Baseline/Full: "
            f"`{requested.get('smoke')}/{requested.get('productScenarioSuite')}/"
            f"{requested.get('baseline')}/{requested.get('fullAcceptance')}`",
            "package_readme_current_readiness_requested_runs_mismatch",
        )
        require_snippet(
            "- currentReadinessExitCodesSmoke/ProductSuite/Baseline/Full: "
            f"`{runs.get('smokeExitCode')}/{runs.get('suiteExitCode')}/"
            f"{runs.get('baselineExitCode')}/{runs.get('fullAcceptanceExitCode')}`",
            "package_readme_current_readiness_exit_codes_mismatch",
        )


def verify_archive_manifest_file_records(archive: tarfile.TarFile, members: dict[str, tarfile.TarInfo], manifest: dict) -> None:
    records = manifest.get("files")
    if not isinstance(records, list) or not records:
        fail("package_manifest_files_missing")
    by_path: dict[str, dict] = {}
    for record in records:
        if not isinstance(record, dict):
            fail("package_manifest_file_record_invalid")
        name = str(record.get("path") or "")
        parts = Path(name).parts
        if (
            not name
            or name.startswith("/")
            or ".." in parts
            or "/" in name
            or is_manifest_excluded_member(name)
            or is_local_metadata_member(name)
        ):
            fail("package_manifest_file_record_path_invalid", f"path={name or '-'}")
        if is_forbidden_evidence_artifact(name):
            fail("package_manifest_forbidden_artifact", f"path={name}")
        if name in by_path:
            fail("package_manifest_file_record_duplicate", f"path={name}")
        member = members.get(name)
        if member is None:
            fail("package_manifest_file_record_missing_member", f"path={name}")
        try:
            expected_bytes = require_json_int(record, "bytes", "package_manifest_file_record_bytes_invalid", f"path={name}")
        except SystemExit:
            raise
        except Exception:
            fail("package_manifest_file_record_bytes_invalid", f"path={name} value={record.get('bytes')}")
        if expected_bytes != member.size:
            fail("package_manifest_file_record_bytes_mismatch", f"path={name} expected={expected_bytes} actual={member.size}")
        expected_sha = str(record.get("sha256") or "")
        if len(expected_sha) != 64 or any(char not in "0123456789abcdefABCDEF" for char in expected_sha):
            fail("package_manifest_file_record_sha256_invalid", f"path={name}")
        actual_sha = archive_member_sha256(archive, member, name)
        if actual_sha.lower() != expected_sha.lower():
            fail("package_manifest_file_record_sha256_mismatch", f"path={name}")
        by_path[name] = record

    actual_payload = {
        name
        for name, member in members.items()
        if member.isfile() and not is_manifest_excluded_member(name)
    }
    recorded_payload = set(by_path)
    missing = sorted(actual_payload - recorded_payload)
    if missing:
        fail("package_manifest_file_record_missing", f"path={missing[0]}")
    extra = sorted(recorded_payload - actual_payload)
    if extra:
        fail("package_manifest_file_record_extra", f"path={extra[0]}")


def verify_package_archive(
    path: Path,
    *,
    expected_target: dict[str, str],
    max_member_bytes: int = MAX_PACKAGE_ARCHIVE_MEMBER_BYTES,
    max_total_bytes: int = MAX_PACKAGE_ARCHIVE_TOTAL_BYTES,
) -> None:
    required = {
        "production-evidence-manifest.json",
        "production-gate.json",
        "README.md",
        "SHA256SUMS",
        "current-production-readiness.json",
        "current-production-readiness.md",
    }
    try:
        with tarfile.open(path, "r:gz") as archive:
            names = []
            members: dict[str, tarfile.TarInfo] = {}
            total_bytes = 0
            for member in archive.getmembers():
                name = member.name
                normalized = name[2:] if name.startswith("./") else name
                parts = Path(normalized).parts
                if normalized == "." and member.isdir():
                    continue
                if (
                    not normalized
                    or normalized.startswith("/")
                    or ".." in parts
                    or member.issym()
                    or member.islnk()
                    or not member.isfile()
                    or is_local_metadata_member(normalized)
                ):
                    fail("package_archive_unsafe_member", f"name={name}")
                validate_package_archive_member(member, normalized, max_member_bytes=max_member_bytes)
                total_bytes += member.size
                if total_bytes > max_total_bytes:
                    fail("package_archive_total_too_large", f"size={total_bytes} max={max_total_bytes}")
                if is_forbidden_evidence_artifact(normalized):
                    fail("package_archive_forbidden_artifact", f"name={name}")
                if normalized in members:
                    fail("package_archive_duplicate_member", f"name={normalized}")
                members[normalized] = member
                names.append(normalized)
            verify_archive_checksums(archive, members)
            manifest = archive_json(archive, members, "production-evidence-manifest.json")
            if manifest.get("schemaVersion") != 1:
                fail("package_manifest_schema_version", f"value={manifest.get('schemaVersion')}")
            verify_archive_manifest_file_records(archive, members, manifest)
            readiness_summary = manifest.get("currentReadiness") or {}
            if not isinstance(readiness_summary, dict):
                fail("package_manifest_current_readiness_missing")
            if readiness_summary.get("present") is not True:
                fail("package_manifest_current_readiness_not_present")
            require_archive_target(
                {"target": readiness_summary.get("target") or {}},
                expected_target,
                "package_manifest_current_readiness_target_mismatch",
            )
            gate = archive_json(archive, members, "production-gate.json")
            readiness = archive_json(archive, members, "current-production-readiness.json")
            require_archive_target(readiness, expected_target, "package_current_readiness_target_mismatch")
            if str(readiness.get("status") or "") != "PASS":
                fail("package_current_readiness_status_mismatch", f"expected=PASS actual={readiness.get('status') or '-'}")
            readiness_markdown = archive_text(archive, members, "current-production-readiness.md")
            verify_archive_current_readiness_markdown(readiness, readiness_markdown)
            readme = archive_text(archive, members, "README.md")
            verify_archive_readme_summary(readme, manifest, gate)
    except tarfile.TarError as exc:
        fail("package_archive_invalid", f"path={path} detail={exc}")
    except OSError as exc:
        fail("package_archive_read_failed", f"path={path} detail={exc}")
    present = set(names)
    missing = sorted(required - present)
    if missing:
        fail("package_archive_required_member_missing", f"member={missing[0]} path={path}")


def write_package_archive_from_stage(package: Path, stage: Path) -> None:
    rows = []
    for member in sorted(stage.iterdir()):
        if member.name == "SHA256SUMS":
            continue
        rows.append(f"{sha256_file(member)}  ./{member.name}\n")
    (stage / "SHA256SUMS").write_text("".join(rows), encoding="utf-8")
    with tarfile.open(package, "w:gz") as archive:
        for member in sorted(stage.iterdir()):
            archive.add(member, arcname=member.name)


def manifest_file_records(stage: Path) -> list[dict]:
    records = []
    for member in sorted(stage.iterdir(), key=lambda item: item.name):
        if not member.is_file() or is_manifest_excluded_member(member.name):
            continue
        records.append({
            "path": member.name,
            "bytes": member.stat().st_size,
            "sha256": sha256_file(member),
        })
    return records


def refresh_stage_manifest_file_records(stage: Path) -> None:
    manifest_path = stage / "production-evidence-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["files"] = manifest_file_records(stage)
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")


def write_minimal_evidence_package(package: Path, stage: Path, target: dict[str, str]) -> None:
    stage.mkdir()
    readiness = {
        "schemaVersion": 1,
        "status": "PASS",
        "reason": "entrypoint_and_requested_runs_passed",
        "generatedAtEpoch": int(time.time()),
        "target": target,
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
    (stage / "production-gate.json").write_text(
        json.dumps({
            "schemaVersion": 1,
            "status": "PASS",
            "profile": "normal-product-baseline",
        }),
        encoding="utf-8",
    )
    (stage / "README.md").write_text(
        "\n".join([
            "# Production Evidence Package",
            "",
            "Install with `69_install_performance_evidence_package.sh`.",
            "Do not install only `production-gate.json`.",
            "",
            "- status: `PASS`",
            "- profile: `normal-product-baseline`",
            "- docsAudit: `PASS`",
            "- productProfileGate: `PASS`",
            "- currentReadinessStatus: `PASS`",
            "- currentReadinessRequestedSmoke/ProductSuite/Baseline/Full: `True/True/True/True`",
            "- currentReadinessExitCodesSmoke/ProductSuite/Baseline/Full: `0/0/0/0`",
            "",
        ]),
        encoding="utf-8",
    )
    (stage / "current-production-readiness.json").write_text(json.dumps(readiness), encoding="utf-8")
    (stage / "current-production-readiness.md").write_text(
        current_readiness_verify.build_readiness_markdown(readiness),
        encoding="utf-8",
    )
    (stage / "production-evidence-manifest.json").write_text(
        json.dumps({
            "schemaVersion": 1,
            "profile": "normal-product-baseline",
            "docsAudit": {"status": "PASS"},
            "productProfileGate": {"status": "PASS"},
            "currentReadiness": {
                "present": True,
                "status": readiness["status"],
                "reason": readiness["reason"],
                "target": target,
                "requestedRuns": readiness["requestedRuns"],
                "runs": readiness["runs"],
            },
            "files": manifest_file_records(stage),
        }),
        encoding="utf-8",
    )
    write_package_archive_from_stage(package, stage)


def int_field(payload: dict, key: str, reason: str) -> int:
    try:
        return int(payload.get(key))
    except Exception:
        fail(reason, f"value={payload.get(key)}")


def require_receipt_timestamp(payload: dict, *, max_age_seconds: int, max_future_skew_seconds: int) -> None:
    if max_age_seconds <= 0:
        fail("receipt_max_age_invalid", f"value={max_age_seconds}")
    if max_future_skew_seconds < 0:
        fail("receipt_max_future_skew_invalid", f"value={max_future_skew_seconds}")
    generated_at = int_field(payload, "generatedAtEpoch", "receipt_generated_at_invalid")
    if generated_at <= 0:
        fail("receipt_generated_at_invalid", f"value={generated_at}")
    now = int(time.time())
    future_skew_seconds = generated_at - now
    if future_skew_seconds > max_future_skew_seconds:
        fail(
            "receipt_generated_at_in_future",
            f"skewSeconds={future_skew_seconds} maxFutureSkewSeconds={max_future_skew_seconds}",
        )
    receipt_age_seconds = now - generated_at
    if receipt_age_seconds > max_age_seconds:
        fail(
            "receipt_stale",
            f"ageSeconds={receipt_age_seconds} maxAgeSeconds={max_age_seconds}",
        )


def operator_network_summary(path: Path) -> dict:
    summary = {
        "present": path.is_file(),
        "failed": False,
        "warnings": [],
        "routeInterfaces": [],
        "routeGateways": [],
        "failureCount": 0,
    }
    if not path.is_file():
        return summary
    warnings: set[str] = set()
    interfaces: set[str] = set()
    gateways: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        fields: dict[str, str] = {}
        for token in line.split():
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            fields[key] = value
        if fields.get("status") == "fail":
            summary["failed"] = True
        warning = fields.get("warning", "")
        if warning and warning not in {"clean", "<none>"}:
            warnings.add(warning)
        route_interface = fields.get("routeInterface", "")
        if route_interface and route_interface != "<none>":
            interfaces.add(route_interface)
        route_gateway = fields.get("routeGateway", "")
        if route_gateway and route_gateway != "<none>":
            gateways.add(route_gateway)
        if "failures" in fields:
            try:
                summary["failureCount"] = max(int(summary["failureCount"]), int(fields["failures"]))
            except Exception:
                pass
    summary["warnings"] = sorted(warnings)
    summary["routeInterfaces"] = sorted(interfaces)
    summary["routeGateways"] = sorted(gateways)
    return summary


def operator_network_json_summary(path: Path) -> dict:
    summary = {
        "present": path.is_file(),
        "failed": False,
        "warnings": [],
        "routeInterfaces": [],
        "routeGateways": [],
        "failureCount": 0,
    }
    if not path.is_file():
        return summary
    payload = load_json(path)
    summary["failed"] = payload.get("failed") is True or str(payload.get("status") or "") == "fail"
    summary["warnings"] = sorted(str(item) for item in payload.get("warnings") or [])
    summary["routeInterfaces"] = sorted(str(item) for item in payload.get("routeInterfaces") or [])
    summary["routeGateways"] = sorted(str(item) for item in payload.get("routeGateways") or [])
    try:
        summary["failureCount"] = int(payload.get("failureCount") or 0)
    except Exception:
        summary["failureCount"] = 0
    return summary


def operator_network_evidence_summary(log_path: Path, json_path: Path) -> dict:
    json_summary = operator_network_json_summary(json_path)
    if json_summary.get("present"):
        return json_summary
    return operator_network_summary(log_path)


def csv_list(value: str | None) -> list[str]:
    if not value:
        return []
    return [item for item in str(value).split(",") if item]


def verify_readiness_operator_network_state(
    readiness_path: Path,
    readiness: dict,
    *,
    evidence_dir: Path | None,
) -> None:
    readiness_artifacts = readiness.get("artifacts") or {}
    operator_log_path = resolve_readiness_artifact_file(
        str(readiness_artifacts.get("operatorNetworkLog") or ""),
        "readiness_operator_network_log_missing",
        readiness_path=readiness_path,
        evidence_dir=evidence_dir,
        fallback_name="current-readiness-operator-network.log",
    )
    if operator_log_path is None:
        fail("readiness_operator_network_log_missing")
    operator_json_path = resolve_readiness_artifact_file(
        str(readiness_artifacts.get("operatorNetworkJSON") or ""),
        "readiness_operator_network_json_missing",
        readiness_path=readiness_path,
        evidence_dir=evidence_dir,
        fallback_name="current-readiness-operator-network.json",
        required=True,
    )
    expected = operator_network_evidence_summary(
        operator_log_path,
        operator_json_path or Path("__missing_current_readiness_operator_network.json__"),
    )
    if expected.get("present") is not True:
        fail("readiness_operator_network_log_missing", f"path={operator_log_path}")
    if expected.get("failed") is True:
        fail("readiness_operator_network_failed", f"path={operator_log_path}")
    warnings = [str(item) for item in expected.get("warnings") or [] if str(item)]
    if warnings:
        fail("readiness_operator_network_warning", f"warning={warnings[0]}")

    state_json_path = resolve_readiness_artifact_file(
        str(readiness_artifacts.get("stateSummary") or ""),
        "readiness_state_summary_missing",
        readiness_path=readiness_path,
        evidence_dir=evidence_dir,
        fallback_name="current-production-state-summary.json",
    )
    if state_json_path is not None and state_json_path.suffix != ".json":
        candidate = state_json_path.with_suffix(".json")
        if candidate.is_file():
            state_json_path = candidate
    if state_json_path is None or not state_json_path.is_file():
        fail("readiness_state_summary_missing")
    state = load_json(state_json_path)
    summary = state.get("summary") or {}
    expected_scalars = {
        "currentReadinessOperatorNetworkPreflight": True,
        "currentReadinessOperatorNetworkLogPresent": expected.get("present"),
        "currentReadinessOperatorNetworkFailed": expected.get("failed"),
        "currentReadinessOperatorNetworkFailureCount": expected.get("failureCount"),
    }
    for key, expected_value in expected_scalars.items():
        if summary.get(key) != expected_value:
            fail(
                "readiness_operator_network_state_mismatch",
                f"field={key} expected={expected_value} actual={summary.get(key)}",
            )
    expected_lists = {
        "currentReadinessOperatorNetworkWarnings": expected.get("warnings") or [],
        "currentReadinessOperatorNetworkRouteInterfaces": expected.get("routeInterfaces") or [],
        "currentReadinessOperatorNetworkRouteGateways": expected.get("routeGateways") or [],
    }
    for key, expected_value in expected_lists.items():
        actual_value = summary.get(key) or []
        if sorted(str(item) for item in actual_value) != sorted(str(item) for item in expected_value):
            fail(
                "readiness_operator_network_state_mismatch",
                f"field={key} expected={','.join(str(item) for item in expected_value) or '-'} actual={','.join(str(item) for item in actual_value) or '-'}",
            )

    state_csv_path = state_json_path.with_suffix(".csv")
    if not state_csv_path.is_file():
        fail("readiness_state_summary_csv_missing", f"path={state_csv_path}")
    try:
        with state_csv_path.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except Exception as exc:
        fail("readiness_state_summary_csv_read_failed", f"path={state_csv_path} detail={exc}")
    csv_summary = next((row for row in rows if row.get("recordType") == "summary"), None)
    if csv_summary is None:
        fail("readiness_state_summary_csv_missing")
    expected_csv = {
        "currentReadinessOperatorNetworkPreflight": "True",
        "currentReadinessOperatorNetworkLogPresent": str(expected.get("present")),
        "currentReadinessOperatorNetworkFailed": str(expected.get("failed")),
        "currentReadinessOperatorNetworkFailureCount": str(expected.get("failureCount")),
    }
    for key, expected_value in expected_csv.items():
        if csv_summary.get(key) != expected_value:
            fail(
                "readiness_operator_network_state_csv_mismatch",
                f"field={key} expected={expected_value} actual={csv_summary.get(key)}",
            )
    expected_csv_lists = {
        "currentReadinessOperatorNetworkWarnings": expected.get("warnings") or [],
        "currentReadinessOperatorNetworkRouteInterfaces": expected.get("routeInterfaces") or [],
        "currentReadinessOperatorNetworkRouteGateways": expected.get("routeGateways") or [],
    }
    for key, expected_value in expected_csv_lists.items():
        actual_value = csv_list(csv_summary.get(key))
        if sorted(actual_value) != sorted(str(item) for item in expected_value):
            fail(
                "readiness_operator_network_state_csv_mismatch",
                f"field={key} expected={','.join(str(item) for item in expected_value) or '-'} actual={','.join(actual_value) or '-'}",
            )


def verify_receipt_artifact_record(receipt_path: Path, name: str, entry: object, *, required: bool) -> Path | None:
    if not isinstance(entry, dict):
        if required:
            fail("cloud_security_group_repair_receipt_artifact_entry_invalid", f"name={name} path={receipt_path}")
        return None
    raw_path = str(entry.get("path") or "")
    present = bool(entry.get("present"))
    if not raw_path:
        if required:
            fail("cloud_security_group_repair_receipt_artifact_path_missing", f"name={name} path={receipt_path}")
        return None
    path = Path(raw_path)
    if not path.is_file():
        if required or present:
            fail("cloud_security_group_repair_receipt_artifact_missing", f"name={name} path={path}")
        return None
    if not present:
        fail("cloud_security_group_repair_receipt_artifact_present_flag_invalid", f"name={name} path={path}")
    expected_bytes = int(entry.get("bytes") or 0)
    if path.stat().st_size != expected_bytes:
        fail(
            "cloud_security_group_repair_receipt_artifact_size_mismatch",
            f"name={name} expected={expected_bytes} actual={path.stat().st_size} path={path}",
        )
    expected_sha = str(entry.get("sha256") or "")
    if len(expected_sha) != 64:
        fail("cloud_security_group_repair_receipt_artifact_sha256_missing", f"name={name} path={path}")
    actual_sha = sha256_file(path)
    if actual_sha != expected_sha:
        fail(
            "cloud_security_group_repair_receipt_artifact_sha256_mismatch",
            f"name={name} expected={expected_sha} actual={actual_sha} path={path}",
        )
    return path


def verify_cloud_security_group_repair_receipt(
    path: Path,
    max_age_seconds: int,
    *,
    expect_security_group_id: str,
    expect_region_id: str,
    expect_admin_cidr: str,
) -> None:
    payload = load_json(path)
    if payload.get("schemaVersion") != 1:
        fail("cloud_security_group_repair_receipt_schema_version", f"path={path}")
    generated_at = int_field(payload, "generatedAtEpoch", "cloud_security_group_repair_receipt_generated_at_invalid")
    if generated_at <= 0:
        fail("cloud_security_group_repair_receipt_generated_at_invalid", f"value={generated_at} path={path}")
    if max_age_seconds <= 0:
        fail("cloud_security_group_repair_receipt_max_age_invalid", f"value={max_age_seconds} path={path}")
    receipt_age_seconds = int(time.time()) - generated_at
    if receipt_age_seconds > max_age_seconds:
        fail(
            "cloud_security_group_repair_receipt_stale",
            f"ageSeconds={receipt_age_seconds} maxAgeSeconds={max_age_seconds} path={path}",
        )
    status = str(payload.get("status") or "")
    if status != "APPLIED_VERIFIED":
        fail("cloud_security_group_repair_receipt_status", f"status={status or '-'} path={path}")
    if payload.get("applied") is not True:
        fail("cloud_security_group_repair_receipt_not_applied", f"path={path}")
    if payload.get("verified") is not True:
        fail("cloud_security_group_repair_receipt_not_verified", f"path={path}")
    security_group_id = str(payload.get("securityGroupId") or "")
    if not security_group_id:
        fail("cloud_security_group_repair_receipt_security_group_missing", f"path={path}")
    if security_group_id != expect_security_group_id:
        fail(
            "cloud_security_group_repair_receipt_security_group_mismatch",
            f"expected={expect_security_group_id} actual={security_group_id or '-'} path={path}",
        )
    region_id = str(payload.get("regionId") or "")
    if not region_id:
        fail("cloud_security_group_repair_receipt_region_missing", f"path={path}")
    if region_id != expect_region_id:
        fail(
            "cloud_security_group_repair_receipt_region_mismatch",
            f"expected={expect_region_id} actual={region_id or '-'} path={path}",
        )
    admin_cidr = str(payload.get("adminCidr") or "")
    if not admin_cidr:
        fail("cloud_security_group_repair_receipt_admin_cidr_missing", f"path={path}")
    if admin_cidr != expect_admin_cidr:
        fail(
            "cloud_security_group_repair_receipt_admin_cidr_mismatch",
            f"expected={expect_admin_cidr} actual={admin_cidr or '-'} path={path}",
        )
    summary = payload.get("summary") or {}
    if not isinstance(summary, dict) or "actionCount" not in summary:
        fail("cloud_security_group_repair_receipt_summary_missing", f"path={path}")
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("cloud_security_group_repair_receipt_artifacts_missing", f"path={path}")
    plan_path = verify_receipt_artifact_record(path, "plan", artifacts.get("plan"), required=True)
    snapshot_path = verify_receipt_artifact_record(path, "snapshot", artifacts.get("snapshot"), required=True)
    post_apply_snapshot_path = verify_receipt_artifact_record(
        path,
        "postApplySnapshot",
        artifacts.get("postApplySnapshot"),
        required=True,
    )
    if plan_path is None or snapshot_path is None or post_apply_snapshot_path is None:
        fail("cloud_security_group_repair_receipt_artifact_missing", f"path={path}")
    if str(Path(str(payload.get("plan") or ""))) != str(plan_path):
        fail("cloud_security_group_repair_receipt_plan_path_mismatch", f"path={path}")
    if str(Path(str(payload.get("snapshot") or ""))) != str(snapshot_path):
        fail("cloud_security_group_repair_receipt_snapshot_path_mismatch", f"path={path}")
    if str(Path(str(payload.get("postApplySnapshot") or ""))) != str(post_apply_snapshot_path):
        fail("cloud_security_group_repair_receipt_post_apply_snapshot_path_mismatch", f"path={path}")
    plan = load_json(plan_path)
    if plan.get("schemaVersion") != 1:
        fail("cloud_security_group_repair_plan_schema_version", f"path={plan_path}")
    if str(plan.get("securityGroupId") or "") != str(payload.get("securityGroupId") or ""):
        fail("cloud_security_group_repair_plan_security_group_mismatch", f"path={plan_path}")
    if str(plan.get("adminCidr") or "") != str(payload.get("adminCidr") or ""):
        fail("cloud_security_group_repair_plan_admin_cidr_mismatch", f"path={plan_path}")
    if str(Path(str(plan.get("snapshot") or ""))) != str(snapshot_path):
        fail("cloud_security_group_repair_plan_snapshot_mismatch", f"path={plan_path}")
    if str(payload.get("planStatus") or "") != str(plan.get("status") or ""):
        fail("cloud_security_group_repair_receipt_plan_status_mismatch", f"path={path}")
    actions = plan.get("actions")
    if not isinstance(actions, list):
        fail("cloud_security_group_repair_plan_actions_invalid", f"path={plan_path}")
    verify_cloud_security_group_repair_plan_policy(
        plan,
        actions,
        expect_admin_cidr=expect_admin_cidr,
    )
    expected_summary = {
        "actionCount": len(actions),
        "authorizeCount": sum(1 for action in actions if isinstance(action, dict) and action.get("kind") == "authorize"),
        "revokeCount": sum(1 for action in actions if isinstance(action, dict) and action.get("kind") == "revoke"),
    }
    for key, expected in expected_summary.items():
        if int(summary.get(key) or 0) != expected:
            fail("cloud_security_group_repair_receipt_summary_mismatch", f"key={key} expected={expected} path={path}")
        plan_summary = plan.get("summary") or {}
        if int(plan_summary.get(key) or 0) != expected:
            fail("cloud_security_group_repair_plan_summary_mismatch", f"key={key} expected={expected} path={plan_path}")


def verify_receipt(
    path: Path,
    *,
    require_pass: bool,
    max_age_seconds: int = 86400,
    max_future_skew_seconds: int = 300,
    package_file: Path | None = None,
    evidence_dir: Path | None = None,
) -> None:
    payload = load_json(path)
    if payload.get("schemaVersion") != 1:
        fail("schema_version", f"path={path}")
    require_receipt_timestamp(
        payload,
        max_age_seconds=max_age_seconds,
        max_future_skew_seconds=max_future_skew_seconds,
    )

    status = str(payload.get("status") or "")
    if require_pass and status != "PASS":
        fail("status_not_pass", f"status={status or '-'}")
    if status == "PASS" and payload.get("reason") != "accepted":
        fail("pass_reason_invalid", f"reason={payload.get('reason') or '-'}")

    target = payload.get("target") or {}
    base_url = str(target.get("baseURL") or "")
    tcp_host = str(target.get("tcpHost") or "")
    parsed = urlparse(base_url)
    if parsed.scheme != "https":
        fail("base_url_https_required", f"baseURL={base_url or '<empty>'}")
    try:
        base_port = parsed.port or 443
    except ValueError:
        fail("base_url_port_invalid", f"baseURL={base_url or '<empty>'}")
    if base_port != 443:
        fail("base_url_default_https_port_required", f"baseURL={base_url or '<empty>'} port={base_port}")
    base_host_reason = dns_host_reason(parsed.hostname or "")
    if base_host_reason:
        fail("base_url_dns_required", f"host={parsed.hostname or '<none>'} hostReason={base_host_reason}")
    tcp_host_reason = dns_host_reason(tcp_host)
    if tcp_host_reason:
        fail("tcp_host_dns_required", f"tcpHost={tcp_host or '<none>'} hostReason={tcp_host_reason}")

    level = str(payload.get("level") or "")
    if level not in {"full", "baseline"}:
        fail("invalid_level", f"level={level or '-'}")
    required_rows = int(target.get("requiredAccountRows") or 0)
    policy = payload.get("policy") or {}
    if policy.get("requirePackageableEvidence") is not True:
        fail("packageable_policy_missing")
    if policy.get("requireCloudSecurityGroup") is not True:
        fail("cloud_security_group_policy_missing")
    if policy.get("requireCloudSecurityGroupRepairReceipt") is not True:
        fail("cloud_security_group_repair_receipt_policy_missing")
    if policy.get("requirePublicPortPolicy") is not True:
        fail("public_port_policy_missing")
    if policy.get("allowTempHTTP8080") is not False:
        fail("temp_http_8080_policy_invalid")
    cloud_security_group_rules_max_age_seconds = int_field(
        policy,
        "cloudSecurityGroupRulesMaxAgeSeconds",
        "cloud_security_group_rules_max_age_invalid",
    )
    if cloud_security_group_rules_max_age_seconds <= 0:
        fail("cloud_security_group_rules_max_age_invalid", f"value={cloud_security_group_rules_max_age_seconds}")
    if policy.get("cloudSecurityGroupRulesRequireRootOwner") is not True:
        fail("cloud_security_group_rules_root_owner_policy_missing")
    if policy.get("operatorNetworkPreflight") is not True:
        fail("operator_network_policy_missing")
    if policy.get("runSmoke") is not True or policy.get("runProductScenarioSuite") is not True:
        fail("product_scenario_policy_missing")
    if policy.get("runBaseline") is not True:
        fail("baseline_policy_missing")
    if level == "full":
        if policy.get("runFullAcceptance") is not True:
            fail("full_acceptance_policy_missing")
        if required_rows < 10000:
            fail("full_required_rows_too_small", f"requiredRows={required_rows}")
    else:
        if policy.get("runFullAcceptance") is not False:
            fail("baseline_full_acceptance_policy_invalid")
        if required_rows < 5000:
            fail("baseline_required_rows_too_small", f"requiredRows={required_rows}")
    if policy.get("fullAcceptanceCampaign") != "production-full-acceptance":
        fail("campaign_policy_invalid")
    cloud_security_group_repair_receipt_max_age_seconds = int_field(
        policy,
        "cloudSecurityGroupRepairReceiptMaxAgeSeconds",
        "cloud_security_group_repair_receipt_max_age_invalid",
    )
    cloud_security_group_repair_receipt_expect_security_group_id = str(
        policy.get("cloudSecurityGroupRepairReceiptExpectSecurityGroupID") or ""
    )
    if not cloud_security_group_repair_receipt_expect_security_group_id:
        fail("cloud_security_group_repair_receipt_expected_security_group_id_missing")
    cloud_security_group_repair_receipt_expect_region_id = str(
        policy.get("cloudSecurityGroupRepairReceiptExpectRegionID") or ""
    )
    if not cloud_security_group_repair_receipt_expect_region_id:
        fail("cloud_security_group_repair_receipt_expected_region_id_missing")
    cloud_security_group_repair_receipt_expect_admin_cidr = str(
        policy.get("cloudSecurityGroupRepairReceiptExpectAdminCIDR") or ""
    )
    if not cloud_security_group_repair_receipt_expect_admin_cidr:
        fail("cloud_security_group_repair_receipt_expected_admin_cidr_missing")
    resolve_artifact_file(
        str(policy.get("cloudSecurityGroupRulesFile") or ""),
        "cloud_security_group_file_missing",
        evidence_dir=evidence_dir,
        fallback_name="cloud-security-group.json",
    )
    cloud_security_group_repair_receipt_path = resolve_artifact_file(
        str(policy.get("cloudSecurityGroupRepairReceiptJSON") or ""),
        "cloud_security_group_repair_receipt_missing",
        evidence_dir=evidence_dir,
        fallback_name="cloud-security-group-repair-receipt.json",
    )
    if cloud_security_group_repair_receipt_path is None:
        fail("cloud_security_group_repair_receipt_missing")
    verify_cloud_security_group_repair_receipt(
        cloud_security_group_repair_receipt_path,
        cloud_security_group_repair_receipt_max_age_seconds,
        expect_security_group_id=cloud_security_group_repair_receipt_expect_security_group_id,
        expect_region_id=cloud_security_group_repair_receipt_expect_region_id,
        expect_admin_cidr=cloud_security_group_repair_receipt_expect_admin_cidr,
    )

    commands = payload.get("commands") or {}
    if status == "PASS":
        if commands.get("readinessExitCode") != 0:
            fail("readiness_exit_code", f"value={commands.get('readinessExitCode')}")
        if commands.get("packageExitCode") != 0:
            fail("package_exit_code", f"value={commands.get('packageExitCode')}")

    artifacts = payload.get("artifacts") or {}
    readiness_json_path = resolve_artifact_file(
        str(artifacts.get("readinessJSON") or ""),
        "readiness_json_missing",
        evidence_dir=evidence_dir,
        fallback_name="current-production-readiness.json",
    )
    if readiness_json_path is None:
        fail("readiness_json_missing")
    resolve_artifact_file(
        str(artifacts.get("readinessLog") or ""),
        "readiness_log_missing",
        evidence_dir=evidence_dir,
        fallback_name="current-readiness-normal-product-baseline.log",
        required=evidence_dir is None,
    )
    resolve_artifact_file(
        str(artifacts.get("packageLog") or ""),
        "package_log_missing",
        evidence_dir=evidence_dir,
        required=evidence_dir is None,
    )
    package_path_raw = str(artifacts.get("package") or "")
    if not package_path_raw:
        fail("package_missing")
    package_path = Path(package_path_raw)
    if artifacts.get("packagePresent") is not True:
        fail("package_present_flag_invalid")
    package_bytes = int(artifacts.get("packageBytes") or 0)
    package_sha = str(artifacts.get("packageSha256") or "")
    if package_bytes <= 0:
        fail("package_bytes_missing")
    if len(package_sha) != 64:
        fail("package_sha256_missing")
    if package_file is not None:
        if not package_file.is_file():
            fail("package_file_missing", f"path={package_file}")
        if package_file.stat().st_size != package_bytes:
            fail("package_file_bytes_mismatch", f"path={package_file}")
        if sha256_file(package_file) != package_sha:
            fail("package_file_sha256_mismatch", f"path={package_file}")
        verify_package_archive(package_file, expected_target={
            "baseURL": base_url,
            "tcpHost": tcp_host,
            "tcpPort": str(target.get("tcpPort") or ""),
        })
    else:
        if not package_path.is_file():
            fail("package_missing", f"path={package_path}")
        if package_path.stat().st_size != package_bytes:
            fail("package_bytes_mismatch", f"path={package_path}")
        if sha256_file(package_path) != package_sha:
            fail("package_sha256_mismatch", f"path={package_path}")
        verify_package_archive(package_path, expected_target={
            "baseURL": base_url,
            "tcpHost": tcp_host,
            "tcpPort": str(target.get("tcpPort") or ""),
        })

    readiness = load_json(readiness_json_path)
    if status == "PASS" and readiness.get("status") != "PASS":
        fail("readiness_status_not_pass", f"status={readiness.get('status') or '-'}")
    requested = readiness.get("requestedRuns") or {}
    if requested.get("smoke") is not True or requested.get("productScenarioSuite") is not True:
        fail("readiness_requested_suite_missing")
    if requested.get("baseline") is not True:
        fail("readiness_requested_baseline_missing")
    if level == "full" and requested.get("fullAcceptance") is not True:
        fail("readiness_requested_full_missing")
    if level == "baseline" and requested.get("fullAcceptance") is not False:
        fail("readiness_requested_full_invalid")
    evidence_policy = readiness.get("evidencePolicy") or {}
    if evidence_policy.get("requireCloudSecurityGroup") is not True:
        fail("readiness_cloud_security_group_policy_missing")
    if evidence_policy.get("requireCloudSecurityGroupRepairReceipt") is not True:
        fail("readiness_cloud_security_group_repair_receipt_policy_missing")
    if evidence_policy.get("requirePublicPortPolicy") is not True:
        fail("readiness_public_port_policy_missing")
    if evidence_policy.get("allowTempHTTP8080") is not False:
        fail("readiness_temp_http_8080_policy_invalid")
    readiness_rules_max_age_seconds = int_field(
        evidence_policy,
        "cloudSecurityGroupRulesMaxAgeSeconds",
        "readiness_cloud_security_group_rules_max_age_invalid",
    )
    if readiness_rules_max_age_seconds <= 0:
        fail("readiness_cloud_security_group_rules_max_age_invalid", f"value={readiness_rules_max_age_seconds}")
    if evidence_policy.get("cloudSecurityGroupRulesRequireRootOwner") is not True:
        fail("readiness_cloud_security_group_rules_root_owner_policy_missing")
    if evidence_policy.get("operatorNetworkPreflight") is not True:
        fail("readiness_operator_network_policy_missing")
    verify_readiness_operator_network_state(
        readiness_json_path,
        readiness,
        evidence_dir=evidence_dir,
    )
    readiness_repair_receipt = str(evidence_policy.get("cloudSecurityGroupRepairReceiptJSON") or "")
    readiness_repair_receipt_max_age_seconds = int_field(
        evidence_policy,
        "cloudSecurityGroupRepairReceiptMaxAgeSeconds",
        "readiness_cloud_security_group_repair_receipt_max_age_invalid",
    )
    if not readiness_repair_receipt:
        fail("readiness_cloud_security_group_repair_receipt_missing")
    readiness_artifacts = readiness.get("artifacts") or {}
    readiness_repair_receipt_artifact = str(readiness_artifacts.get("cloudSecurityGroupRepairReceiptJSON") or "")
    if readiness_repair_receipt_artifact != readiness_repair_receipt:
        fail(
            "readiness_cloud_security_group_repair_receipt_artifact_mismatch",
            f"policy={readiness_repair_receipt} artifact={readiness_repair_receipt_artifact or '-'}",
        )
    readiness_repair_receipt_path = resolve_readiness_artifact_file(
        readiness_repair_receipt,
        "readiness_cloud_security_group_repair_receipt_missing",
        readiness_path=readiness_json_path,
        evidence_dir=evidence_dir,
        fallback_name="cloud-security-group-repair-receipt.json",
    )
    if readiness_repair_receipt_path is None:
        fail("readiness_cloud_security_group_repair_receipt_missing")
    verify_cloud_security_group_repair_receipt(
        readiness_repair_receipt_path,
        readiness_repair_receipt_max_age_seconds,
        expect_security_group_id=cloud_security_group_repair_receipt_expect_security_group_id,
        expect_region_id=cloud_security_group_repair_receipt_expect_region_id,
        expect_admin_cidr=cloud_security_group_repair_receipt_expect_admin_cidr,
    )
    resolve_readiness_artifact_file(
        str(readiness_artifacts.get("cloudSecurityGroupRepairReceiptVerifyLog") or ""),
        "readiness_cloud_security_group_repair_receipt_verify_log_missing",
        readiness_path=readiness_json_path,
        evidence_dir=evidence_dir,
        fallback_name="current-readiness-cloud-security-group-repair-receipt-verify.log",
    )
    entrypoint = readiness.get("entrypoint") or {}
    probe_path = resolve_artifact_file(
        str(entrypoint.get("probeJSON") or ""),
        "readiness_probe_json_missing",
        evidence_dir=evidence_dir,
        fallback_name="current-readiness-entrypoint-probe.json",
    )
    probe = load_json(probe_path)
    public_status = str(probe.get("publicPortPolicyStatus") or (probe.get("signals") or {}).get("publicPortPolicyStatus") or "")
    if public_status != "pass":
        fail("readiness_public_port_policy_not_pass", f"status={public_status or '-'}")
    if probe.get("publicDeniedPortsOpen") or (probe.get("signals") or {}).get("publicDeniedPortsOpen"):
        fail("readiness_public_denied_ports_open")
    if probe.get("publicExpectedPortsMissing") or (probe.get("signals") or {}).get("publicExpectedPortsMissing"):
        fail("readiness_public_expected_ports_missing")
    runs = readiness.get("runs") or {}
    if status == "PASS":
        for key in ("smokeExitCode", "suiteExitCode", "baselineExitCode"):
            if runs.get(key) != 0:
                fail("readiness_run_exit_code", f"key={key} value={runs.get(key)}")
        if level == "full" and runs.get("fullAcceptanceExitCode") != 0:
            fail("readiness_full_exit_code", f"value={runs.get('fullAcceptanceExitCode')}")

    try:
        current_readiness_verify.verify(argparse.Namespace(
            readiness_json=readiness_json_path,
            dashboard_json=None,
            state_json=None,
            probe_json=None,
            evidence_dir=evidence_dir,
            expect_base_url=base_url,
            expect_tcp_host=tcp_host,
            expect_tcp_port=str(target.get("tcpPort") or ""),
        ))
    except SystemExit as exc:
        fail("readiness_artifact_verify_failed", str(exc)[:500])

    print(
        "production_acceptance_verify result=pass "
        f"status={status} level={level} package={package_path}"
    )


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        sg = root / "cloud-security-group.json"
        sg.write_text("{}", encoding="utf-8")
        post_apply_sg = root / "cloud-security-group-post-apply.json"
        post_apply_sg.write_text("{}", encoding="utf-8")
        repair_plan = root / "cloud-security-group-repair-plan.json"
        repair_plan.write_text(
            json.dumps({
                "schemaVersion": 1,
                "securityGroupId": "sg-acceptance-selftest",
                "regionId": "cn-shenzhen",
                "snapshot": str(sg),
                "adminCidr": "203.0.113.10/32",
                "publicClientPorts": [80, 443, 9000],
                "adminPorts": [22],
                "denyPublicPorts": [3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080],
                "status": "NOOP",
                "actions": [],
                "summary": {"actionCount": 0, "authorizeCount": 0, "revokeCount": 0},
            }),
            encoding="utf-8",
        )

        def artifact_record(path: Path) -> dict:
            return {
                "path": str(path),
                "present": True,
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }

        repair_receipt = root / "cloud-security-group-repair-receipt.json"
        generated_at_epoch = int(time.time())
        repair_receipt.write_text(
            json.dumps({
                "schemaVersion": 1,
                "status": "APPLIED_VERIFIED",
                "generatedAtEpoch": generated_at_epoch,
                "securityGroupId": "sg-acceptance-selftest",
                "regionId": "cn-shenzhen",
                "adminCidr": "203.0.113.10/32",
                "applied": True,
                "verified": True,
                "snapshot": str(sg),
                "postApplySnapshot": str(post_apply_sg),
                "plan": str(repair_plan),
                "planStatus": "NOOP",
                "summary": {"actionCount": 0, "authorizeCount": 0, "revokeCount": 0},
                "artifacts": {
                    "snapshot": artifact_record(sg),
                    "postApplySnapshot": artifact_record(post_apply_sg),
                    "plan": artifact_record(repair_plan),
                },
            }),
            encoding="utf-8",
        )
        readiness_log = root / "readiness.log"
        readiness_log.write_text("ok\n", encoding="utf-8")
        package_log = root / "package.log"
        package_log.write_text("ok\n", encoding="utf-8")
        readiness_repair_verify_log = root / "current-readiness-cloud-security-group-repair-receipt-verify.log"
        readiness_repair_verify_log.write_text("cloud_security_group_repair_receipt result=pass\n", encoding="utf-8")
        readiness_cloud_security_group_audit_log = root / "current-readiness-cloud-security-group-audit.log"
        readiness_cloud_security_group_audit_log.write_text("cloud_security_group_audit result=pass\n", encoding="utf-8")
        operator_network_log = root / "current-readiness-operator-network.log"
        operator_network_log.write_text(
            "operator-network target=https://chat.myim-prod.com host=chat.myim-prod.com status=pass warning=clean routeInterface=en0 routeGateway=192.168.1.1 proxyEnv=<none>\n"
            "operator-network result=pass targets=2\n",
            encoding="utf-8",
        )
        operator_network_json = root / "current-readiness-operator-network.json"
        operator_network_json.write_text(
            json.dumps({
                "schemaVersion": 1,
                "status": "pass",
                "failed": False,
                "failureCount": 0,
                "targetCount": 2,
                "warnings": [],
                "warningCounts": {},
                "routeInterfaces": ["en0"],
                "routeGateways": ["192.168.1.1"],
                "failedTargets": [],
                "targets": [
                    {
                        "target": "https://chat.myim-prod.com",
                        "host": "chat.myim-prod.com",
                        "status": "pass",
                        "warning": "clean",
                        "routeInterface": "en0",
                        "routeGateway": "192.168.1.1",
                        "proxyEnv": "<none>",
                    }
                ],
                "action": "",
            }),
            encoding="utf-8",
        )
        smoke_log = root / "current-readiness-normal-product-smoke.log"
        smoke_log.write_text("smoke pass\n", encoding="utf-8")
        suite_log = root / "current-readiness-product-scenario-suite.log"
        suite_log.write_text("suite pass\n", encoding="utf-8")
        baseline_log = root / "current-readiness-normal-product-baseline.log"
        baseline_log.write_text("baseline pass\n", encoding="utf-8")
        full_acceptance_log = root / "current-readiness-production-full-acceptance.log"
        full_acceptance_log.write_text("full acceptance pass\n", encoding="utf-8")
        suite_run_json = root / "product-scenario-suite-run.json"
        suite_run_md = root / "product-scenario-suite-run.md"
        suite_run_json.write_text(json.dumps({
            "schemaVersion": 1,
            "suite": "recommended",
            "status": "PASS",
            "reason": "all_stages_passed",
            "settings": {"dryRun": False, "execute": True, "stopOnFailure": True, "includeLargeGroup": False},
            "target": {
                "baseURL": "https://chat.myim-prod.com",
                "tcpHost": "tcp.myim-prod.com",
                "tcpPort": "9000",
            },
            "stageCount": 1,
            "failedStageCount": 0,
            "plannedStageCount": 0,
            "coverageSummary": {
                "stageCount": 1,
                "productPlanStageCount": 1,
                "coverageErrorCount": 0,
                "uniqueScenarioCount": 8,
                "largeGroupIncluded": False,
                "coveredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"],
                "requiredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"],
                "missingProductDomains": [],
                "requiredProductDomainsCovered": True,
            },
            "failureSummary": [],
            "stageCoverage": [{
                "stage": "normal-smoke",
                "runner": "product-plan",
                "value": "normal-smoke",
                "coverageStatus": "READY",
                "uniqueScenarioCount": 8,
                "largeGroupIncluded": False,
                "coveredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"],
                "requiredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"],
                "missingProductDomains": [],
                "requiredProductDomainsCovered": True,
                "selectedScenarios": ["login-smoke"],
                "sampleScenarios": ["login-smoke"],
            }],
            "stages": [{
                "id": "normal-smoke",
                "runner": "product-plan",
                "value": "normal-smoke",
                "description": "Fast smoke",
                "runDir": ".",
                "status": "PASS",
                "exitCode": 0,
            }],
        }), encoding="utf-8")
        suite_run_md.write_text(
            "# Product Scenario Suite Run\n\n"
            "- suite: `recommended`\n"
            "- status: `PASS`\n\n"
            "## Coverage\n\n"
            "- `normal-smoke`\n",
            encoding="utf-8",
        )
        full_acceptance_run = root / "current-readiness-full-acceptance-run.json"
        full_acceptance_runbook = root / "current-readiness-full-acceptance-runbook.md"
        full_stage_ids = [
            "normal-product-smoke",
            "normal-product-plan",
            "normal-product-baseline",
            "normal-product-capacity",
            "message-realtime-capacity",
            "large-group-isolated",
        ]
        full_stages = []
        for index, stage_id in enumerate(full_stage_ids, start=1):
            is_large = stage_id == "large-group-isolated"
            command = (
                "env BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com TCP_PORT=9000 "
                "IM_INTERNAL_SECRET=<redacted> SCENARIO_GROUPS=large-group ./run_perf_scenarios.sh"
                if is_large else
                "env BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com TCP_PORT=9000 "
                f"IM_INTERNAL_SECRET=<redacted> PRODUCT_TEST_PHASES={stage_id} ./run_product_test_plan.sh"
            )
            full_stages.append({
                "index": index,
                "id": stage_id,
                "runner": "scenario-group" if is_large else "product-plan",
                "required": True,
                "isolated": is_large,
                "status": "PASS",
                "returnCode": 0,
                "runDir": str(root / f"{index:02d}-{stage_id}"),
                "log": str(root / f"{index:02d}-{stage_id}" / "stage.log"),
                "command": command,
                "evidence": "self-test",
                "packageEvidenceProfile": False,
                "packageEvidenceProductPlan": False,
                "skipReason": "",
            })
        full_acceptance_payload = {
            "schemaVersion": 1,
            "generatedAt": "2026-01-01T00:00:00Z",
            "campaign": "production-full-acceptance",
            "description": "production acceptance verifier self-test",
            "campaignCatalog": str(Path(__file__).with_name("perf_product_campaigns.json")),
            "execute": True,
            "stopOnFailure": True,
            "resultDir": str(root),
            "runIDPrefix": "production-acceptance-verifier-self-test",
            "target": {
                "baseURL": "https://chat.myim-prod.com",
                "tcpHost": "tcp.myim-prod.com",
                "tcpPort": "9000",
                "accountFile": "/tmp/self-test-accounts.csv",
                "hasConversationID": "true",
                "hasInternalSecret": "true",
            },
            "evidenceRoot": {"enabled": False},
            "finalStatus": "PASS",
            "failureCount": 0,
            "requiredFailureCount": 0,
            "attemptedStageCount": len(full_stages),
            "skippedStageCount": 0,
            "stageCount": len(full_stages),
            "stages": full_stages,
        }
        full_acceptance_run.write_text(json.dumps(full_acceptance_payload, indent=2, sort_keys=True), encoding="utf-8")
        full_acceptance_runbook.write_text(build_runbook(full_acceptance_payload), encoding="utf-8")
        readiness_summary = {
            "conclusion": "READY",
            "entrypointRescueBlocked": False,
            "entrypointRescueDiagnosis": "",
            "currentReadinessStatus": "PASS",
            "currentReadinessReason": "entrypoint_and_requested_runs_passed",
            "currentReadinessRequestedSmoke": True,
            "currentReadinessRequestedProductScenarioSuite": True,
            "currentReadinessRequestedBaseline": True,
            "currentReadinessRequestedFullAcceptance": True,
            "currentReadinessSmokeExitCode": 0,
            "currentReadinessProductScenarioSuiteExitCode": 0,
            "currentReadinessBaselineExitCode": 0,
            "currentReadinessFullAcceptanceExitCode": 0,
            "currentReadinessProductScenarioSuiteExpected": "recommended",
            "currentReadinessProductScenarioSuite": "recommended",
            "currentReadinessProductScenarioSuiteStatus": "PASS",
            "currentReadinessProductScenarioSuiteStageCount": 1,
            "currentReadinessProductScenarioSuiteFailedStages": 0,
            "currentReadinessProductScenarioSuitePlannedStages": 0,
            "currentReadinessProductScenarioSuiteScenarios": 8,
            "currentReadinessProductScenarioSuiteProductPlanStages": 1,
            "currentReadinessProductScenarioSuiteLargeGroupIncluded": False,
            "currentReadinessFullAcceptanceExpectedCampaign": "production-full-acceptance",
            "currentReadinessFullAcceptanceCampaign": "production-full-acceptance",
            "currentReadinessFullAcceptanceStatus": "PASS",
            "currentReadinessFullAcceptanceFailures": 0,
            "currentReadinessFullAcceptanceRequiredFailures": 0,
            "currentReadinessFullAcceptanceAttempted": 6,
            "currentReadinessFullAcceptanceSkipped": 0,
            "currentReadinessOperatorNetworkPreflight": True,
            "currentReadinessOperatorNetworkLogPresent": True,
            "currentReadinessOperatorNetworkFailed": False,
            "currentReadinessOperatorNetworkWarnings": [],
            "currentReadinessOperatorNetworkRouteInterfaces": ["en0"],
            "currentReadinessOperatorNetworkRouteGateways": ["192.168.1.1"],
            "currentReadinessOperatorNetworkFailureCount": 0,
            "productionEvidenceBlockerCount": 0,
            "productionEvidenceBlockers": [],
        }
        dashboard_json = root / "current-production-dashboard.json"
        dashboard_json.write_text(json.dumps({"summary": readiness_summary, "nextCommand": ""}), encoding="utf-8")
        dashboard_json.with_suffix(".md").write_text("# Current Production Dashboard\n", encoding="utf-8")
        state_summary_json = root / "current-production-state-summary.json"
        state_summary_json.write_text(
            json.dumps({
                "summary": readiness_summary,
                "productionEvidenceBlockers": [],
                "nextCommand": "",
            }),
            encoding="utf-8",
        )
        state_summary_json.with_suffix(".md").write_text("# Current Production State Summary\n", encoding="utf-8")
        state_summary_csv = root / "current-production-state-summary.csv"
        state_csv_fields = [
            "recordType",
            "conclusion",
            "currentReadinessStatus",
            "currentReadinessReason",
            "currentReadinessRequestedSmoke",
            "currentReadinessRequestedProductScenarioSuite",
            "currentReadinessRequestedBaseline",
            "currentReadinessRequestedFullAcceptance",
            "currentReadinessSmokeExitCode",
            "currentReadinessProductScenarioSuiteExitCode",
            "currentReadinessBaselineExitCode",
            "currentReadinessFullAcceptanceExitCode",
            "currentReadinessProductScenarioSuiteExpected",
            "currentReadinessProductScenarioSuite",
            "currentReadinessProductScenarioSuiteStatus",
            "currentReadinessProductScenarioSuiteStageCount",
            "currentReadinessProductScenarioSuiteFailedStages",
            "currentReadinessProductScenarioSuitePlannedStages",
            "currentReadinessProductScenarioSuiteScenarios",
            "currentReadinessProductScenarioSuiteProductPlanStages",
            "currentReadinessProductScenarioSuiteLargeGroupIncluded",
            "currentReadinessFullAcceptanceExpectedCampaign",
            "currentReadinessFullAcceptanceCampaign",
            "currentReadinessFullAcceptanceStatus",
            "currentReadinessFullAcceptanceFailures",
            "currentReadinessFullAcceptanceRequiredFailures",
            "currentReadinessFullAcceptanceAttempted",
            "currentReadinessFullAcceptanceSkipped",
            "currentReadinessOperatorNetworkPreflight",
            "currentReadinessOperatorNetworkLogPresent",
            "currentReadinessOperatorNetworkFailed",
            "currentReadinessOperatorNetworkWarnings",
            "currentReadinessOperatorNetworkRouteInterfaces",
            "currentReadinessOperatorNetworkRouteGateways",
            "currentReadinessOperatorNetworkFailureCount",
            "productionEvidenceBlockerCount",
            "productionEvidenceBlockers",
        ]
        state_csv_row = []
        for field in state_csv_fields:
            if field == "recordType":
                state_csv_row.append("summary")
                continue
            value = readiness_summary.get(field, "")
            if isinstance(value, list):
                value = ",".join(str(item) for item in value)
            state_csv_row.append(str(value))
        state_summary_csv.write_text(
            ",".join(state_csv_fields) + "\n" + ",".join(state_csv_row) + "\n",
            encoding="utf-8",
        )
        package = root / "evidence.tar.gz"
        package_stage = root / "package-stage"
        package_target = {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
        }
        write_minimal_evidence_package(package, package_stage, package_target)
        probe = root / "current-readiness-entrypoint-probe.json"
        probe.write_text(
            json.dumps({
                "schemaVersion": 1,
                "failed": False,
                "diagnosis": "ok",
                "publicPortPolicyStatus": "pass",
                "publicDeniedPortsOpen": [],
                "publicExpectedPortsMissing": [],
            }),
            encoding="utf-8",
        )
        readiness = root / "current-production-readiness.json"
        readiness_payload = {
            "schemaVersion": 1,
            "status": "PASS",
            "reason": "entrypoint_and_requested_runs_passed",
            "generatedAtEpoch": generated_at_epoch,
            "target": {
                "baseURL": "https://chat.myim-prod.com",
                "tcpHost": "tcp.myim-prod.com",
                "tcpPort": "9000",
                "accountFile": "/tmp/accounts.csv",
                "conversationIDPresent": True,
            },
            "requestedRuns": {
                "smoke": True,
                "smokeMode": "smoke",
                "productScenarioSuite": True,
                "productScenarioSuiteName": "recommended",
                "baseline": True,
                "fullAcceptance": True,
                "fullAcceptanceCampaign": "production-full-acceptance",
            },
            "evidencePolicy": {
                "requirePackageableEvidence": True,
                "autoProductScenarioSuiteForPackageableAcceptance": True,
                "requireCloudSecurityGroup": True,
                "requireCloudSecurityGroupRepairReceipt": True,
                "requirePublicPortPolicy": True,
                "allowTempHTTP8080": False,
                "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
                "cloudSecurityGroupRulesRequireRootOwner": True,
                "cloudSecurityGroupRulesFile": str(sg),
                "cloudSecurityGroupRepairReceiptJSON": str(repair_receipt),
                "cloudSecurityGroupRepairReceiptMaxAgeSeconds": 86400,
                "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": "sg-acceptance-selftest",
                "cloudSecurityGroupRepairReceiptExpectRegionID": "cn-shenzhen",
                "cloudSecurityGroupRepairReceiptExpectAdminCIDR": "203.0.113.10/32",
                "operatorNetworkPreflight": True,
            },
            "entrypoint": {
                "probeJSON": str(probe),
                "failed": False,
                "diagnosis": "ok",
                "detail": "ok",
                "blocker": {"preventsPerformanceEvidence": False},
            },
            "artifacts": {
                "runDir": str(root),
                "dashboard": str(dashboard_json.with_suffix(".md")),
                "stateSummary": str(root / "current-production-state-summary.md"),
                "cloudSecurityGroupRulesFile": str(sg),
                "cloudSecurityGroupAuditLog": str(readiness_cloud_security_group_audit_log),
                "cloudSecurityGroupRepairReceiptJSON": str(repair_receipt),
                "cloudSecurityGroupRepairReceiptVerifyLog": str(readiness_repair_verify_log),
                "operatorNetworkLog": str(operator_network_log),
                "operatorNetworkJSON": str(operator_network_json),
                "smokeLog": str(smoke_log),
                "productScenarioSuiteLog": str(suite_log),
                "productScenarioSuiteRunJSON": str(suite_run_json),
                "productScenarioSuiteRunMarkdown": str(suite_run_md),
                "baselineLog": str(baseline_log),
                "fullAcceptanceLog": str(full_acceptance_log),
                "fullAcceptanceRunJSON": str(full_acceptance_run),
                "fullAcceptanceRunbook": str(full_acceptance_runbook),
            },
            "runs": {
                "smokeExitCode": 0,
                "suiteExitCode": 0,
                "baselineExitCode": 0,
                "fullAcceptanceExitCode": 0,
            },
        }
        readiness.write_text(json.dumps(readiness_payload), encoding="utf-8")
        receipt = root / "production-acceptance.json"
        receipt_payload = {
            "schemaVersion": 1,
            "status": "PASS",
            "reason": "accepted",
            "generatedAtEpoch": generated_at_epoch,
            "level": "full",
            "target": {
                "baseURL": "https://chat.myim-prod.com",
                "tcpHost": "tcp.myim-prod.com",
                "tcpPort": "9000",
                "accountFile": "/tmp/accounts.csv",
                "conversationIDPresent": True,
                "requiredAccountRows": 10000,
            },
            "policy": {
                "requirePackageableEvidence": True,
                "requireCloudSecurityGroup": True,
                "requireCloudSecurityGroupRepairReceipt": True,
                "requirePublicPortPolicy": True,
                "allowTempHTTP8080": False,
                "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
                "cloudSecurityGroupRulesRequireRootOwner": True,
                "operatorNetworkPreflight": True,
                "runSmoke": True,
                "runProductScenarioSuite": True,
                "runBaseline": True,
                "runFullAcceptance": True,
                "fullAcceptanceCampaign": "production-full-acceptance",
                "cloudSecurityGroupRulesFile": str(sg),
                "cloudSecurityGroupRepairReceiptJSON": str(repair_receipt),
                "cloudSecurityGroupRepairReceiptMaxAgeSeconds": 86400,
                "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": "sg-acceptance-selftest",
                "cloudSecurityGroupRepairReceiptExpectRegionID": "cn-shenzhen",
                "cloudSecurityGroupRepairReceiptExpectAdminCIDR": "203.0.113.10/32",
            },
            "artifacts": {
                "readinessJSON": str(readiness),
                "readinessLog": str(readiness_log),
                "packageLog": str(package_log),
                "package": str(package),
                "packagePresent": True,
                "packageBytes": package.stat().st_size,
                "packageSha256": sha256_file(package),
            },
            "commands": {"readinessExitCode": 0, "packageExitCode": 0},
        }
        receipt.write_text(json.dumps(receipt_payload), encoding="utf-8")
        verify_receipt(
            receipt,
            require_pass=True,
            max_age_seconds=86400,
            max_future_skew_seconds=300,
            package_file=package,
        )
        cli_good = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--verify-package-archive",
                "--package-file",
                str(package),
                "--expect-base-url",
                package_target["baseURL"],
                "--expect-tcp-host",
                package_target["tcpHost"],
                "--expect-tcp-port",
                package_target["tcpPort"],
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if cli_good.returncode != 0 or "production_acceptance_verify result=pass package=" not in cli_good.stdout:
            fail("self_test_package_archive_cli_good_failed", (cli_good.stdout + cli_good.stderr).strip()[:500])
        source_text = Path(__file__).read_text(encoding="utf-8")
        forbidden_full_read_hash = "hashlib.sha256(" + "archive_member_bytes"
        if forbidden_full_read_hash in source_text:
            fail("self_test_archive_member_hash_full_read_detected")
        with tarfile.open(package, "r:gz") as archive:
            readme_member = archive.getmember("README.md")
            try:
                archive_member_bytes(archive, readme_member, "README.md", max_bytes=2)
            except SystemExit as exc:
                if "package_archive_text_member_too_large" not in str(exc):
                    raise
            else:
                fail("self_test_archive_text_member_limit_passed")
        cli_bad_target = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--verify-package-archive",
                "--package-file",
                str(package),
                "--expect-base-url",
                package_target["baseURL"],
                "--expect-tcp-host",
                "other.myim-prod.com",
                "--expect-tcp-port",
                package_target["tcpPort"],
                "--reason-only",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if cli_bad_target.returncode == 0:
            fail("self_test_package_archive_cli_bad_target_passed")
        cli_bad_output = (cli_bad_target.stdout + cli_bad_target.stderr).strip()
        if "package_manifest_current_readiness_target_mismatch" not in cli_bad_output:
            fail("self_test_package_archive_cli_bad_target_reason_missing", cli_bad_output[:500])
        missing_external = json.loads(json.dumps(receipt_payload))
        missing_external["policy"]["cloudSecurityGroupRulesFile"] = str(root / "missing-cloud-security-group.json")
        missing_external["policy"]["cloudSecurityGroupRepairReceiptJSON"] = str(root / "missing-cloud-security-group-repair-receipt.json")
        missing_external["artifacts"]["readinessJSON"] = str(root / "missing-readiness.json")
        missing_external["artifacts"]["readinessLog"] = str(root / "missing-readiness.log")
        missing_external["artifacts"]["packageLog"] = str(root / "missing-package.log")
        installed_receipt = root / "installed-receipt.json"
        installed_receipt.write_text(json.dumps(missing_external), encoding="utf-8")
        verify_receipt(
            installed_receipt,
            require_pass=True,
            max_age_seconds=86400,
            max_future_skew_seconds=300,
            package_file=package,
            evidence_dir=root,
        )

        stale_acceptance_receipt = json.loads(json.dumps(receipt_payload))
        stale_acceptance_receipt["generatedAtEpoch"] = generated_at_epoch - 90000
        stale_acceptance_path = root / "stale-acceptance-receipt.json"
        stale_acceptance_path.write_text(json.dumps(stale_acceptance_receipt), encoding="utf-8")
        try:
            verify_receipt(
                stale_acceptance_path,
                require_pass=True,
                max_age_seconds=86400,
                max_future_skew_seconds=300,
                package_file=package,
            )
        except SystemExit as exc:
            if "receipt_stale" not in str(exc):
                raise
        else:
            fail("self_test_stale_acceptance_receipt_passed")

        future_acceptance_receipt = json.loads(json.dumps(receipt_payload))
        future_acceptance_receipt["generatedAtEpoch"] = generated_at_epoch + 600
        future_acceptance_path = root / "future-acceptance-receipt.json"
        future_acceptance_path.write_text(json.dumps(future_acceptance_receipt), encoding="utf-8")
        try:
            verify_receipt(
                future_acceptance_path,
                require_pass=True,
                max_age_seconds=86400,
                max_future_skew_seconds=300,
                package_file=package,
            )
        except SystemExit as exc:
            if "receipt_generated_at_in_future" not in str(exc):
                raise
        else:
            fail("self_test_future_acceptance_receipt_passed")

        bad = json.loads(json.dumps(receipt_payload))
        bad["target"]["baseURL"] = "http://47.106.103.10"
        bad_path = root / "bad.json"
        bad_path.write_text(json.dumps(bad), encoding="utf-8")
        try:
            verify_receipt(bad_path, require_pass=True)
        except SystemExit as exc:
            message = str(exc)
            if "base_url_https_required" not in message:
                raise
        else:
            fail("self_test_bad_target_passed")

        bad_non_default_port = json.loads(json.dumps(receipt_payload))
        bad_non_default_port["target"]["baseURL"] = "https://chat.myim-prod.com:8080"
        bad_non_default_port_path = root / "bad-non-default-port.json"
        bad_non_default_port_path.write_text(json.dumps(bad_non_default_port), encoding="utf-8")
        try:
            verify_receipt(bad_non_default_port_path, require_pass=True)
        except SystemExit as exc:
            message = str(exc)
            if "base_url_default_https_port_required" not in message:
                raise
        else:
            fail("self_test_non_default_https_port_target_passed")

        bad_ip_base = json.loads(json.dumps(receipt_payload))
        bad_ip_base["target"]["baseURL"] = "https://47.106.103.10"
        bad_ip_base_path = root / "bad-ip-base.json"
        bad_ip_base_path.write_text(json.dumps(bad_ip_base), encoding="utf-8")
        try:
            verify_receipt(bad_ip_base_path, require_pass=True)
        except SystemExit as exc:
            message = str(exc)
            if "base_url_dns_required" not in message or "hostReason=ip" not in message:
                raise
        else:
            fail("self_test_ip_base_target_passed")

        bad_ip_tcp = json.loads(json.dumps(receipt_payload))
        bad_ip_tcp["target"]["tcpHost"] = "47.106.103.10"
        bad_ip_tcp_path = root / "bad-ip-tcp.json"
        bad_ip_tcp_path.write_text(json.dumps(bad_ip_tcp), encoding="utf-8")
        try:
            verify_receipt(bad_ip_tcp_path, require_pass=True)
        except SystemExit as exc:
            message = str(exc)
            if "tcp_host_dns_required" not in message or "hostReason=ip" not in message:
                raise
        else:
            fail("self_test_ip_tcp_target_passed")

        bad_placeholder = json.loads(json.dumps(receipt_payload))
        bad_placeholder["target"]["baseURL"] = "https://chat.yourdomain.com"
        bad_placeholder["target"]["tcpHost"] = "tcp.yourdomain.com"
        bad_placeholder_path = root / "bad-placeholder.json"
        bad_placeholder_path.write_text(json.dumps(bad_placeholder), encoding="utf-8")
        try:
            verify_receipt(bad_placeholder_path, require_pass=True)
        except SystemExit as exc:
            message = str(exc)
            if "base_url_dns_required" not in message or "hostReason=placeholder" not in message:
                raise
        else:
            fail("self_test_placeholder_target_passed")

        bad_tcp_placeholder = json.loads(json.dumps(receipt_payload))
        bad_tcp_placeholder["target"]["tcpHost"] = "tcp.example.net"
        bad_tcp_placeholder_path = root / "bad-tcp-placeholder.json"
        bad_tcp_placeholder_path.write_text(json.dumps(bad_tcp_placeholder), encoding="utf-8")
        try:
            verify_receipt(bad_tcp_placeholder_path, require_pass=True)
        except SystemExit as exc:
            message = str(exc)
            if "tcp_host_dns_required" not in message or "hostReason=placeholder" not in message:
                raise
        else:
            fail("self_test_placeholder_tcp_target_passed")

        bad_package = json.loads(json.dumps(receipt_payload))
        bad_package["artifacts"]["packagePresent"] = False
        bad_package_path = root / "bad-package.json"
        bad_package_path.write_text(json.dumps(bad_package), encoding="utf-8")
        try:
            verify_receipt(bad_package_path, require_pass=True)
        except SystemExit as exc:
            if "package_present_flag_invalid" not in str(exc):
                raise
        else:
            fail("self_test_bad_package_passed")
        bad_archive = root / "bad-evidence.tar.gz"
        bad_archive.write_text("not a tar archive\n", encoding="utf-8")
        bad_archive_receipt = json.loads(json.dumps(receipt_payload))
        bad_archive_receipt["artifacts"]["package"] = str(bad_archive)
        bad_archive_receipt["artifacts"]["packageBytes"] = bad_archive.stat().st_size
        bad_archive_receipt["artifacts"]["packageSha256"] = sha256_file(bad_archive)
        bad_archive_receipt_path = root / "bad-archive-receipt.json"
        bad_archive_receipt_path.write_text(json.dumps(bad_archive_receipt), encoding="utf-8")
        try:
            verify_receipt(bad_archive_receipt_path, require_pass=True, package_file=bad_archive)
        except SystemExit as exc:
            if "package_archive_invalid" not in str(exc):
                raise
        else:
            fail("self_test_bad_archive_passed")
        tampered_package_stage = root / "tampered-package-stage"
        tampered_package = root / "tampered-evidence.tar.gz"
        write_minimal_evidence_package(tampered_package, tampered_package_stage, package_target)
        (tampered_package_stage / "current-production-readiness.md").write_text(
            "# Current Production Readiness\n\nTampered after checksum generation.\n",
            encoding="utf-8",
        )
        with tarfile.open(tampered_package, "w:gz") as archive:
            for member in sorted(tampered_package_stage.iterdir()):
                archive.add(member, arcname=member.name)
        tampered_package_receipt = json.loads(json.dumps(receipt_payload))
        tampered_package_receipt["artifacts"]["package"] = str(tampered_package)
        tampered_package_receipt["artifacts"]["packageBytes"] = tampered_package.stat().st_size
        tampered_package_receipt["artifacts"]["packageSha256"] = sha256_file(tampered_package)
        tampered_package_receipt_path = root / "tampered-package-receipt.json"
        tampered_package_receipt_path.write_text(json.dumps(tampered_package_receipt), encoding="utf-8")
        try:
            verify_receipt(tampered_package_receipt_path, require_pass=True, package_file=tampered_package)
        except SystemExit as exc:
            if "package_checksum_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_tampered_package_checksum_passed")
        semantic_readme_stage = root / "semantic-readme-package-stage"
        semantic_readme_package = root / "semantic-readme-evidence.tar.gz"
        write_minimal_evidence_package(semantic_readme_package, semantic_readme_stage, package_target)
        readme_path = semantic_readme_stage / "README.md"
        readme_path.write_text(
            readme_path.read_text(encoding="utf-8").replace("- currentReadinessStatus: `PASS`", "- currentReadinessStatus: `FAIL`"),
            encoding="utf-8",
        )
        refresh_stage_manifest_file_records(semantic_readme_stage)
        write_package_archive_from_stage(semantic_readme_package, semantic_readme_stage)
        semantic_readme_receipt = json.loads(json.dumps(receipt_payload))
        semantic_readme_receipt["artifacts"]["package"] = str(semantic_readme_package)
        semantic_readme_receipt["artifacts"]["packageBytes"] = semantic_readme_package.stat().st_size
        semantic_readme_receipt["artifacts"]["packageSha256"] = sha256_file(semantic_readme_package)
        semantic_readme_receipt_path = root / "semantic-readme-package-receipt.json"
        semantic_readme_receipt_path.write_text(json.dumps(semantic_readme_receipt), encoding="utf-8")
        try:
            verify_receipt(semantic_readme_receipt_path, require_pass=True, package_file=semantic_readme_package)
        except SystemExit as exc:
            if "package_readme_current_readiness_status_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_semantic_readme_package_passed")
        semantic_readiness_md_stage = root / "semantic-readiness-md-package-stage"
        semantic_readiness_md_package = root / "semantic-readiness-md-evidence.tar.gz"
        write_minimal_evidence_package(semantic_readiness_md_package, semantic_readiness_md_stage, package_target)
        (semantic_readiness_md_stage / "current-production-readiness.md").write_text(
            "# Current Production Readiness\n\n- status: `PASS`\n\nManual drift with valid checksum.\n",
            encoding="utf-8",
        )
        refresh_stage_manifest_file_records(semantic_readiness_md_stage)
        write_package_archive_from_stage(semantic_readiness_md_package, semantic_readiness_md_stage)
        semantic_readiness_md_receipt = json.loads(json.dumps(receipt_payload))
        semantic_readiness_md_receipt["artifacts"]["package"] = str(semantic_readiness_md_package)
        semantic_readiness_md_receipt["artifacts"]["packageBytes"] = semantic_readiness_md_package.stat().st_size
        semantic_readiness_md_receipt["artifacts"]["packageSha256"] = sha256_file(semantic_readiness_md_package)
        semantic_readiness_md_receipt_path = root / "semantic-readiness-md-package-receipt.json"
        semantic_readiness_md_receipt_path.write_text(json.dumps(semantic_readiness_md_receipt), encoding="utf-8")
        try:
            verify_receipt(semantic_readiness_md_receipt_path, require_pass=True, package_file=semantic_readiness_md_package)
        except SystemExit as exc:
            if "package_current_readiness_markdown_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_semantic_readiness_markdown_package_passed")
        stale_manifest_record_stage = root / "stale-manifest-record-package-stage"
        stale_manifest_record_package = root / "stale-manifest-record-evidence.tar.gz"
        write_minimal_evidence_package(stale_manifest_record_package, stale_manifest_record_stage, package_target)
        stale_readme_path = stale_manifest_record_stage / "README.md"
        stale_readme_path.write_text(
            stale_readme_path.read_text(encoding="utf-8") + "\nAdditional operator note with valid archive checksums.\n",
            encoding="utf-8",
        )
        write_package_archive_from_stage(stale_manifest_record_package, stale_manifest_record_stage)
        stale_manifest_record_receipt = json.loads(json.dumps(receipt_payload))
        stale_manifest_record_receipt["artifacts"]["package"] = str(stale_manifest_record_package)
        stale_manifest_record_receipt["artifacts"]["packageBytes"] = stale_manifest_record_package.stat().st_size
        stale_manifest_record_receipt["artifacts"]["packageSha256"] = sha256_file(stale_manifest_record_package)
        stale_manifest_record_receipt_path = root / "stale-manifest-record-package-receipt.json"
        stale_manifest_record_receipt_path.write_text(json.dumps(stale_manifest_record_receipt), encoding="utf-8")
        try:
            verify_receipt(stale_manifest_record_receipt_path, require_pass=True, package_file=stale_manifest_record_package)
        except SystemExit as exc:
            message = str(exc)
            if (
                "package_manifest_file_record_bytes_mismatch" not in message
                and "package_manifest_file_record_sha256_mismatch" not in message
            ):
                raise
        else:
            fail("self_test_stale_manifest_file_record_package_passed")
        manifest_bytes_string_stage = root / "manifest-bytes-string-package-stage"
        manifest_bytes_string_package = root / "manifest-bytes-string-evidence.tar.gz"
        write_minimal_evidence_package(manifest_bytes_string_package, manifest_bytes_string_stage, package_target)
        manifest_bytes_string_path = manifest_bytes_string_stage / "production-evidence-manifest.json"
        manifest_bytes_string = json.loads(manifest_bytes_string_path.read_text(encoding="utf-8"))
        manifest_bytes_string["files"][0]["bytes"] = str(manifest_bytes_string["files"][0]["bytes"])
        manifest_bytes_string_path.write_text(json.dumps(manifest_bytes_string), encoding="utf-8")
        write_package_archive_from_stage(manifest_bytes_string_package, manifest_bytes_string_stage)
        try:
            verify_package_archive(manifest_bytes_string_package, expected_target=package_target)
        except SystemExit as exc:
            if "package_manifest_file_record_bytes_invalid" not in str(exc):
                raise
        else:
            fail("self_test_manifest_bytes_string_package_passed")
        oversized_member = tarfile.TarInfo("oversized.txt")
        oversized_member.size = MAX_PACKAGE_ARCHIVE_MEMBER_BYTES + 1
        try:
            validate_package_archive_member(oversized_member, oversized_member.name)
        except SystemExit as exc:
            if "package_archive_member_too_large" not in str(exc):
                raise
        else:
            fail("self_test_package_archive_oversized_member_passed")
        try:
            verify_package_archive(package, expected_target=package_target, max_total_bytes=2)
        except SystemExit as exc:
            if "package_archive_total_too_large" not in str(exc):
                raise
        else:
            fail("self_test_package_archive_total_limit_passed")
        account_artifact_package_stage = root / "account-artifact-package-stage"
        account_artifact_package = root / "account-artifact-evidence.tar.gz"
        write_minimal_evidence_package(account_artifact_package, account_artifact_package_stage, package_target)
        (account_artifact_package_stage / "load-10000.csv").write_text(
            "email,password\nload000001@example.com,do-not-package\n",
            encoding="utf-8",
        )
        refresh_stage_manifest_file_records(account_artifact_package_stage)
        write_package_archive_from_stage(account_artifact_package, account_artifact_package_stage)
        account_artifact_receipt = json.loads(json.dumps(receipt_payload))
        account_artifact_receipt["artifacts"]["package"] = str(account_artifact_package)
        account_artifact_receipt["artifacts"]["packageBytes"] = account_artifact_package.stat().st_size
        account_artifact_receipt["artifacts"]["packageSha256"] = sha256_file(account_artifact_package)
        account_artifact_receipt_path = root / "account-artifact-package-receipt.json"
        account_artifact_receipt_path.write_text(json.dumps(account_artifact_receipt), encoding="utf-8")
        try:
            verify_receipt(account_artifact_receipt_path, require_pass=True, package_file=account_artifact_package)
        except SystemExit as exc:
            if "package_archive_forbidden_artifact" not in str(exc):
                raise
        else:
            fail("self_test_account_artifact_package_passed")
        metadata_package_stage = root / "metadata-package-stage"
        metadata_package = root / "metadata-evidence.tar.gz"
        write_minimal_evidence_package(metadata_package, metadata_package_stage, package_target)
        (metadata_package_stage / "._current-production-readiness.json").write_text(
            "local metadata must not be accepted\n",
            encoding="utf-8",
        )
        rows = []
        for member in sorted(metadata_package_stage.iterdir()):
            if member.name == "SHA256SUMS":
                continue
            rows.append(f"{sha256_file(member)}  ./{member.name}\n")
        (metadata_package_stage / "SHA256SUMS").write_text("".join(rows), encoding="utf-8")
        with tarfile.open(metadata_package, "w:gz") as archive:
            for member in sorted(metadata_package_stage.iterdir()):
                archive.add(member, arcname=member.name)
        metadata_package_receipt = json.loads(json.dumps(receipt_payload))
        metadata_package_receipt["artifacts"]["package"] = str(metadata_package)
        metadata_package_receipt["artifacts"]["packageBytes"] = metadata_package.stat().st_size
        metadata_package_receipt["artifacts"]["packageSha256"] = sha256_file(metadata_package)
        metadata_package_receipt_path = root / "metadata-package-receipt.json"
        metadata_package_receipt_path.write_text(json.dumps(metadata_package_receipt), encoding="utf-8")
        try:
            verify_receipt(metadata_package_receipt_path, require_pass=True, package_file=metadata_package)
        except SystemExit as exc:
            if "package_archive_unsafe_member" not in str(exc):
                raise
        else:
            fail("self_test_metadata_package_passed")
        mismatched_package_stage = root / "mismatched-package-stage"
        mismatched_package = root / "mismatched-evidence.tar.gz"
        write_minimal_evidence_package(mismatched_package, mismatched_package_stage, package_target)
        (mismatched_package_stage / "current-production-readiness.json").write_text(
            json.dumps({
                "schemaVersion": 1,
                "target": {
                    "baseURL": "https://other.myim-prod.com",
                    "tcpHost": "tcp.myim-prod.com",
                    "tcpPort": "9000",
                },
            }),
            encoding="utf-8",
        )
        refresh_stage_manifest_file_records(mismatched_package_stage)
        rows = []
        for member in sorted(mismatched_package_stage.iterdir()):
            if member.name == "SHA256SUMS":
                continue
            rows.append(f"{sha256_file(member)}  ./{member.name}\n")
        (mismatched_package_stage / "SHA256SUMS").write_text("".join(rows), encoding="utf-8")
        with tarfile.open(mismatched_package, "w:gz") as archive:
            for member in sorted(mismatched_package_stage.iterdir()):
                archive.add(member, arcname=member.name)
        mismatched_package_receipt = json.loads(json.dumps(receipt_payload))
        mismatched_package_receipt["artifacts"]["package"] = str(mismatched_package)
        mismatched_package_receipt["artifacts"]["packageBytes"] = mismatched_package.stat().st_size
        mismatched_package_receipt["artifacts"]["packageSha256"] = sha256_file(mismatched_package)
        mismatched_package_receipt_path = root / "mismatched-package-receipt.json"
        mismatched_package_receipt_path.write_text(json.dumps(mismatched_package_receipt), encoding="utf-8")
        try:
            verify_receipt(mismatched_package_receipt_path, require_pass=True, package_file=mismatched_package)
        except SystemExit as exc:
            if "package_current_readiness_target_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_package_target_passed")
        bad_repair = load_json(repair_receipt)
        bad_repair["artifacts"]["plan"]["sha256"] = "0" * 64
        bad_repair_path = root / "bad-cloud-security-group-repair-receipt.json"
        bad_repair_path.write_text(json.dumps(bad_repair), encoding="utf-8")
        bad_repair_receipt = json.loads(json.dumps(receipt_payload))
        bad_repair_receipt["policy"]["cloudSecurityGroupRepairReceiptJSON"] = str(bad_repair_path)
        bad_repair_receipt_path = root / "bad-repair-receipt.json"
        bad_repair_receipt_path.write_text(json.dumps(bad_repair_receipt), encoding="utf-8")
        try:
            verify_receipt(bad_repair_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "cloud_security_group_repair_receipt_artifact_sha256_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_repair_receipt_passed")

        stale_repair = load_json(repair_receipt)
        stale_repair["generatedAtEpoch"] = generated_at_epoch - 90000
        stale_repair_path = root / "stale-cloud-security-group-repair-receipt.json"
        stale_repair_path.write_text(json.dumps(stale_repair), encoding="utf-8")
        stale_repair_receipt = json.loads(json.dumps(receipt_payload))
        stale_repair_receipt["policy"]["cloudSecurityGroupRepairReceiptJSON"] = str(stale_repair_path)
        stale_repair_receipt_path = root / "stale-repair-receipt.json"
        stale_repair_receipt_path.write_text(json.dumps(stale_repair_receipt), encoding="utf-8")
        try:
            verify_receipt(stale_repair_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "cloud_security_group_repair_receipt_stale" not in str(exc):
                raise
        else:
            fail("self_test_stale_repair_receipt_passed")

        mismatched_repair_receipt = json.loads(json.dumps(receipt_payload))
        mismatched_repair_receipt["policy"]["cloudSecurityGroupRepairReceiptExpectSecurityGroupID"] = "sg-wrong"
        mismatched_repair_receipt_path = root / "mismatched-repair-receipt.json"
        mismatched_repair_receipt_path.write_text(json.dumps(mismatched_repair_receipt), encoding="utf-8")
        try:
            verify_receipt(mismatched_repair_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "cloud_security_group_repair_receipt_security_group_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_repair_receipt_passed")

        bad_policy_plan = load_json(repair_plan)
        bad_policy_plan["publicClientPorts"] = [80, 443, 9000, 8080]
        bad_policy_plan_path = root / "bad-policy-cloud-security-group-repair-plan.json"
        bad_policy_plan_path.write_text(json.dumps(bad_policy_plan), encoding="utf-8")
        bad_policy_repair = load_json(repair_receipt)
        bad_policy_repair["plan"] = str(bad_policy_plan_path)
        bad_policy_repair["artifacts"]["plan"] = artifact_record(bad_policy_plan_path)
        bad_policy_repair_path = root / "bad-policy-cloud-security-group-repair-receipt.json"
        bad_policy_repair_path.write_text(json.dumps(bad_policy_repair), encoding="utf-8")
        bad_policy_receipt = json.loads(json.dumps(receipt_payload))
        bad_policy_receipt["policy"]["cloudSecurityGroupRepairReceiptJSON"] = str(bad_policy_repair_path)
        bad_policy_receipt_path = root / "bad-policy-repair-receipt.json"
        bad_policy_receipt_path.write_text(json.dumps(bad_policy_receipt), encoding="utf-8")
        try:
            verify_receipt(bad_policy_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "cloud_security_group_repair_plan_public_client_ports_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_policy_repair_receipt_passed")

        temp_http_receipt = json.loads(json.dumps(receipt_payload))
        temp_http_receipt["policy"]["allowTempHTTP8080"] = True
        temp_http_receipt_path = root / "temp-http-8080-receipt.json"
        temp_http_receipt_path.write_text(json.dumps(temp_http_receipt), encoding="utf-8")
        try:
            verify_receipt(temp_http_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "temp_http_8080_policy_invalid" not in str(exc):
                raise
        else:
            fail("self_test_temp_http_8080_receipt_passed")

        non_root_rules_receipt = json.loads(json.dumps(receipt_payload))
        non_root_rules_receipt["policy"]["cloudSecurityGroupRulesRequireRootOwner"] = False
        non_root_rules_receipt_path = root / "non-root-rules-receipt.json"
        non_root_rules_receipt_path.write_text(json.dumps(non_root_rules_receipt), encoding="utf-8")
        try:
            verify_receipt(non_root_rules_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "cloud_security_group_rules_root_owner_policy_missing" not in str(exc):
                raise
        else:
            fail("self_test_non_root_rules_receipt_passed")

        bad_readiness = json.loads(json.dumps(readiness_payload))
        bad_readiness["evidencePolicy"]["requireCloudSecurityGroupRepairReceipt"] = False
        bad_readiness_path = root / "bad-readiness.json"
        bad_readiness_path.write_text(json.dumps(bad_readiness), encoding="utf-8")
        bad_readiness_receipt = json.loads(json.dumps(receipt_payload))
        bad_readiness_receipt["artifacts"]["readinessJSON"] = str(bad_readiness_path)
        bad_readiness_receipt_path = root / "bad-readiness-receipt.json"
        bad_readiness_receipt_path.write_text(json.dumps(bad_readiness_receipt), encoding="utf-8")
        try:
            verify_receipt(bad_readiness_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "readiness_cloud_security_group_repair_receipt_policy_missing" not in str(exc):
                raise
        else:
            fail("self_test_bad_readiness_repair_policy_passed")

        bad_readiness_temp_http = json.loads(json.dumps(readiness_payload))
        bad_readiness_temp_http["evidencePolicy"]["allowTempHTTP8080"] = True
        bad_readiness_temp_http_path = root / "bad-readiness-temp-http-8080.json"
        bad_readiness_temp_http_path.write_text(json.dumps(bad_readiness_temp_http), encoding="utf-8")
        bad_readiness_temp_http_receipt = json.loads(json.dumps(receipt_payload))
        bad_readiness_temp_http_receipt["artifacts"]["readinessJSON"] = str(bad_readiness_temp_http_path)
        bad_readiness_temp_http_receipt_path = root / "bad-readiness-temp-http-8080-receipt.json"
        bad_readiness_temp_http_receipt_path.write_text(json.dumps(bad_readiness_temp_http_receipt), encoding="utf-8")
        try:
            verify_receipt(bad_readiness_temp_http_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "readiness_temp_http_8080_policy_invalid" not in str(exc):
                raise
        else:
            fail("self_test_bad_readiness_temp_http_8080_passed")

        bad_readiness_non_root_rules = json.loads(json.dumps(readiness_payload))
        bad_readiness_non_root_rules["evidencePolicy"]["cloudSecurityGroupRulesRequireRootOwner"] = False
        bad_readiness_non_root_rules_path = root / "bad-readiness-non-root-rules.json"
        bad_readiness_non_root_rules_path.write_text(json.dumps(bad_readiness_non_root_rules), encoding="utf-8")
        bad_readiness_non_root_rules_receipt = json.loads(json.dumps(receipt_payload))
        bad_readiness_non_root_rules_receipt["artifacts"]["readinessJSON"] = str(bad_readiness_non_root_rules_path)
        bad_readiness_non_root_rules_receipt_path = root / "bad-readiness-non-root-rules-receipt.json"
        bad_readiness_non_root_rules_receipt_path.write_text(json.dumps(bad_readiness_non_root_rules_receipt), encoding="utf-8")
        try:
            verify_receipt(bad_readiness_non_root_rules_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "readiness_cloud_security_group_rules_root_owner_policy_missing" not in str(exc):
                raise
        else:
            fail("self_test_bad_readiness_non_root_rules_passed")

        bad_readiness_operator_network = json.loads(json.dumps(readiness_payload))
        bad_readiness_operator_network["evidencePolicy"]["operatorNetworkPreflight"] = False
        bad_readiness_operator_network_path = root / "bad-readiness-operator-network.json"
        bad_readiness_operator_network_path.write_text(json.dumps(bad_readiness_operator_network), encoding="utf-8")
        bad_readiness_operator_network_receipt = json.loads(json.dumps(receipt_payload))
        bad_readiness_operator_network_receipt["artifacts"]["readinessJSON"] = str(bad_readiness_operator_network_path)
        bad_readiness_operator_network_receipt_path = root / "bad-readiness-operator-network-receipt.json"
        bad_readiness_operator_network_receipt_path.write_text(json.dumps(bad_readiness_operator_network_receipt), encoding="utf-8")
        try:
            verify_receipt(bad_readiness_operator_network_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "readiness_operator_network_policy_missing" not in str(exc):
                raise
        else:
            fail("self_test_bad_readiness_operator_network_policy_passed")

        bad_operator_state = json.loads(state_summary_json.read_text(encoding="utf-8"))
        bad_operator_state["summary"]["currentReadinessOperatorNetworkRouteInterfaces"] = ["utun8"]
        bad_operator_state_path = root / "bad-current-production-state-summary.json"
        bad_operator_state_path.write_text(json.dumps(bad_operator_state), encoding="utf-8")
        bad_operator_state_path.with_suffix(".md").write_text("# Bad State Summary\n", encoding="utf-8")
        bad_operator_state_path.with_suffix(".csv").write_text(
            state_summary_csv.read_text(encoding="utf-8").replace(",en0,192.168.1.1,", ",utun8,192.168.1.1,"),
            encoding="utf-8",
        )
        bad_readiness_operator_state = json.loads(json.dumps(readiness_payload))
        bad_readiness_operator_state["artifacts"]["stateSummary"] = str(root / "bad-current-production-state-summary.md")
        bad_readiness_operator_state_path = root / "bad-readiness-operator-state.json"
        bad_readiness_operator_state_path.write_text(json.dumps(bad_readiness_operator_state), encoding="utf-8")
        bad_readiness_operator_state_receipt = json.loads(json.dumps(receipt_payload))
        bad_readiness_operator_state_receipt["artifacts"]["readinessJSON"] = str(bad_readiness_operator_state_path)
        bad_readiness_operator_state_receipt_path = root / "bad-readiness-operator-state-receipt.json"
        bad_readiness_operator_state_receipt_path.write_text(json.dumps(bad_readiness_operator_state_receipt), encoding="utf-8")
        try:
            verify_receipt(bad_readiness_operator_state_receipt_path, require_pass=True)
        except SystemExit as exc:
            if "readiness_operator_network_state_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_readiness_operator_state_passed")
    print("production_acceptance_verify_self_test result=pass")


def main() -> None:
    global FAIL_REASON_ONLY
    parser = argparse.ArgumentParser(
        description="Verify final production acceptance receipts and production evidence packages.",
    )
    parser.add_argument("--receipt-json", type=Path, help="Production acceptance receipt JSON to verify.")
    parser.add_argument("--package-file", type=Path, help="Production evidence package tarball.")
    parser.add_argument("--evidence-dir", type=Path, help="Installed/extracted evidence directory used as artifact fallback.")
    parser.add_argument(
        "--verify-package-archive",
        action="store_true",
        help="Verify only the evidence package archive, target, README, readiness markdown, and manifest file records.",
    )
    parser.add_argument("--expect-base-url", help="Expected production HTTPS origin for --verify-package-archive.")
    parser.add_argument("--expect-tcp-host", help="Expected production TCP DNS host for --verify-package-archive.")
    parser.add_argument("--expect-tcp-port", help="Expected production TCP port for --verify-package-archive.")
    parser.add_argument("--reason-only", action="store_true", help="Print only the failure reason; intended for shell preflight wrappers.")
    parser.add_argument("--max-age-seconds", type=int, default=86400, help="Maximum accepted receipt age in seconds.")
    parser.add_argument("--max-future-skew-seconds", type=int, default=300, help="Maximum accepted receipt future clock skew in seconds.")
    parser.add_argument("--require-pass", action="store_true", help="Require the receipt status to be PASS.")
    parser.add_argument("--self-test", action="store_true", help="Run verifier self-tests.")
    args = parser.parse_args()
    FAIL_REASON_ONLY = bool(args.reason_only)
    if args.self_test:
        run_self_test()
        return
    if args.verify_package_archive:
        if not args.package_file:
            fail("package_file_required")
        expected_target = {
            "baseURL": str(args.expect_base_url or ""),
            "tcpHost": str(args.expect_tcp_host or ""),
            "tcpPort": str(args.expect_tcp_port or ""),
        }
        if not all(expected_target.values()):
            fail("expected_package_target_required")
        verify_package_archive(args.package_file, expected_target=expected_target)
        if not args.reason_only:
            print(f"production_acceptance_verify result=pass package={args.package_file}")
        return
    if not args.receipt_json:
        fail("receipt_json_required")
    verify_receipt(
        args.receipt_json,
        require_pass=args.require_pass,
        max_age_seconds=args.max_age_seconds,
        max_future_skew_seconds=args.max_future_skew_seconds,
        package_file=args.package_file,
        evidence_dir=args.evidence_dir,
    )


if __name__ == "__main__":
    main()
