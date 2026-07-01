#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path
from typing import Any


VALID_STATUSES = {"PASS", "FAIL", "PLANNED"}
VALID_STAGE_STATUSES = {"PASS", "FAIL", "PLANNED"}


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", path=path, error=exc)


def fail(reason: str, **fields: Any) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"product_scenario_suite_verify result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def bool_value(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "on"}
    return bool(value)


def ensure_text_contains(path: Path, needle: str, label: str) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail("markdown_read_failed", path=path, error=exc)
    if needle not in text:
        fail("markdown_missing_value", path=path, label=label, value=needle)


def artifact_path(value: Any, base: Path | None) -> Path | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    path = Path(raw)
    if path.is_absolute() or base is None:
        return path
    return (base / path).resolve()


def verify_rescue_artifact(item: dict[str, Any], receipt_base: Path | None) -> None:
    status = str(item.get("entrypointRescueStatus") or "")
    if status != "PASS":
        return
    stage = str(item.get("stage") or "-")
    tarball = artifact_path(item.get("entrypointRescueTarball"), receipt_base)
    if tarball is None:
        fail("rescue_tarball_missing", stage=stage)
    if not tarball.is_file():
        fail("rescue_tarball_not_found", stage=stage, tarball=tarball)
    for suffix, label in (
        (".verify.sh", "verify_script"),
        (".sha256", "sha256"),
        (".receipt.json", "receipt"),
    ):
        sidecar = Path(f"{tarball}{suffix}")
        if not sidecar.is_file():
            fail("rescue_tarball_sidecar_missing", stage=stage, sidecar=sidecar, label=label)


def verify(
    payload: dict[str, Any],
    markdown_path: Path | None,
    *,
    receipt_base: Path | None,
    require_pass: bool,
    allow_planned: bool,
    require_no_large_group: bool,
) -> None:
    if int(payload.get("schemaVersion") or 0) != 1:
        fail("invalid_schema", schema=payload.get("schemaVersion"))

    suite = str(payload.get("suite") or "")
    status = str(payload.get("status") or "")
    reason = str(payload.get("reason") or "")
    if not suite:
        fail("missing_suite")
    if status not in VALID_STATUSES:
        fail("invalid_status", status=status or "-")
    if not reason:
        fail("missing_reason")
    if require_pass and status != "PASS":
        fail("status_not_pass", status=status, suiteReason=reason)
    if status == "PLANNED" and not allow_planned:
        fail("planned_not_allowed", suite=suite)

    settings = payload.get("settings")
    if not isinstance(settings, dict):
        fail("missing_settings")
    execute = bool_value(settings.get("execute"))
    include_large_group = bool_value(settings.get("includeLargeGroup"))
    if require_no_large_group and include_large_group:
        fail("large_group_not_allowed", suite=suite)
    if include_large_group and suite != "full":
        fail("large_group_opt_in_invalid_for_suite", suite=suite)
    if suite == "full" and not include_large_group:
        fail("full_suite_missing_large_group_opt_in")

    target = payload.get("target")
    if not isinstance(target, dict):
        fail("missing_target")
    for field in ("baseURL", "tcpHost", "tcpPort"):
        if not str(target.get(field) or ""):
            fail("missing_target_field", field=field)

    stages = payload.get("stages")
    if not isinstance(stages, list) or not stages:
        fail("missing_stages")
    if int(payload.get("stageCount") or 0) != len(stages):
        fail("stage_count_mismatch", expected=len(stages), actual=payload.get("stageCount"))

    stage_coverage = payload.get("stageCoverage")
    if not isinstance(stage_coverage, list):
        fail("missing_stage_coverage")
    if len(stage_coverage) != len(stages):
        fail("stage_coverage_count_mismatch", expected=len(stages), actual=len(stage_coverage))
    coverage_summary = payload.get("coverageSummary")
    if not isinstance(coverage_summary, dict):
        fail("missing_coverage_summary")
    if int(coverage_summary.get("stageCount") or 0) != len(stages):
        fail("coverage_stage_count_mismatch", expected=len(stages), actual=coverage_summary.get("stageCount"))
    if int(coverage_summary.get("coverageErrorCount") or 0) != 0:
        fail("coverage_error_count_nonzero", actual=coverage_summary.get("coverageErrorCount"))
    if require_no_large_group and bool_value(coverage_summary.get("largeGroupIncluded")):
        fail("coverage_large_group_not_allowed", suite=suite)

    failed_count = 0
    planned_count = 0
    stage_ids: set[str] = set()
    for index, stage in enumerate(stages, start=1):
        if not isinstance(stage, dict):
            fail("invalid_stage", index=index)
        stage_id = str(stage.get("id") or "")
        runner = str(stage.get("runner") or "")
        value = str(stage.get("value") or "")
        stage_status = str(stage.get("status") or "")
        if not stage_id or not runner or not value:
            fail("stage_missing_identity", index=index)
        if stage_id in stage_ids:
            fail("duplicate_stage", stage=stage_id)
        stage_ids.add(stage_id)
        if stage_status not in VALID_STAGE_STATUSES:
            fail("invalid_stage_status", stage=stage_id, status=stage_status or "-")
        if stage_status == "FAIL":
            failed_count += 1
        if stage_status == "PLANNED":
            planned_count += 1
        exit_code = stage.get("exitCode")
        if stage_status == "PASS" and exit_code not in (0, None):
            fail("pass_stage_exit_code_invalid", stage=stage_id, exitCode=exit_code)
        if stage_status == "FAIL" and (not isinstance(exit_code, int) or exit_code == 0):
            fail("fail_stage_exit_code_invalid", stage=stage_id, exitCode=exit_code)
        if stage_status == "PLANNED" and exit_code is not None:
            fail("planned_stage_exit_code_invalid", stage=stage_id, exitCode=exit_code)
        if require_no_large_group and ("large-group" in stage_id or "large-group" in value):
            fail("large_group_stage_not_allowed", stage=stage_id, value=value)

    coverage_by_stage: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(stage_coverage, start=1):
        if not isinstance(item, dict):
            fail("invalid_stage_coverage", index=index)
        stage_id = str(item.get("stage") or "")
        if not stage_id:
            fail("stage_coverage_missing_stage", index=index)
        if stage_id in coverage_by_stage:
            fail("duplicate_stage_coverage", stage=stage_id)
        coverage_by_stage[stage_id] = item
        if str(item.get("coverageStatus") or "") != "READY":
            fail("stage_coverage_not_ready", stage=stage_id, status=item.get("coverageStatus"))
        if require_no_large_group and bool_value(item.get("largeGroupIncluded")):
            fail("stage_coverage_large_group_not_allowed", stage=stage_id)
    if set(coverage_by_stage) != stage_ids:
        fail("stage_coverage_stage_mismatch", expected=sorted(stage_ids), actual=sorted(coverage_by_stage))

    product_plan_stage_count = 0
    for stage in stages:
        if str(stage.get("runner") or "") != "product-plan":
            continue
        product_plan_stage_count += 1
        coverage = coverage_by_stage.get(str(stage.get("id") or "")) or {}
        if int(coverage.get("uniqueScenarioCount") or 0) <= 0:
            fail("product_plan_stage_coverage_empty", stage=stage.get("id"))
        covered_domains = coverage.get("coveredProductDomains")
        if not isinstance(covered_domains, list) or not covered_domains:
            fail("product_plan_stage_domains_empty", stage=stage.get("id"))
        selected = coverage.get("selectedScenarios")
        if not isinstance(selected, list) or not selected:
            fail("product_plan_stage_scenarios_empty", stage=stage.get("id"))
    if int(coverage_summary.get("productPlanStageCount") or 0) != product_plan_stage_count:
        fail("coverage_product_plan_stage_count_mismatch", expected=product_plan_stage_count, actual=coverage_summary.get("productPlanStageCount"))
    if product_plan_stage_count > 0 and int(coverage_summary.get("uniqueScenarioCount") or 0) <= 0:
        fail("coverage_unique_scenarios_empty")

    if int(payload.get("failedStageCount") or 0) != failed_count:
        fail("failed_stage_count_mismatch", expected=failed_count, actual=payload.get("failedStageCount"))
    if int(payload.get("plannedStageCount") or 0) != planned_count:
        fail("planned_stage_count_mismatch", expected=planned_count, actual=payload.get("plannedStageCount"))

    failure_summary = payload.get("failureSummary")
    if not isinstance(failure_summary, list):
        fail("missing_failure_summary")
    if len(failure_summary) != failed_count:
        fail("failure_summary_count_mismatch", expected=failed_count, actual=len(failure_summary))
    failed_stage_ids = {str(stage.get("id") or "") for stage in stages if str(stage.get("status") or "") == "FAIL"}
    for index, item in enumerate(failure_summary, start=1):
        if not isinstance(item, dict):
            fail("invalid_failure_summary_item", index=index)
        stage_id = str(item.get("stage") or "")
        if stage_id not in failed_stage_ids:
            fail("failure_summary_unknown_stage", index=index, stage=stage_id or "-")
        if not str(item.get("artifact") or ""):
            fail("failure_summary_missing_artifact", stage=stage_id)
        verify_rescue_artifact(item, receipt_base)

    if status == "PASS" and (failed_count or planned_count):
        fail("pass_status_has_non_pass_stages", failed=failed_count, planned=planned_count)
    if status == "FAIL" and failed_count == 0:
        fail("fail_status_without_failed_stage")
    if status == "PLANNED" and planned_count != len(stages):
        fail("planned_status_requires_all_stages_planned", planned=planned_count, stages=len(stages))
    if status == "PLANNED" and execute:
        fail("planned_status_execute_true")

    if markdown_path is not None:
        ensure_text_contains(markdown_path, f"- suite: `{suite}`", "suite")
        ensure_text_contains(markdown_path, f"- status: `{status}`", "status")
        ensure_text_contains(markdown_path, "## Coverage", "coverage-section")
        for stage in stages:
            ensure_text_contains(markdown_path, f"`{stage['id']}`", f"stage:{stage['id']}")


def self_test_payload(*, include_large_group: bool = False) -> dict[str, Any]:
    stage_id = "large-group-send" if include_large_group else "direct-message-lifecycle"
    value = "large-group-1000" if include_large_group else "direct-message"
    suite = "full" if include_large_group else "normal"
    return {
        "schemaVersion": 1,
        "suite": suite,
        "status": "PASS",
        "reason": "all stages passed",
        "settings": {
            "execute": True,
            "includeLargeGroup": include_large_group,
        },
        "target": {
            "baseURL": "https://chat.example.com",
            "tcpHost": "tcp.chat.example.com",
            "tcpPort": 9000,
        },
        "stageCount": 1,
        "failedStageCount": 0,
        "plannedStageCount": 0,
        "stages": [
            {
                "id": stage_id,
                "runner": "product-plan",
                "value": value,
                "status": "PASS",
                "exitCode": 0,
            }
        ],
        "stageCoverage": [
            {
                "stage": stage_id,
                "coverageStatus": "READY",
                "largeGroupIncluded": include_large_group,
                "uniqueScenarioCount": 1,
                "coveredProductDomains": ["messaging"],
                "selectedScenarios": [value],
            }
        ],
        "coverageSummary": {
            "stageCount": 1,
            "coverageErrorCount": 0,
            "largeGroupIncluded": include_large_group,
            "productPlanStageCount": 1,
            "uniqueScenarioCount": 1,
        },
        "failureSummary": [],
    }


def self_test_markdown(payload: dict[str, Any]) -> str:
    stage_ids = [str(stage.get("id") or "") for stage in payload.get("stages") or []]
    lines = [
        "# Product Scenario Suite",
        "",
        f"- suite: `{payload.get('suite')}`",
        f"- status: `{payload.get('status')}`",
        "",
        "## Coverage",
        "",
    ]
    lines.extend(f"- `{stage_id}`" for stage_id in stage_ids)
    return "\n".join(lines) + "\n"


def expect_self_test_failure(label: str, action: Any, expected_reason: str) -> None:
    try:
        action()
    except SystemExit as exc:
        message = str(exc)
        if expected_reason not in message:
            raise SystemExit(f"{label}_wrong_failure reason={message}") from exc
        return
    raise SystemExit(f"{label}_did_not_fail")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        payload = self_test_payload()
        markdown_path = root / "product-scenario-suite-run.md"
        markdown_path.write_text(self_test_markdown(payload), encoding="utf-8")
        verify(
            payload,
            markdown_path,
            receipt_base=root,
            require_pass=True,
            allow_planned=False,
            require_no_large_group=True,
        )

        missing_coverage = json.loads(json.dumps(payload))
        missing_coverage["stageCoverage"] = []
        expect_self_test_failure(
            "self_test_stage_coverage_missing",
            lambda: verify(
                missing_coverage,
                markdown_path,
                receipt_base=root,
                require_pass=True,
                allow_planned=False,
                require_no_large_group=True,
            ),
            "stage_coverage_count_mismatch",
        )

        large_group_payload = self_test_payload(include_large_group=True)
        large_group_markdown = root / "product-scenario-suite-large.md"
        large_group_markdown.write_text(self_test_markdown(large_group_payload), encoding="utf-8")
        expect_self_test_failure(
            "self_test_large_group_not_allowed",
            lambda: verify(
                large_group_payload,
                large_group_markdown,
                receipt_base=root,
                require_pass=True,
                allow_planned=False,
                require_no_large_group=True,
            ),
            "large_group_not_allowed",
        )

        bad_markdown_path = root / "product-scenario-suite-bad.md"
        bad_markdown_path.write_text("# Product Scenario Suite\n", encoding="utf-8")
        expect_self_test_failure(
            "self_test_markdown_missing_coverage",
            lambda: verify(
                payload,
                bad_markdown_path,
                receipt_base=root,
                require_pass=True,
                allow_planned=False,
                require_no_large_group=True,
            ),
            "markdown_missing_value",
        )
    print("product_scenario_suite_verify_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite-run-json")
    parser.add_argument("--markdown")
    parser.add_argument("--require-pass", action="store_true")
    parser.add_argument("--allow-planned", action="store_true")
    parser.add_argument("--require-no-large-group", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    if not args.suite_run_json:
        parser.error("--suite-run-json is required unless --self-test is used")

    suite_run_path = Path(args.suite_run_json)
    payload = read_json(suite_run_path)
    markdown_path = Path(args.markdown) if args.markdown else None
    verify(
        payload,
        markdown_path,
        receipt_base=suite_run_path.parent,
        require_pass=args.require_pass,
        allow_planned=args.allow_planned,
        require_no_large_group=args.require_no_large_group,
    )
    print(f"product_scenario_suite_verify result=pass suite={payload.get('suite')} status={payload.get('status')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
