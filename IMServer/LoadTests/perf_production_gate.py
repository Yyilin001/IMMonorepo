#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import ipaddress
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


PROFILE_CATALOG_PATH = Path(__file__).with_name("perf_production_profiles.json")
REPO_ROOT = Path(__file__).resolve().parents[2]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_value(args: list[str], default: str = "unknown") -> str:
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=REPO_ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return default
    value = completed.stdout.strip()
    return value if value else default


def git_dirty() -> bool:
    return bool(git_value(["status", "--porcelain"], default=""))


def load_profile_catalog(path: Path = PROFILE_CATALOG_PATH) -> dict[str, Any]:
    payload = read_json(path)
    if int(payload.get("schemaVersion") or 0) != 1:
        raise SystemExit(f"Invalid production profile catalog schemaVersion: {path}")
    profiles = payload.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        raise SystemExit(f"Invalid production profile catalog profiles: {path}")
    for profile, scenarios in profiles.items():
        if not isinstance(profile, str) or not profile:
            raise SystemExit(f"Invalid production profile name in catalog: {path}")
        if not isinstance(scenarios, list) or not scenarios:
            raise SystemExit(f"Invalid production profile scenarios for {profile}: {path}")
        seen: set[str] = set()
        for scenario in scenarios:
            if not isinstance(scenario, str) or not scenario:
                raise SystemExit(f"Invalid scenario in production profile {profile}: {path}")
            if scenario in seen:
                raise SystemExit(f"Duplicate scenario {scenario} in production profile {profile}: {path}")
            seen.add(scenario)
    return payload


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


PROFILE_CATALOG = load_profile_catalog()
PROFILES = {
    str(profile): [str(scenario) for scenario in scenarios]
    for profile, scenarios in (PROFILE_CATALOG.get("profiles") or {}).items()
}


def index_scenarios(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(row.get("scenario") or ""): row
        for row in payload.get("scenarios") or []
        if row.get("scenario")
    }


def status_for(row: dict[str, Any] | None) -> str:
    if row is None:
        return "MISSING"
    status = str(row.get("latestSLOStatus") or "")
    return status if status else "UNKNOWN"


def public_host_policy_reason(host: str) -> str:
    value = host.strip().lower().strip("[]")
    if not value:
        return "missing_host"
    if value in {"localhost", "ip6-localhost"} or value.endswith(".local"):
        return "local_host"
    try:
        ipaddress.ip_address(value)
        return "ip_literal"
    except ValueError:
        pass
    if "." not in value:
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
    if value in placeholder_hosts or any(value.endswith(suffix) for suffix in placeholder_suffixes):
        return "placeholder_domain"
    return "ok"


def validate_target_filter(target_filter: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if not target_filter.get("enabled"):
        errors.append("targetFilter.enabled=false")

    base_url = str(target_filter.get("baseURL") or "")
    parsed = urlparse(base_url)
    if parsed.scheme != "https":
        errors.append(f"targetFilter.baseURL.scheme={parsed.scheme or '<empty>'}")
    base_host_reason = public_host_policy_reason(parsed.hostname or "")
    if base_host_reason != "ok":
        errors.append(f"targetFilter.baseURL.host={base_host_reason}")

    tcp_host_reason = public_host_policy_reason(str(target_filter.get("tcpHost") or ""))
    if tcp_host_reason != "ok":
        errors.append(f"targetFilter.tcpHost={tcp_host_reason}")

    tcp_port = str(target_filter.get("tcpPort") or "")
    if not tcp_port.isdigit() or int(tcp_port) <= 0:
        errors.append(f"targetFilter.tcpPort={tcp_port or '<empty>'}")
    return errors


def verify_run_artifacts(row: dict[str, Any] | None, scenario: str) -> tuple[bool, str]:
    if row is None:
        return False, "scenario is required but absent from slo-status.json"
    latest_run_dir = str(row.get("latestRunDir") or "")
    if not latest_run_dir:
        return False, "latest SLO is PASS but no latestRunDir was recorded"
    run_dir = Path(latest_run_dir)
    if not run_dir.is_dir():
        return False, f"latestRunDir is missing or not a directory: {latest_run_dir}"
    missing: list[str] = []
    for artifact in ("slo.json", "report.json"):
        if not (run_dir / artifact).is_file():
            missing.append(artifact)
    scenario_dir = run_dir / scenario
    if not scenario_dir.is_dir():
        missing.append(f"{scenario}/")
    else:
        for artifact in ("scenario.json", "command.sh", "exit-code.txt"):
            if not (scenario_dir / artifact).is_file():
                missing.append(f"{scenario}/{artifact}")
    if missing:
        return False, "latest run artifact missing: " + ", ".join(missing[:5])
    return True, ""


def evidence_age_failure(
    latest_mtime: float,
    generated_at_epoch: int,
    max_age_seconds: int,
    future_skew_seconds: int,
) -> tuple[str, str]:
    if max_age_seconds <= 0:
        return "", ""
    if latest_mtime <= 0:
        return "missing_evidence_time", "latest evidence timestamp is missing while max evidence age is required"
    if latest_mtime > generated_at_epoch + future_skew_seconds:
        return (
            "evidence_time_in_future",
            f"latest evidence timestamp is in the future: latestMtime={int(latest_mtime)} generatedAtEpoch={generated_at_epoch}",
        )
    age_seconds = int(generated_at_epoch - latest_mtime)
    if age_seconds > max_age_seconds:
        return (
            "evidence_stale",
            f"latest evidence is stale: ageSeconds={age_seconds} maxAgeSeconds={max_age_seconds}",
        )
    return "", ""


def failure_kind(source: dict[str, Any] | None, latest_status: str, has_runtime: bool, artifact_ok: bool, evidence_age_kind: str = "") -> str:
    if source is None:
        return "missing_scenario"
    if evidence_age_kind:
        return evidence_age_kind
    if latest_status == "PASS" and not has_runtime:
        return "missing_runtime_evidence"
    if latest_status != "PASS":
        if not has_runtime and latest_status in {"UNKNOWN", "NEVER_RUN", ""}:
            return "missing_runtime_evidence"
        return "slo_not_pass"
    if not artifact_ok:
        return "artifact_missing"
    return ""


def evaluate(args: argparse.Namespace) -> dict[str, Any]:
    payload = read_json(Path(args.slo_status_json))
    target_filter = payload.get("targetFilter") or {}
    target_filter_errors = validate_target_filter(target_filter)
    by_scenario = index_scenarios(payload)
    required = list(PROFILES[args.profile])
    for scenario in args.require_scenario:
        if scenario not in required:
            required.append(scenario)
    max_age_seconds = int(args.max_evidence_age_seconds or 0)
    future_skew_seconds = int(args.future_skew_seconds or 0)
    if max_age_seconds < 0:
        raise SystemExit(f"production_gate result=fail reason=invalid_max_evidence_age value={max_age_seconds}")
    if future_skew_seconds < 0:
        raise SystemExit(f"production_gate result=fail reason=invalid_future_skew value={future_skew_seconds}")
    generated_at_epoch = int(time.time())

    rows: list[dict[str, Any]] = []
    for scenario in required:
        source = by_scenario.get(scenario)
        latest_status = status_for(source)
        run_count = int((source or {}).get("runCount") or 0)
        has_runtime = run_count > 0 and bool((source or {}).get("latestRunID"))
        latest_mtime = float((source or {}).get("latestMtime") or 0)
        artifact_ok = True
        artifact_reason = ""
        if bool(args.require_run_artifacts) and latest_status == "PASS" and has_runtime:
            artifact_ok, artifact_reason = verify_run_artifacts(source, scenario)
        evidence_age_kind = ""
        evidence_age_reason = ""
        if latest_status == "PASS" and has_runtime:
            evidence_age_kind, evidence_age_reason = evidence_age_failure(
                latest_mtime,
                generated_at_epoch,
                max_age_seconds,
                future_skew_seconds,
            )
        passed = latest_status == "PASS" and has_runtime and artifact_ok and not evidence_age_kind
        if source is None:
            reason = "scenario is required but absent from slo-status.json"
        elif latest_status != "PASS":
            reason = str(source.get("latestReason") or source.get("latestAction") or f"latest SLO is {latest_status}")
        elif not has_runtime:
            reason = "latest SLO is PASS but no runtime run ID was recorded"
        elif not artifact_ok:
            reason = artifact_reason
        elif evidence_age_reason:
            reason = evidence_age_reason
        else:
            reason = ""
        kind = "" if passed else failure_kind(source, latest_status, has_runtime, artifact_ok, evidence_age_kind)
        age_seconds = int(generated_at_epoch - latest_mtime) if latest_mtime > 0 else None
        rows.append({
            "scenario": scenario,
            "category": str((source or {}).get("category") or ""),
            "requiredStatus": "PASS",
            "latestSLOStatus": latest_status,
            "latestScenarioStatus": str((source or {}).get("latestScenarioStatus") or ""),
            "runCount": run_count,
            "latestRunID": str((source or {}).get("latestRunID") or ""),
            "latestRunDir": str((source or {}).get("latestRunDir") or ""),
            "latestMtime": latest_mtime,
            "latestEvidenceAgeSeconds": age_seconds,
            "latestHTTPP99Ms": (source or {}).get("latestHTTPP99Ms"),
            "latestDeliveryP99Ms": (source or {}).get("latestDeliveryP99Ms"),
            "runArtifactsVerified": bool(args.require_run_artifacts),
            "runArtifactsOK": artifact_ok,
            "passed": passed,
            "failureKind": kind,
            "reason": reason,
        })

    missing = sum(1 for row in rows if row["latestSLOStatus"] == "MISSING")
    failed = [row for row in rows if not row["passed"]]
    failure_kind_counts: dict[str, int] = {}
    for row in failed:
        kind = str(row.get("failureKind") or "unknown")
        failure_kind_counts[kind] = failure_kind_counts.get(kind, 0) + 1
    if target_filter_errors:
        failure_kind_counts["target_filter_invalid"] = len(target_filter_errors)
    evidence_mtimes = [
        float(row.get("latestMtime") or 0)
        for row in rows
        if float(row.get("latestMtime") or 0) > 0
    ]
    oldest_mtime = min(evidence_mtimes) if evidence_mtimes else 0
    newest_mtime = max(evidence_mtimes) if evidence_mtimes else 0
    return {
        "status": "PASS" if not failed and not target_filter_errors else "FAIL",
        "profile": args.profile,
        "sloStatusJson": str(args.slo_status_json),
        "targetFilter": {
            "enabled": bool(target_filter.get("enabled")),
            "baseURL": str(target_filter.get("baseURL") or ""),
            "tcpHost": str(target_filter.get("tcpHost") or ""),
            "tcpPort": str(target_filter.get("tcpPort") or ""),
        },
        "profileCatalog": {
            "path": str(PROFILE_CATALOG_PATH),
            "schemaVersion": int(PROFILE_CATALOG.get("schemaVersion") or 0),
            "sha256": sha256_file(PROFILE_CATALOG_PATH),
        },
        "source": {
            "repoRoot": str(REPO_ROOT),
            "gitCommit": git_value(["rev-parse", "--verify", "HEAD"]),
            "gitBranch": git_value(["branch", "--show-current"]),
            "gitDirty": git_dirty(),
        },
        "generatedAt": datetime.fromtimestamp(generated_at_epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z"),
        "generatedAtEpoch": generated_at_epoch,
        "summary": {
            "requiredScenarioCount": len(rows),
            "passedScenarioCount": len(rows) - len(failed),
            "failedScenarioCount": len(failed),
            "missingScenarioCount": missing,
            "failureKindCounts": failure_kind_counts,
            "targetFilterInvalidCount": len(target_filter_errors),
            "targetFilterErrors": target_filter_errors,
            "missingRuntimeEvidenceCount": int(failure_kind_counts.get("missing_runtime_evidence") or 0),
            "sloNotPassCount": int(failure_kind_counts.get("slo_not_pass") or 0),
            "artifactMissingCount": int(failure_kind_counts.get("artifact_missing") or 0),
            "evidenceStaleCount": int(failure_kind_counts.get("evidence_stale") or 0),
            "evidenceTimeInFutureCount": int(failure_kind_counts.get("evidence_time_in_future") or 0),
            "missingEvidenceTimeCount": int(failure_kind_counts.get("missing_evidence_time") or 0),
            "evidenceOldestMtime": oldest_mtime,
            "evidenceNewestMtime": newest_mtime,
            "evidenceOldestAgeSeconds": int(generated_at_epoch - oldest_mtime) if oldest_mtime else None,
            "evidenceNewestAgeSeconds": int(generated_at_epoch - newest_mtime) if newest_mtime else None,
            "runArtifactMissingCount": sum(
                1
                for row in rows
                if row.get("latestSLOStatus") == "PASS"
                and row.get("runCount", 0) > 0
                and not row.get("runArtifactsOK")
            ),
        },
        "requirements": {
            "runArtifacts": bool(args.require_run_artifacts),
            "maxEvidenceAgeSeconds": max_age_seconds,
            "futureSkewSeconds": future_skew_seconds,
        },
        "requiredScenarios": rows,
    }


def markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""
    lines = [
        "| " + " | ".join(rows[0]) + " |",
        "| " + " | ".join(["---"] * len(rows[0])) + " |",
    ]
    for row in rows[1:]:
        lines.append("| " + " | ".join(cell.replace("\n", " ") for cell in row) + " |")
    return "\n".join(lines)


def fmt_ms(value: Any) -> str:
    if value is None:
        return "-"
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return str(value)
    if parsed.is_integer():
        return f"{int(parsed)}ms"
    return f"{parsed:.1f}ms"


def build_markdown(payload: dict[str, Any]) -> str:
    summary = payload["summary"]
    target_filter = payload.get("targetFilter") or {}
    failure_kind_counts = summary.get("failureKindCounts") or {}
    failure_kind_text = ", ".join(
        f"{kind}={count}" for kind, count in sorted(failure_kind_counts.items())
    ) or "-"
    rows = [["Scenario", "Category", "SLO", "Failure Kind", "Runs", "Latest Run", "HTTP P99", "Delivery P99", "Reason"]]
    for row in payload["requiredScenarios"]:
        rows.append([
            f"`{row['scenario']}`",
            f"`{row['category'] or '-'}`",
            "`PASS`" if row["passed"] else f"`{row['latestSLOStatus']}`",
            f"`{row.get('failureKind') or '-'}`",
            str(row["runCount"]),
            str(row["latestRunID"] or "-"),
            fmt_ms(row.get("latestHTTPP99Ms")),
            fmt_ms(row.get("latestDeliveryP99Ms")),
            str(row.get("reason") or "-")[:180],
        ])

    return "\n".join([
        "# Production Performance Gate",
        "",
        f"- status: `{payload['status']}`",
        f"- profile: `{payload['profile']}`",
        f"- required scenarios: `{summary['requiredScenarioCount']}`",
        f"- passed/failed/missing: `{summary['passedScenarioCount']}/{summary['failedScenarioCount']}/{summary['missingScenarioCount']}`",
        f"- failure kinds: `{failure_kind_text}`",
        f"- run artifact verification: `{'required' if payload.get('requirements', {}).get('runArtifacts') else 'not-required'}`",
        f"- run artifact missing: `{summary.get('runArtifactMissingCount') or 0}`",
        f"- max evidence age: `{payload.get('requirements', {}).get('maxEvidenceAgeSeconds') or 'disabled'}`",
        f"- evidence age oldest/newest: `{summary.get('evidenceOldestAgeSeconds') if summary.get('evidenceOldestAgeSeconds') is not None else '-'}/{summary.get('evidenceNewestAgeSeconds') if summary.get('evidenceNewestAgeSeconds') is not None else '-'}` seconds",
        f"- target filter: `{'enabled' if target_filter.get('enabled') else 'disabled'}`",
        f"- baseURL: `{target_filter.get('baseURL') or '-'}`",
        f"- tcpHost: `{target_filter.get('tcpHost') or '-'}`",
        f"- tcpPort: `{target_filter.get('tcpPort') or '-'}`",
        f"- target filter errors: `{', '.join(summary.get('targetFilterErrors') or []) or '-'}`",
        f"- sloStatusJson: `{payload['sloStatusJson']}`",
        "",
        "This gate is intentionally stricter than the exploratory matrix reports. It",
        "requires the selected production evidence profile to have latest real SLO",
        "`PASS` results, so one successful large-group run cannot stand in for normal",
        "product workflows.",
        "",
        "## Required Scenarios",
        "",
        markdown_table(rows),
        "",
    ])


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = [
        "scenario",
        "category",
        "requiredStatus",
        "latestSLOStatus",
            "latestScenarioStatus",
            "runCount",
            "latestRunID",
            "latestRunDir",
            "latestMtime",
            "latestEvidenceAgeSeconds",
            "latestHTTPP99Ms",
            "latestDeliveryP99Ms",
            "runArtifactsVerified",
            "runArtifactsOK",
            "passed",
            "failureKind",
            "reason",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key) for key in fieldnames})


def main() -> int:
    parser = argparse.ArgumentParser(description="Gate production performance evidence against a required scenario profile.")
    parser.add_argument("--slo-status-json", required=True)
    parser.add_argument("--profile", choices=sorted(PROFILES), default="normal-product-baseline")
    parser.add_argument("--require-scenario", action="append", default=[], help="Add one extra required scenario. May be repeated.")
    parser.add_argument("--require-run-artifacts", action="store_true", help="Require latestRunDir and key per-run/per-scenario artifacts for every passing required scenario.")
    parser.add_argument("--max-evidence-age-seconds", type=int, default=0, help="Fail required scenarios whose latest evidence is older than this many seconds. 0 disables the freshness check.")
    parser.add_argument("--future-skew-seconds", type=int, default=300, help="Allow this many seconds of clock skew before treating evidence timestamps as future-dated.")
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    args = parser.parse_args()

    payload = evaluate(args)
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown, end="")
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["requiredScenarios"])
    return 0 if payload["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
