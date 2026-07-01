#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import tempfile
import time
from pathlib import Path
from typing import Any

from perf_matrix_audit import list_output_scenarios


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_AUDITED_COMMAND_DOCS = [
    Path(__file__).with_name("run_current_production_readiness.sh"),
    Path(__file__).with_name("run_non_large_group_regression.sh"),
    Path(__file__).with_name("run_production_acceptance.sh"),
    Path(__file__).with_name("run_product_scenario_suite.sh"),
    Path(__file__).with_name("run_product_test_plan.sh"),
]
SCENARIO_GROUPS_RE = re.compile(r'SCENARIO_GROUPS="([^"]+)"')
PRODUCTION_PROFILE_RE = re.compile(r"PERF_PRODUCTION_GATE_PROFILE=([A-Za-z0-9_-]+)")
REQUIRED_PRODUCTION_EVIDENCE_PHRASES = [
    "currentReadinessFullAcceptanceExpectedCampaign",
    "currentReadinessFullAcceptanceCampaign",
    "currentReadinessFullAcceptanceStatus",
    "currentReadinessFullAcceptanceFailures/required/attempted/skipped",
    "CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true",
    "currentReadinessRequestedProductScenarioSuite",
    "currentReadinessProductScenarioSuiteExitCode",
    "currentReadinessProductScenarioSuiteExpected",
    "currentReadinessProductScenarioSuiteStatus",
    "currentReadinessProductScenarioSuiteLargeGroupIncluded",
    "current-production-dashboard.*",
    "current-production-state-summary.*",
    "production-full-acceptance",
    "product-scenario-suite-run.json",
    "product-scenario-suite-run.md",
    "perf_product_scenario_suite_verify.py",
]
REQUIRED_DEPLOY_README_PHRASES = [
    "PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true",
    "PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true",
    "PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=true",
    "CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true",
    "current-production-readiness.json",
    "productScenarioSuite",
    "fullAcceptance",
    "currentReadinessRequestedProductScenarioSuite",
    "currentReadinessProductScenarioSuiteExitCode",
    "currentReadinessProductScenarioSuiteExpected",
    "currentReadinessProductScenarioSuiteStatus",
    "currentReadinessProductScenarioSuiteLargeGroupIncluded",
    "installed current-evidence release",
    "Do not point the timer at temporary external",
]
REQUIRED_PLACEHOLDER_DOMAIN_PHRASES = [
    "All `*.yourdomain.com` targets in examples are replace-before-run placeholders.",
    "Production gates reject literal `yourdomain.com` and `*.yourdomain.com` values",
]
REQUIRED_COMMAND_PLACEHOLDER_NOTICE = "Replace *.yourdomain.com before running; production gates reject literal placeholder domains."
PUBLIC_HTTP_8080_RE = re.compile(r"http://(?!(?:127\.0\.0\.1|localhost)(?::|/|$))(?P<host>(?:<server-public-ip>)|(?:\d{1,3}\.){3}\d{1,3}|[A-Za-z0-9.-]+\.[A-Za-z]{2,}):8080\b")
PLACEHOLDER_PRODUCTION_TARGET_RE = re.compile(
    r"(?:(?:BASE_URL|PUBLIC_BASE_URL|IM_PUBLIC_BASE_URL|TCP_HOST|PERF_PLAN_BASE_URL|PERF_PLAN_TCP_HOST)="
    r"|--base-url\s+|--tcp-host\s+|https://)"
    r"(?P<target>[A-Za-z0-9_.-]*example\.(?:com|net|org))\b"
)
STALE_PUBLIC_IPS = ("47.106.103.10", "120.25.106.200")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"Failed to read {path}: {exc}") from exc


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_profile_names(path: Path) -> set[str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc
    return {str(name) for name in (payload.get("profiles") or {})}


def split_group_value(value: str) -> list[str]:
    if "..." in value:
        return []
    return [item for item in re.split(r"\s+", value.strip()) if item]


def parse_presets_line(readme: str) -> list[str]:
    match = re.search(r"^Presets:\s*(?P<value>.+)$", readme, re.MULTILINE)
    if not match:
        return []
    return [item.strip() for item in match.group("value").split(",") if item.strip()]


def issue(kind: str, severity: str, item: str, detail: str) -> dict[str, str]:
    return {"kind": kind, "severity": severity, "item": item, "detail": detail}


def audit_required_phrases(
    text: str,
    phrases: list[str],
    *,
    kind: str,
    detail: str,
    issues: list[dict[str, str]],
) -> None:
    for phrase in phrases:
        if phrase not in text:
            issues.append(issue(kind, "error", phrase, detail))


def audit_public_http_8080_examples(text: str, *, label: str, issues: list[dict[str, str]]) -> None:
    for match in PUBLIC_HTTP_8080_RE.finditer(text):
        issues.append(issue(
            "public-http-8080-doc",
            "error",
            f"{label}:{match.group(0)}",
            "Production-facing documentation must use HTTPS/domain or HTTP port 80; keep :8080 only for localhost development examples.",
        ))


def audit_stale_public_ip_examples(text: str, *, label: str, issues: list[dict[str, str]]) -> None:
    for stale_ip in STALE_PUBLIC_IPS:
        if stale_ip in text:
            issues.append(issue(
                "stale-public-ip-doc",
                "error",
                f"{label}:{stale_ip}",
                "Production-facing documentation must use a domain/placeholder target, not an old temporary server IP.",
            ))


def audit_placeholder_production_targets(text: str, *, label: str, issues: list[dict[str, str]]) -> None:
    for match in PLACEHOLDER_PRODUCTION_TARGET_RE.finditer(text):
        issues.append(issue(
            "placeholder-production-target-doc",
            "error",
            f"{label}:{match.group('target')}",
            "Production command examples must not use example.com/net/org targets because production gates reject placeholder domains; use a real domain in production and keep literal placeholders replace-before-run.",
        ))


def extract_usage_text(text: str) -> str:
    marker = "Usage:"
    start = text.find(marker)
    if start == -1:
        return text
    remainder = text[start:]
    for terminator in ("\nEOF", "\n}\n", "\nCommon env:", "\nPurpose:"):
        index = remainder.find(terminator)
        if index > 0:
            return remainder[:index]
    return remainder


def audit(
    readme_path: Path,
    matrix_script: Path,
    profile_catalog: Path,
    deploy_readme_path: Path | None,
    audited_command_docs: list[Path] | None = None,
) -> dict[str, Any]:
    readme_path = readme_path.resolve()
    matrix_script = matrix_script.resolve()
    profile_catalog = profile_catalog.resolve()
    deploy_readme_path = deploy_readme_path.resolve() if deploy_readme_path else None
    audited_command_docs = [path.resolve() for path in (audited_command_docs or DEFAULT_AUDITED_COMMAND_DOCS)]
    readme = read_text(readme_path)
    deploy_readme = read_text(deploy_readme_path) if deploy_readme_path else ""
    command_doc_texts = [(path, read_text(path)) for path in audited_command_docs]
    listed_groups, _ = list_output_scenarios(matrix_script)
    listed_group_set = set(listed_groups)
    profile_names = read_profile_names(profile_catalog)
    issues: list[dict[str, str]] = []

    presets = parse_presets_line(readme)
    if not presets:
        issues.append(issue("presets-missing", "error", "Presets", "README must contain a Presets line for scenario groups."))
    elif presets != listed_groups:
        missing = [item for item in listed_groups if item not in presets]
        extra = [item for item in presets if item not in listed_group_set]
        if missing:
            issues.append(issue("presets-missing-groups", "error", ",".join(missing), "Presets line omits scenario groups listed by run_perf_scenarios.sh --list."))
        if extra:
            issues.append(issue("presets-extra-groups", "error", ",".join(extra), "Presets line includes scenario groups not listed by run_perf_scenarios.sh --list."))
        if not missing and not extra:
            issues.append(issue("presets-order", "error", "Presets", "Presets line must match run_perf_scenarios.sh --list order."))
    duplicate_presets = sorted({item for item in presets if presets.count(item) > 1})
    for item in duplicate_presets:
        issues.append(issue("presets-duplicate-group", "error", item, "Scenario group appears more than once in README Presets line."))

    referenced_groups: list[str] = []
    for match in SCENARIO_GROUPS_RE.finditer(readme):
        referenced_groups.extend(split_group_value(match.group(1)))
    for group in sorted(set(referenced_groups) - listed_group_set):
        issues.append(issue("unknown-scenario-group-reference", "error", group, "README references a scenario group not listed by run_perf_scenarios.sh --list."))

    referenced_profiles = sorted(set(PRODUCTION_PROFILE_RE.findall(readme)))
    for profile in referenced_profiles:
        if profile not in profile_names:
            issues.append(issue("unknown-production-profile-reference", "error", profile, "README references a production profile not present in perf_production_profiles.json."))

    audit_required_phrases(
        readme,
        REQUIRED_PRODUCTION_EVIDENCE_PHRASES,
        kind="missing-production-evidence-doc",
        detail="README must document final current-readiness/full-acceptance evidence fields required for production acceptance.",
        issues=issues,
    )
    audit_required_phrases(
        readme,
        REQUIRED_PLACEHOLDER_DOMAIN_PHRASES,
        kind="missing-placeholder-domain-doc",
        detail="README must explain that yourdomain.com targets are replace-before-run placeholders rejected by production gates.",
        issues=issues,
    )
    audit_public_http_8080_examples(readme, label="loadtests-readme", issues=issues)
    audit_stale_public_ip_examples(readme, label="loadtests-readme", issues=issues)
    audit_placeholder_production_targets(readme, label="loadtests-readme", issues=issues)
    if deploy_readme_path:
        audit_required_phrases(
            deploy_readme,
            REQUIRED_DEPLOY_README_PHRASES,
            kind="missing-deploy-production-evidence-doc",
            detail="Deployment README must document the production evidence and current-readiness packageability gates enforced by deploy scripts.",
            issues=issues,
        )
        audit_required_phrases(
            deploy_readme,
            REQUIRED_PLACEHOLDER_DOMAIN_PHRASES,
            kind="missing-deploy-placeholder-domain-doc",
            detail="Deployment README must explain that yourdomain.com targets are replace-before-run placeholders rejected by production gates.",
            issues=issues,
        )
        audit_public_http_8080_examples(deploy_readme, label="deploy-readme", issues=issues)
        audit_stale_public_ip_examples(deploy_readme, label="deploy-readme", issues=issues)
        audit_placeholder_production_targets(deploy_readme, label="deploy-readme", issues=issues)
    for command_doc_path, command_doc in command_doc_texts:
        label = f"command-doc:{command_doc_path.name}"
        usage_text = extract_usage_text(command_doc)
        if "yourdomain.com" in usage_text and REQUIRED_COMMAND_PLACEHOLDER_NOTICE not in usage_text:
            issues.append(issue(
                "missing-command-placeholder-notice",
                "error",
                label,
                "Command usage that includes yourdomain.com must say it is a replace-before-run placeholder rejected by production gates.",
            ))
        audit_public_http_8080_examples(usage_text, label=label, issues=issues)
        audit_stale_public_ip_examples(command_doc, label=label, issues=issues)
        audit_placeholder_production_targets(usage_text, label=label, issues=issues)

    error_count = sum(1 for item in issues if item["severity"] == "error")
    warning_count = sum(1 for item in issues if item["severity"] == "warning")
    inputs = {
        "readme": {"path": str(readme_path), "sha256": sha256_file(readme_path)},
        "matrixScript": {"path": str(matrix_script), "sha256": sha256_file(matrix_script)},
        "profileCatalog": {"path": str(profile_catalog), "sha256": sha256_file(profile_catalog)},
    }
    if deploy_readme_path:
        inputs["deployReadme"] = {"path": str(deploy_readme_path), "sha256": sha256_file(deploy_readme_path)}
    inputs["auditedCommandDocs"] = [
        {"path": str(path), "sha256": sha256_file(path)}
        for path in audited_command_docs
    ]
    return {
        "schemaVersion": 1,
        "status": "PASS" if error_count == 0 else "FAIL",
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "readme": str(readme_path),
        "deployReadme": str(deploy_readme_path) if deploy_readme_path else "",
        "matrixScript": str(matrix_script),
        "profileCatalog": str(profile_catalog),
        "inputs": inputs,
        "listedGroupCount": len(listed_groups),
        "presetsGroupCount": len(presets),
        "referencedScenarioGroupCount": len(set(referenced_groups)),
        "referencedProductionProfileCount": len(referenced_profiles),
        "deployEvidencePhraseCount": len(REQUIRED_DEPLOY_README_PHRASES) if deploy_readme_path else 0,
        "auditedCommandDocCount": len(audited_command_docs),
        "errorCount": error_count,
        "warningCount": warning_count,
        "issues": issues,
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


def build_markdown(payload: dict[str, Any]) -> str:
    issue_rows = [["Severity", "Kind", "Item", "Detail"]]
    for row in payload["issues"]:
        issue_rows.append([row["severity"], row["kind"], f"`{row['item']}`", row["detail"]])
    return "\n".join([
        "# Performance Docs Audit",
        "",
        f"- status: `{payload['status']}`",
        f"- readme: `{payload['readme']}`",
        f"- deployReadme: `{payload.get('deployReadme') or '-'}`",
        f"- matrixScript: `{payload['matrixScript']}`",
        f"- profileCatalog: `{payload['profileCatalog']}`",
        f"- listed groups: `{payload['listedGroupCount']}`",
        f"- presets groups: `{payload['presetsGroupCount']}`",
        f"- referenced scenario groups: `{payload['referencedScenarioGroupCount']}`",
        f"- referenced production profiles: `{payload['referencedProductionProfileCount']}`",
        f"- deploy evidence phrases: `{payload.get('deployEvidencePhraseCount') or 0}`",
        f"- audited command docs: `{payload.get('auditedCommandDocCount') or 0}`",
        f"- errors/warnings: `{payload['errorCount']}/{payload['warningCount']}`",
        "",
        "## Issues",
        "",
        markdown_table(issue_rows) if payload["issues"] else "No documentation consistency issues found.",
        "",
    ])


def fail(reason: str, **fields: Any) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"docs_audit result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def verify_json(
    audit_json: Path,
    readme_path: Path,
    matrix_script: Path,
    profile_catalog: Path,
    deploy_readme_path: Path | None,
    audited_command_docs: list[Path] | None = None,
) -> None:
    try:
        actual = json.loads(audit_json.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", path=audit_json, error=exc)
    expected = audit(readme_path, matrix_script, profile_catalog, deploy_readme_path, audited_command_docs)
    if int(actual.get("schemaVersion") or 0) != 1:
        fail("invalid_schema", path=audit_json)
    for key in (
        "status",
        "listedGroupCount",
        "presetsGroupCount",
        "referencedScenarioGroupCount",
        "referencedProductionProfileCount",
        "deployEvidencePhraseCount",
        "auditedCommandDocCount",
        "errorCount",
        "warningCount",
    ):
        if actual.get(key) != expected.get(key):
            fail("field_mismatch", path=audit_json, field=key, expected=expected.get(key), actual=actual.get(key))
    actual_inputs = actual.get("inputs") or {}
    expected_inputs = expected.get("inputs") or {}
    for name in expected_inputs:
        if isinstance(expected_inputs[name], list):
            actual_items = actual_inputs.get(name) or []
            if not isinstance(actual_items, list) or len(actual_items) != len(expected_inputs[name]):
                fail("input_count_mismatch", path=audit_json, input=name, expected=len(expected_inputs[name]), actual=len(actual_items) if isinstance(actual_items, list) else "-")
            for index, expected_item in enumerate(expected_inputs[name]):
                actual_item = actual_items[index] if index < len(actual_items) and isinstance(actual_items[index], dict) else {}
                actual_sha = str(actual_item.get("sha256") or "")
                expected_sha = str(expected_item.get("sha256") or "")
                if not actual_sha or actual_sha != expected_sha:
                    fail("input_sha_mismatch", path=audit_json, input=f"{name}[{index}]", expected=expected_sha or "-", actual=actual_sha or "-")
        else:
            actual_sha = str((actual_inputs.get(name) or {}).get("sha256") or "")
            expected_sha = str((expected_inputs.get(name) or {}).get("sha256") or "")
            if not actual_sha or actual_sha != expected_sha:
                fail("input_sha_mismatch", path=audit_json, input=name, expected=expected_sha or "-", actual=actual_sha or "-")
    if actual.get("issues") != expected.get("issues"):
        fail("issues_mismatch", path=audit_json)


def verify_markdown(audit_json: Path, markdown_path: Path) -> None:
    try:
        payload = json.loads(audit_json.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", path=audit_json, error=exc)
    try:
        markdown = markdown_path.read_text(encoding="utf-8")
    except Exception as exc:
        fail("invalid_markdown", path=markdown_path, error=exc)
    required_fragments = [
        "# Performance Docs Audit",
        f"- status: `{payload.get('status')}`",
        f"- readme: `{payload.get('readme')}`",
        f"- deployReadme: `{payload.get('deployReadme') or '-'}`",
        f"- matrixScript: `{payload.get('matrixScript')}`",
        f"- profileCatalog: `{payload.get('profileCatalog')}`",
        f"- listed groups: `{payload.get('listedGroupCount')}`",
        f"- presets groups: `{payload.get('presetsGroupCount')}`",
        f"- referenced scenario groups: `{payload.get('referencedScenarioGroupCount')}`",
        f"- referenced production profiles: `{payload.get('referencedProductionProfileCount')}`",
        f"- deploy evidence phrases: `{payload.get('deployEvidencePhraseCount') or 0}`",
        f"- audited command docs: `{payload.get('auditedCommandDocCount') or 0}`",
        f"- errors/warnings: `{payload.get('errorCount')}/{payload.get('warningCount')}`",
        "## Issues",
    ]
    for fragment in required_fragments:
        if fragment not in markdown:
            fail("markdown_summary_mismatch", path=markdown_path, fragment=fragment)
    issues = payload.get("issues") or []
    if issues:
        for row in issues:
            if not isinstance(row, dict):
                continue
            issue_fragments = [
                str(row.get("severity") or ""),
                str(row.get("kind") or ""),
                f"`{row.get('item') or ''}`",
                str(row.get("detail") or ""),
            ]
            for fragment in issue_fragments:
                if fragment and fragment not in markdown:
                    fail(
                        "markdown_issue_mismatch",
                        path=markdown_path,
                        kind=row.get("kind") or "-",
                        fragment=fragment,
                    )
    elif "No documentation consistency issues found." not in markdown:
        fail("markdown_no_issues_mismatch", path=markdown_path)


def write_self_test_matrix(path: Path) -> None:
    content = """#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--list" ]]; then
  echo "Available scenario groups:"
  echo "normal-product-smoke"
  echo "daily-core"
  echo "Available scenarios:"
  echo "login-smoke"
  exit 0
fi
exit 0
"""
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def self_test_readme(*, group: str = "normal-product-smoke", profile: str = "normal-product-baseline", extra: str = "") -> str:
    phrases = "\n".join(REQUIRED_PRODUCTION_EVIDENCE_PHRASES + REQUIRED_PLACEHOLDER_DOMAIN_PHRASES)
    return "\n".join([
        "# Load Test README",
        "",
        "Presets: normal-product-smoke, daily-core",
        f'SCENARIO_GROUPS="{group}"',
        f"PERF_PRODUCTION_GATE_PROFILE={profile}",
        phrases,
        extra,
        "",
    ])


def self_test_deploy_readme(extra: str = "") -> str:
    phrases = "\n".join(REQUIRED_DEPLOY_README_PHRASES + REQUIRED_PLACEHOLDER_DOMAIN_PHRASES)
    return "\n".join([
        "# Deploy README",
        "",
        phrases,
        extra,
        "",
    ])


def self_test_command_doc(extra: str = "") -> str:
    return "\n".join([
        "#!/usr/bin/env bash",
        "# Usage:",
        "# BASE_URL=https://chat.yourdomain.com TCP_HOST=tcp.yourdomain.com ./run.sh",
        f"# {REQUIRED_COMMAND_PLACEHOLDER_NOTICE}",
        extra,
        "",
    ])


def self_test_paths(root: Path) -> tuple[Path, Path, Path, Path, Path]:
    readme = root / "README.md"
    deploy_readme = root / "deploy-README.md"
    matrix = root / "run_perf_scenarios.sh"
    profiles = root / "perf_production_profiles.json"
    command_doc = root / "run_production_acceptance.sh"
    readme.write_text(self_test_readme(), encoding="utf-8")
    deploy_readme.write_text(self_test_deploy_readme(), encoding="utf-8")
    write_self_test_matrix(matrix)
    write_json(profiles, {"schemaVersion": 1, "profiles": {"normal-product-baseline": ["login-smoke"]}})
    command_doc.write_text(self_test_command_doc(), encoding="utf-8")
    return readme, deploy_readme, matrix, profiles, command_doc


def expect_self_test_issue(payload: dict[str, Any], kind: str, label: str) -> None:
    kinds = {str(row.get("kind") or "") for row in payload.get("issues") or [] if isinstance(row, dict)}
    if payload.get("status") != "FAIL" or kind not in kinds:
        raise SystemExit(f"docs_audit_self_test result=fail reason={label} status={payload.get('status')} kinds={sorted(kinds)}")


def expect_self_test_verify_failure(func: Any, label: str, expected: str) -> None:
    try:
        func()
    except SystemExit as exc:
        message = str(exc)
        if expected not in message:
            raise SystemExit(f"docs_audit_self_test result=fail reason={label}_wrong_error error={message}") from exc
        return
    raise SystemExit(f"docs_audit_self_test result=fail reason={label}_passed")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="docs-audit-self-test-") as raw_root:
        root = Path(raw_root)
        readme, deploy_readme, matrix, profiles, command_doc = self_test_paths(root)
        payload = audit(readme, matrix, profiles, deploy_readme, [command_doc])
        if payload.get("status") != "PASS":
            raise SystemExit(f"docs_audit_self_test result=fail reason=good_docs_failed issues={payload.get('issues')}")
        json_path = root / "docs-audit.json"
        markdown_path = root / "docs-audit.md"
        write_json(json_path, payload)
        markdown_path.write_text(build_markdown(payload), encoding="utf-8")
        verify_json(json_path, readme, matrix, profiles, deploy_readme, [command_doc])
        verify_markdown(json_path, markdown_path)

        bad_md = root / "docs-audit-bad.md"
        bad_md.write_text(markdown_path.read_text(encoding="utf-8").replace("- status: `PASS`", "- auditStatus: `PASS`"), encoding="utf-8")
        expect_self_test_verify_failure(
            lambda: verify_markdown(json_path, bad_md),
            "self_test_markdown_summary_mismatch",
            "markdown_summary_mismatch",
        )

        bad_json = root / "docs-audit-bad-input.json"
        bad_payload = json.loads(json_path.read_text(encoding="utf-8"))
        bad_payload["inputs"]["readme"]["sha256"] = "0" * 64
        write_json(bad_json, bad_payload)
        expect_self_test_verify_failure(
            lambda: verify_json(bad_json, readme, matrix, profiles, deploy_readme, [command_doc]),
            "self_test_input_sha_mismatch",
            "input_sha_mismatch",
        )

        readme.write_text(self_test_readme(group="missing-group"), encoding="utf-8")
        expect_self_test_issue(
            audit(readme, matrix, profiles, deploy_readme, [command_doc]),
            "unknown-scenario-group-reference",
            "self_test_unknown_group_rejected",
        )

        readme.write_text(self_test_readme(profile="missing-profile"), encoding="utf-8")
        expect_self_test_issue(
            audit(readme, matrix, profiles, deploy_readme, [command_doc]),
            "unknown-production-profile-reference",
            "self_test_unknown_profile_rejected",
        )

        readme.write_text(self_test_readme(extra="BASE_URL=http://chat.yourdomain.com:8080"), encoding="utf-8")
        expect_self_test_issue(
            audit(readme, matrix, profiles, deploy_readme, [command_doc]),
            "public-http-8080-doc",
            "self_test_public_8080_rejected",
        )

        readme.write_text(self_test_readme(extra="Temporary server 47.106.103.10"), encoding="utf-8")
        expect_self_test_issue(
            audit(readme, matrix, profiles, deploy_readme, [command_doc]),
            "stale-public-ip-doc",
            "self_test_stale_public_ip_rejected",
        )

        readme.write_text(self_test_readme(extra="BASE_URL=https://chat.example.com"), encoding="utf-8")
        expect_self_test_issue(
            audit(readme, matrix, profiles, deploy_readme, [command_doc]),
            "placeholder-production-target-doc",
            "self_test_example_domain_rejected",
        )

    print("docs_audit_self_test result=pass")


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    fieldnames = ["severity", "kind", "item", "detail"]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit performance load-test documentation against executable scenario metadata.")
    parser.add_argument("--readme", default=str(Path(__file__).with_name("README.md")))
    parser.add_argument("--deploy-readme", default=str(REPO_ROOT / "deploy" / "ubuntu" / "README.md"))
    parser.add_argument(
        "--audited-command-doc",
        action="append",
        default=None,
        help="Additional production command/help script to scan for stale public targets. Can be passed more than once.",
    )
    parser.add_argument("--matrix-script", default=str(Path(__file__).with_name("run_perf_scenarios.sh")))
    parser.add_argument("--profile-catalog", default=str(Path(__file__).with_name("perf_production_profiles.json")))
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    parser.add_argument("--verify-json")
    parser.add_argument("--verify-md")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    audited_command_docs = [Path(path) for path in args.audited_command_doc] if args.audited_command_doc is not None else None

    if args.self_test:
        run_self_test()
        return 0

    if args.verify_json:
        verify_json(
            Path(args.verify_json),
            Path(args.readme),
            Path(args.matrix_script),
            Path(args.profile_catalog),
            Path(args.deploy_readme) if args.deploy_readme else None,
            audited_command_docs,
        )
        if args.verify_md:
            verify_markdown(Path(args.verify_json), Path(args.verify_md))
        print(f"docs_audit result=pass action=verify path={args.verify_json}")
        return 0

    payload = audit(
        Path(args.readme),
        Path(args.matrix_script),
        Path(args.profile_catalog),
        Path(args.deploy_readme) if args.deploy_readme else None,
        audited_command_docs,
    )
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    if args.output and args.json_output:
        verify_markdown(Path(args.json_output), Path(args.output))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["issues"])
    return 1 if args.strict and payload["status"] != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main())
