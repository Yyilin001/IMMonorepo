#!/usr/bin/env python3
from __future__ import annotations

import argparse
import tempfile
from pathlib import Path
from typing import Iterable


def fail(reason: str, **fields: object) -> None:
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"production_evidence_recovery_paths result=fail reason={reason}"
    if detail:
        message = f"{message} {detail}"
    raise SystemExit(message)


def canonical_path(value: str) -> Path:
    return Path(value).expanduser().resolve()


def verify_unique(paths: Iterable[tuple[str, str]], *, group: str) -> dict[Path, str]:
    seen: dict[Path, str] = {}
    for label, value in paths:
        path = canonical_path(value)
        previous = seen.get(path)
        if previous is not None:
            fail(
                f"{group}_artifact_path_conflict",
                label=label,
                conflictsWith=previous,
                path=path,
            )
        seen[path] = label
    return seen


def verify_paths(strict_paths: list[tuple[str, str]], diagnostic_paths: list[tuple[str, str]]) -> None:
    strict_seen = verify_unique(strict_paths, group="strict")
    diagnostic_seen = verify_unique(diagnostic_paths, group="diagnostic")
    for diagnostic_path, diagnostic_label in diagnostic_seen.items():
        strict_label = strict_seen.get(diagnostic_path)
        if strict_label is not None:
            fail(
                "diagnostic_artifact_conflicts_with_strict",
                label=diagnostic_label,
                conflictsWith=strict_label,
                path=diagnostic_path,
            )


def strict_args(args: argparse.Namespace) -> list[tuple[str, str]]:
    return [
        ("strict completion status JSON", args.strict_completion_status_json),
        ("strict completion status Markdown", args.strict_completion_status_markdown),
        ("strict recovery plan JSON", args.strict_recovery_plan_json),
        ("strict recovery plan Markdown", args.strict_recovery_plan_markdown),
        ("strict recovery script", args.strict_recovery_script),
    ]


def diagnostic_args(args: argparse.Namespace) -> list[tuple[str, str]]:
    return [
        ("diagnostic completion status JSON", args.diagnostic_completion_status_json),
        ("diagnostic completion status Markdown", args.diagnostic_completion_status_markdown),
        ("diagnostic recovery plan JSON", args.diagnostic_recovery_plan_json),
        ("diagnostic recovery plan Markdown", args.diagnostic_recovery_plan_markdown),
        ("diagnostic recovery script", args.diagnostic_recovery_script),
    ]


def expect_exit(label: str, reason: str, fn: object) -> None:
    try:
        fn()
    except SystemExit as error:
        if reason not in str(error):
            raise
        print(label)
        return
    fail("self_test_expected_failure_missing", label=label)


def self_test() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        strict = [
            ("strict completion status JSON", str(root / "strict/latest.json")),
            ("strict completion status Markdown", str(root / "strict/latest.md")),
            ("strict recovery plan JSON", str(root / "strict/recovery.json")),
            ("strict recovery plan Markdown", str(root / "strict/recovery.md")),
            ("strict recovery script", str(root / "strict/recovery.sh")),
        ]
        diagnostic = [
            ("diagnostic completion status JSON", str(root / "diagnostic/latest.json")),
            ("diagnostic completion status Markdown", str(root / "diagnostic/latest.md")),
            ("diagnostic recovery plan JSON", str(root / "diagnostic/recovery.json")),
            ("diagnostic recovery plan Markdown", str(root / "diagnostic/recovery.md")),
            ("diagnostic recovery script", str(root / "diagnostic/recovery.sh")),
        ]
        verify_paths(strict, diagnostic)
        strict_duplicate = list(strict)
        strict_duplicate[2] = ("strict recovery plan JSON", str(root / "./strict/latest.json"))
        expect_exit(
            "self_test_strict_artifact_path_conflict",
            "strict_artifact_path_conflict",
            lambda: verify_paths(strict_duplicate, diagnostic),
        )
        diagnostic_duplicate = list(diagnostic)
        diagnostic_duplicate[2] = ("diagnostic recovery plan JSON", str(root / "./diagnostic/latest.json"))
        expect_exit(
            "self_test_diagnostic_artifact_path_conflict",
            "diagnostic_artifact_path_conflict",
            lambda: verify_paths(strict, diagnostic_duplicate),
        )
        diagnostic_cross = list(diagnostic)
        diagnostic_cross[0] = ("diagnostic completion status JSON", str(root / "./strict/recovery.json"))
        expect_exit(
            "self_test_diagnostic_artifact_conflicts_with_strict",
            "diagnostic_artifact_conflicts_with_strict",
            lambda: verify_paths(strict, diagnostic_cross),
        )
    print("production_evidence_recovery_paths_self_test result=pass")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Verify strict and diagnostic production evidence recovery paths are isolated.")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--strict-completion-status-json")
    parser.add_argument("--strict-completion-status-markdown")
    parser.add_argument("--strict-recovery-plan-json")
    parser.add_argument("--strict-recovery-plan-markdown")
    parser.add_argument("--strict-recovery-script")
    parser.add_argument("--diagnostic-completion-status-json")
    parser.add_argument("--diagnostic-completion-status-markdown")
    parser.add_argument("--diagnostic-recovery-plan-json")
    parser.add_argument("--diagnostic-recovery-plan-markdown")
    parser.add_argument("--diagnostic-recovery-script")
    return parser


def require_args(args: argparse.Namespace) -> None:
    required = [
        "strict_completion_status_json",
        "strict_completion_status_markdown",
        "strict_recovery_plan_json",
        "strict_recovery_plan_markdown",
        "strict_recovery_script",
        "diagnostic_completion_status_json",
        "diagnostic_completion_status_markdown",
        "diagnostic_recovery_plan_json",
        "diagnostic_recovery_plan_markdown",
        "diagnostic_recovery_script",
    ]
    missing = [name for name in required if not getattr(args, name)]
    if missing:
        fail("missing_argument", field=missing[0])


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    require_args(args)
    verify_paths(strict_args(args), diagnostic_args(args))
    print("production_evidence_recovery_paths result=pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
