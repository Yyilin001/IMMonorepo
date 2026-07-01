#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from production_static_gate_receipt import DEFAULT_COMPLETION_STATUS_JSON as DEFAULT_STATIC_COMPLETION_STATUS_JSON
from production_static_gate_receipt import DEFAULT_COMPLETION_STATUS_MARKDOWN as DEFAULT_STATIC_COMPLETION_STATUS_MARKDOWN
from production_static_gate_receipt import DEFAULT_RECEIPT_JSON as DEFAULT_STATIC_GATE_RECEIPT_JSON
from production_static_gate_receipt import DEFAULT_RECOVERY_PLAN_JSON as DEFAULT_STATIC_RECOVERY_PLAN_JSON
from production_static_gate_receipt import DEFAULT_RECOVERY_PLAN_MARKDOWN as DEFAULT_STATIC_RECOVERY_PLAN_MARKDOWN
from production_static_gate_receipt import DEFAULT_RECOVERY_PLAN_SCRIPT as DEFAULT_STATIC_RECOVERY_PLAN_SCRIPT
from production_static_gate_receipt import receipt_payload as static_gate_receipt_payload
from production_static_gate_receipt import verify_receipt as verify_static_gate_receipt


@dataclass(frozen=True)
class LocalCheck:
    item: str
    path: str
    description: str
    contains: tuple[str, ...] = ()
    executable: bool = False


@dataclass(frozen=True)
class EvidenceCheck:
    item: str
    path_env: str
    description: str
    required_json: tuple[tuple[str, str], ...] = ()


MAX_FINAL_ASSERTION_ARCHIVE_MANIFEST_BYTES = 4 * 1024 * 1024


LOCAL_CHECKS: tuple[LocalCheck, ...] = (
    LocalCheck("make-static-gate", "Makefile", "local production static gate", ("validate-production-static:", "verify-production-static-receipt:")),
    LocalCheck("make-deep-gate", "Makefile", "local production gate suite", ("validate-production-gates:",)),
    LocalCheck("make-readiness-status", "Makefile", "operator readiness status entrypoint", ("production-readiness-status:",)),
    LocalCheck("make-final-assertion", "Makefile", "final production-ready assertion entrypoint", ("assert-production-ready:",)),
    LocalCheck("make-assertion-verifier", "Makefile", "final assertion verifier entrypoint", ("verify-production-ready-assertion:",)),
    LocalCheck("make-archive-verifier", "Makefile", "self-contained archive verifier entrypoint", ("verify-production-ready-archive:",)),
    LocalCheck("make-evidence-recovery-plan", "Makefile", "live evidence recovery plan entrypoint", ("production-evidence-recovery-plan:",)),
    LocalCheck("make-evidence-recovery-plan-verifier", "Makefile", "live evidence recovery plan verifier entrypoint", ("verify-production-evidence-recovery-plan:",)),
    LocalCheck(
        "make-evidence-recovery-env-validator",
        "Makefile",
        "operator live evidence recovery environment validator",
        (
            "validate-production-evidence-recovery-env:",
            "$(MAKE) --no-print-directory verify-production-static-receipt >/dev/null",
            "$(MAKE) --no-print-directory verify-production-evidence-recovery-plan >/dev/null",
            "PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true bash \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)\"",
        ),
    ),
    LocalCheck(
        "make-completion-status-markdown",
        "Makefile",
        "operator-readable production completion status report",
        (
            "PRODUCTION_COMPLETION_STATUS_MD",
            "--markdown-output \"$(PRODUCTION_COMPLETION_STATUS_MD)\"",
            "--markdown-report \"$(PRODUCTION_COMPLETION_STATUS_MD)\"",
        ),
    ),
    LocalCheck("make-ops-gates", "Makefile", "operations gate entrypoints", ("check-production-ops:", "run-operational-audit:",)),
    LocalCheck("make-backup-restore", "Makefile", "backup and restore drill entrypoints", ("create-backup-single-node:", "verify-backup:", "run-restore-drill:")),
    LocalCheck("make-product-scenarios", "Makefile", "product scenario test entrypoints", ("run-product-scenario-suite:", "run-product-test-plan:")),
    LocalCheck("static-workflow", ".github/workflows/production-static-gate.yml", "CI static production gate", ("make validate-production-static",)),
    LocalCheck("deep-workflow", ".github/workflows/production-gates-validation.yml", "CI deep production gate", ("make validate-production-gates",)),
    LocalCheck("release-workflow", ".github/workflows/imserver-production-release-gate.yml", "server release gate workflow", ("production_release_gate.sh",)),
    LocalCheck("smoke-workflow", ".github/workflows/imserver-production-smoke.yml", "production topology smoke workflow", ("make run-imserver-production-smoke",)),
    LocalCheck("readiness-status-script", "IMServer/LoadTests/production_readiness_status.sh", "operator-facing evidence preflight", ("production_readiness_status",), True),
    LocalCheck("current-readiness-script", "IMServer/LoadTests/run_current_production_readiness.sh", "current production readiness runner", ("current-production-readiness",), True),
    LocalCheck(
        "acceptance-env-validator",
        "IMServer/LoadTests/validate_production_acceptance_env.sh",
        "production acceptance env validator",
        (
            "PRODUCTION_ACCEPTANCE_ENV_MODE",
            "MAX_PACKAGE_ARCHIVE_MEMBER_BYTES",
            "MAX_PACKAGE_ARCHIVE_TOTAL_BYTES",
            "MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES",
            "archive_member_sha256(",
            "production_evidence_package_member_too_large",
            "production_evidence_package_total_too_large",
            "production_evidence_package_text_member_too_large",
            "self_test_package_archive_full_read_hash_detected",
        ),
        True,
    ),
    LocalCheck("acceptance-runner", "IMServer/LoadTests/run_production_acceptance.sh", "production acceptance runner", ("production-acceptance",), True),
    LocalCheck("acceptance-verifier", "IMServer/LoadTests/verify_production_acceptance.sh", "production acceptance verifier", ("verify_production_acceptance",), True),
    LocalCheck(
        "assertion-script",
        "IMServer/LoadTests/assert_production_ready.sh",
        "final no-shortcut assertion",
        (
            "assert_production_ready",
            "PRODUCTION_DEPLOY_READINESS_VERIFIER",
            "productionDeployReadinessVerifier",
            "productionClaim",
            "verified-final-production-evidence",
            "self_test_assertion_receipt_claim_allowed",
        ),
        True,
    ),
    LocalCheck(
        "assertion-verifier",
        "IMServer/LoadTests/verify_production_ready_assertion.py",
        "final assertion verifier",
        (
            "imserver-production-ready-assertion",
            "verify_topology_smoke_artifact(",
            "verify_deploy_readiness_artifact(",
            "verify_static_gate_artifact(",
            "require_completion_status=True",
            "require_recovery_plan=True",
            "require_clean_git=True",
            "support_roots=[str(path.parent / \"support\")]",
            "completionStatusMarkdown",
            "prefer_support_roots=args.require_static_gate_support_root",
            "require_support_root=args.require_static_gate_support_root",
            "prefer_artifact_roots=args.require_static_gate_support_root",
            "artifact_root_candidates(",
            "require_json_int(",
            "--require-static-gate-support-root",
            "TARGET_POLICY_PATH",
            "require_public_production_target(",
            "production_target_policy_invalid",
            "static_gate_target_values(",
            "require_static_gate_local_only_claim(",
            "require_final_production_claim(",
            "final_production_claim(",
            "verified-final-production-evidence",
            "production_static_gate_target_mismatch",
            "production_static_gate_claim_mismatch",
            "production_static_gate_git_dirty",
            "production_claim_missing",
            "production_claim_mismatch",
            "bad-production-claim",
            "schema-version-string",
            "generated-at-string",
            "artifact-bytes-string",
            "verify_current_readiness_artifact(",
            "verify_production_acceptance_artifact(",
            "verify_package_archive(",
            "topology_smoke_receipt_invalid",
            "production_deploy_readiness_receipt_invalid",
            "production_static_gate_receipt_invalid",
            "current_readiness_receipt_invalid",
            "production_acceptance_receipt_invalid",
            "production_acceptance_package_binding_invalid",
            "production_evidence_package_invalid",
            "productionTarget",
            "bad-topology-smoke",
            "bad-deploy-readiness",
            "bad-static-gate",
            "bad-static-gate-missing-recovery-plan",
            "bad-static-gate-target",
            "bad-static-gate-claim",
            "bad-static-gate-dirty-git",
            "recovery_plan_missing",
            "portable_support_tamper_passed",
            "portable_support_tamper_reason_missing",
            "bad-current-readiness",
            "bad-production-acceptance",
            "bad-production-acceptance-package-binding",
            "production-acceptance-package-bytes-string",
            "bad-production-evidence-package",
            "bad-public-target",
            "--fail-reason-only",
            "fail_reason_only_missing_reason",
            "fail_reason_only_prefix_leaked",
        ),
    ),
    LocalCheck(
        "assertion-packager",
        "IMServer/LoadTests/package_production_ready_assertion.py",
        "final assertion archive packager",
        (
            "--verify-archive",
            "safe_extract_archive",
            "MAX_ARCHIVE_MEMBER_BYTES",
            "MAX_ARCHIVE_TOTAL_BYTES",
            "archive_member_too_large",
            "archive_total_too_large",
            "oversized_member_archive_passed",
            "archive_total_limit_passed",
            "archive_manifest_target_mismatch",
            "archive_manifest_production_claim_mismatch",
            "bad_target_manifest_archive_passed",
            "bad_claim_manifest_archive_passed",
            "run_verifier_command(",
            "SENSITIVE_BEARER_OUTPUT_PATTERN",
            "SENSITIVE_VERIFIER_OUTPUT_PATTERN",
            "verifier_output_secret_leaked",
            "verifier_output_redaction_missing",
            "spaced-secret",
            "json-token",
            "live-bearer-token",
            "source_receipt_verify_failed",
            "archive_assertion_verify_failed",
            "packaged_assertion_verify_failed",
            "bad_source_receipt_verifier_output_missing",
            "STATIC_GATE_SUPPORT_ARTIFACTS",
            "completionStatusMarkdown",
            "copy_static_gate_support_files(",
            "require_json_int(",
            "ARCHIVE_STATIC_GATE_REPO_ROOT",
            "replace_string_value(",
            "rewrite_static_gate_support_files_for_archive(",
            "verify_archived_static_gate_support_payloads(",
            "rewrite_static_gate_receipt_for_archive(",
            "verify_archived_static_gate_receipt_support_paths(",
            "archive_manifest_static_gate_support_missing",
            "static_gate_support_missing",
            "archive_static_gate_host_path",
            "archive_static_gate_support_host_path",
            "archive_static_gate_support_markdown_host_path",
            "archive_static_gate_support_text_host_path",
            "archive_static_gate_support_source_status_mismatch",
            "archived_static_gate_target(",
            "archive_static_gate_target_missing",
            "archive_static_gate_recovery_target_mismatch",
            "archived_static_gate_claim(",
            "verify_archived_static_gate_claim(",
            "archive_static_gate_claim_mismatch",
            "archive_static_gate_recovery_claim_mismatch",
            "archived_static_gate_readiness_tiers(",
            "verify_archived_static_gate_readiness_tiers(",
            "archive_static_gate_readiness_tiers_missing",
            "archive_static_gate_readiness_tiers_mismatch",
            "archive_static_gate_recovery_readiness_tiers_mismatch",
            "bad_static_recovery_target_archive_passed",
            "bad_static_recovery_target_type_archive_passed",
            "bad_static_recovery_claim_archive_passed",
            "bad_static_recovery_claim_type_archive_passed",
            "bad_static_recovery_readiness_tiers_extra_field_archive_passed",
            "bad_static_recovery_readiness_tiers_type_archive_passed",
            "bad_static_recovery_readiness_tiers_archive_passed",
            "archive_manifest_artifacts_key_mismatch",
            "archive_assertion_artifacts_key_mismatch",
            "bad_extra_artifact_key_archive_passed",
            "archive_manifest_assertion_artifact_mismatch",
            "bad_manifest_artifact_archive_passed",
            "support_completion_repo_root_not_portable",
            "support_completion_json_not_portable",
            "support_completion_markdown_not_portable",
            "support_recovery_source_status_not_portable",
            "archive_static_gate_support_path_mismatch",
            "archive_static_gate_support_sha_mismatch",
            "static_gate_path_not_portable",
            "bad_static_gate_sha_archive_passed",
            "FORBIDDEN_MANIFEST_HOST_PATH_FIELDS",
            "verify_manifest_has_no_host_paths(",
            "archive_manifest_host_path_field",
            "require_manifest_file_name(",
            "archive_manifest_file_name_invalid",
            "require_manifest_generated_at(",
            "archive_manifest_generated_at_future",
            "archive_manifest_generated_at_epoch_invalid",
            "archive_manifest_generated_at_mismatch",
            "require_manifest_not_before_assertion(",
            "archive_assertion_generated_at_epoch_invalid",
            "archive_manifest_before_assertion",
            "archived_assertion_payload(",
            "verify_archived_assertion_has_no_host_paths(",
            "archive_assertion_host_path",
            "archive_assertion_artifact_path_invalid",
            "archived_assertion_path_not_portable",
            "sourceReceiptFileName",
            "archiveName",
            "REQUIRED_ARCHIVE_README_PHRASES",
            "verify_archive_readme(",
            "archive_readme_phrase_missing",
            "archive_readme_field_mismatch",
            "verify_archive_manifest_file_set(",
            "archive_manifest_readme_record_invalid",
            "archive_manifest_file_extra",
            "--require-static-gate-support-root",
            "artifacts/productionStaticGateReceipt/support/",
            "do not rely on original host paths",
            "manifest_host_path_leak",
            "bad_assertion_host_path_archive_passed",
            "bad_assertion_host_path_archive_reason_missing",
            "bad_static_gate_host_path_archive_passed",
            "bad_static_gate_host_path_archive_reason_missing",
            "bad_static_claim_archive_passed",
            "bad_static_claim_archive_reason_missing",
            "bad_static_readiness_tiers_archive_passed",
            "bad_static_readiness_tiers_archive_reason_missing",
            "bad_static_support_host_path_archive_passed",
            "bad_static_support_host_path_archive_reason_missing",
            "bad_static_support_markdown_host_path_archive_passed",
            "bad_static_support_markdown_host_path_archive_reason_missing",
            "bad_static_support_recovery_markdown_host_path_archive_passed",
            "bad_static_support_recovery_markdown_host_path_archive_reason_missing",
            "bad_static_support_recovery_script_host_path_archive_passed",
            "bad_static_support_recovery_script_host_path_archive_reason_missing",
            "bad_host_path_archive_passed",
            "bad_host_path_archive_reason_missing",
            "bad_source_receipt_file_name_archive_passed",
            "bad_source_receipt_file_name_archive_reason_missing",
            "bad_archive_name_archive_passed",
            "bad_archive_name_archive_reason_missing",
            "bad_manifest_schema_string_archive_passed",
            "bad_manifest_generated_at_string_archive_passed",
            "bad_assertion_generated_at_string_archive_passed",
            "bad_manifest_assertion_bytes_string_archive_passed",
            "bad_manifest_artifact_bytes_string_archive_passed",
            "bad_static_support_bytes_string_archive_passed",
            "bad_manifest_future_archive_passed",
            "bad_manifest_future_archive_reason_missing",
            "bad_manifest_time_mismatch_archive_passed",
            "bad_manifest_time_mismatch_archive_reason_missing",
            "bad_manifest_before_assertion_archive_passed",
            "bad_manifest_before_assertion_archive_reason_missing",
            "bad_readme_archive_passed",
            "bad_readme_archive_reason_missing",
            "bad_readme_target_archive_passed",
            "bad_readme_target_archive_reason_missing",
            "extra_file_archive_passed",
            "extra_file_archive_reason_missing",
            "bad_static_support_archive_passed",
            "bad_static_support_archive_reason_missing",
            "valid_deploy_readiness_payload()",
            "valid_topology_smoke_payload(",
            "valid_static_gate_payload(",
            "valid_current_readiness_payload(",
            "valid_production_acceptance_payload(",
            "valid_production_evidence_package(",
        ),
    ),
    LocalCheck(
        "forbidden-artifacts-helper",
        "IMServer/LoadTests/perf_forbidden_artifacts.py",
        "shared forbidden runtime artifact classifier",
        (
            "def forbidden_runtime_artifact_kinds(",
            "def is_forbidden_runtime_artifact(",
            "def self_test(",
            "perf_forbidden_artifacts_self_test result=pass",
            "token_cache_artifact",
            "account_artifact",
            "env_artifact",
        ),
    ),
    LocalCheck(
        "secret-scanner",
        "IMServer/LoadTests/perf_secret_scan.py",
        "production evidence secret scanner",
        (
            "perf_secret_scan_self_test result=pass",
            "from perf_forbidden_artifacts import forbidden_runtime_artifact_kinds",
            "private_key_marker",
            "sensitive_key_value",
            "symlink_artifact",
            "special_file_artifact",
        ),
    ),
    LocalCheck(
        "production-acceptance-verifier",
        "IMServer/LoadTests/perf_production_acceptance_verify.py",
        "production acceptance and evidence package verifier",
        (
            "production_acceptance_verify_self_test result=pass",
            "from perf_forbidden_artifacts import is_forbidden_runtime_artifact",
            "MAX_PACKAGE_ARCHIVE_MEMBER_BYTES",
            "MAX_PACKAGE_ARCHIVE_TOTAL_BYTES",
            "MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES",
            "archive_member_sha256(",
            "validate_package_archive_member(",
            "package_archive_member_too_large",
            "package_archive_total_too_large",
            "package_archive_text_member_too_large",
            "package_manifest_file_record_bytes_invalid",
            "self_test_archive_member_hash_full_read_detected",
            "self_test_archive_text_member_limit_passed",
            "self_test_manifest_bytes_string_package_passed",
            "self_test_package_archive_oversized_member_passed",
            "self_test_package_archive_total_limit_passed",
            "package_archive_forbidden_artifact",
            "package_manifest_forbidden_artifact",
            "self_test_account_artifact_package_passed",
        ),
    ),
    LocalCheck(
        "current-readiness-verifier",
        "IMServer/LoadTests/perf_current_production_readiness_verify.py",
        "current production readiness artifact verifier",
        (
            "current_production_readiness_verify_self_test result=pass",
            "require_state_production_evidence_blocker_contract(",
            "require_operator_network_state_consistency(",
            "target_mismatch_not_detected",
        ),
    ),
    LocalCheck(
        "production-evidence-manifest",
        "IMServer/LoadTests/perf_evidence_manifest.py",
        "production evidence manifest generator and verifier",
        (
            "evidence_manifest_self_test result=pass",
            "def run_self_test()",
            "iter_payload_files(root)",
            "sha256_file(payload)",
            "self_test_payload_files_mismatch",
        ),
    ),
    LocalCheck(
        "matrix-audit-verifier",
        "IMServer/LoadTests/perf_matrix_audit.py",
        "performance scenario matrix audit verifier",
        (
            "matrix_audit_self_test result=pass",
            "self_test_missing_case_rejected",
            "self_test_missing_list_entry_rejected",
            "self_test_missing_k6_script_rejected",
            "self_test_duplicate_list_warned",
        ),
    ),
    LocalCheck(
        "coverage-verifier",
        "IMServer/LoadTests/perf_coverage.py",
        "performance endpoint coverage report verifier",
        (
            "coverage_self_test result=pass",
            "self_test_critical_gap_detected",
            "self_test_optional_gap_detected",
            "self_test_duplicate_endpoint_rejected",
            "self_test_count_mismatch_rejected",
        ),
    ),
    LocalCheck(
        "route-audit-verifier",
        "IMServer/LoadTests/perf_route_audit.py",
        "server route inventory to performance coverage verifier",
        (
            "route_audit_self_test result=pass",
            "self_test_missing_route_detected",
            "self_test_orphan_endpoint_detected",
            "self_test_duplicate_source_rejected",
            "self_test_duplicate_coverage_rejected",
        ),
    ),
    LocalCheck(
        "scenario-status-verifier",
        "IMServer/LoadTests/perf_scenario_status.py",
        "performance scenario latest status verifier",
        (
            "scenario_status_self_test result=pass",
            "self_test_latest_run_selected",
            "self_test_never_run_seeded",
            "self_test_target_filter_applied",
            "self_test_duplicate_scenario_rejected",
        ),
    ),
    LocalCheck(
        "scenario-catalog-verifier",
        "IMServer/LoadTests/perf_scenario_catalog.py",
        "performance scenario domain and maturity catalog verifier",
        (
            "scenario_catalog_self_test result=pass",
            "self_test_maturity_gap_detected",
            "self_test_status_attached",
            "self_test_tcp_domain_detected",
            "self_test_duplicate_scenario_rejected",
        ),
    ),
    LocalCheck(
        "run-plan-verifier",
        "IMServer/LoadTests/perf_run_plan.py",
        "performance next run command planner verifier",
        (
            "run_plan_self_test result=pass",
            "self_test_p0_blocks_matrix",
            "self_test_smoke_selection_ready",
            "self_test_secret_redacted",
            "self_test_duplicate_selection_rejected",
        ),
    ),
    LocalCheck(
        "evidence-recovery-plan",
        "IMServer/LoadTests/production_evidence_recovery_plan.py",
        "ordered live production evidence recovery planner",
        (
            "production_evidence_recovery_plan_self_test result=pass",
            "self_test_incomplete_status_plan",
            "self_test_ready_status_plan",
            "self_test_duplicate_step_rejected",
            "self_test_artifact_markdown_mismatch_rejected",
            "self_test_local_incomplete_rejected",
            "operatorEnvironmentTemplate",
            "oneShotRecoveryCommands",
            "productionTarget",
            "production_target_from_status(",
            "production_target_mismatch",
            "field_invalid",
            "production_claim_from_status(",
            "production_claim_field_invalid",
            "production_claim_required_evidence_invalid",
            "production_claim_required_evidence_mismatch",
            "requiredEvidence",
            "readiness_tiers_from_status(",
            "readiness_tiers_mismatch",
            "readinessTiers",
            "targetBaseURL",
            "targetTCP",
            "EXPECTED_BASE_URL",
            "require_expected_env_value()",
            "production evidence env target mismatch",
            "render_shell_script(",
            "write_script(",
            "verify_shell_script_syntax(",
            "plan_script_syntax_invalid",
            "production evidence recovery failed: line=",
            "production evidence recovery completed",
            "require_https_url()",
            "require_tcp_host()",
            "require_tcp_port()",
            "PRODUCTION_TARGET_POLICY=\\\"${PRODUCTION_TARGET_POLICY:-IMServer/LoadTests/production_target_policy.py}\\\"",
            "require_public_target_policy()",
            "--result-prefix production_evidence_recovery_target",
            "self_test_recovery_script_missing_public_target_policy",
            "run_recovery_validate_only(",
            "self_test_recovery_validate_only_valid_target_failed",
            "self_test_recovery_validate_only_bound_target_failed",
            "self_test_recovery_validate_only_bound_target_mismatch_passed",
            "self_test_recovery_validate_only_bound_target_mismatch_reason_missing",
            "self_test_recovery_validate_only_placeholder_target_passed",
            "self_test_recovery_validate_only_placeholder_reason_missing",
            "PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY",
            "production evidence recovery validation passed",
            "verify_operator_environment_template(",
            "verify_one_shot_recovery_commands(",
            "self_test_missing_operator_env_template_rejected",
            "self_test_target_bound_plan",
            "self_test_production_target_mismatch_rejected",
            "self_test_production_target_type_rejected",
            "self_test_production_claim_type_rejected",
            "self_test_summary_count_type_rejected",
            "self_test_completion_percent_type_rejected",
            "self_test_production_claim_required_evidence_rejected",
            "self_test_production_claim_required_evidence_mismatch_rejected",
            "self_test_readiness_tiers_mismatch_rejected",
            "self_test_reordered_one_shot_recovery_rejected",
            "self_test_recovery_script_missing_target_validation",
            "self_test_recovery_script_missing_validate_only",
            "self_test_recovery_script_missing_progress_logs",
            "self_test_artifact_script_mismatch_rejected",
            "self_test_artifact_script_not_executable_rejected",
            "self_test_artifact_script_syntax_rejected",
            "production_evidence_recovery_plan_verify result=pass",
        ),
    ),
    LocalCheck(
        "evidence-recovery-path-verifier",
        "IMServer/LoadTests/verify_production_evidence_recovery_paths.py",
        "strict and diagnostic evidence recovery artifact path isolation verifier",
        (
            "production_evidence_recovery_paths_self_test result=pass",
            "strict_artifact_path_conflict",
            "diagnostic_artifact_path_conflict",
            "diagnostic_artifact_conflicts_with_strict",
            "Path(value).expanduser().resolve()",
            "--strict-completion-status-json",
            "--diagnostic-recovery-script",
            "production_evidence_recovery_paths result=pass",
        ),
    ),
    LocalCheck(
        "default-profile-audit-verifier",
        "IMServer/LoadTests/perf_default_profile_audit.py",
        "default production performance profile audit verifier",
        (
            "default_profile_audit_self_test result=pass",
            "self_test_profile_drift_rejected",
            "self_test_missing_file_rejected",
            "self_test_missing_pattern_rejected",
            "self_test_payload_count_mismatch_rejected",
        ),
    ),
    LocalCheck(
        "docs-audit-verifier",
        "IMServer/LoadTests/perf_docs_audit.py",
        "production documentation audit verifier",
        (
            "docs_audit_self_test result=pass",
            "self_test_unknown_group_rejected",
            "self_test_unknown_profile_rejected",
            "self_test_public_8080_rejected",
            "self_test_stale_public_ip_rejected",
            "self_test_example_domain_rejected",
        ),
    ),
    LocalCheck(
        "validation-inventory",
        "IMServer/LoadTests/perf_validation_inventory.py",
        "production validation inventory generator and verifier",
        (
            "validation_inventory_self_test result=pass",
            "def run_self_test()",
            "REQUIRED_INVENTORY_RECORDS",
            "self_test_missing_required_record",
            "source_git_dirty_mismatch",
        ),
    ),
    LocalCheck(
        "product-scenario-suite-verifier",
        "IMServer/LoadTests/perf_product_scenario_suite_verify.py",
        "product scenario suite artifact verifier",
        (
            "product_scenario_suite_verify_self_test result=pass",
            "self_test_stage_coverage_missing",
            "self_test_large_group_not_allowed",
            "self_test_markdown_missing_coverage",
            "require_no_large_group",
        ),
    ),
    LocalCheck(
        "production-profiles-audit-verifier",
        "IMServer/LoadTests/perf_production_profiles_audit.py",
        "production profile catalog audit verifier",
        (
            "production_profiles_audit_self_test result=pass",
            "self_test_unknown_scenario_rejected",
            "self_test_duplicate_scenario_rejected",
            "self_test_group_subset_warned",
            "profile_group_relation(",
        ),
    ),
    LocalCheck(
        "product-plan-artifacts-verifier",
        "IMServer/LoadTests/perf_product_plan_artifacts_verify.py",
        "product test plan artifact verifier",
        (
            "product_plan_artifacts_self_test result=pass",
            "self_test_phase_status_tsv_mismatch",
            "self_test_plan_preview_unique_count_mismatch",
            "self_test_phase_command_secret_not_redacted",
            "require_secret_redacted(",
        ),
    ),
    LocalCheck(
        "product-campaign-artifacts-verifier",
        "IMServer/LoadTests/perf_product_campaign_artifacts_verify.py",
        "product campaign artifact verifier",
        (
            "product_campaign_artifacts_self_test result=pass",
            "self_test_stage_count_mismatch",
            "self_test_stage_command_secret_not_redacted",
            "self_test_large_group_stage_not_isolated",
            "require_stage_target_matches(",
        ),
    ),
    LocalCheck(
        "product-campaign-audit-verifier",
        "IMServer/LoadTests/perf_product_campaign_audit.py",
        "product campaign catalog audit verifier",
        (
            "product_campaign_audit_self_test result=pass",
            "self_test_non_large_missing_phase_rejected",
            "self_test_non_large_large_group_rejected",
            "self_test_unknown_phase_rejected",
            "required_phase_policies_missing",
        ),
    ),
    LocalCheck(
        "product-profile-gate-verifier",
        "IMServer/LoadTests/perf_product_profile_gate.py",
        "product profile gate verifier",
        (
            "product_profile_gate_self_test result=pass",
            "self_test_missing_domain_rejected",
            "self_test_large_group_rejected",
            "self_test_unknown_scenario_rejected",
            "self_test_maturity_gap_rejected",
        ),
    ),
    LocalCheck(
        "profile-artifacts-verifier",
        "IMServer/LoadTests/perf_profile_artifacts_verify.py",
        "production profile artifact verifier",
        (
            "profile_artifacts_self_test result=pass",
            "self_test_production_gate_target_public_required",
            "self_test_profile_run_batch_selection_mismatch",
            "self_test_profile_catalog_missing_selected_scenario",
            "require_public_target(",
        ),
    ),
    LocalCheck(
        "production-evidence-packager",
        "IMServer/LoadTests/package_production_evidence.sh",
        "production evidence package builder",
        (
            "production_evidence_package_self_test result=pass",
            "perf_evidence_manifest.py",
            "perf_secret_scan.py",
            "production-evidence-manifest.json",
            "secret-scan.log",
        ),
        True,
    ),
    LocalCheck(
        "static-receipt-helper",
        "IMServer/LoadTests/production_static_gate_receipt.py",
        "local production static receipt and evidence recovery binding verifier",
        (
            "production_static_gate_receipt_self_test result=pass",
            "verify_completion_status_binding(",
            "verify_recovery_plan_binding(",
            "resolve_bound_file(",
            "support_root_match(",
            "prefer_support_roots",
            "require_support_root",
            "DEFAULT_COMPLETION_STATUS_MARKDOWN",
            "recovery_plan_summary(",
            "normalized_production_target(",
            "normalized_production_claim(",
            "normalized_readiness_tiers(",
            "require_json_int(",
            "require_json_bool(",
            "productionTarget",
            "productionClaim",
            "readinessTiers",
            "finalAssertionClaimVerified",
            "finalAssertionArchiveClaimVerified",
            "completion_status_target_mismatch",
            "completion_status_claim_mismatch",
            "completion_status_readiness_tiers_invalid",
            "completion_status_readiness_tiers_mismatch",
            "recovery_plan_target_mismatch",
            "recovery_plan_completion_target_mismatch",
            "recovery_plan_claim_mismatch",
            "recovery_plan_completion_claim_mismatch",
            "recovery_plan_readiness_tiers_invalid",
            "recovery_plan_readiness_tiers_mismatch",
            "recovery_plan_completion_readiness_tiers_mismatch",
            "completion_status_markdown_render_failed",
            "completion_status_markdown_mismatch",
            "completion_status_markdown_sha256_mismatch",
            "recovery_plan_artifact_render_failed",
            "recovery_plan_markdown_mismatch",
            "recovery_plan_script_mismatch",
            "recovery_plan_markdown_sha256_mismatch",
            "recovery_plan_script_sha256_mismatch",
            "recovery_plan_script_not_executable",
            "self_test_recovery_script_sha_failed",
            "self_test_completion_markdown_sha_failed",
            "self_test_completion_target_mismatch_failed",
            "self_test_completion_target_type_failed",
            "self_test_completion_claim_mismatch_failed",
            "self_test_completion_claim_type_failed",
            "self_test_completion_final_claim_mismatch_failed",
            "self_test_completion_readiness_tiers_mismatch_failed",
            "self_test_completion_readiness_tiers_extra_field_failed",
            "self_test_completion_readiness_tiers_type_failed",
            "self_test_recovery_target_mismatch_failed",
            "self_test_recovery_completion_target_mismatch_failed",
            "self_test_recovery_claim_mismatch_failed",
            "self_test_recovery_claim_type_failed",
            "self_test_recovery_completion_claim_mismatch_failed",
            "self_test_recovery_readiness_tiers_mismatch_failed",
            "self_test_recovery_readiness_tiers_extra_field_failed",
            "self_test_recovery_readiness_tiers_type_failed",
            "self_test_completion_markdown_semantic_failed",
            "self_test_completion_binding_count_type_failed",
            "self_test_completion_source_count_type_failed",
            "self_test_recovery_markdown_semantic_failed",
            "self_test_recovery_script_semantic_failed",
            "self_test_recovery_script_executable_failed",
            "self_test_recovery_ready_type_failed",
            "self_test_recovery_source_ready_type_failed",
            "--recovery-plan-script",
            "--support-root",
            "--prefer-support-root",
            "--require-support-root",
            "self_test_support_root_preference_failed",
            "self_test_support_root_required_failed",
            "--require-recovery-plan",
        ),
    ),
    LocalCheck(
        "production-worktree-inventory",
        "IMServer/LoadTests/production_worktree_inventory.py",
        "dirty worktree inventory for production static gate cleanup",
        (
            "imserver-production-worktree-inventory",
            "production_worktree_inventory_self_test result=pass",
            "trackedModified",
            "untracked",
            "generatedLocalArtifacts",
            "forbiddenRuntimeArtifacts",
            "remove_runtime_artifact_before_static_gate",
            "remove_or_ignore_generated_artifact",
            "actionSummary",
            "categorySummary",
            "commitGroupSummary",
            "directorySummary",
            "--untracked-files=all",
            "--group",
            "--category",
            "--action",
            "--type",
            "--paths-only",
            "--tracked-diff-stat",
            "--plan",
            "render_paths(",
            "render_tracked_diff_stat(",
            "plan_payload(",
            "build_plan_groups(",
            "render_plan(",
            "commit_runbook(",
            "verify_commit_runbook(",
            "render_verify_commit_runbook_result(",
            "IMSERVER_WORKTREE_RUNBOOK_CONFIRMED=reviewed",
            "Refusing to run commit runbook without IMSERVER_WORKTREE_RUNBOOK_CONFIRMED=reviewed.",
            "production_worktree_plan",
            "production_worktree_commit_runbook_verify",
            "commit_runbook_current",
            "commit_runbook_stale_or_mismatched",
            "imserver-production-worktree-plan",
            "--plan-json",
            "--plan-json-output",
            "--commit-runbook",
            "--commit-runbook-output",
            "--verify-commit-runbook",
            "--verify-plan-json",
            "--stage-dry-run",
            "--stage-dry-run-json-output",
            "--verify-stage-dry-run-json",
            "--stage-dry-run-batch",
            "--stage-dry-run-batch-json-output",
            "--verify-stage-dry-run-batch-json",
            "verify_plan_payload(",
            "verify_plan_command_contract(",
            "render_verify_plan_result(",
            "stage_dry_run_receipt(",
            "verify_stage_dry_run_receipt(",
            "stage_dry_run_batch_receipt(",
            "verify_stage_dry_run_batch_receipt(",
            "render_stage_dry_run_result(",
            "render_verify_stage_dry_run_result(",
            "render_stage_dry_run_batch_result(",
            "render_verify_stage_dry_run_batch_result(",
            "production_worktree_plan_verify",
            "production_worktree_stage_dry_run",
            "production_worktree_stage_dry_run_verify",
            "production_worktree_stage_dry_run_batch",
            "production_worktree_stage_dry_run_batch_verify",
            "imserver-production-worktree-stage-dry-run",
            "imserver-production-worktree-stage-dry-run-batch",
            "stage_dry_run_json_current",
            "stage_dry_run_batch_json_current",
            "stage_dry_run_json_git_status_mismatch",
            "stage_dry_run_batch_json_git_status_mismatch",
            "stage_dry_run_json_stale_or_mismatched",
            "stage_dry_run_batch_json_stale_or_mismatched",
            "plan_json_stale_or_mismatched",
            "plan_json_git_status_mismatch",
            "plan_json_required_command_missing",
            "plan_json_stage_not_source_only",
            "statusSha256",
            "--verify-staged-source-only",
            "verify_staged_source_only(",
            "render_staged_verify_result(",
            "verify_staged_single_group(",
            "render_staged_group_result(",
            "production_worktree_staging_verify",
            "production_worktree_staged_group_verify",
            "staged_non_source_change",
            "staged_multiple_commit_groups",
            "staged_single_commit_group",
            "staged_plan_missing_path",
            "staged_plan_unstaged_changes",
            "source_paths_matched",
            "--verify-staged-single-group",
            "reviewCommand=make production-worktree-inventory",
            "pathsCommand=make production-worktree-inventory",
            "sourcePathsCommand",
            "sourceTrackedDiffCommand",
            "sourceUntrackedPathsCommand",
            "--type tracked --tracked-diff-stat",
            "sourceTracked=",
            "sourceUntracked=",
            "stageDryRunCommand",
            "stageDryRunReceiptCommand",
            "make production-worktree-stage-dry-run",
            "git add --dry-run --pathspec-from-file",
            "stageCommand=make production-worktree-inventory",
            "--category source_change --paths-only",
            "--pathspec-from-file",
            "generatedArtifactsCommand=make production-worktree-inventory",
            "generatedArtifactsAction=remove_or_ignore_generated_artifact",
            "forbiddenArtifactsCommand=make production-worktree-inventory",
            "forbiddenArtifactsAction=remove_runtime_artifact_before_static_gate",
            "pathspec_file_for_group(",
            "commitSubject=",
            "commitCommand=git commit -m",
            "commit_subject_for_group(",
            "forbidden_runtime_artifact_kinds(",
        ),
    ),
    LocalCheck("target-policy", "IMServer/LoadTests/production_target_policy.py", "public production target policy", ("--self-test",)),
    LocalCheck("readiness-gate", "deploy/ubuntu/95_production_readiness_gate.sh", "host production readiness gate", ("readiness",), True),
    LocalCheck("performance-gate-install", "deploy/ubuntu/68_install_performance_gate.sh", "performance gate installation", ("performance",), True),
    LocalCheck("performance-evidence-install", "deploy/ubuntu/69_install_performance_evidence_package.sh", "performance evidence package installation", ("evidence",), True),
    LocalCheck(
        "install-dependencies",
        "deploy/ubuntu/00_install_dependencies.sh",
        "base dependency and Swiftly setup archive verification",
        (
            "INSTALL_DEPENDENCIES_SELF_TEST",
            "SWIFTLY_VERSION",
            "verify_swiftly_archive_signature()",
            "safe_extract_swiftly_archive()",
            "install_dependencies step=swiftly_signature result=pass",
            "install_dependencies step=swiftly_archive_safety result=pass",
            "SWIFTLY_ARCHIVE_MEMBER_MAX_BYTES",
            "SWIFTLY_ARCHIVE_TOTAL_MAX_BYTES",
            "swiftly_signature_gpg_missing",
            "swiftly_signature_verify_failed",
            "swiftly_archive_member_path_unsafe",
            "swiftly_archive_member_too_large",
            "bad_swiftly_signature_accepted",
            "unsafe_swiftly_archive_accepted",
            "oversized_swiftly_archive_accepted",
            "install_dependencies_self_test result=pass",
            "${swift_archive_url}.sig",
            "https://www.swift.org/keys/all-keys.asc",
        ),
        True,
    ),
    LocalCheck(
        "build-imserver",
        "deploy/ubuntu/40_build_imserver.sh",
        "release build artifact and release directory safety",
        (
            "BUILD_IMSERVER_SELF_TEST",
            "validate_release_id()",
            "resolve_release_dir()",
            "release_id_invalid",
            "release_id_traversal",
            "release_dir_outside_releases",
            "unsafe_release_id_slash_accepted",
            "unsafe_release_id_dotdot_accepted",
            "unsafe_release_id_dash_accepted",
            "build_imserver_self_test result=pass",
        ),
        True,
    ),
    LocalCheck(
        "systemd-units",
        "deploy/ubuntu/50_install_systemd_units.sh",
        "IMServer systemd service sandbox baseline",
        (
            "SYSTEMD_UNITS_RENDER_SELF_TEST",
            "NoNewPrivileges=true",
            "PrivateTmp=true",
            "PrivateDevices=true",
            "ProtectSystem=full",
            "ProtectHome=true",
            "ProtectKernelTunables=true",
            "ProtectKernelModules=true",
            "ProtectControlGroups=true",
            "RestrictSUIDSGID=true",
            "RestrictRealtime=true",
            "RestrictNamespaces=true",
            "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6",
            "LockPersonality=true",
            "SystemCallArchitectures=native",
            "CapabilityBoundingSet=",
            "AmbientCapabilities=",
            "systemd-units-render-self-test result=pass",
        ),
        True,
    ),
    LocalCheck(
        "systemd-unit-verifier",
        "deploy/ubuntu/52_verify_systemd_units.sh",
        "IMServer systemd service runtime drift verifier",
        (
            "SYSTEMD_UNIT_VERIFY_SELF_TEST",
            "PrivateDevices=true",
            "ProtectKernelTunables=true",
            "ProtectKernelModules=true",
            "ProtectControlGroups=true",
            "RestrictRealtime=true",
            "RestrictNamespaces=true",
            "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6",
            "CapabilityBoundingSet=",
            "AmbientCapabilities=",
            "missing_private_devices_accepted",
            "missing_PrivateDevices",
            "systemd-unit-verify-self-test result=pass",
        ),
        True,
    ),
    LocalCheck(
        "kafka-setup",
        "deploy/ubuntu/30_setup_kafka.sh",
        "Kafka setup archive verification",
        (
            "KAFKA_SETUP_SELF_TEST",
            "verify_kafka_archive_checksum()",
            "safe_extract_kafka_archive()",
            "kafka_setup step=archive_checksum result=pass",
            "kafka_setup step=archive_safety result=pass",
            "KAFKA_ARCHIVE_MEMBER_MAX_BYTES",
            "KAFKA_ARCHIVE_TOTAL_MAX_BYTES",
            "archive_checksum_mismatch",
            "archive_member_path_unsafe",
            "archive_member_too_large",
            "bad_checksum_accepted",
            "unsafe_archive_accepted",
            "oversized_member_accepted",
            "kafka_setup_self_test result=pass",
            "${download_url}.sha512",
            "PrivateDevices=true",
            "ProtectKernelTunables=true",
            "ProtectKernelModules=true",
            "ProtectControlGroups=true",
            "RestrictRealtime=true",
            "RestrictNamespaces=true",
            "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6",
            "CapabilityBoundingSet=",
            "AmbientCapabilities=",
        ),
        True,
    ),
    LocalCheck(
        "operational-audit",
        "deploy/ubuntu/77_operational_audit.sh",
        "operational audit",
        (
            "operational",
            "validate_release_checksum_file()",
            "audit release-checksum-safety result=pass",
            "unsafe_checksum_file release=",
            "release_checksum_unsafe_path_accepted",
            "release_checksum_extra_file_accepted",
        ),
        True,
    ),
    LocalCheck("alerting", "deploy/ubuntu/79_send_operational_alert.sh", "operational alert sender", ("alert",), True),
    LocalCheck("backup", "deploy/ubuntu/80_backup_single_node.sh", "single-node backup", ("backup",), True),
    LocalCheck(
        "backup-verify",
        "deploy/ubuntu/81_verify_backup.sh",
        "backup verification",
        (
            "verify",
            "validate_checksum_file()",
            "BACKUP_VERIFY_MANIFEST_MAX_BYTES",
            "BACKUP_VERIFY_ETC_ARCHIVE_MEMBER_MAX_BYTES",
            "BACKUP_VERIFY_ETC_ARCHIVE_TOTAL_MAX_BYTES",
            "backup-verify step=checksum_file_safety result=pass",
            "Backup checksum file has unsafe file reference",
            "Backup checksum file has duplicate file reference",
            "backup manifest is too large",
            "archive member too large",
            "archive total size too large",
            "unsafe_checksum_file_passed",
            "duplicate_checksum_file_passed",
            "manifest_too_large_accepted",
            "oversized_archive_passed",
            "total_too_large_archive_passed",
        ),
        True,
    ),
    LocalCheck("restore-drill", "deploy/ubuntu/82_restore_drill_single_node.sh", "restore drill", ("restore",), True),
    LocalCheck("backup-timer", "deploy/ubuntu/85_install_backup_timer.sh", "scheduled backup timer", ("timer",), True),
    LocalCheck("offsite-backup", "deploy/ubuntu/86_sync_backup_offsite.sh", "offsite backup sync", ("offsite",), True),
    LocalCheck(
        "deploy-failure-artifact-package",
        "deploy/ubuntu/92_package_deploy_failure_artifacts.sh",
        "deploy failure artifact package",
        (
            "DEPLOY_FAILURE_ARTIFACT_PACKAGE_SELF_TEST",
            "safe_extract_archive()",
            "deploy_failure_artifact_package_verify step=archive_safety result=pass",
            "DEPLOY_FAILURE_ARTIFACT_ARCHIVE_MEMBER_MAX_BYTES",
            "DEPLOY_FAILURE_ARTIFACT_ARCHIVE_TOTAL_MAX_BYTES",
            "archive_unsafe_member",
            "archive_member_too_large",
            "archive_total_too_large",
            "oversized_archive_member_accepted",
            "oversized_archive_total_accepted",
            "unsafe_archive_passed",
            "deploy_failure_artifact_package_self_test result=pass",
        ),
        True,
    ),
    LocalCheck(
        "node-access-rescue-artifact",
        "IMServer/LoadTests/generate_node_access_rescue_artifact.sh",
        "node access rescue artifact generator",
        (
            "NODE_ACCESS_RESCUE_ARTIFACT_SELF_TEST",
            "validate_checksum_file()",
            "node_access_rescue_artifact_verify step=checksum_file_safety result=pass",
            "safe_extract_artifact_archive()",
            "node_access_rescue_package_verify step=archive_safety result=pass",
            "archive_member_path_unsafe",
            "unsafe_archive_member_accepted",
            "checksum_file_unsafe_path",
            "checksum_file_duplicate_path",
            "unsafe_checksum_file_accepted",
            "duplicate_checksum_file_accepted",
            "node_access_rescue_artifact_self_test result=pass",
        ),
        True,
    ),
    LocalCheck(
        "root-runbook",
        "README.md",
        "root production runbook",
        (
            "Current production readiness status:",
            "make assert-production-ready",
            "verify-production-ready-archive",
            "make validate-production-evidence-recovery-env",
            "PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true",
        ),
    ),
    LocalCheck(
        "loadtest-runbook",
        "IMServer/LoadTests/README.md",
        "load-test production runbook",
        (
            "production-acceptance.env.example",
            "make verify-production-ready-archive",
            "make validate-production-evidence-recovery-env",
            "PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true",
        ),
    ),
    LocalCheck("acceptance-env-example", "IMServer/LoadTests/production-acceptance.env.example", "production acceptance env template", ("PRODUCTION_ACCEPTANCE_BASE_URL", "PRODUCTION_ACCEPTANCE_CONVERSATION_ID")),
)


EVIDENCE_CHECKS: tuple[EvidenceCheck, ...] = (
)


DEFAULT_ASSERTION_JSON = "IMServer/LoadTests/results/production-ready/latest.json"
DEFAULT_ASSERTION_ARTIFACT_ROOT = ""
FINAL_ASSERTION_REQUIRED_ARTIFACTS = (
    "topologySmokeReceipt",
    "deployReadinessReceipt",
    "productionStaticGateReceipt",
    "currentProductionReadinessJSON",
    "productionAcceptanceReceiptJSON",
    "productionEvidencePackage",
)
FINAL_ASSERTION_REQUIRED_POLICIES = (
    "requiresPublicProductionTarget",
    "requiresTopologySmokeReceipt",
    "requiresDeployReadinessReceipt",
    "requiresProductionStaticGateReceipt",
    "requiresCurrentProductionReadiness",
    "requiresProductionAcceptanceReceipt",
    "requiresProductionEvidencePackage",
    "requiresFreshTopologySmokeReceipt",
    "requiresFreshDeployReadinessReceipt",
    "requiresFreshProductionStaticGateReceipt",
    "requiresFreshCurrentProductionReadiness",
    "requiresFreshProductionAcceptanceReceipt",
    "requiresMatchingTarget",
)

EVIDENCE_CONTRACTS: dict[str, dict[str, Any]] = {
    "deploy-readiness": {
        "requiredEnv": ["PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON", "BASE_URL", "TCP_HOST", "TCP_PORT"],
        "runCommand": "make run-production-readiness-gate",
        "verifyCommand": "python3 IMServer/LoadTests/verify_deploy_readiness_receipt.py --receipt-json \"$PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON\" --expect-base-url \"$BASE_URL\" --expect-tcp-host \"$TCP_HOST\" --expect-tcp-port \"$TCP_PORT\"",
    },
    "current-readiness": {
        "requiredEnv": [
            "CURRENT_PRODUCTION_READINESS_JSON",
            "CURRENT_PRODUCTION_READINESS_DASHBOARD_JSON",
            "CURRENT_PRODUCTION_READINESS_STATE_JSON",
            "CURRENT_PRODUCTION_READINESS_PROBE_JSON",
            "CURRENT_PRODUCTION_READINESS_EVIDENCE_DIR",
            "BASE_URL",
            "TCP_HOST",
            "TCP_PORT",
        ],
        "runCommand": "make run-current-production-readiness",
        "verifyCommand": "make verify-current-production-readiness",
    },
    "production-acceptance": {
        "requiredEnv": ["PRODUCTION_ACCEPTANCE_RECEIPT_JSON", "PRODUCTION_EVIDENCE_PACKAGE"],
        "runCommand": "make run-production-acceptance",
        "verifyCommand": "make verify-production-acceptance",
    },
    "production-evidence-package": {
        "requiredEnv": ["PRODUCTION_EVIDENCE_PACKAGE", "BASE_URL", "TCP_HOST", "TCP_PORT"],
        "runCommand": "bash IMServer/LoadTests/package_production_evidence.sh",
        "verifyCommand": "python3 IMServer/LoadTests/perf_production_acceptance_verify.py --verify-package-archive --package-file \"$PRODUCTION_EVIDENCE_PACKAGE\" --expect-base-url \"$BASE_URL\" --expect-tcp-host \"$TCP_HOST\" --expect-tcp-port \"$TCP_PORT\"",
    },
    "topology-smoke": {
        "requiredEnv": ["PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON"],
        "runCommand": "make run-imserver-production-smoke",
        "verifyCommand": "make verify-imserver-production-smoke",
    },
    "final-assertion": {
        "requiredEnv": ["PRODUCTION_READY_ASSERTION_JSON", "BASE_URL", "TCP_HOST", "TCP_PORT"],
        "runCommand": "make assert-production-ready",
        "verifyCommand": "make verify-production-ready-assertion",
    },
    "final-assertion-archive": {
        "requiredEnv": ["PRODUCTION_READY_ASSERTION_ARCHIVE_FILE", "BASE_URL", "TCP_HOST", "TCP_PORT"],
        "runCommand": "make package-production-ready-assertion",
        "verifyCommand": "make verify-production-ready-archive",
    },
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def add_evidence_contract(result: dict[str, Any]) -> dict[str, Any]:
    contract = EVIDENCE_CONTRACTS.get(str(result.get("item") or ""))
    if contract is not None:
        result["evidenceContract"] = {
            "requiredEnv": list(contract["requiredEnv"]),
            "runCommand": contract["runCommand"],
            "verifyCommand": contract["verifyCommand"],
        }
    return result


def check_local(repo_root: Path, check: LocalCheck) -> dict[str, Any]:
    path = repo_root / check.path
    result: dict[str, Any] = {
        "item": check.item,
        "description": check.description,
        "path": check.path,
        "status": "pass",
        "reason": "ok",
    }
    if not path.exists():
        result["status"] = "fail"
        result["reason"] = "missing_file"
        return result
    if check.executable and not os.access(path, os.X_OK):
        result["status"] = "fail"
        result["reason"] = "not_executable"
        return result
    if check.contains:
        content = read_text(path)
        missing = [marker for marker in check.contains if marker not in content]
        if missing:
            result["status"] = "fail"
            result["reason"] = "missing_marker"
            result["missingMarkers"] = missing
    return result


def nested_value(payload: dict[str, Any], key: str) -> Any:
    current: Any = payload
    for part in key.split("."):
        if not isinstance(current, dict):
            return None
        current = current.get(part)
    return current


def check_evidence(repo_root: Path, check: EvidenceCheck, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get(check.path_env, "")
    if not raw and check.path_env == "PRODUCTION_READY_ASSERTION_JSON":
        raw = DEFAULT_ASSERTION_JSON
    result: dict[str, Any] = {
        "item": check.item,
        "description": check.description,
        "env": check.path_env,
        "path": raw,
        "status": "missing",
        "reason": "missing_env",
    }
    if not raw:
        return result
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    result["path"] = str(path)
    if not path.is_file():
        result["reason"] = "file_missing"
        return result
    result["status"] = "pass"
    result["reason"] = "present"
    if check.required_json:
        try:
            payload = json.loads(read_text(path))
        except Exception as error:  # noqa: BLE001 - report should explain malformed evidence.
            result["status"] = "fail"
            result["reason"] = "invalid_json"
            result["error"] = str(error)
            return result
        for key, expected in check.required_json:
            actual = nested_value(payload, key)
            if str(actual) != expected:
                result["status"] = "fail"
                result["reason"] = "json_value_mismatch"
                result["key"] = key
                result["expected"] = expected
                result["actual"] = actual
                break
    return result


def command_failure_reason(completed: subprocess.CompletedProcess[str]) -> tuple[str, str]:
    output = f"{completed.stdout}\n{completed.stderr}".strip()
    for token in output.replace("\n", " ").split():
        if token.startswith("reason="):
            return token.split("=", 1)[1], output
    return "verify_failed", output


def is_final_production_claim(claim: Any) -> bool:
    if not isinstance(claim, dict):
        return False
    return (
        claim.get("productionReady") is True
        and claim.get("claimAllowed") is True
        and claim.get("targetComplete") is True
        and claim.get("claimLevel") == "production-ready"
        and claim.get("basis") == "verified-final-production-evidence"
        and claim.get("blockers") == []
        and claim.get("requiredArtifacts") == list(FINAL_ASSERTION_REQUIRED_ARTIFACTS)
        and claim.get("requiredPolicies") == list(FINAL_ASSERTION_REQUIRED_POLICIES)
    )


def final_production_claim_result(claim: Any) -> dict[str, Any]:
    if not isinstance(claim, dict):
        return {
            "valid": False,
            "productionReady": False,
            "claimAllowed": False,
            "claimLevel": "",
            "basis": "",
        }
    return {
        "valid": is_final_production_claim(claim),
        "productionReady": bool(claim.get("productionReady")),
        "claimAllowed": bool(claim.get("claimAllowed")),
        "claimLevel": str(claim.get("claimLevel") or ""),
        "basis": str(claim.get("basis") or ""),
    }


def read_json_file(path: Path) -> dict[str, Any]:
    payload = json.loads(read_text(path))
    if not isinstance(payload, dict):
        raise ValueError("json_not_object")
    return payload


def archive_manifest_claim(path: Path, max_manifest_bytes: int = MAX_FINAL_ASSERTION_ARCHIVE_MANIFEST_BYTES) -> Any:
    with tarfile.open(path, "r:gz") as archive:
        member = archive.getmember("production-ready-archive-manifest.json")
        if not member.isfile():
            raise ValueError("archive_manifest_not_file")
        if member.size < 0:
            raise ValueError("archive_manifest_size_invalid")
        if member.size > max_manifest_bytes:
            raise ValueError("archive_manifest_too_large")
        handle = archive.extractfile(member)
        if handle is None:
            raise ValueError("archive_manifest_unreadable")
        data = handle.read(max_manifest_bytes + 1)
        if len(data) > max_manifest_bytes:
            raise ValueError("archive_manifest_too_large")
        payload = json.loads(data.decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("archive_manifest_not_object")
    return payload.get("productionClaim")


def append_optional_path_arg(command: list[str], repo_root: Path, flag: str, value: str) -> None:
    if not value:
        return
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    command.extend([flag, str(path)])


def check_current_readiness(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get("CURRENT_PRODUCTION_READINESS_JSON", "")
    result: dict[str, Any] = {
        "item": "current-readiness",
        "description": "verified current production readiness receipt and artifacts",
        "env": "CURRENT_PRODUCTION_READINESS_JSON",
        "path": raw,
        "status": "missing",
        "reason": "missing_env",
    }
    if not raw:
        return result
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    result["path"] = str(path)
    if not path.is_file():
        result["reason"] = "file_missing"
        return result

    command = [
        "python3",
        str(repo_root / "IMServer/LoadTests/perf_current_production_readiness_verify.py"),
        "--readiness-json",
        str(path),
        "--max-age-seconds",
        env.get("CURRENT_PRODUCTION_READINESS_MAX_AGE_SECONDS", "86400"),
        "--max-future-skew-seconds",
        env.get("CURRENT_PRODUCTION_READINESS_MAX_FUTURE_SKEW_SECONDS", "300"),
    ]
    append_optional_path_arg(command, repo_root, "--dashboard-json", env.get("CURRENT_PRODUCTION_READINESS_DASHBOARD_JSON", ""))
    append_optional_path_arg(command, repo_root, "--state-json", env.get("CURRENT_PRODUCTION_READINESS_STATE_JSON", ""))
    append_optional_path_arg(command, repo_root, "--probe-json", env.get("CURRENT_PRODUCTION_READINESS_PROBE_JSON", ""))
    append_optional_path_arg(command, repo_root, "--evidence-dir", env.get("CURRENT_PRODUCTION_READINESS_EVIDENCE_DIR", ""))
    base_url = env.get("BASE_URL") or env.get("PUBLIC_BASE_URL") or env.get("IM_PUBLIC_BASE_URL", "")
    tcp_host = env.get("TCP_HOST") or env.get("IM_PUBLIC_HOST", "")
    tcp_port = env.get("TCP_PORT") or env.get("IM_TCP_PORT", "")
    if base_url:
        command.extend(["--expect-base-url", base_url])
    if tcp_host:
        command.extend(["--expect-tcp-host", tcp_host])
    if tcp_port:
        command.extend(["--expect-tcp-port", tcp_port])

    completed = subprocess.run(command, cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if completed.returncode != 0:
        reason, output = command_failure_reason(completed)
        result["status"] = "fail"
        result["reason"] = reason
        result["output"] = output[-1000:]
        return result
    result["status"] = "pass"
    result["reason"] = "verified"
    return result


def check_deploy_readiness(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get("PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON") or env.get("DEPLOY_READINESS_RECEIPT_JSON") or env.get("READINESS_RECEIPT_JSON", "")
    result: dict[str, Any] = {
        "item": "deploy-readiness",
        "description": "verified deployed host readiness receipt",
        "env": "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON",
        "path": raw,
        "status": "missing",
        "reason": "missing_env",
    }
    if not raw:
        return result
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    result["path"] = str(path)
    if not path.is_file():
        result["reason"] = "file_missing"
        return result
    base_url, tcp_host, tcp_port = target_from_env(env)
    missing_target = [
        name
        for name, value in (
            ("BASE_URL", base_url),
            ("TCP_HOST", tcp_host),
            ("TCP_PORT", tcp_port),
        )
        if not value
    ]
    if missing_target:
        result["status"] = "fail"
        result["reason"] = "target_env_missing"
        result["missingEnv"] = missing_target
        return result
    command = [
        "python3",
        str(repo_root / "IMServer/LoadTests/verify_deploy_readiness_receipt.py"),
        "--receipt-json",
        str(path),
        "--expect-base-url",
        base_url,
        "--expect-tcp-host",
        tcp_host,
        "--expect-tcp-port",
        tcp_port,
        "--max-age-seconds",
        env.get("PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS", "86400"),
        "--max-future-skew-seconds",
        env.get("PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS", "300"),
    ]
    completed = subprocess.run(command, cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if completed.returncode != 0:
        reason, output = command_failure_reason(completed)
        result["status"] = "fail"
        result["reason"] = reason
        result["output"] = output[-1000:]
        return result
    result["status"] = "pass"
    result["reason"] = "verified"
    return result


def check_production_acceptance(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get("PRODUCTION_ACCEPTANCE_RECEIPT_JSON", "")
    result: dict[str, Any] = {
        "item": "production-acceptance",
        "description": "verified production acceptance receipt and evidence package",
        "env": "PRODUCTION_ACCEPTANCE_RECEIPT_JSON",
        "path": raw,
        "status": "missing",
        "reason": "missing_env",
    }
    if not raw:
        return result
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    result["path"] = str(path)
    if not path.is_file():
        result["reason"] = "file_missing"
        return result

    command_env = dict(os.environ)
    command_env.update(env)
    command_env["PRODUCTION_ACCEPTANCE_RECEIPT_JSON"] = str(path)
    completed = subprocess.run(
        ["bash", str(repo_root / "IMServer/LoadTests/verify_production_acceptance.sh")],
        cwd=repo_root,
        env=command_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        reason, output = command_failure_reason(completed)
        result["status"] = "fail"
        result["reason"] = reason
        result["output"] = output[-1000:]
        return result
    result["status"] = "pass"
    result["reason"] = "verified"
    return result


def target_from_env(env: dict[str, str]) -> tuple[str, str, str]:
    base_url = env.get("BASE_URL") or env.get("PUBLIC_BASE_URL") or env.get("IM_PUBLIC_BASE_URL", "")
    tcp_host = env.get("TCP_HOST") or env.get("IM_PUBLIC_HOST", "")
    tcp_port = env.get("TCP_PORT") or env.get("IM_TCP_PORT", "")
    return base_url, tcp_host, tcp_port


def missing_target_env(base_url: str, tcp_host: str, tcp_port: str) -> list[str]:
    return [
        name
        for name, value in (
            ("BASE_URL", base_url),
            ("TCP_HOST", tcp_host),
            ("TCP_PORT", tcp_port),
        )
        if not value
    ]


def production_target(env: dict[str, str]) -> dict[str, Any]:
    base_url, tcp_host, tcp_port = target_from_env(env)
    return {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "missingEnv": missing_target_env(base_url, tcp_host, tcp_port),
    }


def check_production_evidence_package(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get("PRODUCTION_EVIDENCE_PACKAGE") or env.get("PRODUCTION_ACCEPTANCE_PACKAGE", "")
    result: dict[str, Any] = {
        "item": "production-evidence-package",
        "description": "verified production evidence package archive",
        "env": "PRODUCTION_EVIDENCE_PACKAGE",
        "path": raw,
        "status": "missing",
        "reason": "missing_env",
    }
    if not raw:
        return result
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    result["path"] = str(path)
    if not path.is_file():
        result["reason"] = "file_missing"
        return result
    base_url, tcp_host, tcp_port = target_from_env(env)
    missing_target = missing_target_env(base_url, tcp_host, tcp_port)
    if missing_target:
        result["status"] = "fail"
        result["reason"] = "target_env_missing"
        result["missingEnv"] = missing_target
        return result
    command = [
        "python3",
        str(repo_root / "IMServer/LoadTests/perf_production_acceptance_verify.py"),
        "--verify-package-archive",
        "--package-file",
        str(path),
        "--expect-base-url",
        base_url,
        "--expect-tcp-host",
        tcp_host,
        "--expect-tcp-port",
        tcp_port,
    ]
    completed = subprocess.run(command, cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if completed.returncode != 0:
        reason, output = command_failure_reason(completed)
        result["status"] = "fail"
        result["reason"] = reason
        result["output"] = output[-1000:]
        return result
    result["status"] = "pass"
    result["reason"] = "verified"
    return result


def check_final_assertion(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get("PRODUCTION_READY_ASSERTION_JSON", DEFAULT_ASSERTION_JSON)
    artifact_root = env.get("PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT", DEFAULT_ASSERTION_ARTIFACT_ROOT)
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    result: dict[str, Any] = {
        "item": "final-assertion",
        "description": "verified final production-ready assertion",
        "env": "PRODUCTION_READY_ASSERTION_JSON",
        "path": str(path),
        "status": "missing",
        "reason": "file_missing",
    }
    if not path.is_file():
        return result
    base_url, tcp_host, tcp_port = target_from_env(env)
    missing_target = missing_target_env(base_url, tcp_host, tcp_port)
    if missing_target:
        result["status"] = "fail"
        result["reason"] = "target_env_missing"
        result["missingEnv"] = missing_target
        return result
    command = [
        "python3",
        str(repo_root / "IMServer/LoadTests/verify_production_ready_assertion.py"),
        "--receipt-json",
        str(path),
        "--require-pass",
        "--require-artifacts-exist",
    ]
    if artifact_root:
        command.extend(["--artifact-root", artifact_root])
    command.extend([
        "--expect-base-url",
        base_url,
        "--expect-tcp-host",
        tcp_host,
        "--expect-tcp-port",
        tcp_port,
    ])
    completed = subprocess.run(command, cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if completed.returncode != 0:
        reason, output = command_failure_reason(completed)
        result["status"] = "fail"
        result["reason"] = reason
        result["output"] = output[-1000:]
        return result
    try:
        claim = read_json_file(path).get("productionClaim")
    except Exception as error:  # noqa: BLE001 - completion report should expose malformed assertion claim.
        result["status"] = "fail"
        result["reason"] = "final_assertion_claim_unreadable"
        result["error"] = str(error)
        return result
    result["productionClaim"] = final_production_claim_result(claim)
    if not result["productionClaim"]["valid"]:
        result["status"] = "fail"
        result["reason"] = "final_assertion_claim_invalid"
        return result
    result["status"] = "pass"
    result["reason"] = "verified"
    return result


def check_final_assertion_archive(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get("PRODUCTION_READY_ASSERTION_ARCHIVE_FILE", "")
    result: dict[str, Any] = {
        "item": "final-assertion-archive",
        "description": "verified self-contained final assertion archive",
        "env": "PRODUCTION_READY_ASSERTION_ARCHIVE_FILE",
        "path": raw,
        "status": "missing",
        "reason": "missing_env",
    }
    if not raw:
        return result
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    result["path"] = str(path)
    if not path.is_file():
        result["reason"] = "file_missing"
        return result
    base_url, tcp_host, tcp_port = target_from_env(env)
    missing_target = missing_target_env(base_url, tcp_host, tcp_port)
    if missing_target:
        result["status"] = "fail"
        result["reason"] = "target_env_missing"
        result["missingEnv"] = missing_target
        return result
    command = [
        "python3",
        str(repo_root / "IMServer/LoadTests/package_production_ready_assertion.py"),
        "--verify-archive",
        "--archive-file",
        str(path),
        "--expect-base-url",
        base_url,
        "--expect-tcp-host",
        tcp_host,
        "--expect-tcp-port",
        tcp_port,
    ]
    completed = subprocess.run(command, cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if completed.returncode != 0:
        reason, output = command_failure_reason(completed)
        result["status"] = "fail"
        result["reason"] = reason
        result["output"] = output[-1000:]
        return result
    try:
        claim = archive_manifest_claim(path)
    except Exception as error:  # noqa: BLE001 - completion report should expose malformed archive claim.
        result["status"] = "fail"
        result["reason"] = "final_assertion_archive_claim_unreadable"
        result["error"] = str(error)
        return result
    result["productionClaim"] = final_production_claim_result(claim)
    if not result["productionClaim"]["valid"]:
        result["status"] = "fail"
        result["reason"] = "final_assertion_archive_claim_invalid"
        return result
    result["status"] = "pass"
    result["reason"] = "verified"
    return result


def check_topology_smoke(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get("PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON") or env.get("TOPOLOGY_SMOKE_RECEIPT_JSON") or env.get("IMSERVER_PRODUCTION_SMOKE_JSON", "")
    result: dict[str, Any] = {
        "item": "topology-smoke",
        "description": "verified production topology smoke receipt",
        "env": "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON",
        "path": raw,
        "status": "missing",
        "reason": "missing_env",
    }
    if not raw:
        return result
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    result["path"] = str(path)
    if not path.is_file():
        result["reason"] = "file_missing"
        return result
    command = [
        "python3",
        str(repo_root / "IMServer/scripts/verify_production_smoke.py"),
        "--receipt-json",
        str(path),
        "--require-pass",
        "--require-artifacts-exist",
        "--max-age-seconds",
        env.get("PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS", env.get("TOPOLOGY_SMOKE_MAX_AGE_SECONDS", "86400")),
        "--max-future-skew-seconds",
        env.get("PRODUCTION_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS", env.get("TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS", "300")),
    ]
    completed = subprocess.run(command, cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if completed.returncode != 0:
        reason, output = command_failure_reason(completed)
        result["status"] = "fail"
        result["reason"] = reason
        result["output"] = output[-1000:]
        return result
    result["status"] = "pass"
    result["reason"] = "verified"
    return result


def int_env(env: dict[str, str], name: str, default: int) -> int:
    try:
        return int(env.get(name, str(default)))
    except Exception:
        return default


def check_static_gate_receipt(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    raw = env.get("PRODUCTION_STATIC_GATE_RECEIPT_JSON", DEFAULT_STATIC_GATE_RECEIPT_JSON)
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    max_age = int_env(env, "PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS", 86400)
    future_skew = int_env(env, "PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS", 300)
    bootstrap = str(env.get("PRODUCTION_COMPLETION_STATUS_STATIC_RECEIPT_BOOTSTRAP") or "").lower() in {"1", "true", "yes"}
    receipt = verify_static_gate_receipt(
        path,
        max_age,
        future_skew,
        require_completion_status=not bootstrap,
        require_recovery_plan=not bootstrap,
        expect_repo_root=str(repo_root),
        require_current_git=True,
        require_clean_git=True,
    )
    status = "pass" if receipt["status"] == "pass" else "fail"
    result: dict[str, Any] = {
        "item": "local-static-gate-receipt",
        "description": "fresh local validate-production-static pass receipt",
        "path": str(path),
        "status": status,
        "reason": receipt["reason"],
        "maxAgeSeconds": max_age,
        "cleanGit": True,
    }
    if bootstrap:
        result["staticReceiptBootstrap"] = True
    for field in (
        "field",
        "expected",
        "actual",
        "value",
        "expectedSha256",
        "actualSha256",
        "expectedRepoRoot",
        "actualRepoRoot",
        "expectedCommand",
        "actualCommand",
        "ageSeconds",
        "currentDirtyCount",
        "boundDirtyCount",
        "currentTrackedModifiedCount",
        "boundTrackedModifiedCount",
        "currentUntrackedCount",
        "boundUntrackedCount",
    ):
        if field in receipt:
            result[field] = receipt[field]
    return result


def percent(pass_count: int, total: int) -> int:
    if total <= 0:
        return 0
    return round((pass_count / total) * 100)


def evidence_recovery_plan(missing: list[dict[str, Any]]) -> list[dict[str, Any]]:
    plan: list[dict[str, Any]] = []
    for item in missing:
        if item.get("scope") != "evidence":
            continue
        name = str(item.get("item") or "")
        contract = EVIDENCE_CONTRACTS.get(name)
        if contract is None:
            continue
        plan.append({
            "item": name,
            "reason": item.get("reason", ""),
            "requiredEnv": list(contract["requiredEnv"]),
            "runCommand": contract["runCommand"],
            "verifyCommand": contract["verifyCommand"],
        })
    return plan


def missing_record(scope: str, item: dict[str, Any]) -> dict[str, Any]:
    record: dict[str, Any] = {
        "scope": scope,
        "item": item["item"],
        "reason": item["reason"],
        "path": item.get("path", ""),
    }
    if scope == "evidence":
        record["env"] = item.get("env", "")
    for field in (
        "field",
        "expected",
        "actual",
        "value",
        "expectedSha256",
        "actualSha256",
        "expectedRepoRoot",
        "actualRepoRoot",
        "expectedCommand",
        "actualCommand",
        "ageSeconds",
        "currentDirtyCount",
        "boundDirtyCount",
        "currentTrackedModifiedCount",
        "boundTrackedModifiedCount",
        "currentUntrackedCount",
        "boundUntrackedCount",
    ):
        if field in item:
            record[field] = item[field]
    return record


def build_report(repo_root: Path, env: dict[str, str]) -> dict[str, Any]:
    local_results = [check_local(repo_root, check) for check in LOCAL_CHECKS]
    local_results.append(check_static_gate_receipt(repo_root, env))
    evidence_results = [add_evidence_contract(check_evidence(repo_root, check, env)) for check in EVIDENCE_CHECKS]
    evidence_results.append(add_evidence_contract(check_deploy_readiness(repo_root, env)))
    evidence_results.append(add_evidence_contract(check_current_readiness(repo_root, env)))
    evidence_results.append(add_evidence_contract(check_production_acceptance(repo_root, env)))
    evidence_results.append(add_evidence_contract(check_production_evidence_package(repo_root, env)))
    evidence_results.append(add_evidence_contract(check_topology_smoke(repo_root, env)))
    evidence_results.append(add_evidence_contract(check_final_assertion(repo_root, env)))
    evidence_results.append(add_evidence_contract(check_final_assertion_archive(repo_root, env)))
    target = production_target(env)
    local_pass = sum(1 for item in local_results if item["status"] == "pass")
    evidence_pass = sum(1 for item in evidence_results if item["status"] == "pass")
    local_completion = percent(local_pass, len(local_results))
    live_completion = percent(evidence_pass, len(evidence_results))
    production_completion = round((local_completion * 0.75) + (live_completion * 0.25))
    final_assertion = next((item for item in evidence_results if item["item"] == "final-assertion"), None)
    final_archive = next((item for item in evidence_results if item["item"] == "final-assertion-archive"), None)
    final_assertion_claim_valid = bool(((final_assertion or {}).get("productionClaim") or {}).get("valid"))
    final_archive_claim_valid = bool(((final_archive or {}).get("productionClaim") or {}).get("valid"))
    ready = (
        local_pass == len(local_results)
        and evidence_pass == len(evidence_results)
        and final_assertion is not None
        and final_assertion["status"] == "pass"
        and final_assertion_claim_valid
        and final_archive is not None
        and final_archive["status"] == "pass"
        and final_archive_claim_valid
        and not target["missingEnv"]
    )
    missing = [
        missing_record("local", item)
        for item in local_results
        if item["status"] != "pass"
    ] + [
        missing_record("evidence", item)
        for item in evidence_results
        if item["status"] != "pass"
    ]
    recovery_plan = evidence_recovery_plan(missing)
    local_missing_count = sum(1 for item in missing if item["scope"] == "local")
    live_evidence_missing_count = sum(1 for item in missing if item["scope"] == "evidence")
    claim = production_claim(
        ready=ready,
        local_results=local_results,
        evidence_results=evidence_results,
        target=target,
        final_assertion=final_assertion,
        final_archive=final_archive,
    )
    return {
        "kind": "imserver-production-completion-status",
        "schemaVersion": 1,
        "generatedAtEpoch": int(time.time()),
        "repoRoot": str(repo_root),
        "productionTarget": target,
        "productionClaim": claim,
        "readinessTiers": readiness_tiers(
            ready=ready,
            claim=claim,
            local_pass=local_pass,
            local_total=len(local_results),
            evidence_pass=evidence_pass,
            evidence_total=len(evidence_results),
            local_completion=local_completion,
            live_completion=live_completion,
            production_completion=production_completion,
        ),
        "status": "ready" if ready else "incomplete",
        "localCompletionPercent": local_completion,
        "liveEvidenceCompletionPercent": live_completion,
        "productionCompletionPercent": production_completion,
        "weights": {
            "localEngineering": 75,
            "liveProductionEvidence": 25,
        },
        "summary": {
            "localPassed": local_pass,
            "localTotal": len(local_results),
            "localMissingCount": local_missing_count,
            "liveEvidencePassed": evidence_pass,
            "liveEvidenceTotal": len(evidence_results),
            "liveEvidenceMissingCount": live_evidence_missing_count,
            "missingCount": len(missing),
            "evidenceRecoveryPlanCount": len(recovery_plan),
        },
        "localChecks": local_results,
        "evidenceChecks": evidence_results,
        "missing": missing,
        "evidenceRecoveryPlan": recovery_plan,
        "nextActions": next_actions(missing),
    }


def next_actions(missing: list[dict[str, Any]]) -> list[str]:
    actions: list[str] = []
    scopes = {item["scope"] for item in missing}
    if "local" in scopes:
        static_receipt_reasons = {
            str(item.get("reason") or "")
            for item in missing
            if item.get("scope") == "local" and item.get("item") == "local-static-gate-receipt"
        }
        if "production_static_gate_git_dirty" in static_receipt_reasons:
            actions.append("Commit or remove local changes, then rerun make validate-production-static to regenerate a clean production static receipt.")
        elif "git_binding_mismatch" in static_receipt_reasons:
            actions.append("Run make production-worktree-plan, run make production-worktree-stage-dry-run-batch and verify-production-worktree-stage-dry-run-batch, then review each commit group, run stageDryRunCommand and stageDryRunReceiptCommand, execute only the source_change stageCommand after review, verify the staged group, clean generated/forbidden artifacts separately, then rerun make validate-production-static.")
        elif static_receipt_reasons:
            actions.append("Rerun make validate-production-static to refresh the production static receipt before using it as evidence.")
        else:
            actions.append("Run make validate-production-static, then fix missing local production scripts, Make targets, docs, or workflows.")
    evidence_items = {item["item"] for item in missing if item["scope"] == "evidence"}
    if evidence_items:
        actions.append("Restore a real production target and run make run-current-production-readiness.")
        actions.append("Run make run-production-acceptance, make verify-production-acceptance, and make assert-production-ready.")
        actions.append("Run make package-production-ready-assertion and verify the archive before claiming production ready.")
    return actions


def readiness_tiers(
    *,
    ready: bool,
    claim: dict[str, Any],
    local_pass: int,
    local_total: int,
    evidence_pass: int,
    evidence_total: int,
    local_completion: int,
    live_completion: int,
    production_completion: int,
) -> dict[str, Any]:
    local_complete = local_pass == local_total
    live_complete = evidence_pass == evidence_total
    target_complete = bool(claim.get("targetComplete"))
    blockers = [str(item) for item in claim.get("blockers") or []]
    return {
        "localEngineering": {
            "status": "complete" if local_complete else "incomplete",
            "percent": local_completion,
            "passed": local_pass,
            "total": local_total,
            "claim": "local-engineering-complete" if local_complete else "local-engineering-incomplete",
        },
        "liveProductionEvidence": {
            "status": "complete" if live_complete else "incomplete",
            "percent": live_completion,
            "passed": evidence_pass,
            "total": evidence_total,
            "claim": "verified-live-production-evidence" if live_complete else "missing-live-production-evidence",
        },
        "productionReady": {
            "status": "ready" if ready else "blocked",
            "percent": production_completion,
            "claimAllowed": ready,
            "targetComplete": target_complete,
            "blockingReasons": blockers,
            "claim": "production-ready" if ready else "not-production-ready",
        },
    }


def production_claim(
    *,
    ready: bool,
    local_results: list[dict[str, Any]],
    evidence_results: list[dict[str, Any]],
    target: dict[str, Any],
    final_assertion: dict[str, Any] | None,
    final_archive: dict[str, Any] | None,
) -> dict[str, Any]:
    local_complete = all(item["status"] == "pass" for item in local_results)
    live_complete = all(item["status"] == "pass" for item in evidence_results)
    final_assertion_passed = final_assertion is not None and final_assertion.get("status") == "pass"
    final_archive_passed = final_archive is not None and final_archive.get("status") == "pass"
    final_assertion_claim_valid = bool(((final_assertion or {}).get("productionClaim") or {}).get("valid"))
    final_archive_claim_valid = bool(((final_archive or {}).get("productionClaim") or {}).get("valid"))
    target_complete = not target.get("missingEnv")
    blockers: list[str] = []
    if not local_complete:
        blockers.append("local-engineering-incomplete")
    if not live_complete:
        blockers.append("live-production-evidence-incomplete")
    if not target_complete:
        blockers.append("production-target-incomplete")
    if not final_assertion_passed:
        blockers.append("final-assertion-not-passed")
    if not final_archive_passed:
        blockers.append("final-assertion-archive-not-passed")
    if not final_assertion_claim_valid:
        blockers.append("final-assertion-claim-not-verified")
    if not final_archive_claim_valid:
        blockers.append("final-assertion-archive-claim-not-verified")
    return {
        "productionReady": ready,
        "claimAllowed": ready,
        "claimLevel": "production-ready" if ready else "not-production-ready",
        "basis": "verified-live-production-evidence" if ready else "local-engineering-or-partial-evidence-only",
        "localEngineeringComplete": local_complete,
        "liveEvidenceComplete": live_complete,
        "targetComplete": target_complete,
        "finalAssertionPassed": final_assertion_passed,
        "finalAssertionArchivePassed": final_archive_passed,
        "finalAssertionClaimVerified": final_assertion_claim_valid,
        "finalAssertionArchiveClaimVerified": final_archive_claim_valid,
        "requiredEvidence": [item for item in EVIDENCE_CONTRACTS],
        "blockers": blockers,
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(value, encoding="utf-8")
    tmp.replace(path)


def render_text(report: dict[str, Any]) -> str:
    target = report.get("productionTarget") or {}
    claim = report.get("productionClaim") or {}
    tiers = report.get("readinessTiers") or {}
    local_tier = tiers.get("localEngineering") or {}
    live_tier = tiers.get("liveProductionEvidence") or {}
    production_tier = tiers.get("productionReady") or {}
    missing_target = ",".join(str(item) for item in target.get("missingEnv") or []) or "-"
    lines = [
        f"production_completion_status status={report['status']} "
        f"local={report['localCompletionPercent']} "
        f"liveEvidence={report['liveEvidenceCompletionPercent']} "
        f"production={report['productionCompletionPercent']}",
        f"readiness_tiers localEngineering={local_tier.get('status') or '-'}:{local_tier.get('percent', '-')} "
        f"liveProductionEvidence={live_tier.get('status') or '-'}:{live_tier.get('percent', '-')} "
        f"productionReady={production_tier.get('status') or '-'}:{production_tier.get('percent', '-')}",
        f"production_claim productionReady={str(bool(claim.get('productionReady'))).lower()} "
        f"claimAllowed={str(bool(claim.get('claimAllowed'))).lower()} "
        f"claimLevel={claim.get('claimLevel') or 'not-production-ready'} "
        f"basis={claim.get('basis') or '-'} "
        f"finalAssertionClaimVerified={str(bool(claim.get('finalAssertionClaimVerified'))).lower()} "
        f"finalAssertionArchiveClaimVerified={str(bool(claim.get('finalAssertionArchiveClaimVerified'))).lower()}",
        f"production_target baseURL={target.get('baseURL') or '-'} "
        f"tcpHost={target.get('tcpHost') or '-'} "
        f"tcpPort={target.get('tcpPort') or '-'} "
        f"missingEnv={missing_target}",
        f"local passed {report['summary']['localPassed']}/{report['summary']['localTotal']}",
        f"live evidence passed {report['summary']['liveEvidencePassed']}/{report['summary']['liveEvidenceTotal']}",
        f"summary missing={report['summary']['missingCount']} "
        f"localMissing={report['summary']['localMissingCount']} "
        f"liveEvidenceMissing={report['summary']['liveEvidenceMissingCount']} "
        f"recoveryPlan={report['summary']['evidenceRecoveryPlanCount']}",
    ]
    for item in report["missing"][:12]:
        detail = item.get("path") or item.get("env") or ""
        diagnostic = " ".join(
            f"{field}={item[field]}"
            for field in (
                "field",
                "expected",
                "actual",
                "value",
                "ageSeconds",
                "currentDirtyCount",
                "boundDirtyCount",
                "currentTrackedModifiedCount",
                "boundTrackedModifiedCount",
                "currentUntrackedCount",
                "boundUntrackedCount",
            )
            if field in item
        )
        lines.append(
            f"missing scope={item['scope']} item={item['item']} reason={item['reason']} {detail} {diagnostic}".rstrip()
        )
    if len(report["missing"]) > 12:
        lines.append(f"missing_more count={len(report['missing']) - 12}")
    for item in report.get("evidenceRecoveryPlan", []):
        lines.append(
            f"recovery item={item['item']} "
            f"reason={item['reason']} "
            f"run={item['runCommand']} "
            f"verify={item['verifyCommand']}"
        )
    for action in report["nextActions"]:
        lines.append(f"next_action {action}")
    return "\n".join(lines)


def render_markdown(report: dict[str, Any]) -> str:
    summary = report["summary"]
    target = report.get("productionTarget") or {}
    claim = report.get("productionClaim") or {}
    tiers = report.get("readinessTiers") or {}
    local_tier = tiers.get("localEngineering") or {}
    live_tier = tiers.get("liveProductionEvidence") or {}
    production_tier = tiers.get("productionReady") or {}
    missing_target = ", ".join(f"`{item}`" for item in target.get("missingEnv") or []) or "None"
    claim_blockers = ", ".join(f"`{item}`" for item in claim.get("blockers") or []) or "None"
    lines = [
        "# Production Completion Status",
        "",
        f"- status: `{report['status']}`",
        f"- productionReadyClaimAllowed: `{bool(claim.get('claimAllowed'))}`",
        f"- productionReadyClaimLevel: `{claim.get('claimLevel') or 'not-production-ready'}`",
        f"- productionReadyFinalAssertionClaimVerified: `{bool(claim.get('finalAssertionClaimVerified'))}`",
        f"- productionReadyFinalAssertionArchiveClaimVerified: `{bool(claim.get('finalAssertionArchiveClaimVerified'))}`",
        f"- productionReadyClaimBlockers: {claim_blockers}",
        f"- localEngineering: `{summary['localPassed']}/{summary['localTotal']}` (`{report['localCompletionPercent']}%`)",
        f"- liveProductionEvidence: `{summary['liveEvidencePassed']}/{summary['liveEvidenceTotal']}` (`{report['liveEvidenceCompletionPercent']}%`)",
        f"- productionCompletion: `{report['productionCompletionPercent']}%`",
        f"- localEngineeringTier: `{local_tier.get('status') or '-'}` / `{local_tier.get('claim') or '-'}`",
        f"- liveProductionEvidenceTier: `{live_tier.get('status') or '-'}` / `{live_tier.get('claim') or '-'}`",
        f"- productionReadyTier: `{production_tier.get('status') or '-'}` / `{production_tier.get('claim') or '-'}`",
        f"- targetBaseURL: `{target.get('baseURL') or '-'}`",
        f"- targetTCP: `{target.get('tcpHost') or '-'}:{target.get('tcpPort') or '-'}`",
        f"- targetMissingEnv: {missing_target}",
        f"- generatedAtEpoch: `{report['generatedAtEpoch']}`",
        f"- repoRoot: `{report['repoRoot']}`",
        "",
        "Do not claim production readiness unless status is `ready`, every live evidence check passes, and the final assertion plus archive production claims verify.",
        "",
    ]
    missing = report.get("missing") or []
    if missing:
        lines.extend(["## Missing Requirements", ""])
        for item in missing:
            detail = item.get("path") or item.get("env") or ""
            suffix = f" `{detail}`" if detail else ""
            diagnostic = ", ".join(
                f"`{field}={item[field]}`"
                for field in (
                    "field",
                    "expected",
                    "actual",
                    "value",
                    "ageSeconds",
                    "currentDirtyCount",
                    "boundDirtyCount",
                    "currentTrackedModifiedCount",
                    "boundTrackedModifiedCount",
                    "currentUntrackedCount",
                    "boundUntrackedCount",
                )
                if field in item
            )
            diagnostic_suffix = f" ({diagnostic})" if diagnostic else ""
            lines.append(f"- `{item['scope']}` / `{item['item']}`: `{item['reason']}`{suffix}{diagnostic_suffix}")
        lines.append("")
    else:
        lines.extend(["## Missing Requirements", "", "None.", ""])

    recovery_plan = report.get("evidenceRecoveryPlan") or []
    if recovery_plan:
        lines.extend([
            "## Evidence Recovery Plan",
            "",
            "Recovery commands are operator instructions, not proof. Re-run the listed verify command after each step.",
            "",
        ])
        for index, item in enumerate(recovery_plan, start=1):
            required_env = " ".join(f"${name}" for name in item["requiredEnv"])
            lines.extend([
                f"### {index}. {item['item']}",
                "",
                f"- reason: `{item['reason']}`",
                f"- requiredEnv: `{required_env}`",
                f"- run: `{item['runCommand']}`",
                f"- verify: `{item['verifyCommand']}`",
                "",
            ])
    else:
        lines.extend(["## Evidence Recovery Plan", "", "No recovery steps required by the current status report.", ""])

    next_actions = report.get("nextActions") or []
    lines.extend(["## Next Actions", ""])
    if next_actions:
        for action in next_actions:
            lines.append(f"- {action}")
    else:
        lines.append("None.")
    lines.append("")
    return "\n".join(lines)


def assert_recovery_plan_rendered(report: dict[str, Any], rendered: str) -> None:
    recovery_plan = report.get("evidenceRecoveryPlan", [])
    lines = [line for line in rendered.splitlines() if line.startswith("recovery item=")]
    if len(lines) != len(recovery_plan):
        raise SystemExit(
            f"self_test_recovery_render_count_mismatch expected={len(recovery_plan)} actual={len(lines)}"
        )
    for item in recovery_plan:
        expected_tokens = (
            f"recovery item={item['item']} ",
            f"reason={item['reason']} ",
            f"run={item['runCommand']} ",
            f"verify={item['verifyCommand']}",
        )
        if not any(all(token in line for token in expected_tokens) for line in lines):
            raise SystemExit(f"self_test_recovery_render_item_missing item={item['item']}")


def assert_summary_counts_rendered(report: dict[str, Any], rendered: str) -> None:
    expected = (
        f"summary missing={report['summary']['missingCount']} "
        f"localMissing={report['summary']['localMissingCount']} "
        f"liveEvidenceMissing={report['summary']['liveEvidenceMissingCount']} "
        f"recoveryPlan={report['summary']['evidenceRecoveryPlanCount']}"
    )
    if expected not in rendered.splitlines():
        raise SystemExit("self_test_summary_counts_render_missing")


def assert_readiness_tiers_rendered(report: dict[str, Any], rendered: str, markdown: str) -> None:
    tiers = report.get("readinessTiers") or {}
    local_tier = tiers.get("localEngineering") or {}
    live_tier = tiers.get("liveProductionEvidence") or {}
    production_tier = tiers.get("productionReady") or {}
    expected_line = (
        f"readiness_tiers localEngineering={local_tier.get('status') or '-'}:{local_tier.get('percent', '-')} "
        f"liveProductionEvidence={live_tier.get('status') or '-'}:{live_tier.get('percent', '-')} "
        f"productionReady={production_tier.get('status') or '-'}:{production_tier.get('percent', '-')}"
    )
    if expected_line not in rendered.splitlines():
        raise SystemExit("self_test_readiness_tiers_render_missing")
    expected_markdown = f"productionReadyTier: `{production_tier.get('status') or '-'}` / `{production_tier.get('claim') or '-'}`"
    if expected_markdown not in markdown:
        raise SystemExit("self_test_readiness_tiers_markdown_missing")


def assert_production_claim_rendered(report: dict[str, Any], rendered: str, markdown: str) -> None:
    claim = report.get("productionClaim") or {}
    expected_line = (
        f"production_claim productionReady={str(bool(claim.get('productionReady'))).lower()} "
        f"claimAllowed={str(bool(claim.get('claimAllowed'))).lower()} "
        f"claimLevel={claim.get('claimLevel') or 'not-production-ready'} "
        f"basis={claim.get('basis') or '-'} "
        f"finalAssertionClaimVerified={str(bool(claim.get('finalAssertionClaimVerified'))).lower()} "
        f"finalAssertionArchiveClaimVerified={str(bool(claim.get('finalAssertionArchiveClaimVerified'))).lower()}"
    )
    if expected_line not in rendered.splitlines():
        raise SystemExit("self_test_production_claim_render_missing")
    expected_markdown = f"productionReadyClaimAllowed: `{bool(claim.get('claimAllowed'))}`"
    if expected_markdown not in markdown:
        raise SystemExit("self_test_production_claim_markdown_missing")
    expected_assertion_claim_markdown = (
        f"productionReadyFinalAssertionClaimVerified: `{bool(claim.get('finalAssertionClaimVerified'))}`"
    )
    if expected_assertion_claim_markdown not in markdown:
        raise SystemExit("self_test_production_claim_assertion_markdown_missing")
    expected_archive_claim_markdown = (
        f"productionReadyFinalAssertionArchiveClaimVerified: `{bool(claim.get('finalAssertionArchiveClaimVerified'))}`"
    )
    if expected_archive_claim_markdown not in markdown:
        raise SystemExit("self_test_production_claim_archive_markdown_missing")


def self_test() -> None:
    import production_evidence_recovery_plan as recovery_plan_renderer

    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        source_root = Path(__file__).resolve().parents[2]
        content_by_path: dict[str, list[str]] = {}
        for check in LOCAL_CHECKS:
            content_by_path.setdefault(check.path, []).extend(check.contains or (check.description,))
        for check_path, markers in content_by_path.items():
            path = root / check_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("\n".join(markers) + "\n", encoding="utf-8")
        for check in LOCAL_CHECKS:
            path = root / check.path
            if check.executable:
                path.chmod(0o755)
        static_receipt = root / DEFAULT_STATIC_GATE_RECEIPT_JSON
        static_receipt.parent.mkdir(parents=True, exist_ok=True)
        static_completion = root / DEFAULT_STATIC_COMPLETION_STATUS_JSON
        static_completion_markdown = root / DEFAULT_STATIC_COMPLETION_STATUS_MARKDOWN
        static_completion.parent.mkdir(parents=True, exist_ok=True)
        completion_generated_at = int(time.time())
        recovery_steps = [
            {
                "item": item,
                "reason": "missing_env",
                "requiredEnv": list(contract["requiredEnv"]),
                "runCommand": str(contract["runCommand"]),
                "verifyCommand": str(contract["verifyCommand"]),
            }
            for item, contract in EVIDENCE_CONTRACTS.items()
        ]
        missing_evidence = [
            {
                "scope": "evidence",
                "item": step["item"],
                "reason": step["reason"],
                "path": "",
                "env": step["requiredEnv"][0],
            }
            for step in recovery_steps
        ]
        static_production_target = {
            "baseURL": "",
            "tcpHost": "",
            "tcpPort": "",
            "missingEnv": ["BASE_URL", "TCP_HOST", "TCP_PORT"],
        }
        static_completion.write_text(
            json.dumps({
                "kind": "imserver-production-completion-status",
                "schemaVersion": 1,
                "repoRoot": str(root),
                "generatedAtEpoch": completion_generated_at,
                "productionTarget": static_production_target,
                "productionClaim": {
                    "productionReady": False,
                    "claimAllowed": False,
                    "claimLevel": "not-production-ready",
                    "basis": "local-engineering-or-partial-evidence-only",
                    "localEngineeringComplete": True,
                    "liveEvidenceComplete": False,
                    "targetComplete": False,
                    "finalAssertionPassed": False,
                    "finalAssertionArchivePassed": False,
                    "finalAssertionClaimVerified": False,
                    "finalAssertionArchiveClaimVerified": False,
                    "requiredEvidence": list(EVIDENCE_CONTRACTS),
                    "blockers": [
                        "live-production-evidence-incomplete",
                        "production-target-incomplete",
                        "final-assertion-not-passed",
                        "final-assertion-archive-not-passed",
                        "final-assertion-claim-not-verified",
                        "final-assertion-archive-claim-not-verified",
                    ],
                },
                "readinessTiers": readiness_tiers(
                    ready=False,
                    claim={
                        "targetComplete": False,
                        "blockers": [
                            "live-production-evidence-incomplete",
                            "production-target-incomplete",
                            "final-assertion-not-passed",
                            "final-assertion-archive-not-passed",
                            "final-assertion-claim-not-verified",
                            "final-assertion-archive-claim-not-verified",
                        ],
                    },
                    local_pass=1,
                    local_total=1,
                    evidence_pass=0,
                    evidence_total=7,
                    local_completion=100,
                    live_completion=0,
                    production_completion=75,
                ),
                "status": "incomplete",
                "localCompletionPercent": 100,
                "liveEvidenceCompletionPercent": 0,
                "productionCompletionPercent": 75,
                "weights": {
                    "localEngineering": 75,
                    "liveProductionEvidence": 25,
                },
                "summary": {
                    "localPassed": 1,
                    "localTotal": 1,
                    "localMissingCount": 0,
                    "liveEvidencePassed": 0,
                    "liveEvidenceTotal": 7,
                    "liveEvidenceMissingCount": 7,
                    "missingCount": 7,
                    "evidenceRecoveryPlanCount": 7,
                },
                "missing": missing_evidence,
                "evidenceRecoveryPlan": recovery_steps,
                "nextActions": [
                    "Restore a real production target and run make run-current-production-readiness."
                ],
            }),
            encoding="utf-8",
        )
        static_completion_markdown.write_text(
            render_markdown(json.loads(static_completion.read_text(encoding="utf-8"))),
            encoding="utf-8",
        )
        static_completion_payload = json.loads(static_completion.read_text(encoding="utf-8"))
        static_recovery_plan = root / DEFAULT_STATIC_RECOVERY_PLAN_JSON
        static_recovery_plan_markdown = root / DEFAULT_STATIC_RECOVERY_PLAN_MARKDOWN
        static_recovery_plan_script = root / DEFAULT_STATIC_RECOVERY_PLAN_SCRIPT
        static_recovery_plan.parent.mkdir(parents=True, exist_ok=True)
        static_recovery_plan_markdown.parent.mkdir(parents=True, exist_ok=True)
        static_recovery_plan_script.parent.mkdir(parents=True, exist_ok=True)
        static_recovery_plan_payload = {
            "kind": "imserver-production-evidence-recovery-plan",
            "schemaVersion": 1,
            "generatedAtEpoch": completion_generated_at,
            "sourceStatus": "incomplete",
            "sourceStatusJson": str(static_completion),
            "sourceStatusGeneratedAtEpoch": completion_generated_at,
            "productionTarget": static_production_target,
            "productionClaim": static_completion_payload["productionClaim"],
            "readinessTiers": static_completion_payload["readinessTiers"],
            "readyToClaimProduction": False,
            "localEngineeringComplete": True,
            "summary": {
                "status": "incomplete",
                "localCompletionPercent": 100,
                "liveEvidenceCompletionPercent": 0,
                "productionCompletionPercent": 75,
                "localPassed": 1,
                "localTotal": 1,
                "liveEvidencePassed": 0,
                "liveEvidenceTotal": 7,
                "missingCount": 7,
                "evidenceRecoveryPlanCount": 7,
            },
            "localMissing": [],
            "evidenceMissing": missing_evidence,
            "steps": recovery_steps,
            "finalVerificationCommands": [
                "make production-completion-status",
                "make verify-production-completion-status",
                "make verify-production-ready-assertion",
                "make verify-production-ready-archive",
            ],
        }
        static_recovery_plan_payload["operatorEnvironmentTemplate"] = recovery_plan_renderer.operator_environment_template(static_recovery_plan_payload)
        static_recovery_plan_payload["oneShotRecoveryCommands"] = recovery_plan_renderer.one_shot_recovery_commands(static_recovery_plan_payload)
        static_recovery_plan.write_text(
            json.dumps(static_recovery_plan_payload),
            encoding="utf-8",
        )
        static_recovery_plan_markdown.write_text(
            recovery_plan_renderer.render_markdown(static_recovery_plan_payload),
            encoding="utf-8",
        )
        static_recovery_plan_script.write_text(
            recovery_plan_renderer.render_shell_script(static_recovery_plan_payload),
            encoding="utf-8",
        )
        static_recovery_plan_script.chmod(0o755)
        tool_dir = root / "IMServer/LoadTests"
        for name in (
            "verify_production_ready_assertion.py",
            "package_production_ready_assertion.py",
            "perf_forbidden_artifacts.py",
            "production_target_policy.py",
            "verify_deploy_readiness_receipt.py",
            "production_static_gate_receipt.py",
            "production_completion_status.py",
            "production_evidence_recovery_plan.py",
            "verify_production_evidence_recovery_paths.py",
            "verify_production_completion_status.py",
        ):
            source = source_root / "IMServer/LoadTests" / name
            destination = tool_dir / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
        acceptance_wrapper = tool_dir / "verify_production_acceptance.sh"
        acceptance_wrapper.write_text(
            (source_root / "IMServer/LoadTests/verify_production_acceptance.sh").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        acceptance_wrapper.chmod(0o755)
        fake_current_readiness_verifier = tool_dir / "perf_current_production_readiness_verify.py"
        fake_current_readiness_verifier.write_text(
            "#!/usr/bin/env python3\n"
            "# current_production_readiness_verify_self_test result=pass\n"
            "# require_state_production_evidence_blocker_contract(\n"
            "# require_operator_network_state_consistency(\n"
            "# target_mismatch_not_detected\n"
            "# operatorNetworkPreflight\n"
            "import json\n"
            "import sys\n"
            "from pathlib import Path\n"
            "args = sys.argv[1:]\n"
            "required = ['--readiness-json', '--dashboard-json', '--state-json', '--probe-json', '--evidence-dir', '--expect-base-url', '--expect-tcp-host', '--expect-tcp-port', '--max-age-seconds', '--max-future-skew-seconds']\n"
            "missing = [flag for flag in required if flag not in args]\n"
            "if missing:\n"
            "    raise SystemExit('missing_flags=' + ','.join(missing))\n"
            "for flag in ['--readiness-json', '--dashboard-json', '--state-json', '--probe-json']:\n"
            "    path = Path(args[args.index(flag) + 1])\n"
            "    if not path.is_file():\n"
            "        raise SystemExit(f'missing_file flag={flag} path={path}')\n"
            "evidence_dir = Path(args[args.index('--evidence-dir') + 1])\n"
            "if not evidence_dir.is_dir():\n"
            "    raise SystemExit(f'missing_evidence_dir path={evidence_dir}')\n"
            "payload = json.loads(Path(args[args.index('--readiness-json') + 1]).read_text(encoding='utf-8'))\n"
            "if payload.get('status') != 'PASS':\n"
            "    raise SystemExit('readiness_status_not_pass')\n"
            "print('current_production_readiness_artifacts result=pass')\n",
            encoding="utf-8",
        )
        fake_production_acceptance_verifier = tool_dir / "perf_production_acceptance_verify.py"
        fake_production_acceptance_verifier.write_text(
            "#!/usr/bin/env python3\n"
            "# from perf_forbidden_artifacts import is_forbidden_runtime_artifact\n"
            "# production_acceptance_verify_self_test result=pass\n"
            "# MAX_PACKAGE_ARCHIVE_MEMBER_BYTES\n"
            "# MAX_PACKAGE_ARCHIVE_TOTAL_BYTES\n"
            "# MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES\n"
            "# archive_member_sha256(\n"
            "# validate_package_archive_member(\n"
            "# package_archive_member_too_large\n"
            "# package_archive_total_too_large\n"
            "# package_archive_text_member_too_large\n"
            "# package_manifest_file_record_bytes_invalid\n"
            "# self_test_archive_member_hash_full_read_detected\n"
            "# self_test_archive_text_member_limit_passed\n"
            "# self_test_manifest_bytes_string_package_passed\n"
            "# self_test_package_archive_oversized_member_passed\n"
            "# self_test_package_archive_total_limit_passed\n"
            "# package_archive_forbidden_artifact\n"
            "# package_manifest_forbidden_artifact\n"
            "# self_test_account_artifact_package_passed\n"
            "import tarfile\n"
            "import sys\n"
            "from pathlib import Path\n"
            "def is_forbidden_evidence_artifact(path):\n"
            "    return False\n"
            "def write_minimal_evidence_package(package, stage, target):\n"
            "    stage.mkdir(parents=True, exist_ok=True)\n"
            "    (stage / 'production-evidence-manifest.json').write_text('{\"schemaVersion\":1}', encoding='utf-8')\n"
            "    (stage / 'production-gate.json').write_text('{\"schemaVersion\":1,\"status\":\"PASS\"}', encoding='utf-8')\n"
            "    (stage / 'README.md').write_text('ok\\n', encoding='utf-8')\n"
            "    (stage / 'SHA256SUMS').write_text('', encoding='utf-8')\n"
            "    (stage / 'current-production-readiness.json').write_text('{\"schemaVersion\":1,\"status\":\"PASS\"}', encoding='utf-8')\n"
            "    (stage / 'current-production-readiness.md').write_text('ok\\n', encoding='utf-8')\n"
            "    with tarfile.open(package, 'w:gz') as archive:\n"
            "        for member in sorted(stage.iterdir()):\n"
            "            archive.add(member, arcname=member.name)\n"
            "def verify_package_archive(path, *, expected_target):\n"
            "    if not Path(path).is_file():\n"
            "        raise SystemExit(f'package_missing path={path}')\n"
            "if __name__ == '__main__':\n"
            "    args = sys.argv[1:]\n"
            "    required = ['--verify-package-archive', '--package-file', '--expect-base-url', '--expect-tcp-host', '--expect-tcp-port']\n"
            "    missing = [flag for flag in required if flag not in args]\n"
            "    if missing:\n"
            "        raise SystemExit('missing_flags=' + ','.join(missing))\n"
            "    package = Path(args[args.index('--package-file') + 1])\n"
            "    if not package.is_file():\n"
            "        raise SystemExit(f'package_missing path={package}')\n"
            "    print('production_acceptance_verify_package_archive result=pass')\n",
            encoding="utf-8",
        )
        smoke_tool_dir = root / "IMServer/scripts"
        smoke_tool = smoke_tool_dir / "verify_production_smoke.py"
        smoke_tool_dir.mkdir(parents=True, exist_ok=True)
        smoke_tool.write_text((source_root / "IMServer/scripts/verify_production_smoke.py").read_text(encoding="utf-8"), encoding="utf-8")
        (root / ".gitignore").write_text(
            "IMServer/LoadTests/results/\n"
            "evidence/\n"
            "**/__pycache__/\n",
            encoding="utf-8",
        )
        for command in (
            ["git", "init"],
            ["git", "config", "user.email", "self-test@example.invalid"],
            ["git", "config", "user.name", "Production Completion Self Test"],
            ["git", "add", "."],
            ["git", "commit", "-m", "production completion self-test fixture"],
        ):
            completed = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if completed.returncode != 0:
                raise SystemExit(f"self_test_git_fixture_failed command={' '.join(command)} stdout={completed.stdout} stderr={completed.stderr}")
        static_receipt.write_text(
            json.dumps(
                static_gate_receipt_payload(
                    root,
                    static_completion,
                    static_recovery_plan,
                    static_recovery_plan_markdown,
                    static_recovery_plan_script,
                    static_completion_markdown,
                )
            ),
            encoding="utf-8",
        )
        import importlib.util

        verifier_path = tool_dir / "verify_production_ready_assertion.py"
        spec = importlib.util.spec_from_file_location("completion_status_self_test_assertion", verifier_path)
        if spec is None or spec.loader is None:
            raise SystemExit("self_test_verifier_import_failed")
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        assertion = root / DEFAULT_ASSERTION_JSON
        assertion.parent.mkdir(parents=True, exist_ok=True)
        verifier.write_receipt(assertion, assertion.parent)
        archive = root / "evidence/final-assertion-archive.tar.gz"
        archive.parent.mkdir(parents=True, exist_ok=True)
        completed = subprocess.run(
            [
                "python3",
                str(tool_dir / "package_production_ready_assertion.py"),
                "--receipt-json",
                str(assertion),
                "--archive-file",
                str(archive),
                "--output-dir",
                str(archive.parent),
            ],
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if completed.returncode != 0:
            raise SystemExit(f"self_test_archive_package_failed: {completed.stdout} {completed.stderr}")
        try:
            archive_manifest_claim(archive, max_manifest_bytes=2)
        except ValueError as error:
            if "archive_manifest_too_large" not in str(error):
                raise SystemExit("self_test_archive_manifest_size_reason_missing")
        else:
            raise SystemExit("self_test_archive_manifest_size_limit_passed")
        smoke_spec = importlib.util.spec_from_file_location("completion_status_self_test_smoke", smoke_tool)
        if smoke_spec is None or smoke_spec.loader is None:
            raise SystemExit("self_test_smoke_verifier_import_failed")
        smoke_verifier = importlib.util.module_from_spec(smoke_spec)
        smoke_spec.loader.exec_module(smoke_verifier)
        topology_smoke = root / "evidence/topology-smoke.json"
        topology_smoke.parent.mkdir(parents=True, exist_ok=True)
        topology_payload = smoke_verifier.valid_payload(topology_smoke.parent)
        smoke_verifier.write_json(topology_smoke, topology_payload)
        deploy_spec = importlib.util.spec_from_file_location("completion_status_self_test_deploy", tool_dir / "verify_deploy_readiness_receipt.py")
        if deploy_spec is None or deploy_spec.loader is None:
            raise SystemExit("self_test_deploy_verifier_import_failed")
        deploy_verifier = importlib.util.module_from_spec(deploy_spec)
        deploy_spec.loader.exec_module(deploy_verifier)
        deploy_receipt = root / "evidence/deploy-readiness.json"
        deploy_verifier.write_json(deploy_receipt, deploy_verifier.valid_payload())
        acceptance_package = root / "evidence/production-evidence.tar.gz"
        acceptance_package.write_text("package\n", encoding="utf-8")
        acceptance_receipt = root / "evidence/production-acceptance.json"
        acceptance_receipt.write_text(
            json.dumps({
                "schemaVersion": 1,
                "status": "PASS",
                "generatedAtEpoch": int(time.time()),
                "target": {
                    "baseURL": "https://chat.myim-prod.com",
                    "tcpHost": "tcp.myim-prod.com",
                    "tcpPort": "9000",
                },
                "artifacts": {
                    "package": str(acceptance_package),
                    "packagePresent": True,
                    "packageBytes": acceptance_package.stat().st_size,
                    "packageSha256": hashlib.sha256(acceptance_package.read_bytes()).hexdigest(),
                },
            }),
            encoding="utf-8",
        )
        fake_acceptance_verifier = root / "evidence/fake-production-acceptance-verifier.py"
        fake_acceptance_verifier.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "from pathlib import Path\n"
            "Path(sys.argv[-1]).write_text('\\n'.join(sys.argv[1:]), encoding='utf-8') if sys.argv[-1].endswith('.args') else None\n",
            encoding="utf-8",
        )
        fake_acceptance_verifier.chmod(0o755)
        current_readiness = root / "evidence/current-production-readiness.json"
        current_dashboard = root / "evidence/current-production-dashboard.json"
        current_state = root / "evidence/current-production-state.json"
        current_probe = root / "evidence/current-production-probe.json"
        current_evidence_dir = root / "evidence/current-production-artifacts"
        current_evidence_dir.mkdir(parents=True, exist_ok=True)
        current_readiness.write_text(json.dumps({"schemaVersion": 1, "status": "PASS"}), encoding="utf-8")
        current_dashboard.write_text(json.dumps({"status": "PASS"}), encoding="utf-8")
        current_state.write_text(json.dumps({"status": "PASS"}), encoding="utf-8")
        current_probe.write_text(json.dumps({"status": "pass"}), encoding="utf-8")
        for check in EVIDENCE_CHECKS:
            path = root / f"evidence/{check.item}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("ok\n", encoding="utf-8")
        env = {
            check.path_env: str(root / f"evidence/{check.item}.json")
            for check in EVIDENCE_CHECKS
            if check.path_env not in {"PRODUCTION_READY_ASSERTION_JSON", "PRODUCTION_READY_ASSERTION_ARCHIVE_FILE"}
        }
        env["BASE_URL"] = "https://chat.myim-prod.com"
        env["TCP_HOST"] = "tcp.myim-prod.com"
        env["TCP_PORT"] = "9000"
        env["CURRENT_PRODUCTION_READINESS_JSON"] = str(current_readiness)
        env["CURRENT_PRODUCTION_READINESS_DASHBOARD_JSON"] = str(current_dashboard)
        env["CURRENT_PRODUCTION_READINESS_STATE_JSON"] = str(current_state)
        env["CURRENT_PRODUCTION_READINESS_PROBE_JSON"] = str(current_probe)
        env["CURRENT_PRODUCTION_READINESS_EVIDENCE_DIR"] = str(current_evidence_dir)
        env["CURRENT_PRODUCTION_READINESS_MAX_AGE_SECONDS"] = "86400"
        env["CURRENT_PRODUCTION_READINESS_MAX_FUTURE_SKEW_SECONDS"] = "300"
        env["PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON"] = str(deploy_receipt)
        env["PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS"] = "86400"
        env["PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS"] = "300"
        env["PRODUCTION_ACCEPTANCE_RECEIPT_JSON"] = str(acceptance_receipt)
        env["PRODUCTION_EVIDENCE_PACKAGE"] = str(acceptance_package)
        env["PRODUCTION_ACCEPTANCE_VERIFIER"] = str(fake_acceptance_verifier)
        env["PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON"] = str(topology_smoke)
        env["PRODUCTION_READY_ASSERTION_ARCHIVE_FILE"] = str(archive)
        report = build_report(root, env)
        if report["status"] != "ready":
            raise SystemExit(f"self_test_ready_failed: {report['missing']}")
        ready_claim = report.get("productionClaim") or {}
        if ready_claim.get("finalAssertionClaimVerified") is not True:
            raise SystemExit("self_test_final_assertion_claim_not_verified")
        if ready_claim.get("finalAssertionArchiveClaimVerified") is not True:
            raise SystemExit("self_test_final_archive_claim_not_verified")
        final_assertion_row = next((item for item in report["evidenceChecks"] if item["item"] == "final-assertion"), {})
        final_archive_row = next((item for item in report["evidenceChecks"] if item["item"] == "final-assertion-archive"), {})
        if ((final_assertion_row.get("productionClaim") or {}).get("valid") is not True):
            raise SystemExit("self_test_final_assertion_claim_row_missing")
        if ((final_archive_row.get("productionClaim") or {}).get("valid") is not True):
            raise SystemExit("self_test_final_archive_claim_row_missing")
        if report.get("productionTarget") != {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
            "missingEnv": [],
        }:
            raise SystemExit(f"self_test_production_target_mismatch target={report.get('productionTarget')}")
        ready_text = render_text(report)
        if "production_target baseURL=https://chat.myim-prod.com tcpHost=tcp.myim-prod.com tcpPort=9000 missingEnv=-" not in ready_text:
            raise SystemExit("self_test_production_target_render_missing")
        assert_summary_counts_rendered(report, ready_text)
        assert_recovery_plan_rendered(report, ready_text)
        ready_markdown = render_markdown(report)
        assert_readiness_tiers_rendered(report, ready_text, ready_markdown)
        assert_production_claim_rendered(report, ready_text, ready_markdown)
        if (
            "status: `ready`" not in ready_markdown
            or "targetBaseURL: `https://chat.myim-prod.com`" not in ready_markdown
            or "targetTCP: `tcp.myim-prod.com:9000`" not in ready_markdown
            or "No recovery steps required" not in ready_markdown
        ):
            raise SystemExit("self_test_ready_markdown_mismatch")
        if "recovery item=" in ready_text:
            raise SystemExit("self_test_ready_recovery_render_leaked")
        mismatched_env = dict(env)
        mismatched_env["TCP_HOST"] = "other.myim-prod.com"
        report = build_report(root, mismatched_env)
        missing_items = {
            (item["scope"], item["item"])
            for item in report["missing"]
            if item.get("scope") == "evidence"
        }
        if ("evidence", "final-assertion") not in missing_items:
            raise SystemExit("self_test_final_assertion_target_mismatch_passed")
        if ("evidence", "final-assertion-archive") not in missing_items:
            raise SystemExit("self_test_final_archive_target_mismatch_passed")
        assertion.write_text(json.dumps({"kind": "imserver-production-ready-assertion", "status": "pass"}), encoding="utf-8")
        report = build_report(root, env)
        if not any(item["scope"] == "evidence" and item["item"] == "final-assertion" for item in report["missing"]):
            raise SystemExit("self_test_bad_final_assertion_failed")
        recovery_text = render_text(report)
        assert_summary_counts_rendered(report, recovery_text)
        assert_recovery_plan_rendered(report, recovery_text)
        recovery_markdown = render_markdown(report)
        assert_readiness_tiers_rendered(report, recovery_text, recovery_markdown)
        assert_production_claim_rendered(report, recovery_text, recovery_markdown)
        if "## Evidence Recovery Plan" not in recovery_markdown or "final-assertion" not in recovery_markdown:
            raise SystemExit("self_test_recovery_markdown_missing")
        if "Recovery commands are operator instructions, not proof" not in recovery_markdown:
            raise SystemExit("self_test_recovery_markdown_guard_missing")
        if "recovery item=final-assertion " not in recovery_text or "run=make assert-production-ready" not in recovery_text:
            raise SystemExit("self_test_recovery_render_missing")
        verifier.write_receipt(assertion, assertion.parent)
        archive.write_text("not an archive\n", encoding="utf-8")
        report = build_report(root, env)
        if not any(item["scope"] == "evidence" and item["item"] == "final-assertion-archive" for item in report["missing"]):
            raise SystemExit("self_test_bad_final_archive_failed")
        dirty_static_actions = next_actions([{
            "scope": "local",
            "item": "local-static-gate-receipt",
            "reason": "production_static_gate_git_dirty",
        }])
        if not any(action.startswith("Commit or remove local changes, then rerun make validate-production-static") for action in dirty_static_actions):
            raise SystemExit("self_test_dirty_static_gate_next_action_missing")
        git_binding_actions = next_actions([{
            "scope": "local",
            "item": "local-static-gate-receipt",
            "reason": "git_binding_mismatch",
        }])
        if not any(action.startswith("Run make production-worktree-plan, run make production-worktree-stage-dry-run-batch and verify-production-worktree-stage-dry-run-batch, then review each commit group, run stageDryRunCommand and stageDryRunReceiptCommand, execute only the source_change stageCommand after review, verify the staged group, clean generated/forbidden artifacts separately, then rerun make validate-production-static") for action in git_binding_actions):
            raise SystemExit("self_test_git_binding_static_gate_next_action_missing")
        (root / "Makefile").write_text("validate-production-static:\n", encoding="utf-8")
        report = build_report(root, env)
        if report["status"] == "ready" or not any(item["scope"] == "local" for item in report["missing"]):
            raise SystemExit("self_test_missing_local_failed")
    print("production_completion_status_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Report local and live-evidence completion for the IMServer production-ready path.")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--json-output", help="Optional path for the machine-readable status report.")
    parser.add_argument("--markdown-output", help="Optional path for the operator-readable status report.")
    parser.add_argument("--fail-if-incomplete", action="store_true", help="Exit non-zero unless all local checks and live evidence are present.")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    repo_root = Path(args.repo_root).resolve()
    report = build_report(repo_root, dict(os.environ))
    if args.json_output:
        write_json(Path(args.json_output), report)
    if args.markdown_output:
        write_text(Path(args.markdown_output), render_markdown(report))
    print(render_text(report))
    if args.fail_if_incomplete and report["status"] != "ready":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
