#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_validation_inventory_required_records(repo_root: Path) -> tuple[list[str], list[str]]:
    module_path = repo_root / "IMServer/LoadTests/perf_validation_inventory.py"
    if not module_path.is_file():
        return [], ["IMServer/LoadTests/perf_validation_inventory.py:missing_required_inventory_source"]
    spec = importlib.util.spec_from_file_location("perf_validation_inventory_for_workflow_audit", module_path)
    if spec is None or spec.loader is None:
        return [], ["IMServer/LoadTests/perf_validation_inventory.py:required_inventory_import_unavailable"]
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as error:  # noqa: BLE001 - audit must report import failures without hiding the cause.
        return [], [f"IMServer/LoadTests/perf_validation_inventory.py:required_inventory_import_failed:{error}"]
    records = getattr(module, "REQUIRED_INVENTORY_RECORDS", {})
    required: set[str] = set()
    if not isinstance(records, dict):
        return [], ["IMServer/LoadTests/perf_validation_inventory.py:required_inventory_records_not_dict"]
    for group in ("shell", "python", "docs"):
        values = records.get(group) or set()
        if isinstance(values, (str, bytes)) or not hasattr(values, "__iter__"):
            return [], [f"IMServer/LoadTests/perf_validation_inventory.py:required_inventory_group_invalid:{group}"]
        required.update(str(value) for value in values if str(value).strip())
    if not required:
        return [], ["IMServer/LoadTests/perf_validation_inventory.py:required_inventory_records_empty"]
    return sorted(required), []


REQUIRED_MAKE_TARGETS = [
    "help",
    "validate-production-static",
    "validate-production-gates",
    "verify-production-static-receipt",
    "production-worktree-inventory",
    "production-worktree-inventory-json",
    "production-worktree-plan",
    "production-worktree-plan-json",
    "verify-production-worktree-plan-json",
    "production-worktree-commit-runbook",
    "verify-production-worktree-commit-runbook",
    "production-worktree-stage-dry-run",
    "verify-production-worktree-stage-dry-run",
    "production-worktree-stage-dry-run-batch",
    "verify-production-worktree-stage-dry-run-batch",
    "verify-production-worktree-staging",
    "verify-production-worktree-staged-group",
    "check-production-worktree-inventory",
    "check-imserver-production-release-gate",
    "check-imserver-production-smoke",
    "run-imserver-production-smoke",
    "verify-imserver-production-smoke",
    "install-production-smoke-receipt",
    "run-imserver-production-release-gate",
    "verify-imserver-production-release-gate",
    "check-production-ops",
    "production-completion-status",
    "verify-production-completion-status",
    "production-evidence-recovery-plan",
    "production-evidence-recovery-plan-diagnostic",
    "verify-production-evidence-recovery-plan",
    "verify-production-evidence-recovery-plan-diagnostic",
    "check-production-evidence-recovery-diagnostic-paths",
    "validate-production-evidence-recovery-env",
    "production-readiness-status",
    "run-current-production-readiness",
    "verify-current-production-readiness",
    "validate-production-acceptance-env",
    "run-production-acceptance",
    "verify-production-acceptance",
    "assert-production-ready",
    "verify-production-ready-assertion",
    "package-production-ready-assertion",
    "verify-production-ready-archive",
    "run-production-readiness-gate",
    "run-operational-audit",
    "install-operational-audit-timer",
    "send-operational-alert",
    "install-backup-timer",
    "create-backup-single-node",
    "verify-backup",
    "run-restore-drill",
    "install-restore-drill-timer",
    "sync-offsite-backup",
    "run-non-large-group-regression-plan",
    "check-non-large-group-regression",
    "run-non-large-group-regression",
    "run-product-test-plan-plan",
    "check-product-test-plan",
    "run-product-test-plan",
    "run-product-scenario-suite-plan",
    "check-product-scenario-suite",
    "run-product-scenario-suite",
    "run-local-acceptance-plan",
    "check-local-acceptance",
    "run-local-acceptance",
    "verify-local-acceptance",
]


HELP_REQUIRED_MAKE_TARGETS = [
    "local-dev",
    "validate-production-static",
    "validate-production-gates",
    "verify-production-static-receipt",
    "production-worktree-inventory",
    "production-worktree-inventory-json",
    "production-worktree-plan",
    "production-worktree-plan-json",
    "verify-production-worktree-plan-json",
    "production-worktree-commit-runbook",
    "verify-production-worktree-commit-runbook",
    "production-worktree-stage-dry-run",
    "verify-production-worktree-stage-dry-run",
    "production-worktree-stage-dry-run-batch",
    "verify-production-worktree-stage-dry-run-batch",
    "verify-production-worktree-staging",
    "verify-production-worktree-staged-group",
    "check-production-worktree-inventory",
    "check-imserver-production-release-gate",
    "check-imserver-production-smoke",
    "run-imserver-production-smoke",
    "verify-imserver-production-smoke",
    "install-production-smoke-receipt",
    "verify-imserver-production-release-gate",
    "check-production-ops",
    "production-completion-status",
    "verify-production-completion-status",
    "production-evidence-recovery-plan",
    "production-evidence-recovery-plan-diagnostic",
    "verify-production-evidence-recovery-plan",
    "verify-production-evidence-recovery-plan-diagnostic",
    "validate-production-evidence-recovery-env",
    "production-readiness-status",
    "run-current-production-readiness",
    "verify-current-production-readiness",
    "run-production-acceptance",
    "verify-production-acceptance",
    "assert-production-ready",
    "verify-production-ready-assertion",
    "package-production-ready-assertion",
    "verify-production-ready-archive",
    "run-production-readiness-gate",
    "run-operational-audit",
    "install-backup-timer",
    "create-backup-single-node",
    "verify-backup",
    "run-restore-drill",
    "sync-offsite-backup",
    "run-non-large-group-regression-plan",
    "run-product-test-plan-plan",
    "run-product-scenario-suite-plan",
]


REQUIRED = {
    ".github/workflows/production-static-gate.yml": {
        "commands": [
            "run: make validate-production-static",
        ],
        "paths": [
            ".github/workflows/production-static-gate.yml",
            ".github/workflows/imapp-production-config-gate.yml",
            ".github/workflows/imserver-production-release-gate.yml",
            ".github/workflows/imserver-production-smoke.yml",
            ".gitignore",
            "IMServer/.dockerignore",
            ".github/pull_request_template.md",
            ".github/CODEOWNERS",
            "Makefile",
            "README.md",
            "scripts/validate_android_network_configuration.py",
            "scripts/validate_production_workflows.py",
            "docs/architecture-boundaries.md",
            "docs/domain-boundaries.md",
            "app/build.gradle.kts",
            "app/src/main/java/com/xmtx/imappandroid/di/**",
            "app/src/test/java/com/xmtx/imappandroid/di/**",
            "IMApp/Config/IMAppInfo.plist",
            "IMApp/Scripts/**",
            "IMApp/IMApp/App/AppNetworkConfiguration.swift",
            "IMApp/README.md",
            "IMServer/LoadTests/README.md",
            "IMServer/LoadTests/run_local_acceptance.sh",
            "IMServer/LoadTests/run_local_http_smoke.sh",
            "IMServer/LoadTests/validate_load_tests.sh",
            "IMServer/LoadTests/verify_local_acceptance.py",
            "IMServer/LoadTests/production-acceptance.env.example",
            "IMServer/LoadTests/run_current_production_readiness.sh",
            "IMServer/LoadTests/run_production_acceptance.sh",
            "IMServer/LoadTests/run_production_profile.sh",
            "IMServer/LoadTests/run_perf_scenarios.sh",
            "IMServer/LoadTests/run_non_large_group_regression.sh",
            "IMServer/LoadTests/run_product_test_plan.sh",
            "IMServer/LoadTests/run_product_scenario_suite.sh",
            "IMServer/LoadTests/package_production_evidence.sh",
            "IMServer/LoadTests/perf_dashboard.py",
            "IMServer/LoadTests/perf_docs_audit.py",
            "IMServer/LoadTests/perf_evidence_manifest.py",
            "IMServer/LoadTests/perf_matrix_audit.py",
            "IMServer/LoadTests/perf_next_actions.py",
            "IMServer/LoadTests/perf_product_campaign_audit.py",
            "IMServer/LoadTests/perf_product_plan_artifacts_verify.py",
            "IMServer/LoadTests/perf_product_profile_gate.py",
            "IMServer/LoadTests/perf_product_scenario_suite_verify.py",
            "IMServer/LoadTests/perf_product_test_plan_runbook.py",
            "IMServer/LoadTests/perf_current_production_readiness_verify.py",
            "IMServer/LoadTests/perf_forbidden_artifacts.py",
            "IMServer/LoadTests/perf_secret_scan.py",
            "IMServer/LoadTests/perf_production_acceptance_verify.py",
            "IMServer/LoadTests/perf_production_gate.py",
            "IMServer/LoadTests/perf_readiness_gate.py",
            "IMServer/LoadTests/perf_run_plan.py",
            "IMServer/LoadTests/perf_scenario_catalog.py",
            "IMServer/LoadTests/perf_scenario_status.py",
            "IMServer/LoadTests/perf_slo_status.py",
            "IMServer/LoadTests/perf_state_summary.py",
            "IMServer/LoadTests/perf_validation_inventory.py",
            "IMServer/LoadTests/production_completion_status.py",
            "IMServer/LoadTests/production_evidence_recovery_plan.py",
            "IMServer/LoadTests/verify_production_evidence_recovery_paths.py",
            "IMServer/LoadTests/verify_production_completion_status.py",
            "IMServer/LoadTests/verify_deploy_readiness_receipt.py",
            "IMServer/LoadTests/perf_product_campaigns.json",
            "IMServer/LoadTests/perf_production_profiles.json",
            "IMServer/LoadTests/validate_production_acceptance_env.sh",
            "IMServer/LoadTests/verify_production_acceptance.sh",
            "IMServer/LoadTests/assert_production_ready.sh",
            "IMServer/LoadTests/production_readiness_status.sh",
            "IMServer/LoadTests/production_static_gate_receipt.py",
            "IMServer/LoadTests/production_target_policy.py",
            "IMServer/Dockerfile",
            "IMServer/docker-compose.production-smoke.yml",
            "IMServer/config/env/**",
            "IMServer/scripts/production_env_preflight.sh",
            "IMServer/scripts/production_env_preflight_test.sh",
            "IMServer/scripts/production_release_gate.sh",
            "IMServer/scripts/production_smoke.sh",
            "IMServer/scripts/verify_production_smoke.py",
            "deploy/ubuntu/72_install_topology_smoke_receipt.sh",
            "IMServer/scripts/verify_production_release_gate.py",
            "IMServer/Sources/IMServer/Auth/AuthConfiguration.swift",
            "IMServer/Sources/IMServer/Auth/AuthService.swift",
            "IMServer/Sources/IMServer/Controllers/IMConversationCommonFeatureController.swift",
            "IMServer/Sources/IMServer/IM/IMGatewaySessionRuntimeSupports.swift",
            "IMServer/Sources/IMServer/IMProductionRuntimeValidationSupport.swift",
            "IMServer/Sources/IMServer/IMProductionRuntimeValidator.swift",
            "deploy/ubuntu/**",
            "deploy/ubuntu/README.md",
            "docs/imserver-aliyun-local-binary-deploy.md",
        ],
    },
    ".github/workflows/production-gates-validation.yml": {
        "commands": [
            "run: make validate-production-gates",
            "uses: actions/upload-artifact@v4",
            "IMServer/LoadTests/results/validate-load-tests/",
        ],
        "paths": [
            ".github/workflows/production-gates-validation.yml",
            ".github/workflows/production-static-gate.yml",
            ".gitignore",
            "IMServer/.dockerignore",
            ".github/pull_request_template.md",
            "Makefile",
            "README.md",
            "scripts/validate_android_network_configuration.py",
            "scripts/validate_production_workflows.py",
            "docs/architecture-boundaries.md",
            "app/build.gradle.kts",
            "app/src/main/java/com/xmtx/imappandroid/di/**",
            "app/src/test/java/com/xmtx/imappandroid/di/**",
            "IMApp/Scripts/**",
            "IMServer/LoadTests/**",
            "IMServer/config/env/**",
            "IMServer/scripts/production_env_preflight.sh",
            "IMServer/scripts/production_env_preflight_test.sh",
            "deploy/ubuntu/**",
            "docs/imserver-aliyun-local-binary-deploy.md",
        ],
    },
    ".github/workflows/imserver-production-release-gate.yml": {
        "commands": [
            "uses: swift-actions/setup-swift@v2",
            "swift-version: \"6.0\"",
            "sudo apt-get install -y librdkafka-dev libssl-dev protobuf-compiler",
            "working-directory: IMServer",
            "./scripts/production_release_gate.sh",
            "./scripts/production_release_gate.sh --skip-swift-tests",
            "python3 scripts/verify_production_release_gate.py",
            "--receipt-json reports/latest-production-release-gate.json",
            "--require-pass",
            "--require-release-run",
            "--require-swift-tests",
            "uses: actions/upload-artifact@v4",
            "IMServer/reports/",
        ],
        "paths": [
            ".github/workflows/imserver-production-release-gate.yml",
            "IMServer/**",
            "Protocol/im_realtime/**",
            "scripts/check_protobuf_generated.sh",
            "scripts/generate_protobuf.sh",
        ],
    },
    ".github/workflows/imapp-production-config-gate.yml": {
        "commands": [
            "runs-on: macos-latest",
            "xcodebuild -version",
            "run: make validate-ios-network-config",
            "IMAPP_NETWORK_CONFIG_MODE=development",
            "IM_API_BASE_URL: http://127.0.0.1:8080",
            "IM_TCP_HOST: 127.0.0.1",
            "run: make validate-ios-debug-network-defaults",
            "xcodebuild build",
            "-scheme IMApp",
            "-configuration Debug",
            "run: make validate-ios-production-config",
            "-configuration Release",
            "IM_API_BASE_URL=\"${IM_API_BASE_URL}\"",
            "IM_TCP_HOST=\"${IM_TCP_HOST}\"",
            "IM_TCP_PORT=\"${IM_TCP_PORT}\"",
        ],
        "paths": [
            ".github/workflows/imapp-production-config-gate.yml",
            "IMApp/**",
            "IMClientKit/**",
            "Protocol/im_realtime/**",
            "Makefile",
        ],
    },
}


GOVERNANCE_REQUIRED = {
    "README.md": [
        "make help",
        "make validate-production-static",
        "make verify-production-static-receipt",
        "make validate-production-gates",
        "make check-imserver-production-release-gate",
        "make check-imserver-production-smoke",
        "make run-imserver-production-smoke",
        "make verify-imserver-production-smoke",
        "make run-imserver-production-release-gate",
        "make verify-imserver-production-release-gate",
        "make check-production-ops",
        "make run-production-readiness-gate",
        "make run-operational-audit",
        "make create-backup-single-node",
        "make verify-backup",
        "make run-restore-drill",
        "make validate-production-acceptance-env",
        "make run-current-production-readiness",
        "make verify-current-production-readiness",
        "make run-production-acceptance",
        "make verify-production-acceptance",
        "make assert-production-ready",
        "make verify-production-ready-assertion",
        "make package-production-ready-assertion",
        "make verify-production-ready-archive",
        "make production-completion-status",
        "latest.md",
        "operator-readable",
        "matches the JSON report exactly",
        "sha256-binds both files",
        "make validate-production-evidence-recovery-env",
        "PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true",
        "evidence-recovery-run.sh",
        "make production-evidence-recovery-plan-diagnostic",
        "diagnostic-latest.*",
        "diagnostic-evidence-recovery-plan.*",
        "diagnostic-evidence-recovery-run.sh",
        "make verify-production-evidence-recovery-plan-diagnostic",
        "diagnostic targets fail fast",
        "Local Gate First",
        "diagnostic plan as production",
        "`git_binding_mismatch`",
        "`field=dirtyCount`",
        "`currentTrackedModifiedCount=...`",
        "`currentUntrackedCount=...`",
        "`make production-worktree-inventory`",
        "`make production-worktree-inventory-json`",
        "`make production-worktree-plan`",
        "`make production-worktree-plan-json`",
        "`make verify-production-worktree-plan-json`",
        "`make verify-production-worktree-staging`",
        "`make verify-production-worktree-staged-group`",
        "read-only commit-group review plan",
        "tracked diff",
        "source_change",
        "stageDryRunCommand",
        "stageCommand",
        "commitCommand",
        "stageCommand and commitCommand are not executed by the plan",
        "PRODUCTION_WORKTREE_INVENTORY_ARGS='--group deploy-ops --paths-only'",
        "production-worktree-inventory/latest.json",
        "remove forbidden runtime artifacts",
        "Each `recovery item=` line",
        "Recovery lines are operator instructions, not proof",
        "make production-readiness-status",
        "localCompletionPercent",
        "productionCompletionPercent",
        "local static gate receipt",
        "Generated load-test accounts, results, login cache files, and token cache files",
        "Account CSVs can contain reusable login",
        "login/token cache files can contain reusable access",
        "stay out of Git, Docker build contexts, and production evidence",
        "`IMServer/LoadTests/**/*login-cache*`",
        "`IMServer/LoadTests/**/*token-cache*`",
        "`IMServer/LoadTests/**/*token_cache*`",
        "re-include token cache files",
        "production-acceptance.env.example",
        "`Production Static Gate` workflow",
        "`Production Gates Validation` workflow",
        "do not replace real production evidence",
        "real DNS HTTPS target",
        "public TCP gateway",
        "fresh Aliyun security-group JSON plus verified repair receipt",
        "production acceptance/load-test evidence",
        "Current production readiness status:",
        "This repository state is not itself production-ready until live evidence is",
        "The only acceptable final assertion is `make assert-production-ready`",
        "imserver-production-ready-assertion",
        "ASSERT_PRODUCTION_READY_RECEIPT_JSON",
        "PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT",
        "package-production-ready-assertion",
        "verify-production-ready-archive",
        "The final archive",
        "static gate support artifacts",
        "artifacts/productionStaticGateReceipt/support/",
        "--require-static-gate-support-root",
        "instead of any original host paths",
        "archive-relative paths",
        "`sourcePath`, `sourceReceipt`, or `archiveFile`",
        "The archived `production-ready-assertion.json` is also rewritten",
        "`artifacts/<artifactKey>/...` paths inside the archive",
        "The archived static gate receipt is rewritten as well",
        "`artifacts/productionStaticGateReceipt/support/...` copies in the same archive",
        "completion-status `repoRoot`",
        "`/imserver-production-ready-archive/repo`",
        "recovery plan points `sourceStatusJson`",
        "also rejects runtime artifacts",
        "even when they are nested under",
        "evidence package target matches too",
        "Production target contract:",
        "`BASE_URL` must be the public HTTPS origin only",
        "https://chat.prod.company.com",
        "Do not include `/api`, query",
        "strings, fragments, username/password",
        "trailing dots, surrounding whitespace",
        "`TCP_HOST` must be a real public DNS host only",
        "tcp.prod.company.com",
        "`:9000`, raw IPs",
        "underscores, trailing dots",
        "`TCP_PORT` must be `9000`",
        "python3 IMServer/LoadTests/production_target_policy.py --self-test",
        "export PRODUCTION_ACCEPTANCE_BASE_URL=\"https://chat.prod.company.com\"",
        "export PRODUCTION_ACCEPTANCE_TCP_HOST=\"tcp.prod.company.com\"",
        "export PRODUCTION_ACCEPTANCE_ACCOUNT_FILE=\"IMServer/LoadTests/accounts/load-10000.csv\"",
        "export PRODUCTION_ACCEPTANCE_CONVERSATION_ID=\"<real-conversation-uuid>\"",
        "production acceptance env",
        "verifiers",
        "production acceptance env drift",
        "exact public target",
        "`PRODUCTION_EVIDENCE_PACKAGE` is required",
        "make run-product-test-plan-plan",
        "make check-product-test-plan",
        "make run-product-test-plan",
        "make validate-android-network-config",
        "Android network configuration policy",
    ],
    "IMServer/LoadTests/README.md": [
        "make verify-local-acceptance",
        "make run-current-production-readiness",
        "make verify-current-production-readiness",
        "make run-production-acceptance",
        "production-acceptance.env.example",
        "production-acceptance.env",
        "make validate-production-acceptance-env",
        "PRODUCTION_ACCEPTANCE_ENV_MODE=verify make validate-production-acceptance-env",
        "make verify-production-acceptance",
        "make verify-production-ready-assertion",
        "make package-production-ready-assertion",
        "make verify-production-ready-archive",
        "make production-completion-status",
        "latest.md",
        "operator-readable",
        "matches the JSON report exactly",
        "sha256-binds both files",
        "make validate-production-evidence-recovery-env",
        "PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true",
        "evidence-recovery-run.sh",
        "make production-evidence-recovery-plan-diagnostic",
        "diagnostic-latest.*",
        "diagnostic-evidence-recovery-plan.*",
        "diagnostic-evidence-recovery-run.sh",
        "make verify-production-evidence-recovery-plan-diagnostic",
        "diagnostic output path is configured to the same path",
        "Local Gate First",
        "That diagnostic output includes a `Local Gate First` section, writes",
        "`git_binding_mismatch`",
        "`field=dirtyCount`",
        "`currentTrackedModifiedCount=...`",
        "`currentUntrackedCount=...`",
        "`make production-worktree-inventory`",
        "`make production-worktree-inventory-json`",
        "`make production-worktree-plan`",
        "`make production-worktree-plan-json`",
        "`make verify-production-worktree-plan-json`",
        "`make verify-production-worktree-staging`",
        "`make verify-production-worktree-staged-group`",
        "read-only commit-group review plan",
        "tracked diff",
        "source_change",
        "stageDryRunCommand",
        "stageCommand",
        "commitCommand",
        "stageCommand and commitCommand are not executed by the plan",
        "PRODUCTION_WORKTREE_INVENTORY_ARGS='--group deploy-ops --paths-only'",
        "production-worktree-inventory/latest.json",
        "remove forbidden runtime artifacts",
        "Every `recovery item=` line",
        "Do not count a recovery line itself as evidence",
        "localCompletionPercent",
        "liveEvidenceCompletionPercent",
        "productionCompletionPercent",
        "imserver-production-ready-assertion",
        "ASSERT_PRODUCTION_READY_RECEIPT_JSON",
        "PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT",
        "artifacts/productionStaticGateReceipt/support/",
        "--require-static-gate-support-root",
        "instead of falling back to original host paths",
        "archive-relative",
        "`sourcePath`, `sourceReceipt`, or `archiveFile`",
        "The archived `production-ready-assertion.json` is rewritten the same way",
        "`artifacts/<artifactKey>/...` inside the archive",
        "The archived static gate receipt is also rewritten",
        "`artifacts/productionStaticGateReceipt/support/...` copies in the archive",
        "completion-status `repoRoot` uses",
        "recovery-plan `sourceStatusJson`",
        "`BASE_URL` is the HTTPS origin only",
        "https://chat.prod.company.com",
        "do not append `/api`, query strings, fragments",
        "trailing dots, surrounding whitespace",
        "`TCP_HOST` is the DNS host only",
        "tcp.prod.company.com",
        "do not include `:9000`",
        "underscores, trailing dots",
        "`TCP_PORT` must be `9000`",
        "shared `production_target_policy.py`",
        "export PRODUCTION_ACCEPTANCE_BASE_URL=\"https://chat.prod.company.com\"",
        "export PRODUCTION_ACCEPTANCE_TCP_HOST=\"tcp.prod.company.com\"",
        "export PRODUCTION_ACCEPTANCE_ACCOUNT_FILE=\"IMServer/LoadTests/accounts/load-10000.csv\"",
        "export PRODUCTION_ACCEPTANCE_CONVERSATION_ID=\"<real-conversation-uuid>\"",
        "productionEvidence=false",
        "local artifacts cannot be confused with production evidence",
        "Generated account CSVs, result receipts, reports, login cache files, and token",
        "Login/token cache",
        "can contain access tokens",
        "never commit them",
        "include them in Docker images",
        "`IMServer/LoadTests/**/*login-cache*`",
        "`IMServer/LoadTests/**/*token-cache*`",
        "`IMServer/LoadTests/**/*token_cache*`",
        "negation rules that would re-include token cache files",
        "Treat the generated login cache as a sensitive token cache",
        "Prefer `/tmp` for",
        "`LOGIN_CACHE_DIR`/`LOGIN_CACHE_FILE`",
        "forbidden login-cache/token-cache",
        "artifact paths",
        "symlink artifacts",
        "special file artifacts such as FIFOs/devices/sockets",
        "non-example `.env`/`*.env` artifacts",
        "generated account CSV/account artifact paths",
        "`tcp-login-cache*.json`",
        "`tcp_login_cache*.json`",
        "`access-token-cache*.json`",
        "`load-*.csv`",
        "`provisioned-accounts.csv`",
        "`account-credentials.csv`",
        "unsafe tar members",
        "forbidden runtime artifacts",
        "login/token-cache files, and non-example `.env` files",
        "even when they are nested under `artifacts/`",
        "file fails even if its content is empty",
        "load-test account lists are",
        "cache files are runtime inputs",
        "never production evidence",
        "secret store",
    ],
    "IMServer/LoadTests/production-acceptance.env.example": [
        "Root .gitignore excludes non-example *.env files.",
        "BASE_URL=${PRODUCTION_ACCEPTANCE_BASE_URL:?set-PRODUCTION_ACCEPTANCE_BASE_URL}",
        "TCP_HOST=${PRODUCTION_ACCEPTANCE_TCP_HOST:?set-PRODUCTION_ACCEPTANCE_TCP_HOST}",
        "TCP_PORT=${PRODUCTION_ACCEPTANCE_TCP_PORT:-9000}",
        "ACCOUNT_FILE=${PRODUCTION_ACCEPTANCE_ACCOUNT_FILE:?set-PRODUCTION_ACCEPTANCE_ACCOUNT_FILE}",
        "IM_CONVERSATION_ID=${PRODUCTION_ACCEPTANCE_CONVERSATION_ID:?set-PRODUCTION_ACCEPTANCE_CONVERSATION_ID}",
        "operator shell",
        "replace these assignments with real production values",
        "Do not append /api",
        "do not include :9000",
        "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}",
        "PRODUCTION_ACCEPTANCE_LEVEL=full",
        "CLOUD_SECURITY_GROUP_RULES_FILE=/etc/imserver/cloud-security-group.json",
        "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400",
        "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-REPLACE_ME",
        "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen",
        "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32",
        "# PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=IMServer/reports/latest-production-smoke.json",
        "# PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=86400",
        "# PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=/var/lib/imserver/readiness/latest.json",
        "# PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS=86400",
        "# PRODUCTION_ACCEPTANCE_RECEIPT_JSON=IMServer/LoadTests/results/production-acceptance/<run-id>/production-acceptance.json",
        "# PRODUCTION_EVIDENCE_PACKAGE=IMServer/LoadTests/results/production-acceptance/production-evidence/production-evidence-<run-id>.tar.gz",
    ],
    ".gitignore": [
        "*.env",
        "!*.env.example",
        "!*.example.env",
        "*.pem",
        "*.key",
        "*.p12",
        "*.pfx",
        "*.mobileprovision",
        "id_rsa*",
        "id_dsa*",
        "id_ecdsa*",
        "id_ed25519*",
        "IMServer/LoadTests/accounts/",
        "IMServer/LoadTests/**/*login-cache*",
        "IMServer/LoadTests/**/login_cache/*",
        "IMServer/LoadTests/**/*token-cache*",
        "IMServer/LoadTests/**/*token_cache*",
        "IMServer/LoadTests/**/*tcp_login_cache*",
        "IMServer/LoadTests/results/",
        "IMServer/reports/",
    ],
    "IMServer/.dockerignore": [
        ".build/",
        ".swiftpm/",
        ".env",
        ".env.*",
        "*.env",
        "!*.env.example",
        "!*.example.env",
        "*.pem",
        "**/*.pem",
        "*.key",
        "**/*.key",
        "*.p12",
        "**/*.p12",
        "*.pfx",
        "**/*.pfx",
        "*.mobileprovision",
        "**/*.mobileprovision",
        "id_rsa*",
        "**/id_rsa*",
        "id_dsa*",
        "**/id_dsa*",
        "id_ecdsa*",
        "**/id_ecdsa*",
        "id_ed25519*",
        "**/id_ed25519*",
        "reports/",
        "LoadTests/accounts/",
        "LoadTests/**/*login-cache*",
        "LoadTests/login_cache/*",
        "LoadTests/**/login_cache/*",
        "LoadTests/token-cache/*",
        "LoadTests/**/token-cache/*",
        "LoadTests/token_cache/*",
        "LoadTests/**/token_cache/*",
        "LoadTests/**/*token-cache*",
        "LoadTests/**/*token_cache*",
        "LoadTests/**/*tcp_login_cache*",
        "LoadTests/results/",
    ],
    "IMServer/Dockerfile": [
        "ARG GIT_HTTPS_PROXY_PREFIX=\"\"",
        'if [ -n "${GIT_HTTPS_PROXY_PREFIX}" ]; then',
        'git config --global url."${GIT_HTTPS_PROXY_PREFIX}".insteadOf "https://github.com/";',
        "apt-get install -y --no-install-recommends",
        "apt-get -q install -y --no-install-recommends",
        "curl \\",
        "rm -rf /var/lib/apt/lists/*",
        "HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD curl -fsS",
        'http://127.0.0.1:${PORT:-8080}/health',
    ],
    ".github/workflows/imserver-production-smoke.yml": [
        "name: IMServer Production Topology Smoke",
        "workflow_dispatch:",
        "make run-imserver-production-smoke",
        "uses: actions/upload-artifact@v4",
        "IMServer/reports/",
        "latest-production-smoke.json",
    ],
    "IMServer/docker-compose.production-smoke.yml": [
        "x-imserver-env:",
        "IM_RUNTIME_ROLE",
        "IM_EVENT_STREAM_DRIVER: kafka",
        "IM_ROUTING_MODE: redis",
        "IM_SEQUENCE_ALLOCATION_MODE: block",
        "IM_MESSAGE_WRITE_BATCH_ENABLED: \"true\"",
        "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE: timeline-pull",
        "IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED: \"false\"",
        "IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE: redis",
        "x-imserver-worker-healthcheck: &imserver_worker_healthcheck",
        'test: ["CMD-SHELL", "kill -0 1"]',
        "healthcheck: *imserver_worker_healthcheck",
        "healthcheck:",
        "stream-consumer-domain:",
        "stream-consumer-realtime:",
    ],
    "IMServer/scripts/production_smoke.sh": [
        "COMPOSE_FILE=\"${ROOT_DIR}/docker-compose.production-smoke.yml\"",
        "production_smoke_config_self_test()",
        "compose_service_names()",
        "service_block(service_name)",
        "up_stack_services()",
        "wait_for_http_body()",
        "write_state_body()",
        "runtime_health_wait_services()",
        "compose_container_health_status()",
        "wait_for_compose_service_health()",
        "wait_for_runtime_services_health()",
        "compose build gateway",
        "compose up -d postgres redpanda redis minio redpanda-init minio-init",
        "compose run --rm ops",
        "outbox_inspect_commands =",
        "outbox_inspect_must_use_smoke_env:",
        "outbox_inspect_must_not_use_real_production_env:",
        "stream-consumer-domain \\",
        "stream-consumer-realtime",
        "runtime_services_not_started:",
        "runtime_services_not_health_waited:",
        "http_readiness_must_use_health_endpoint",
        "state_file_must_not_persist_internal_secret",
        "state_file_must_not_persist_owner_token",
        'if curl -fsS "${url}/health" >/dev/null 2>&1; then',
        "compose_health_wait_must_inspect_container_state",
        "docker inspect --format",
        "write_smoke_receipt()",
        "latest-production-smoke.json",
        '"runtimeEvidence": True',
        '"checks": [',
        '"runtime_services_health"',
        "write_smoke_receipt \"${generated_at}\"",
        "worker_service_missing_worker_healthcheck:",
        "wait_for_http gateway",
        "wait_for_http command-api",
        "wait_for_http query-api",
        "production-smoke-config-self-test result=pass",
    ],
    ".github/pull_request_template.md": [
        "make validate-production-static",
        "make validate-ios-debug-network-defaults",
        "make validate-android-network-config",
        "make validate-production-gates",
        "make validate-production-acceptance-env",
        "make verify-production-acceptance",
        "cd IMServer && ./scripts/production_release_gate.sh",
        "Release gate/capacity changes use real staging data before claiming GA readiness.",
    ],
    "IMApp/README.md": [
        "make validate-ios-network-config",
        "make validate-ios-debug-network-defaults",
        "Debug 构建的实际 Xcode build settings",
        "$(IM_API_BASE_URL)",
        "Release-only build phase",
    ],
    "docs/architecture-boundaries.md": [
        "make validate-production-static",
        "make validate-production-gates",
        "make validate-production-acceptance-env",
        "make verify-production-acceptance",
        "real production/staging data or local gate/smoke only",
        "exact public",
        "Production safety assumptions",
    ],
    "Makefile": [
        "help:",
        "IMMonorepo make targets",
        "validate-android-network-config:",
        "python3 scripts/validate_android_network_configuration.py --self-test",
        "python3 scripts/validate_android_network_configuration.py",
        "validate-ios-debug-network-defaults-self-test:",
        "IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST=true IMApp/Scripts/validate_debug_network_defaults.sh",
        "python3 scripts/validate_production_workflows.py --self-test",
        "python3 scripts/validate_production_workflows.py",
        "PRODUCTION_RELEASE_GATE_SELF_TEST=true bash IMServer/scripts/production_release_gate.sh",
        "python3 IMServer/scripts/verify_production_release_gate.py --self-test",
        "python3 IMServer/LoadTests/perf_forbidden_artifacts.py --self-test",
        "python3 IMServer/LoadTests/perf_secret_scan.py --self-test",
        "python3 IMServer/LoadTests/perf_production_acceptance_verify.py --self-test",
        "python3 IMServer/LoadTests/perf_current_production_readiness_verify.py --self-test",
        "python3 IMServer/LoadTests/perf_evidence_manifest.py --self-test",
        "python3 IMServer/LoadTests/perf_matrix_audit.py --self-test",
        "python3 IMServer/LoadTests/perf_coverage.py --self-test",
        "python3 IMServer/LoadTests/perf_route_audit.py --self-test",
        "python3 IMServer/LoadTests/perf_scenario_status.py --self-test",
        "python3 IMServer/LoadTests/perf_scenario_catalog.py --self-test",
        "python3 IMServer/LoadTests/perf_run_plan.py --self-test",
        "python3 IMServer/LoadTests/perf_default_profile_audit.py --self-test",
        "python3 IMServer/LoadTests/perf_docs_audit.py --self-test",
        "python3 IMServer/LoadTests/perf_validation_inventory.py --self-test",
        "python3 IMServer/LoadTests/perf_production_profiles_audit.py --self-test",
        "python3 IMServer/LoadTests/perf_product_scenario_suite_verify.py --self-test",
        "python3 IMServer/LoadTests/perf_product_plan_artifacts_verify.py --self-test",
        "python3 IMServer/LoadTests/perf_product_campaign_artifacts_verify.py --self-test",
        "python3 IMServer/LoadTests/perf_product_campaign_audit.py --self-test",
        "python3 IMServer/LoadTests/perf_product_profile_gate.py --self-test",
        "python3 IMServer/LoadTests/perf_profile_artifacts_verify.py --self-test",
        "PRODUCTION_EVIDENCE_SELF_TEST=true bash IMServer/LoadTests/package_production_evidence.sh",
        "CURRENT_PRODUCTION_SELF_TEST=true bash IMServer/LoadTests/run_current_production_readiness.sh",
        "PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=true bash IMServer/LoadTests/validate_production_acceptance_env.sh",
        "PRODUCTION_ACCEPTANCE_SELF_TEST=true bash IMServer/LoadTests/run_production_acceptance.sh",
        "VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=true bash IMServer/LoadTests/verify_production_acceptance.sh",
        "ASSERT_PRODUCTION_READY_SELF_TEST=true bash IMServer/LoadTests/assert_production_ready.sh",
        "python3 IMServer/LoadTests/verify_production_ready_assertion.py --self-test",
        "python3 IMServer/LoadTests/package_production_ready_assertion.py --self-test",
        "python3 IMServer/LoadTests/verify_deploy_readiness_receipt.py --self-test",
        "python3 IMServer/LoadTests/production_completion_status.py --self-test",
        "python3 IMServer/LoadTests/verify_production_completion_status.py --self-test",
        "python3 IMServer/LoadTests/production_evidence_recovery_plan.py --self-test",
        "python3 IMServer/LoadTests/verify_production_evidence_recovery_paths.py --self-test",
        "$(MAKE) check-production-worktree-inventory",
        "$(MAKE) check-production-evidence-recovery-diagnostic-paths",
        "python3 IMServer/LoadTests/production_static_gate_receipt.py --self-test",
        "python3 IMServer/LoadTests/production_static_gate_receipt.py --receipt-json",
        "production-worktree-inventory:",
        "production-worktree-inventory-json:",
        "production-worktree-plan:",
        "production-worktree-plan-json:",
        "verify-production-worktree-plan-json:",
        "production-worktree-commit-runbook:",
        "verify-production-worktree-commit-runbook:",
        "production-worktree-stage-dry-run:",
        "verify-production-worktree-stage-dry-run:",
        "production-worktree-stage-dry-run-batch:",
        "verify-production-worktree-stage-dry-run-batch:",
        "verify-production-worktree-staging:",
        "verify-production-worktree-staged-group:",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --json-output \"$(PRODUCTION_WORKTREE_INVENTORY_JSON)\" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --plan $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --plan-json-output \"$(PRODUCTION_WORKTREE_PLAN_JSON)\" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --verify-plan-json \"$(PRODUCTION_WORKTREE_PLAN_JSON)\" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --commit-runbook-output \"$(PRODUCTION_WORKTREE_COMMIT_RUNBOOK)\" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --verify-commit-runbook \"$(PRODUCTION_WORKTREE_COMMIT_RUNBOOK)\" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --stage-dry-run --stage-dry-run-json-output \"$(PRODUCTION_WORKTREE_STAGE_DRY_RUN_JSON)\" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --verify-stage-dry-run-json \"$(PRODUCTION_WORKTREE_STAGE_DRY_RUN_JSON)\" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --stage-dry-run-batch --stage-dry-run-batch-json-output \"$(PRODUCTION_WORKTREE_STAGE_DRY_RUN_BATCH_JSON)\"",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --verify-stage-dry-run-batch-json \"$(PRODUCTION_WORKTREE_STAGE_DRY_RUN_BATCH_JSON)\"",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --verify-staged-source-only",
        "\t@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root \"$(CURDIR)\" --verify-staged-single-group",
        "--plan $(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "PRODUCTION_WORKTREE_PLAN_JSON ?=",
        "PRODUCTION_WORKTREE_COMMIT_RUNBOOK ?=",
        "PRODUCTION_WORKTREE_STAGE_DRY_RUN_JSON ?=",
        "PRODUCTION_WORKTREE_STAGE_DRY_RUN_BATCH_JSON ?=",
        "--plan-json-output \"$(PRODUCTION_WORKTREE_PLAN_JSON)\"",
        "PRODUCTION_WORKTREE_INVENTORY_ARGS ?=",
        "$(PRODUCTION_WORKTREE_INVENTORY_ARGS)",
        "--json-output \"$(PRODUCTION_WORKTREE_INVENTORY_JSON)\"",
        "PRODUCTION_COMPLETION_STATUS_STATIC_RECEIPT_BOOTSTRAP=true $(MAKE) production-completion-status",
        "$(MAKE) production-completion-status",
        "$(MAKE) verify-production-completion-status",
        "python3 IMServer/LoadTests/production_evidence_recovery_plan.py --status-json \"$(PRODUCTION_COMPLETION_STATUS_JSON)\" --repo-root \"$(CURDIR)\"",
        "python3 IMServer/LoadTests/production_evidence_recovery_plan.py --verify --status-json \"$(PRODUCTION_COMPLETION_STATUS_JSON)\" --repo-root \"$(CURDIR)\"",
        "--output \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)\"",
        "--json-output \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)\"",
        "--completion-status-json \"$(PRODUCTION_COMPLETION_STATUS_JSON)\"",
        "--completion-status-markdown \"$(PRODUCTION_COMPLETION_STATUS_MD)\"",
        "--recovery-plan-json \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)\"",
        "--recovery-plan-markdown \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)\"",
        "--recovery-plan-script \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)\"",
        "$(MAKE) verify-production-static-receipt",
        "PRODUCTION_READINESS_STATUS_SELF_TEST=true bash IMServer/LoadTests/production_readiness_status.sh",
        "$(MAKE) check-production-ops",
        "$(MAKE) check-imserver-production-smoke",
        "check-imserver-production-release-gate:",
        "PRODUCTION_RELEASE_GATE_SELF_TEST=true bash IMServer/scripts/production_release_gate.sh",
        "check-imserver-production-smoke:",
        "bash -n IMServer/scripts/production_smoke.sh",
        "bash IMServer/scripts/production_smoke.sh self-test",
        "python3 IMServer/scripts/verify_production_smoke.py --self-test",
        "TOPOLOGY_SMOKE_INSTALL_SELF_TEST=true bash deploy/ubuntu/72_install_topology_smoke_receipt.sh",
        "run-imserver-production-smoke:",
        "cd IMServer && ./scripts/production_smoke.sh run",
        "$(MAKE) verify-imserver-production-smoke",
        "verify-imserver-production-smoke:",
        "python3 IMServer/scripts/verify_production_smoke.py --receipt-json",
        "--require-pass --require-artifacts-exist",
        "install-production-smoke-receipt:",
        "TOPOLOGY_SMOKE_RECEIPT_SOURCE=\"$(IMSERVER_PRODUCTION_SMOKE_JSON)\" bash deploy/ubuntu/72_install_topology_smoke_receipt.sh",
        "run-imserver-production-release-gate:",
        "cd IMServer && ./scripts/production_release_gate.sh && python3 scripts/verify_production_release_gate.py --receipt-json reports/latest-production-release-gate.json --require-pass --require-release-run --require-swift-tests",
        "verify-imserver-production-release-gate:",
        "python3 IMServer/scripts/verify_production_release_gate.py --receipt-json",
        "--require-pass --require-release-run --require-swift-tests",
        "check-production-ops:",
        "INSTALL_DEPENDENCIES_SELF_TEST=true bash deploy/ubuntu/00_install_dependencies.sh",
        "BUILD_IMSERVER_SELF_TEST=true bash deploy/ubuntu/40_build_imserver.sh",
        "SYSTEMD_UNITS_RENDER_SELF_TEST=true bash deploy/ubuntu/50_install_systemd_units.sh",
        "SYSTEMD_UNIT_VERIFY_SELF_TEST=true bash deploy/ubuntu/52_verify_systemd_units.sh",
        "READINESS_DEFAULTS_SELF_TEST=true bash deploy/ubuntu/95_production_readiness_gate.sh",
        "READINESS_TOPOLOGY_SMOKE_SELF_TEST=true bash deploy/ubuntu/95_production_readiness_gate.sh",
        "READINESS_RECEIPT_SELF_TEST=true bash deploy/ubuntu/95_production_readiness_gate.sh",
        "IM_HOST_SECURITY_SELF_TEST=true bash deploy/ubuntu/25_setup_host_security.sh",
        "AUDIT_DEFAULTS_SELF_TEST=true bash deploy/ubuntu/77_operational_audit.sh",
        "KAFKA_SETUP_SELF_TEST=true bash deploy/ubuntu/30_setup_kafka.sh",
        "BACKUP_CREATE_SELF_TEST=true bash deploy/ubuntu/80_backup_single_node.sh",
        "BACKUP_VERIFY_SELF_TEST=true bash deploy/ubuntu/81_verify_backup.sh",
        "RESTORE_DRILL_SAFETY_SELF_TEST=true bash deploy/ubuntu/82_restore_drill_single_node.sh",
        "DEPLOY_FAILURE_ARTIFACT_PACKAGE_SELF_TEST=true bash deploy/ubuntu/92_package_deploy_failure_artifacts.sh",
        "run-production-readiness-gate:",
        "bash deploy/ubuntu/95_production_readiness_gate.sh",
        "run-operational-audit:",
        "bash deploy/ubuntu/77_operational_audit.sh",
        "create-backup-single-node:",
        "bash deploy/ubuntu/80_backup_single_node.sh",
        "verify-backup:",
        "bash deploy/ubuntu/81_verify_backup.sh",
        "run-restore-drill:",
        "bash deploy/ubuntu/82_restore_drill_single_node.sh",
        "python3 IMServer/LoadTests/production_target_policy.py --self-test",
        "production-completion-status:",
        "python3 IMServer/LoadTests/production_completion_status.py --json-output",
        "--markdown-output \"$(PRODUCTION_COMPLETION_STATUS_MD)\"",
        "verify-production-completion-status:",
        "python3 IMServer/LoadTests/verify_production_completion_status.py --status-json",
        "--markdown-report \"$(PRODUCTION_COMPLETION_STATUS_MD)\"",
        "--expect-repo-root \"$(CURDIR)\"",
        "PRODUCTION_EVIDENCE_RECOVERY_ALLOW_LOCAL_INCOMPLETE",
        "PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON",
        "PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD",
        "PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT",
        "PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_JSON",
        "PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_MD",
        "PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_JSON",
        "PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_MD",
        "PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT",
        "production-evidence-recovery-plan:",
        "$(MAKE) --no-print-directory verify-production-completion-status",
        "python3 IMServer/LoadTests/production_evidence_recovery_plan.py --status-json",
        "--output \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)\"",
        "--json-output \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)\"",
        "--script-output \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)\"",
        "--allow-local-incomplete",
        "check-production-evidence-recovery-diagnostic-paths:",
        "python3 IMServer/LoadTests/verify_production_evidence_recovery_paths.py",
        "--strict-completion-status-json \"$(PRODUCTION_COMPLETION_STATUS_JSON)\"",
        "--diagnostic-recovery-script \"$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT)\"",
        "strict recovery plan JSON",
        "diagnostic recovery plan JSON",
        "production-evidence-recovery-plan-diagnostic:",
        "production-evidence-recovery-plan-diagnostic: check-production-evidence-recovery-diagnostic-paths",
        "PRODUCTION_COMPLETION_STATUS_JSON=\"$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_JSON)\"",
        "PRODUCTION_COMPLETION_STATUS_MD=\"$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_MD)\"",
        "PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON=\"$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_JSON)\"",
        "PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD=\"$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_MD)\"",
        "PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT=\"$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT)\"",
        "PRODUCTION_EVIDENCE_RECOVERY_ALLOW_LOCAL_INCOMPLETE=true",
        "$(MAKE) --no-print-directory production-evidence-recovery-plan",
        "verify-production-evidence-recovery-plan:",
        "python3 IMServer/LoadTests/production_evidence_recovery_plan.py --verify",
        "verify-production-evidence-recovery-plan-diagnostic:",
        "python3 IMServer/LoadTests/verify_production_completion_status.py --status-json \"$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_JSON)\"",
        "--markdown-report \"$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_MD)\"",
        "--output \"$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_MD)\"",
        "--json-output \"$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_JSON)\"",
        "--script-output \"$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT)\"",
        "bash -n \"$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT)\"",
        "verify-production-evidence-recovery-plan-diagnostic: check-production-evidence-recovery-diagnostic-paths",
        "validate-production-evidence-recovery-env:",
        "$(MAKE) --no-print-directory verify-production-static-receipt >/dev/null",
        "$(MAKE) --no-print-directory verify-production-evidence-recovery-plan >/dev/null",
        "PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true bash \"$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)\"",
        "verify-production-static-receipt:",
        "python3 IMServer/LoadTests/production_static_gate_receipt.py --verify",
        "--require-completion-status",
        "--require-recovery-plan",
        "--expect-repo-root \"$(CURDIR)\"",
        "--require-current-git",
        "--require-clean-git",
        "production-readiness-status:",
        "bash IMServer/LoadTests/production_readiness_status.sh",
        "validate-production-acceptance-env:",
        "bash IMServer/LoadTests/validate_production_acceptance_env.sh",
        "run-current-production-readiness:",
        "bash IMServer/LoadTests/run_current_production_readiness.sh",
        "verify-current-production-readiness:",
        "perf_current_production_readiness_verify.py",
        "run-production-acceptance:",
        "bash IMServer/LoadTests/run_production_acceptance.sh",
        "verify-production-acceptance:",
        "bash IMServer/LoadTests/verify_production_acceptance.sh",
        "assert-production-ready:",
        "bash IMServer/LoadTests/assert_production_ready.sh",
        "verify-production-ready-assertion:",
        "python3 IMServer/LoadTests/verify_production_ready_assertion.py --receipt-json",
        "PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT",
        "package-production-ready-assertion:",
        "python3 IMServer/LoadTests/package_production_ready_assertion.py --receipt-json",
        "PRODUCTION_READY_ASSERTION_ARCHIVE_DIR",
        "verify-production-ready-archive:",
        "--verify-archive",
        "run-product-test-plan-plan:",
        "bash IMServer/LoadTests/run_product_test_plan.sh --print-plan",
        "check-product-test-plan:",
        "bash IMServer/LoadTests/run_product_test_plan.sh --validate-plan",
        "run-product-test-plan:",
        "bash IMServer/LoadTests/run_product_test_plan.sh",
        "verify-local-acceptance:",
        "python3 IMServer/LoadTests/verify_local_acceptance.py",
    ],
    "deploy/ubuntu/95_production_readiness_gate.sh": [
        "READINESS_REQUIRE_TOPOLOGY_SMOKE",
        "READINESS_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "READINESS_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS",
        "READINESS_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "READINESS_REQUIRE_TIME_SYNC",
        "READINESS_TOPOLOGY_SMOKE_JSON",
        "READINESS_TOPOLOGY_SMOKE_MAX_AGE_SECONDS",
        "READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS",
        "READINESS_TOPOLOGY_SMOKE_SELF_TEST",
        "READINESS_RECEIPT_JSON",
        "READINESS_WRITE_RECEIPT",
        "READINESS_RECEIPT_SELF_TEST",
        "write_readiness_receipt()",
        "imserver-production-readiness-gate",
        "readiness step=receipt result=pass",
        "AUDIT_REQUIRE_ALERT_LOG_REDACTION=",
        "READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS_EFFECTIVE",
        "READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS_EFFECTIVE",
        "resolve_restore_drill_freshness_requirement()",
        "resolve_offsite_backup_freshness_requirement()",
        "resolve_topology_smoke_requirement()",
        "restore_drill_freshness_false_ignored_when_gate_required",
        "offsite_backup_freshness_false_ignored_when_gate_required",
        "topology_smoke_required_when_performance_gate_required",
        "AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=\"${READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS_EFFECTIVE}\"",
        "AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=\"${READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS_EFFECTIVE}\"",
        "require_alert_log_redaction_mapping",
        "verify_topology_smoke_receipt()",
        "topology_smoke_receipt_missing",
        "verify_production_smoke.py",
        "--require-pass",
        "--require-artifacts-exist",
        "readiness step=topology-smoke-receipt",
        "run_step \"topology-smoke-receipt\" verify_topology_smoke_receipt",
        "readiness-topology-smoke result=pass",
    ],
    "deploy/ubuntu/72_install_topology_smoke_receipt.sh": [
        "TOPOLOGY_SMOKE_RECEIPT_SOURCE",
        "TOPOLOGY_SMOKE_INSTALL_DIR",
        "TOPOLOGY_SMOKE_LATEST_RECEIPT",
        "TOPOLOGY_SMOKE_MAX_AGE_SECONDS",
        "TOPOLOGY_SMOKE_INSTALL_SELF_TEST",
        "verify_production_smoke.py",
        "--require-artifacts-exist",
        "payload[\"artifacts\"] = rewritten",
        "topology_smoke_receipt_install result=pass",
        "topology_smoke_receipt_install_self_test result=pass",
        "artifact_path_not_rewritten",
        "missing_artifact_accepted",
    ],
    "deploy/ubuntu/00_install_dependencies.sh": [
        "systemd-timesyncd",
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
    ],
    "deploy/ubuntu/40_build_imserver.sh": [
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
    ],
    "deploy/ubuntu/50_install_systemd_units.sh": [
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
    ],
    "deploy/ubuntu/52_verify_systemd_units.sh": [
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
    ],
    "deploy/ubuntu/25_setup_host_security.sh": [
        "ENABLE_TIME_SYNC",
        "time_sync_required_for_production",
        "systemd_unit_exists()",
        "timedatectl set-ntp true",
        "systemctl enable --now systemd-timesyncd",
        "systemctl enable --now chrony",
        "time_sync_service_missing",
        "time_sync_skip_allowed_in_production",
        "host-security-self-test result=pass",
    ],
    "deploy/ubuntu/30_setup_kafka.sh": [
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
    ],
    "deploy/ubuntu/77_operational_audit.sh": [
        "AUDIT_REQUIRE_TOPOLOGY_SMOKE",
        "AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON",
        "AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS",
        "AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS",
        "validate_release_checksum_file()",
        "audit release-checksum-safety result=pass",
        "unsafe_checksum_file release=",
        "release_checksum_unsafe_path_accepted",
        "release_checksum_extra_file_accepted",
        "AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS",
        "AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "AUDIT_REQUIRE_TIME_SYNC",
        "AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS",
        "AUDIT_TOPOLOGY_SMOKE_VERIFIER",
        "AUDIT_ALERT_ALLOW_INSECURE_HTTP",
        "AUDIT_ALERT_REDACT_LOG_TAIL",
        "AUDIT_REQUIRE_ALERT_LOG_REDACTION",
        "alert_webhook_url_policy_reason()",
        "configured_alert_allow_insecure_http()",
        "configured_alert_redact_log_tail()",
        "resolve_alert_log_redaction_requirement()",
        "resolve_topology_smoke_requirement()",
        "topology_smoke_false_ignored_when_gate_required",
        "alert_log_redaction_false_ignored_when_alert_required",
        "check_topology_smoke_receipt()",
        "check_time_sync()",
        "timedatectl show -p NTPSynchronized --value",
        "no_enabled_active_time_sync_service",
        "topology-smoke-receipt",
        "topologySmoke require=%s",
        "verify_production_smoke.py",
        "--require-pass",
        "--require-artifacts-exist",
        "Environment=AUDIT_REQUIRE_TOPOLOGY_SMOKE=",
        "Environment=AUDIT_ALERT_REDACT_LOG_TAIL=",
        "backup-alert-unit",
        "restore-drill-alert-unit",
        "Environment=AUDIT_ALERT_LOG_FILE=",
        "broken_backup_alert_env_unit_accepted",
        "broken_restore_drill_alert_log_unit_accepted",
        "receipt_backupManifestSha256_missing",
        "receipt_requiredTables_missing",
        "shallow_restore_drill_accepted",
        "receipt_postSyncVerify_not_true",
        "receipt_postSyncVerifyMode_invalid",
        "unverified_offsite_backup_accepted",
        "manifest_createdAt_in_future",
        "receipt_completedAt_in_future",
        "future_latest_backup_accepted",
        "future_restore_drill_accepted",
        "future_offsite_backup_accepted",
        "time_sync_unsynced_accepted",
        "time_sync_inactive_service_accepted",
        "topology_smoke_bad_accepted",
        "placeholder_alert_url_accepted",
        "insecure_placeholder_alert_url_accepted",
        "log_tail_redaction_disabled",
        "insecure_alert_url_accepted",
        "insecure_alert_url_override_rejected",
        "insecure_alert_url_env_override_rejected",
        "alert_redact_log_tail",
        "status_not_passed",
    ],
    "deploy/ubuntu/78_install_operational_audit_timer.sh": [
        "AUDIT_REQUIRE_TOPOLOGY_SMOKE",
        "AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON",
        "AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS",
        "AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS",
        "AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS",
        "AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "AUDIT_REQUIRE_TIME_SYNC",
        "AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS",
        "AUDIT_ALERT_ALLOW_INSECURE_HTTP",
        "AUDIT_ALERT_REDACT_LOG_TAIL",
        "AUDIT_ALERT_WEBHOOK_URL_EFFECTIVE",
        "AUDIT_ALERT_WEBHOOK_HEADER_EFFECTIVE",
        "resolve_topology_smoke_requirement_for_timer()",
        "Environment=AUDIT_REQUIRE_TOPOLOGY_SMOKE=",
        "Environment=AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON=",
        "Environment=AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=",
        "Environment=AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS=",
        "Environment=AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS=",
        "Environment=AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS=",
        "Environment=AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS=",
        "Environment=AUDIT_REQUIRE_TIME_SYNC=",
        "Environment=AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS=",
        "Environment=AUDIT_ALERT_ALLOW_INSECURE_HTTP=",
        "Environment=AUDIT_ALERT_REDACT_LOG_TAIL=",
        "require_topology_smoke_missing",
        "topology_smoke_receipt_json_missing",
        "topology_smoke_max_future_skew_missing",
        "service_alert_allow_insecure_http_missing",
        "service_alert_redact_log_tail_missing",
        "RequireTopologySmoke=%s",
        "TopologySmokeReceipt=%s",
        "TopologySmokeMaxAgeSeconds=%s",
        "TopologySmokeMaxFutureSkewSeconds=%s",
        "TopologySmokeRequireArtifacts=%s",
        "AlertAllowInsecureHTTP=%s",
        "AlertRedactLogTail=%s",
        "alert_allow_insecure_http_missing",
        "alert_redact_log_tail_missing",
        "summary_alert_allow_insecure_http_missing",
        "summary_alert_redact_log_tail_missing",
        "summary_require_topology_smoke_missing",
        "summary_topology_smoke_max_future_skew_missing",
        "stale_alert_env_url_not_preserved",
        "stale_alert_env_header_not_preserved",
        "stale_alert_env_allow_insecure_not_reset",
        "stale_alert_env_redact_not_reset",
        "stale_alert_env_log_file_not_updated",
        "stale_alert_env_timeout_not_updated",
    ],
    "deploy/ubuntu/79_send_operational_alert.sh": [
        "AUDIT_ALERT_ALLOW_INSECURE_HTTP",
        "AUDIT_ALERT_REDACT_LOG_TAIL",
        "alert_webhook_url_policy_reason()",
        "placeholder_hosts",
        "placeholder_suffixes",
        "placeholder_domain",
        "def redact(text: str) -> str:",
        "logTailRedacted",
        "insecure_http",
        "invalid_webhook_url",
        "use_https_webhook_or_set_AUDIT_ALERT_ALLOW_INSECURE_HTTP_true_for_bootstrap",
        "placeholder_https_webhook_accepted",
        "placeholder_https_reason_missing",
        "insecure_placeholder_webhook_accepted",
        "insecure_placeholder_reason_missing",
        "insecure_http_webhook_accepted",
        "insecure_http_reason_missing",
        "insecure_http_override_rejected",
        "secret_not_redacted",
        "redaction_marker_missing",
        "logTail",
    ],
    "deploy/ubuntu/92_package_deploy_failure_artifacts.sh": [
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
    ],
    "deploy/ubuntu/80_backup_single_node.sh": [
        "manifest_artifact_files",
        "\"artifacts\": artifacts",
        "\"schemaVersion\": 2",
        "\"sha256\": file_sha256(path)",
        "\"sizeBytes\": os.path.getsize(path)",
        "checksum_files=(manifest.json \"${manifest_artifact_files[@]}\")",
    ],
    "deploy/ubuntu/81_verify_backup.sh": [
        "validate_manifest_artifacts()",
        "validate_checksum_file()",
        "BACKUP_VERIFY_MANIFEST_MAX_BYTES",
        "BACKUP_VERIFY_ETC_ARCHIVE_MEMBER_MAX_BYTES",
        "BACKUP_VERIFY_ETC_ARCHIVE_TOTAL_MAX_BYTES",
        "backup-verify step=checksum_file_safety result=pass",
        "backup-verify step=manifest_artifacts result=pass",
        "Backup checksum file has unsafe file reference",
        "Backup checksum file has duplicate file reference",
        "backup manifest is too large",
        "archive member too large",
        "archive total size too large",
        "manifest artifacts must be a non-empty object",
        "manifest artifacts missing required record",
        "sizeBytes mismatch",
        "sha256 mismatch",
        "unsafe_checksum_file_passed",
        "duplicate_checksum_file_passed",
        "manifest_too_large_accepted",
        "oversized_archive_passed",
        "total_too_large_archive_passed",
        "manifest_artifacts_bad_sha_accepted",
        "manifest_artifacts_extra_bad_sha_accepted",
        "validate_artifact_record(name, required_record=False)",
    ],
    "deploy/ubuntu/82_restore_drill_single_node.sh": [
        "backupManifestSha256",
        "manifest_sha256=\"$(sha256sum \"${BACKUP_DIR}/manifest.json\"",
        "\"backupManifestSha256\": manifest_sha256",
        "RESTORE_DRILL_REQUIRED_TABLES",
        "parse_restore_drill_required_tables()",
        "restore-drill step=critical_tables result=pass",
        "\"requiredTables\": [table for table in required_tables_csv.split(\",\") if table]",
    ],
    "deploy/ubuntu/86_sync_backup_offsite.sh": [
        "backupManifestSha256",
        "manifest_sha256=\"$(sha256sum \"${BACKUP_DIR}/manifest.json\"",
        "\"backupManifestSha256\": manifest_sha256",
        "OFFSITE_BACKUP_POST_VERIFY",
        "run_post_sync_verify()",
        "--checksum",
        "--delete",
        "\"postSyncVerify\": post_verify.lower() in {\"1\", \"true\", \"yes\", \"on\"}",
        "\"postSyncVerifyMode\": \"rsync-dry-run-checksum-delete\"",
        "post_verify_drift_accepted",
        "receipt_manifest_sha_missing",
    ],
    "deploy/ubuntu/90_deploy_single_node.sh": [
        "IM_DEPLOY_TOPOLOGY_SMOKE_RECEIPT_SOURCE",
        "IM_DEPLOY_TOPOLOGY_SMOKE_LATEST_RECEIPT",
        "IM_DEPLOY_TOPOLOGY_SMOKE_INSTALL_DIR",
        "IM_DEPLOY_FINAL_AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "IM_DEPLOY_FINAL_AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS",
        "IM_DEPLOY_FINAL_AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "IM_DEPLOY_FINAL_AUDIT_REQUIRE_TIME_SYNC",
        "IM_DEPLOY_FINAL_AUDIT_REQUIRE_TIME_SYNC_EFFECTIVE",
        "resolve_final_audit_restore_drill_freshness_requirement()",
        "resolve_final_audit_offsite_backup_freshness_requirement()",
        "IM_DEPLOY_FINAL_AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS_EFFECTIVE=\"$(resolve_final_audit_restore_drill_freshness_requirement)\"",
        "IM_DEPLOY_FINAL_AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS_EFFECTIVE=\"$(resolve_final_audit_offsite_backup_freshness_requirement)\"",
        "final_audit_effective_restore_drill_freshness_invalid",
        "final_audit_effective_offsite_backup_freshness_invalid",
        "IM_RELEASE_AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "IM_RELEASE_AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS",
        "IM_RELEASE_AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS",
        "IM_RELEASE_AUDIT_REQUIRE_TIME_SYNC",
        "install_topology_smoke_receipt_if_configured()",
        "bash \"${SCRIPT_DIR}/72_install_topology_smoke_receipt.sh\"",
        "install_topology_smoke_receipt_if_configured",
        "final_audit_topology_smoke_receipt_source_missing",
        "final_audit_topology_smoke_receipt_missing",
        "topologySmokeReceiptSourceProvided",
    ],
    "IMApp/Scripts/validate_debug_network_defaults.sh": [
        "IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST",
        "FAKE_XCODEBUILD_CASE=public",
        "debug_api_must_be_local_http",
        "FAKE_XCODEBUILD_CASE=unresolved",
        "unresolved_IM_API_BASE_URL",
        "debug-network-defaults-self-test result=pass",
        "xcodebuild",
        "-showBuildSettings",
    ],
    "scripts/validate_android_network_configuration.py": [
        "AndroidNetworkConfigurationPolicy.kt",
        "AppContainer.kt",
        "AndroidNetworkConfigurationPolicyTests.kt",
        "stalePublicIPs",
        "AndroidNetworkConfigurationPolicy.validateRelease(",
        "releaseRejectsRawTCPIPAddress",
        "android-network-config-audit-self-test result=pass",
    ],
    "IMServer/LoadTests/validate_load_tests.sh": [
        "production acceptance env validator self-test",
        "PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=true",
        "validate_production_acceptance_env.sh",
        "production-acceptance-env-validator-self-test.log",
        "production acceptance final verifier wrapper self-test",
        "production public target policy self-test",
        "production_target_policy.py",
        "production-target-policy-self-test.log",
        "VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=true",
        "verify_production_acceptance.sh",
        "production-acceptance-final-verifier-self-test.log",
        "final production-ready assertion self-test",
        "ASSERT_PRODUCTION_READY_SELF_TEST=true",
        "assert_production_ready.sh",
        "production-ready-assertion-self-test.log",
        "final production-ready assertion verifier self-test",
        "verify_production_ready_assertion.py",
        "production-ready-assertion-verifier-self-test.log",
        "final production-ready assertion package self-test",
        "package_production_ready_assertion.py",
        "production-ready-assertion-package-self-test.log",
        "production readiness status self-test",
        "PRODUCTION_READINESS_STATUS_SELF_TEST=true",
        "production_readiness_status.sh",
        "production-readiness-status-self-test.log",
        "local acceptance artifact verifier self-test",
        "verify_local_acceptance.py",
        "local-acceptance-verify-self-test.log",
        "NODE_ACCESS_RESCUE_ARTIFACT_SELF_TEST=true",
        "generate_node_access_rescue_artifact.sh",
        "node-access-rescue-artifact-self-test.log",
    ],
    "IMServer/LoadTests/generate_node_access_rescue_artifact.sh": [
        "node_access_rescue_artifact_self_test result=pass",
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
        "NODE_ACCESS_RESCUE_ARTIFACT_SELF_TEST",
        "verify-artifact.sh",
    ],
    "IMServer/LoadTests/package_production_evidence.sh": [
        "production_evidence_package_self_test result=pass",
        "perf_evidence_manifest.py",
        "perf_secret_scan.py",
        "production-evidence-manifest.json",
        "secret-scan.log",
        "account_artifact_path_packaged",
        "bad-validation-inventory-manifest",
        "bad-current-full-manifest",
    ],
    "IMServer/LoadTests/perf_evidence_manifest.py": [
        "evidence_manifest_self_test result=pass",
        "def run_self_test()",
        "iter_payload_files(root)",
        "sha256_file(payload)",
        "self_test_payload_files_mismatch",
    ],
    "IMServer/LoadTests/perf_matrix_audit.py": [
        "matrix_audit_self_test result=pass",
        "self_test_missing_case_rejected",
        "self_test_missing_list_entry_rejected",
        "self_test_missing_k6_script_rejected",
        "self_test_duplicate_list_warned",
    ],
    "IMServer/LoadTests/perf_coverage.py": [
        "coverage_self_test result=pass",
        "self_test_critical_gap_detected",
        "self_test_optional_gap_detected",
        "self_test_duplicate_endpoint_rejected",
        "self_test_count_mismatch_rejected",
    ],
    "IMServer/LoadTests/perf_route_audit.py": [
        "route_audit_self_test result=pass",
        "self_test_missing_route_detected",
        "self_test_orphan_endpoint_detected",
        "self_test_duplicate_source_rejected",
        "self_test_duplicate_coverage_rejected",
    ],
    "IMServer/LoadTests/perf_scenario_status.py": [
        "scenario_status_self_test result=pass",
        "self_test_latest_run_selected",
        "self_test_never_run_seeded",
        "self_test_target_filter_applied",
        "self_test_duplicate_scenario_rejected",
    ],
    "IMServer/LoadTests/perf_scenario_catalog.py": [
        "scenario_catalog_self_test result=pass",
        "self_test_maturity_gap_detected",
        "self_test_status_attached",
        "self_test_tcp_domain_detected",
        "self_test_duplicate_scenario_rejected",
    ],
    "IMServer/LoadTests/perf_run_plan.py": [
        "run_plan_self_test result=pass",
        "self_test_p0_blocks_matrix",
        "self_test_smoke_selection_ready",
        "self_test_secret_redacted",
        "self_test_duplicate_selection_rejected",
    ],
    "IMServer/LoadTests/perf_default_profile_audit.py": [
        "default_profile_audit_self_test result=pass",
        "self_test_profile_drift_rejected",
        "self_test_missing_file_rejected",
        "self_test_missing_pattern_rejected",
        "self_test_payload_count_mismatch_rejected",
    ],
    "IMServer/LoadTests/perf_docs_audit.py": [
        "docs_audit_self_test result=pass",
        "self_test_unknown_group_rejected",
        "self_test_unknown_profile_rejected",
        "self_test_public_8080_rejected",
        "self_test_stale_public_ip_rejected",
        "self_test_example_domain_rejected",
    ],
    "IMServer/LoadTests/perf_validation_inventory.py": [
        "validation_inventory_self_test result=pass",
        "def run_self_test()",
        "REQUIRED_INVENTORY_RECORDS",
        "self_test_missing_required_record",
        "source_git_dirty_mismatch",
    ],
    "IMServer/LoadTests/perf_production_profiles_audit.py": [
        "production_profiles_audit_self_test result=pass",
        "self_test_unknown_scenario_rejected",
        "self_test_duplicate_scenario_rejected",
        "self_test_group_subset_warned",
        "profile_group_relation(",
    ],
    "IMServer/LoadTests/perf_product_scenario_suite_verify.py": [
        "product_scenario_suite_verify_self_test result=pass",
        "self_test_stage_coverage_missing",
        "self_test_large_group_not_allowed",
        "self_test_markdown_missing_coverage",
        "require_no_large_group",
    ],
    "IMServer/LoadTests/perf_product_plan_artifacts_verify.py": [
        "product_plan_artifacts_self_test result=pass",
        "self_test_phase_status_tsv_mismatch",
        "self_test_plan_preview_unique_count_mismatch",
        "self_test_phase_command_secret_not_redacted",
        "require_secret_redacted(",
    ],
    "IMServer/LoadTests/perf_product_campaign_artifacts_verify.py": [
        "product_campaign_artifacts_self_test result=pass",
        "self_test_stage_count_mismatch",
        "self_test_stage_command_secret_not_redacted",
        "self_test_large_group_stage_not_isolated",
        "require_stage_target_matches(",
    ],
    "IMServer/LoadTests/perf_product_campaign_audit.py": [
        "product_campaign_audit_self_test result=pass",
        "self_test_non_large_missing_phase_rejected",
        "self_test_non_large_large_group_rejected",
        "self_test_unknown_phase_rejected",
        "required_phase_policies_missing",
    ],
    "IMServer/LoadTests/perf_product_profile_gate.py": [
        "product_profile_gate_self_test result=pass",
        "self_test_missing_domain_rejected",
        "self_test_large_group_rejected",
        "self_test_unknown_scenario_rejected",
        "self_test_maturity_gap_rejected",
    ],
    "IMServer/LoadTests/perf_profile_artifacts_verify.py": [
        "profile_artifacts_self_test result=pass",
        "self_test_production_gate_target_public_required",
        "self_test_profile_run_batch_selection_mismatch",
        "self_test_profile_catalog_missing_selected_scenario",
        "require_public_target(",
    ],
    "IMServer/LoadTests/verify_local_acceptance.py": [
        "local_acceptance_verify result=pass",
        "productionEvidence",
        "localOnly",
        "REQUIRED_CHECKS",
        "summary_database_unsafe_reset",
        "http_smoke_checks_not_ok",
    ],
    "IMServer/LoadTests/verify_production_acceptance.sh": [
        "validate_public_target()",
        "production_target_policy.py",
        "--result-prefix \"verify_production_acceptance\"",
        "PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS",
        "PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS",
        "verify_receipt_freshness()",
        "generatedAtEpoch",
        "--max-age-seconds",
        "--max-future-skew-seconds",
        "receipt_stale",
        "receipt_from_future",
        "self_test_receipt_stale_passed",
        "self_test_receipt_from_future_passed",
        "BASE_URL=https://chat.prod.company.com",
        "TCP_HOST=tcp.prod.company.com",
        "self_test_local_target_passed",
        "self_test_path_target_passed",
        "self_test_bad_tcp_port_passed",
    ],
    "IMServer/LoadTests/run_current_production_readiness.sh": [
        "PRODUCTION_TARGET_POLICY",
        "production_target_policy.py",
        "--reason-only",
        "BASE_URL=https://chat.prod.company.com",
        "TCP_HOST=tcp.prod.company.com",
        "Replace prod.company.com examples before running",
        "CURRENT_PRODUCTION_SELF_TEST",
        "public_base_url_https_required",
        "public_base_url_default_https_port_required",
        "public_base_url_origin_required",
        "public_base_url_domain_required",
        "tcp_host_domain_required",
        "tcp_port_required",
        "bad_tcp_port_path_passed",
        "bad_tcp_port_started_load",
        "path_public_target_path_passed",
        "path_public_target_started_load",
    ],
    "IMServer/LoadTests/run_production_acceptance.sh": [
        "validate_public_target()",
        "production_target_policy.py",
        "--result-prefix \"production_acceptance\"",
        "BASE_URL=https://chat.prod.company.com",
        "TCP_HOST=tcp.prod.company.com",
        "Replace prod.company.com examples before running",
        "PRODUCTION_ACCEPTANCE_SELF_TEST",
        "invalid_target_passed",
        "non_default_https_port_target_passed",
        "path_target_passed",
        "base_url_origin_required",
        "bad_tcp_port_target_passed",
        "ip_base_target_passed",
        "ip_tcp_target_passed",
        "placeholder_target_passed",
        "placeholder_tcp_target_passed",
    ],
    "IMServer/LoadTests/assert_production_ready.sh": [
        "validate_public_target()",
        "production_target_policy.py",
        "--result-prefix \"assert_production_ready\"",
        "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON",
        "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON",
        "PRODUCTION_DEPLOY_READINESS_VERIFIER",
        "PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS",
        "PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS",
        "PRODUCTION_STATIC_GATE_RECEIPT_JSON",
        "PRODUCTION_STATIC_GATE_VERIFIER",
        "--require-completion-status",
        "--require-recovery-plan",
        "--require-current-git",
        "--require-clean-git",
        "static-support/completion-status.json",
        "static-support/evidence-recovery-plan.json",
        "PRODUCTION_TOPOLOGY_SMOKE_VERIFIER",
        "verify_deploy_readiness_receipt.py",
        "verify_production_smoke.py",
        "--require-artifacts-exist",
        "self_test_deploy_readiness_receipt_arg_missing",
        "self_test_deploy_readiness_base_url_arg_missing",
        "self_test_deploy_readiness_tcp_host_arg_missing",
        "self_test_deploy_readiness_tcp_port_arg_missing",
        "self_test_deploy_readiness_max_age_arg_missing",
        "self_test_deploy_readiness_max_future_skew_arg_missing",
        "ASSERT_PRODUCTION_READY_RECEIPT_JSON",
        "imserver-production-ready-assertion",
        "write_assertion_receipt()",
        "productionClaim",
        "verified-final-production-evidence",
        "self_test_assertion_receipt_claim_allowed",
        "self_test_receipt_missing",
        "requiresFreshProductionAcceptanceReceipt",
        "productionAcceptanceMaxAgeSeconds",
        "self_test_assertion_receipt_acceptance_freshness",
        "self_test_receipt_log_missing",
        "self_test_status_topology_smoke_env_missing",
        "self_test_status_deploy_readiness_env_missing",
        "self_test_status_static_gate_env_missing",
        "self_test_auto_status_topology_smoke_env_missing",
        "self_test_auto_status_deploy_readiness_env_missing",
        "self_test_missing_deploy_readiness_passed",
        "self_test_dirty_static_gate_passed",
        "BASE_URL=https://chat.prod.company.com",
        "TCP_HOST=tcp.prod.company.com",
        "self_test_local_target_passed",
        "self_test_path_target_passed",
        "self_test_bad_tcp_port_passed",
    ],
    "IMServer/LoadTests/verify_production_ready_assertion.py": [
        "production_ready_assertion_verify result=pass",
        "production_ready_assertion_verify_self_test result=pass",
        "imserver-production-ready-assertion",
        "REQUIRED_POLICY_TRUE",
        "REQUIRED_ARTIFACTS",
        "requiresDeployReadinessReceipt",
        "requiresProductionStaticGateReceipt",
        "productionStaticGateReceipt",
        "verify_deploy_readiness_receipt.py",
        "verify_topology_smoke_artifact(",
        "verify_deploy_readiness_artifact(",
        "verify_static_gate_artifact(",
        "require_completion_status=True",
        "require_recovery_plan=True",
        "require_current_git=not args.require_static_gate_support_root",
        "require_clean_git=True",
        "init_self_test_git_repo(",
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
        "production_static_gate_git_binding_mismatch",
        "production_claim_missing",
        "production_claim_mismatch",
        "bad-production-claim",
        "schema-version-string",
        "generated-at-string",
        "artifact-bytes-string",
        "verify_current_readiness_artifact(",
        "verify_production_acceptance_artifact(",
        "requiresFreshProductionAcceptanceReceipt",
        "productionAcceptanceMaxAgeSeconds",
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
        "stale-production-acceptance",
        "bad-production-acceptance-package-binding",
        "production-acceptance-package-bytes-string",
        "bad-production-evidence-package",
        "bad-public-target",
        "--fail-reason-only",
        "fail_reason_only_missing_reason",
        "fail_reason_only_prefix_leaked",
        "requiresProductionEvidencePackage",
        "artifact_sha256_mismatch",
        "artifact_bytes_mismatch",
        "receipt_stale",
        "receipt_from_future",
        "target_mismatch",
        "policy_not_enforced",
        "artifact_file_missing",
        "--artifact-root",
        "artifactRoots=",
        "portable-artifacts",
    ],
    "IMServer/LoadTests/package_production_ready_assertion.py": [
        "production_ready_assertion_package result=pass",
        "production_ready_assertion_package_self_test result=pass",
        "from perf_forbidden_artifacts import is_forbidden_runtime_artifact",
        "imserver-production-ready-assertion-archive",
        "production-ready-archive-manifest.json",
        "production-ready-assertion.json",
        "SHA256SUMS",
        "artifacts",
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
        "archive_manifest_production_claim_mismatch",
        "bad_claim_manifest_archive_passed",
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
        "safe_extract_archive(",
        "MAX_ARCHIVE_MEMBER_BYTES",
        "MAX_ARCHIVE_TOTAL_BYTES",
        "archive_member_too_large",
        "archive_total_too_large",
        "oversized_member_archive_passed",
        "archive_total_limit_passed",
        "verify_archive(",
        "production_ready_assertion_archive_verify result=pass",
        "archive_member_path_unsafe",
        "forbidden_runtime_artifact_name(",
        "archive_member_forbidden_artifact",
        "forbidden_artifact_archive_passed",
        "forbidden_artifact_archive_reason_missing",
        "load-10000.csv",
        "archive_sha256sums_mismatch",
        "archive_manifest_target_mismatch",
        "bad_target_manifest_archive_passed",
        "verify_production_ready_assertion.py",
        "--artifact-root",
        "--verify-archive",
    ],
    "IMServer/LoadTests/production_completion_status.py": [
        "imserver-production-completion-status",
        "production_completion_status_self_test result=pass",
        "local-static-gate-receipt",
        "verify_production_ready_assertion.py",
        "package_production_ready_assertion.py",
        "perf_forbidden_artifacts.py",
        "forbidden-artifacts-helper",
        "verify_deploy_readiness_receipt.py",
        "production_evidence_recovery_plan.py",
        "production_static_gate_receipt.py",
        "static-receipt-helper",
        "production_worktree_inventory.py",
        "production-worktree-inventory",
        "Run make production-worktree-plan",
        "run stageDryRunCommand and stageDryRunReceiptCommand",
        "run make production-worktree-stage-dry-run-batch and verify-production-worktree-stage-dry-run-batch",
        "verify the staged group",
        "clean generated/forbidden artifacts separately",
        "require_current_git=True",
        "DEFAULT_STATIC_RECOVERY_PLAN_JSON",
        "DEFAULT_STATIC_RECOVERY_PLAN_MARKDOWN",
        "PRODUCTION_COMPLETION_STATUS_STATIC_RECEIPT_BOOTSTRAP",
        "staticReceiptBootstrap",
        "require_recovery_plan=not bootstrap",
        "expect_repo_root=str(repo_root)",
        "require_current_git=True",
        "require_clean_git=True",
        "Commit or remove local changes, then rerun make validate-production-static",
        "self_test_dirty_static_gate_next_action_missing",
        "PRODUCTION_DEPLOY_READINESS_VERIFIER",
        "productionDeployReadinessVerifier",
        "verify_deploy_readiness_artifact(",
        "production_deploy_readiness_receipt_invalid",
        "valid_deploy_readiness_payload()",
        "verify_production_smoke.py",
        "verify_production_acceptance.sh",
        "perf_current_production_readiness_verify.py",
        "perf_production_acceptance_verify.py",
        "--verify-package-archive",
        "CURRENT_PRODUCTION_READINESS_DASHBOARD_JSON",
        "CURRENT_PRODUCTION_READINESS_EVIDENCE_DIR",
        "PRODUCTION_ACCEPTANCE_VERIFIER",
        "check_deploy_readiness(",
        "check_current_readiness(",
        "check_production_acceptance(",
        "check_production_evidence_package(",
        "check_final_assertion(",
        "check_final_assertion_archive(",
        "is_final_production_claim(",
        "requiresFreshProductionAcceptanceReceipt",
        "final_production_claim_result(",
        "MAX_FINAL_ASSERTION_ARCHIVE_MANIFEST_BYTES",
        "archive_manifest_claim(",
        "archive_manifest_too_large",
        "self_test_archive_manifest_size_limit_passed",
        "final_assertion_claim_invalid",
        "final_assertion_archive_claim_invalid",
        "production_target(",
        "productionTarget",
        "production_claim(",
        "productionClaim",
        "readiness_tiers(",
        "readinessTiers",
        "readiness_tiers localEngineering=",
        "productionReadyTier",
        "self_test_readiness_tiers_render_missing",
        "self_test_readiness_tiers_markdown_missing",
        "finalAssertionClaimVerified",
        "finalAssertionArchiveClaimVerified",
        "self_test_final_assertion_claim_row_missing",
        "self_test_final_archive_claim_row_missing",
        "production_claim productionReady=",
        "finalAssertionClaimVerified=",
        "finalAssertionArchiveClaimVerified=",
        "productionReadyClaimAllowed",
        "productionReadyFinalAssertionClaimVerified",
        "productionReadyFinalAssertionArchiveClaimVerified",
        "self_test_production_claim_render_missing",
        "self_test_production_claim_markdown_missing",
        "self_test_production_claim_assertion_markdown_missing",
        "self_test_production_claim_archive_markdown_missing",
        "production_target baseURL=",
        "currentTrackedModifiedCount",
        "boundTrackedModifiedCount",
        "currentUntrackedCount",
        "boundUntrackedCount",
        "targetBaseURL",
        "targetTCP",
        "self_test_production_target_mismatch",
        "self_test_production_target_render_missing",
        "missing_target_env(",
        "--expect-base-url",
        "--expect-tcp-host",
        "--expect-tcp-port",
        "check_topology_smoke(",
        "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON",
        "self_test_final_assertion_target_mismatch_passed",
        "self_test_final_archive_target_mismatch_passed",
        "self_test_bad_final_assertion_failed",
        "self_test_bad_final_archive_failed",
        "self_test_ready_recovery_render_leaked",
        "self_test_ready_markdown_mismatch",
        "self_test_recovery_render_count_mismatch",
        "self_test_recovery_render_item_missing",
        "self_test_recovery_render_missing",
        "self_test_recovery_markdown_missing",
        "self_test_recovery_markdown_guard_missing",
        "self_test_summary_counts_render_missing",
        "render_markdown(",
        "--markdown-output",
        "Production Completion Status",
        "Recovery commands are operator instructions, not proof",
        "final assertion plus archive production claims verify",
        "localCompletionPercent",
        "liveEvidenceCompletionPercent",
        "productionCompletionPercent",
        "localMissingCount",
        "liveEvidenceMissingCount",
        "evidenceRecoveryPlanCount",
        "make assert-production-ready",
        "PRODUCTION_READY_ASSERTION_ARCHIVE_FILE",
        "EVIDENCE_CONTRACTS",
        "evidenceContract",
        "evidenceRecoveryPlan",
        "evidence_recovery_plan(",
        "recovery item=",
        "summary missing=",
        "localMissing=",
        "liveEvidenceMissing=",
        "recoveryPlan=",
        "production_completion_status status=",
    ],
    "IMServer/LoadTests/production_evidence_recovery_plan.py": [
        "imserver-production-evidence-recovery-plan",
        "production_evidence_recovery_plan_self_test result=pass",
        "production_evidence_recovery_plan_verify result=pass",
        "verify_production_completion_status.verify_status_report(",
        "build_plan(",
        "verify_plan(",
        "verify_recovery_artifacts(",
        "field_invalid",
        "production_claim_from_status(",
        "production_claim_field_invalid",
        "production_claim_required_evidence_invalid",
        "production_claim_required_evidence_mismatch",
        "requiredEvidence",
        "readiness_tiers_from_status(",
        "readiness_tiers_mismatch",
        "readinessTiers",
        "ready_to_claim_production(",
        "production_claim_mismatch",
        "claimAllowed is true",
        "final assertion plus archive production claims verify",
        "render_markdown(",
        "self_test_incomplete_status_plan",
        "self_test_ready_status_plan",
        "self_test_production_claim_mismatch_rejected",
        "self_test_markdown_missing_claim_allowed",
        "self_test_markdown_missing_final_assertion_claim",
        "self_test_ready_production_claim_not_copied",
        "self_test_duplicate_step_rejected",
        "self_test_production_claim_required_evidence_rejected",
        "self_test_readiness_tiers_mismatch_rejected",
        "self_test_production_claim_required_evidence_mismatch_rejected",
        "self_test_missing_verify_rejected",
        "self_test_artifact_markdown_mismatch_rejected",
        "self_test_local_incomplete_rejected",
        "local_missing_invalid",
        "local_missing_count_mismatch",
        "local_missing_mismatch",
        "self_test_missing_local_missing_rejected",
        "self_test_mismatched_local_missing_rejected",
        "Live evidence recovery is blocked until the local production gate is complete.",
        "Commit or remove local changes, then rerun `make validate-production-static`",
        "self_test_local_gate_blocker_markdown_missing",
        "self_test_local_missing_reason_markdown_missing",
        "self_test_dirty_static_gate_markdown_missing",
        "local_missing_diagnostic_suffix(",
        "self_test_dirty_static_gate_diagnostic_markdown_missing",
        "operatorEnvironmentTemplate",
        "oneShotRecoveryCommands",
        "productionTarget",
        "production_target_from_status(",
        "production_target_mismatch",
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
        "self_test_reordered_one_shot_recovery_rejected",
        "self_test_recovery_script_missing_target_validation",
        "self_test_recovery_script_missing_validate_only",
        "self_test_recovery_script_missing_progress_logs",
        "self_test_artifact_script_mismatch_rejected",
        "self_test_artifact_script_not_executable_rejected",
        "self_test_artifact_script_syntax_rejected",
        "final-assertion-archive",
        "Do not claim production readiness",
    ],
    "IMServer/LoadTests/verify_production_evidence_recovery_paths.py": [
        "production_evidence_recovery_paths_self_test result=pass",
        "production_evidence_recovery_paths result=pass",
        "verify_paths(",
        "verify_unique(",
        "Path(value).expanduser().resolve()",
        "strict_artifact_path_conflict",
        "diagnostic_artifact_path_conflict",
        "diagnostic_artifact_conflicts_with_strict",
        "self_test_strict_artifact_path_conflict",
        "self_test_diagnostic_artifact_path_conflict",
        "self_test_diagnostic_artifact_conflicts_with_strict",
        "--strict-completion-status-json",
        "--diagnostic-recovery-script",
    ],
    "IMServer/LoadTests/perf_production_acceptance_verify.py": [
        "from perf_forbidden_artifacts import is_forbidden_runtime_artifact",
        "production_acceptance_verify_self_test result=pass",
        "def is_forbidden_evidence_artifact(",
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
        "load-10000.csv",
        "self_test_account_artifact_package_passed",
    ],
    "IMServer/LoadTests/perf_current_production_readiness_verify.py": [
        "current_production_readiness_verify_self_test result=pass",
        "def run_self_test(",
        "require_state_production_evidence_blocker_contract(",
        "require_operator_network_state_consistency(",
        "target_mismatch_not_detected",
        "operatorNetworkPreflight",
    ],
    "IMServer/LoadTests/perf_secret_scan.py": [
        "from perf_forbidden_artifacts import forbidden_runtime_artifact_kinds",
        "perf_secret_scan_self_test result=pass",
        "def forbidden_token_cache_path(",
        "def forbidden_account_artifact_path(",
        "def forbidden_env_artifact_path(",
        "token_cache_artifact",
        "account_artifact",
        "env_artifact",
        "private_key_marker",
        "sensitive_key_value",
        "symlink_artifact",
        "special_file_artifact",
    ],
    "IMServer/LoadTests/perf_forbidden_artifacts.py": [
        "def forbidden_runtime_artifact_kinds(",
        "def is_forbidden_runtime_artifact(",
        "def self_test(",
        "perf_forbidden_artifacts_self_test result=pass",
        "argparse.ArgumentParser(",
        "TOKEN_CACHE_PARTS",
        "ACCOUNT_ARTIFACT_PARTS",
        "ACCOUNT_ARTIFACT_NAMES",
        "TOKEN_CACHE_PREFIXES",
        "token_cache_artifact",
        "account_artifact",
        "env_artifact",
        "load-\\d+\\.csv",
    ],
    "deploy/ubuntu/69_install_performance_evidence_package.sh": [
        "account-artifact-evidence.tar.gz",
        "account-artifact-package",
        "load-10000.csv",
        "account_artifact_passed",
        "account_artifact_reason_missing",
        "account_artifact_changed_gate",
        "account_artifact_changed_current_link",
    ],
    "deploy/ubuntu/70_verify_performance_evidence_package.sh": [
        "account-artifact-evidence",
        "load-10000.csv",
        "account_artifact_evidence_passed",
        "account_artifact_evidence_reason_missing",
    ],
    "IMServer/LoadTests/verify_production_completion_status.py": [
        "production_completion_status_verify result=pass",
        "production_completion_status_verify_self_test result=pass",
        "imserver-production-completion-status",
        "REQUIRED_LOCAL_ITEMS",
        "REQUIRED_EVIDENCE_ITEMS",
        "EXPECTED_LOCAL_ENGINEERING_WEIGHT",
        "EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT",
        "ALLOWED_CHECK_STATUSES",
        "--markdown-report",
        "verify_markdown_report(",
        "completion_markdown_missing",
        "completion_markdown_mismatch",
        "self_test_missing_markdown_report_passed",
        "self_test_bad_markdown_report_passed",
        "require_absolute_repo_root(",
        "repo_root_not_absolute",
        "repo_root_mismatch",
        "self_test_relative_repo_root_passed",
        "self_test_mismatched_repo_root_passed",
        "require_production_target(",
        "require_production_claim(",
        "require_readiness_tiers(",
        "readiness_tiers_missing",
        "readiness_tier_mismatch",
        "readiness_tier_field_unexpected",
        "readiness_tier_unexpected",
        "self_test_missing_readiness_tiers_passed",
        "self_test_mismatched_readiness_tier_passed",
        "self_test_unexpected_readiness_tier_field_passed",
        "self_test_unexpected_readiness_tier_passed",
        "finalAssertionClaimVerified",
        "finalAssertionArchiveClaimVerified",
        "production_claim_missing",
        "production_claim_mismatch",
        "production_claim_field_invalid",
        "production_target_field_invalid",
        "field_invalid",
        "production_claim_required_evidence_invalid",
        "production_claim_required_evidence_mismatch",
        "production_claim_incomplete_without_blockers",
        "self_test_missing_production_claim_passed",
        "self_test_mismatched_production_claim_passed",
        "self_test_invalid_production_target_type_passed",
        "self_test_invalid_production_claim_type_passed",
        "self_test_invalid_required_evidence_type_passed",
        "self_test_invalid_completion_percent_type_passed",
        "self_test_invalid_summary_count_type_passed",
        "self_test_invalid_weight_type_passed",
        "self_test_incomplete_production_claim_without_blockers_passed",
        "production_target_missing",
        "production_target_missing_env_mismatch",
        "production_target_incomplete_for_ready",
        "self_test_missing_production_target_passed",
        "self_test_mismatched_production_target_missing_env_passed",
        "self_test_ready_incomplete_production_target_passed",
        "row_status_invalid",
        "self_test_bad_row_status_passed",
        "localMissingCount",
        "liveEvidenceMissingCount",
        "evidenceRecoveryPlanCount",
        "self_test_bad_local_missing_count_passed",
        "self_test_bad_recovery_plan_count_passed",
        "self_test_bad_live_evidence_missing_count_passed",
        "row_reason_missing",
        "self_test_missing_pass_row_reason_passed",
        "missing_reason_missing",
        "missing_reason_mismatch",
        "missing_path_mismatch",
        "missing_env_mismatch",
        "missing_diagnostic_field_missing",
        "missing_diagnostic_field_mismatch",
        "currentTrackedModifiedCount",
        "boundTrackedModifiedCount",
        "currentUntrackedCount",
        "boundUntrackedCount",
        "self_test_missing_diagnostic_field_passed",
        "self_test_mismatched_diagnostic_field_passed",
        "verify_evidence_contracts(",
        "evidence_contract_mismatch",
        "verify_evidence_recovery_plan(",
        "evidence_recovery_plan_mismatch",
        "evidence_recovery_plan_reason_mismatch",
        "evidence_recovery_plan_order_mismatch",
        "evidence_recovery_plan_omitted",
        "self_test_missing_row_reason_passed",
        "self_test_missing_entry_reason_passed",
        "self_test_mismatched_missing_reason_passed",
        "self_test_mismatched_missing_path_passed",
        "self_test_mismatched_missing_env_passed",
        "self_test_bad_evidence_contract_passed",
        "self_test_bad_evidence_recovery_plan_passed",
        "self_test_mismatched_evidence_recovery_plan_reason_passed",
        "self_test_reordered_evidence_recovery_plan_passed",
        "self_test_missing_evidence_recovery_plan_item_passed",
        "row_item_unexpected",
        "self_test_unexpected_local_item_passed",
        "self_test_unexpected_evidence_item_passed",
        "required_item_missing",
        "self_test_missing_required_passed",
        "missing_item_unexpected",
        "missing_item_omitted",
        "self_test_bad_missing_item_passed",
        "verify_next_actions(",
        "incomplete_next_actions_missing",
        "dirty_static_gate_next_action_missing",
        "git_binding_static_gate_next_action_missing",
        "ready_next_actions_not_empty",
        "self_test_missing_next_actions_passed",
        "self_test_dirty_static_gate_next_action_passed",
        "self_test_git_binding_static_gate_next_action_passed",
        "self_test_ready_next_actions_passed",
        "self_test_bad_weights_passed",
        "require_local_complete",
        "require_live_evidence_complete",
        "require_production_ready",
        "summary_count_mismatch",
        "completion_percent_mismatch",
        "missing_count_mismatch",
        "status_report_stale",
        "production_not_ready",
        "--require-local-complete",
        "--require-production-ready",
    ],
    "IMServer/LoadTests/verify_deploy_readiness_receipt.py": [
        "deploy_readiness_receipt_verify_self_test result=pass",
        "imserver-production-readiness-gate",
        "REQUIRED_POLICY_TRUE",
        "REQUIRED_PERFORMANCE_POLICY_TRUE",
        "REQUIRED_PASS_STEPS",
        "deploy_readiness_policy_not_enforced",
        "deploy_readiness_performance_policy_not_enforced",
        "deploy_readiness_step_not_passed",
        "deploy_readiness_target_mismatch",
        "deploy_readiness_stale",
        "--expect-base-url",
        "--expect-tcp-host",
        "--expect-tcp-port",
    ],
    "IMServer/LoadTests/production_static_gate_receipt.py": [
        "imserver-production-static-gate-receipt",
        "EXPECTED_STATIC_RECEIPT_KIND",
        "EXPECTED_STATIC_RECEIPT_SCHEMA_VERSION",
        "EXPECTED_STATIC_GATE_COMMAND",
        "production_static_gate_receipt_self_test result=pass",
        "production_static_gate_receipt result=pass",
        "production_static_gate_receipt_verify",
        "cli_result_line(",
        "self_test_git_binding_cli_detail_failed",
        "self_test_git_status_hash_cli_detail_failed",
        "self_test_clean_git_cli_detail_failed",
        "verify_git_binding(",
        "verify_clean_git_binding(",
        "git_binding_invalid",
        "git_binding_mismatch",
        "production_static_gate_git_dirty",
        "statusSha256",
        "trackedModifiedCount",
        "untrackedCount",
        "--untracked-files=all",
        "git_diagnostic_value(",
        "self_test_git_summary_counts(",
        "self_test_git_summary_tracked_count_failed",
        "self_test_git_summary_untracked_count_failed",
        "currentTrackedModifiedCount",
        "boundTrackedModifiedCount",
        "currentUntrackedCount",
        "boundUntrackedCount",
        "self_test_git_binding_cli_dirty_detail_failed",
        "DEFAULT_COMPLETION_STATUS_JSON",
        "DEFAULT_COMPLETION_STATUS_MARKDOWN",
        "DEFAULT_RECOVERY_PLAN_JSON",
        "DEFAULT_RECOVERY_PLAN_MARKDOWN",
        "DEFAULT_RECOVERY_PLAN_SCRIPT",
        "completionStatus",
        "recoveryPlan",
        "markdownPath",
        "markdownSha256",
        "EXPECTED_COMPLETION_STATUS_KIND",
        "EXPECTED_COMPLETION_STATUS_SCHEMA_VERSION",
        "EXPECTED_RECOVERY_PLAN_KIND",
        "EXPECTED_RECOVERY_PLAN_SCHEMA_VERSION",
        "EXPECTED_LOCAL_ENGINEERING_WEIGHT",
        "EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT",
        "completion_status_summary(",
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
        "support_root_match(",
        "resolve_bound_file(",
        "prefer_support_roots",
        "require_support_root",
        "verify_completion_status_binding(",
        "verify_recovery_plan_binding(",
        "completion_status_missing",
        "completion_status_sha256_mismatch",
        "completion_status_markdown_missing",
        "completion_status_markdown_render_failed",
        "completion_status_markdown_mismatch",
        "completion_status_markdown_sha256_mismatch",
        "completion_status_kind_mismatch",
        "completion_status_schema_version_mismatch",
        "completion_status_weights_invalid",
        "completion_status_weights_mismatch",
        "self_test_completion_readiness_tiers_mismatch_failed",
        "self_test_completion_readiness_tiers_extra_field_failed",
        "self_test_completion_readiness_tiers_type_failed",
        "self_test_recovery_readiness_tiers_mismatch_failed",
        "self_test_recovery_readiness_tiers_extra_field_failed",
        "self_test_recovery_readiness_tiers_type_failed",
        "schema_version_mismatch",
        "gate_command_mismatch",
        "gate_not_completed",
        "completion_status_local_incomplete",
        "completion_status_repo_root_missing",
        "completion_status_repo_root_not_absolute",
        "completion_status_repo_root_mismatch",
        "completion_status_generated_at_in_future",
        "completion_status_newer_than_receipt",
        "completion_status_stale",
        "recovery_plan_missing",
        "recovery_plan_sha256_mismatch",
        "recovery_plan_artifact_render_failed",
        "recovery_plan_markdown_mismatch",
        "recovery_plan_script_mismatch",
        "recovery_plan_markdown_sha256_mismatch",
        "recovery_plan_script_sha256_mismatch",
        "recovery_plan_script_not_executable",
        "recovery_plan_source_status_mismatch",
        "recovery_plan_steps_count_mismatch",
        "repo_root_not_absolute",
        "repo_root_mismatch",
        "self_test_recovery_missing_failed",
        "self_test_recovery_markdown_sha_failed",
        "self_test_recovery_script_sha_failed",
        "self_test_recovery_script_executable_failed",
        "self_test_recovery_markdown_semantic_failed",
        "self_test_recovery_script_semantic_failed",
        "self_test_recovery_source_failed",
        "self_test_completion_missing_failed",
            "self_test_completion_markdown_sha_failed",
            "self_test_completion_target_mismatch_failed",
            "self_test_completion_target_type_failed",
            "self_test_completion_claim_mismatch_failed",
            "self_test_completion_claim_type_failed",
            "self_test_completion_final_claim_mismatch_failed",
            "self_test_recovery_target_mismatch_failed",
            "self_test_recovery_claim_mismatch_failed",
        "self_test_recovery_claim_type_failed",
        "self_test_recovery_completion_target_mismatch_failed",
        "self_test_recovery_completion_claim_mismatch_failed",
        "self_test_completion_markdown_semantic_failed",
        "self_test_completion_binding_failed",
        "self_test_completion_binding_count_type_failed",
        "self_test_completion_source_count_type_failed",
        "self_test_recovery_ready_type_failed",
        "self_test_recovery_source_ready_type_failed",
        "self_test_completion_repo_root_binding_failed",
        "self_test_completion_newer_than_receipt_failed",
        "self_test_completion_stale_failed",
        "self_test_completion_kind_failed",
        "self_test_completion_weights_failed",
        "self_test_schema_version_failed",
        "self_test_gate_command_failed",
        "self_test_gate_completed_failed",
        "self_test_git_binding_failed",
        "self_test_git_status_hash_failed",
        "self_test_relative_repo_root_failed",
        "self_test_repo_root_mismatch_failed",
        "doesNotReplaceProductionAssertion",
        "runtimeProductionEvidence",
        "--completion-status-json",
        "--completion-status-markdown",
        "--recovery-plan-json",
        "--recovery-plan-markdown",
        "--recovery-plan-script",
        "--require-completion-status",
        "--require-recovery-plan",
        "--support-root",
        "--prefer-support-root",
        "--require-support-root",
        "self_test_support_root_preference_failed",
        "self_test_support_root_required_failed",
        "--expect-repo-root",
        "--require-current-git",
        "--require-clean-git",
        "self_test_clean_git_failed",
        "--verify",
    ],
    "IMServer/LoadTests/production_worktree_inventory.py": [
        "imserver-production-worktree-inventory",
        "production_worktree_inventory_self_test result=pass",
        "trackedModified",
        "untracked",
        "--untracked-files=all",
        "generatedLocalArtifacts",
        "forbiddenRuntimeArtifacts",
        "remove_runtime_artifact_before_static_gate",
        "remove_or_ignore_generated_artifact",
        "actionSummary",
        "categorySummary",
        "commitGroupSummary",
        "commit_group_summary group=",
        "commitGroup=",
        "--group",
        "--category",
        "--action",
        "--type",
        "--paths-only",
        "--tracked-diff-stat",
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
        "--plan",
        "render_tracked_diff_stat(",
        "plan_payload(",
        "verify_plan_payload(",
        "verify_plan_command_contract(",
        "render_verify_plan_result(",
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
        "production_worktree_stage_dry_run",
        "production_worktree_stage_dry_run_batch",
        "production_worktree_stage_dry_run_batch_verify",
        "imserver-production-worktree-stage-dry-run",
        "imserver-production-worktree-stage-dry-run-batch",
        "stage_dry_run_receipt(",
        "stage_dry_run_batch_receipt(",
        "verify_stage_dry_run_receipt(",
        "verify_stage_dry_run_batch_receipt(",
        "render_stage_dry_run_result(",
        "render_stage_dry_run_batch_result(",
        "render_verify_stage_dry_run_result(",
        "render_verify_stage_dry_run_batch_result(",
        "stage_dry_run_passed",
        "stage_dry_run_batch_passed",
        "stage_dry_run_json_current",
        "stage_dry_run_batch_json_current",
        "stage_dry_run_json_git_status_mismatch",
        "stage_dry_run_batch_json_git_status_mismatch",
        "stage_dry_run_json_stale_or_mismatched",
        "stage_dry_run_batch_json_stale_or_mismatched",
        "stage_dry_run_group_required",
        "production_worktree_stage_dry_run_verify",
        "imserver-production-worktree-plan",
        "production_worktree_plan_verify",
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
        "sourceChangesAction=no_source_changes_to_stage",
        "generatedArtifactsCommand=make production-worktree-inventory",
        "generatedArtifactsAction=remove_or_ignore_generated_artifact",
        "forbiddenArtifactsCommand=make production-worktree-inventory",
        "forbiddenArtifactsAction=remove_runtime_artifact_before_static_gate",
        "--pathspec-from-file",
        "pathspec_file_for_group(",
        "commitSubject=",
        "commitCommand=git commit -m",
        "commit_subject_for_group(",
        "test(production): add load test evidence gates",
        "verifyCommand=",
        "render_paths(",
        "filteredSummary",
        "commit_group_for_path(",
        "load-tests-and-production-evidence",
        "deploy-ops",
        "server-runtime",
        "directorySummary",
        "action_summary action=",
        "directory_summary path=",
        "directory_bucket(",
        "forbidden_runtime_artifact_kinds(",
        "self_test(",
    ],
    "IMServer/LoadTests/production_target_policy.py": [
        "production_target_policy_self_test result=pass",
        "base_url_https_required",
        "base_url_default_https_port_required",
        "base_url_origin_required",
        "base_url_format_invalid",
        "base_url_dns_required",
        "tcp_host_format_invalid",
        "tcp_host_dns_required",
        "tcp_port_required",
        "placeholder_hosts",
        "placeholder_suffixes",
        "DNS_LABEL_RE",
        "invalid_dns",
        "trailing_dot",
        "wildcard",
        "https://localhost.",
        "https://chat.example.com.",
        "https://127.0.0.1.",
        "tcp.example.net.",
        "https://chat.myim-prod.com.",
        "tcp.myim-prod.com.",
        "https://*.myim-prod.com",
        "https://user:pass@chat.myim-prod.com",
        "https://chat.myim-prod.com/api",
        "https://chat.myim-prod.com?env=prod",
        "https://chat.myim-prod.com#prod",
        "tcp.myim-prod.com:9000",
        "tcp_host.myim-prod.com",
        "https://chat.myim-prod.com ",
        "tcp.myim-prod.com ",
        "[tcp.myim-prod.com]",
        '"09000"',
        '"+9000"',
        '"9000 "',
        "missing_env",
    ],
    "IMServer/LoadTests/production_readiness_status.sh": [
        "production_readiness_status readyToAssert=true",
        "production_readiness_status readyToAssert=false",
        "production_target_policy.py",
        "--reason-only",
        "BASE_URL=https://chat.prod.company.com",
        "TCP_HOST=tcp.prod.company.com",
        "currentReadinessTarget",
        "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON",
        "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON",
        "PRODUCTION_DEPLOY_READINESS_VERIFIER",
        "PRODUCTION_STATIC_GATE_RECEIPT_JSON",
        "PRODUCTION_STATIC_GATE_VERIFIER",
        "--require-completion-status",
        "--require-recovery-plan",
        "--require-current-git",
        "--require-clean-git",
        "commit --allow-empty",
        "static-support/completion-status.json",
        "static-support/evidence-recovery-plan.json",
        "static_gate_next_command()",
        "production_static_gate_git_dirty",
        "git_binding_mismatch",
        "commit or remove local changes, then make validate-production-static",
        "commit intended source changes or ignore only generated local artifacts, then make validate-production-static",
        "PRODUCTION_TOPOLOGY_SMOKE_VERIFIER",
        "verify_deploy_readiness_receipt.py",
        "topologySmokeReceipt",
        "deployReadinessReceipt",
        "productionStaticGateReceipt",
        "make validate-production-static && make production-readiness-status",
        "deploy_readiness_policy_not_enforced",
        "sudo -E make run-production-readiness-gate && make production-readiness-status",
        "verify_production_smoke.py",
        "--require-artifacts-exist",
        "make run-imserver-production-smoke && make production-readiness-status",
        "acceptanceReceiptTarget",
        "evidencePackageTarget",
        "json_target_field_missing",
        "target_mismatch",
        "package_manifest_current_readiness_target_mismatch",
        "package_current_readiness_status_mismatch",
        "package_readme_current_readiness_status_mismatch",
        "package_current_readiness_markdown_mismatch",
        "base_url_https_required",
        "base_url_origin_required",
        "PRODUCTION_READINESS_STATUS_SELF_TEST",
        "local_target_passed",
        "path_target_passed",
        "missing_file_passed",
        "mismatched_receipt_target_passed",
        "mismatched_deploy_readiness_passed",
        "weakened_deploy_readiness_passed",
        "missing_static_gate_passed",
        "dirty_static_gate_passed",
        "auto_discovery_static_gate_missing",
        "missing_readiness_target_passed",
        "mismatched_package_target_passed",
        "ready_summary_missing",
    ],
    "IMServer/LoadTests/validate_production_acceptance_env.sh": [
        "production_acceptance_receipt_target_mismatch",
        "cloud_security_group_repair_receipt_security_group_mismatch",
        "cloud_security_group_repair_receipt_region_mismatch",
        "cloud_security_group_repair_receipt_admin_cidr_mismatch",
        "cloud_security_group_repair_receipt_stale",
        "cloud_security_group_repair_receipt_status",
        "production_evidence_package_checksum_mismatch",
        "production_evidence_package_checksum_member_missing",
        "MAX_PACKAGE_ARCHIVE_MEMBER_BYTES",
        "MAX_PACKAGE_ARCHIVE_TOTAL_BYTES",
        "MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES",
        "archive_member_sha256(",
        "production_evidence_package_member_too_large",
        "production_evidence_package_total_too_large",
        "production_evidence_package_text_member_too_large",
        "self_test_package_archive_full_read_hash_detected",
        "production_evidence_manifest_target_mismatch",
        "production_evidence_current_readiness_target_mismatch",
        "PRODUCTION_TOPOLOGY_SMOKE_VERIFIER",
        "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON",
        "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON",
        "validate_deploy_readiness_receipt(",
        "production_deploy_readiness_receipt_missing",
        "production_deploy_readiness_receipt_policy",
        "self_test_missing_deploy_readiness_receipt_passed",
        "self_test_weakened_deploy_readiness_receipt_passed",
        "production_topology_smoke_receipt_missing",
        "production_topology_smoke_receipt_invalid",
        "validate_topology_smoke_receipt(topology_smoke_receipt_path)",
        "production_target_policy.py",
        "--result-prefix",
        "production_acceptance_env",
        "validate_cloud_security_group_repair_receipt(",
        "verify_archive_checksums(archive, members)",
        "validate_evidence_package_target(package_path, expected_target)",
        '"baseURL": base_url',
        '"tcpHost": tcp_host',
        '"tcpPort": str(port)',
        "base_url_origin_required",
        "self_test_path_target_passed",
        "self_test_bad_tcp_port_passed",
        "self_test_security_group_receipt_mismatch_passed",
        "self_test_receipt_target_mismatch_passed",
        "self_test_missing_topology_smoke_receipt_passed",
        "self_test_failed_topology_smoke_receipt_passed",
        "self_test_package_checksum_mismatch_passed",
        "self_test_package_target_mismatch_passed",
    ],
    "IMServer/scripts/production_release_gate.sh": [
        "PRODUCTION_RELEASE_GATE_SELF_TEST",
        "--validate-args-only",
        "--report-json",
        "latest-production-release-gate.json",
        "production_release_gate validate_args=pass",
        "production_release_gate_self_test result=pass",
        "Production release gate receipt:",
        '"schemaVersion": 1',
        '"steps": steps',
        "Real env preflight requires --command-api, --gateway, --query-api, --outbox-relay, --ops, and at least one --stream-consumer",
        "Real env preflight requires --strict-secrets",
        "swift build -c release --package-path",
        "swift test --no-parallel --package-path",
    ],
    "IMServer/scripts/verify_production_release_gate.py": [
        "production_release_gate_verify result=pass",
        "production_release_gate_verify_self_test result=pass",
        "summary_mismatch",
        "validate_args_only_not_release_run",
        "status_not_passed",
        "receipt_stale",
        "--require-release-run",
        "--require-swift-tests",
    ],
    "IMServer/scripts/verify_production_smoke.py": [
        "production_smoke_verify result=pass",
        "production_smoke_verify_self_test result=pass",
        "REQUIRED_CHECKS",
        "runtime_services_health",
        "runtimeEvidence",
        "required_checks_missing",
        "state_artifact_contains_sensitive_marker",
        "OWNER_TOKEN",
        "INTERNAL_SECRET",
        "receipt_stale",
        "--require-artifacts-exist",
    ],
}


AUTH_SAFETY_REQUIRED = {
    "IMServer/Sources/IMServer/Auth/AuthConfiguration.swift": {
        "required": [
            "private static let developmentFallbackJWTSecret: String",
            "SymmetricKey(size: .bits256)",
            "secret: developmentFallbackJWTSecret",
            "case weakJWTSecret(String)",
            "case placeholderJWTSecret(String)",
            "private static func validateProductionJWTSecrets",
            "private static func isPlaceholderProductionJWTSecret",
        ],
        "forbidden": [
            'secret: "dev-jwt-secret-change-me"',
        ],
    },
    "IMServer/Sources/IMServer/Auth/AuthService.swift": {
        "required": [
            "private static let credentialMaskingHashResult: Result<String, any Error> = Result",
            "private static func performCredentialMaskingCheck(password: String, logger: Logger)",
            "Self.performCredentialMaskingCheck(password: request.password, logger: app.logger)",
        ],
        "forbidden": [
            "try! Bcrypt.hash",
        ],
    },
    "IMServer/Sources/IMServer/Controllers/IMConversationCommonFeatureController.swift": {
        "required": [
            "if let conversationID = query.conversationID",
            "strongReadDatabase(forConversationID: conversationID)",
        ],
        "forbidden": [
            "query.conversationID!",
        ],
    },
    "IMServer/Sources/IMServer/IM/IMGatewaySessionRuntimeSupports.swift": {
        "required": [
            "case responseTypeMismatch(String)",
            "guard let emptyResponse = EmptyGatewayRelayResponse() as? Response else",
        ],
        "forbidden": [
            "as! Response",
        ],
    },
}


def require_contains(text: str, needle: str, workflow: str, kind: str) -> list[str]:
    if needle in text:
        return []
    return [f"{workflow}:missing_{kind}:{needle}"]


def parse_make_phony_targets(text: str) -> set[str]:
    targets: set[str] = set()
    for line in text.splitlines():
        if not line.startswith(".PHONY:"):
            continue
        targets.update(part.strip() for part in line.split(":", 1)[1].split() if part.strip())
    return targets


def parse_make_defined_targets(text: str) -> set[str]:
    targets: set[str] = set()
    for line in text.splitlines():
        if line.startswith("\t") or line.startswith(" "):
            continue
        if not line or line.startswith("#") or line.startswith("."):
            continue
        match = re.match(r"^([A-Za-z0-9_.-]+)\s*:", line)
        if match:
            targets.add(match.group(1))
    return targets


def make_help_recipe_text(text: str) -> str:
    lines = text.splitlines()
    in_help = False
    recipe: list[str] = []
    for line in lines:
        if not in_help:
            if line == "help:":
                in_help = True
            continue
        if line and not line.startswith("\t") and re.match(r"^[A-Za-z0-9_.-]+\s*:", line):
            break
        recipe.append(line)
    return "\n".join(recipe)


def audit_make_targets(repo_root: Path) -> list[str]:
    path = repo_root / "Makefile"
    if not path.is_file():
        return ["Makefile:missing_makefile"]

    text = path.read_text(encoding="utf-8")
    phony = parse_make_phony_targets(text)
    defined = parse_make_defined_targets(text)
    help_text = make_help_recipe_text(text)

    errors: list[str] = []
    for target in REQUIRED_MAKE_TARGETS:
        if target not in phony:
            errors.append(f"Makefile:missing_phony_target:{target}")
        if target not in defined:
            errors.append(f"Makefile:missing_make_target:{target}")
    for target in HELP_REQUIRED_MAKE_TARGETS:
        if target not in help_text:
            errors.append(f"Makefile:missing_help_target:{target}")
    return errors


def indentation(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def workflow_trigger_paths(text: str, trigger: str) -> set[str]:
    lines = text.splitlines()
    trigger_indent: int | None = None
    trigger_start = 0
    for index, line in enumerate(lines):
        if re.match(rf"^\s*{re.escape(trigger)}:\s*$", line):
            trigger_indent = indentation(line)
            trigger_start = index + 1
            break
    if trigger_indent is None:
        return set()

    paths_indent: int | None = None
    paths_start = 0
    for index in range(trigger_start, len(lines)):
        line = lines[index]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        current_indent = indentation(line)
        if current_indent <= trigger_indent:
            return set()
        if re.match(r"^\s*paths:\s*$", line):
            paths_indent = current_indent
            paths_start = index + 1
            break
    if paths_indent is None:
        return set()

    paths: set[str] = set()
    for index in range(paths_start, len(lines)):
        line = lines[index]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        current_indent = indentation(line)
        if current_indent <= paths_indent:
            break
        match = re.match(r"^\s*-\s+(.+?)\s*$", line)
        if not match:
            continue
        value = match.group(1).strip()
        if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        paths.add(value)
    return paths


def require_path_in_pr_and_push(text: str, path_entry: str, workflow: str) -> list[str]:
    quoted = f'"{path_entry}"'
    pr_paths = workflow_trigger_paths(text, "pull_request")
    push_paths = workflow_trigger_paths(text, "push")
    if path_entry in pr_paths and path_entry in push_paths:
        return []
    if path_entry not in pr_paths and path_entry not in push_paths:
        return [f"{workflow}:missing_path:{quoted}"]
    if path_entry not in pr_paths:
        return [f"{workflow}:missing_pull_request_path:{quoted}"]
    return [f"{workflow}:missing_push_path:{quoted}"]


def audit_workflow(
    repo_root: Path,
    workflow: str,
    requirements: dict[str, list[str]],
    *,
    static_gate_required_inventory_paths: list[str],
) -> list[str]:
    path = repo_root / workflow
    if not path.is_file():
        return [f"{workflow}:missing_workflow_file"]

    text = path.read_text(encoding="utf-8")
    errors: list[str] = []
    for command in requirements["commands"]:
        errors.extend(require_contains(text, command, workflow, "command"))
    for path_entry in requirements["paths"]:
        errors.extend(require_path_in_pr_and_push(text, path_entry, workflow))
    if workflow == ".github/workflows/production-static-gate.yml":
        for path_entry in static_gate_required_inventory_paths:
            errors.extend(require_path_in_pr_and_push(text, path_entry, workflow))

    if "pull_request:" not in text:
        errors.append(f"{workflow}:missing_pull_request_trigger")
    if "push:" not in text:
        errors.append(f"{workflow}:missing_push_trigger")
    if "workflow_dispatch:" not in text:
        errors.append(f"{workflow}:missing_workflow_dispatch_trigger")

    return errors


def audit_repo(repo_root: Path) -> list[str]:
    errors: list[str] = []
    static_gate_required_inventory_paths, inventory_errors = load_validation_inventory_required_records(repo_root)
    errors.extend(inventory_errors)
    for workflow, requirements in REQUIRED.items():
        errors.extend(
            audit_workflow(
                repo_root,
                workflow,
                requirements,
                static_gate_required_inventory_paths=static_gate_required_inventory_paths,
            )
        )
    errors.extend(audit_governance_docs(repo_root))
    errors.extend(audit_make_targets(repo_root))
    errors.extend(audit_gitignore_behavior(repo_root))
    errors.extend(audit_dockerignore_behavior(repo_root))
    errors.extend(audit_dockerfile_supply_chain(repo_root))
    errors.extend(audit_auth_safety(repo_root))
    return errors


def audit_auth_safety(repo_root: Path) -> list[str]:
    errors: list[str] = []
    for relative_path, requirements in AUTH_SAFETY_REQUIRED.items():
        path = repo_root / relative_path
        if not path.is_file():
            errors.append(f"{relative_path}:missing_auth_safety_file")
            continue
        text = path.read_text(encoding="utf-8")
        for required in requirements["required"]:
            if required not in text:
                errors.append(f"{relative_path}:missing_auth_safety_text:{required}")
        for forbidden in requirements["forbidden"]:
            if forbidden in text:
                errors.append(f"{relative_path}:forbidden_auth_force_try:{forbidden}")
    return errors


def audit_governance_docs(repo_root: Path) -> list[str]:
    errors: list[str] = []
    for document, required_texts in GOVERNANCE_REQUIRED.items():
        path = repo_root / document
        if not path.is_file():
            errors.append(f"{document}:missing_governance_file")
            continue

        text = path.read_text(encoding="utf-8")
        for required_text in required_texts:
            errors.extend(require_contains(text, required_text, document, "governance_text"))

    return errors


def audit_dockerignore_behavior(repo_root: Path) -> list[str]:
    dockerignore = repo_root / "IMServer/.dockerignore"
    if not dockerignore.is_file():
        return ["IMServer/.dockerignore:missing_dockerignore_file"]
    required_lines = GOVERNANCE_REQUIRED.get("IMServer/.dockerignore", [])
    dockerignore_lines = dockerignore.read_text(encoding="utf-8").splitlines()
    lines = {line.strip() for line in dockerignore_lines if line.strip()}
    errors: list[str] = []
    for required_line in required_lines:
        if required_line not in lines:
            errors.append(f"IMServer/.dockerignore:missing_dockerignore_rule:{required_line}")
    ignored_probes = [
        ".env",
        "config/env/runtime.env",
        "secret.pem",
        "nested/private.key",
        "ios-distribution.p12",
        "tls-bundle.pfx",
        "Profiles/AppStore.mobileprovision",
        "id_ed25519",
        "reports/latest-production-release-gate.json",
        "LoadTests/accounts/load-10000.csv",
        "LoadTests/login-cache/tcp-login-cache-lg1-1000.json",
        "LoadTests/custom/tcp-login-cache-lg1-1000.json",
        "LoadTests/login_cache/cache.json",
        "LoadTests/custom/tcp_login_cache-lg1-1000.json",
        "LoadTests/token-cache/cache.json",
        "LoadTests/token-cache/access-token-cache-lg1-1000.json",
        "LoadTests/token_cache/cache.json",
        "LoadTests/custom/access_token_cache-lg1-1000.json",
        "LoadTests/results/production-static/latest.json",
    ]
    for probe_path in ignored_probes:
        ignored, detail = dockerignore_path_ignored(dockerignore_lines, probe_path)
        if not ignored:
            errors.append(f"IMServer/.dockerignore:not_ignored:{probe_path}:{detail or '-'}")
    allowed_probes = [
        "config/env/gateway.production.env.example",
        "config/env/inventory.example.env",
        "LoadTests/prewarm_login_cache_parallel.py",
    ]
    for probe_path in allowed_probes:
        ignored, detail = dockerignore_path_ignored(dockerignore_lines, probe_path)
        if ignored:
            errors.append(f"IMServer/.dockerignore:required_source_ignored:{probe_path}:{detail or '-'}")
    return errors


def dockerignore_path_ignored(lines: list[str], path: str) -> tuple[bool, str]:
    ignored = False
    matched_rule = ""
    normalized_path = path.strip("/")
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        negated = line.startswith("!")
        pattern = line[1:] if negated else line
        if dockerignore_pattern_matches(pattern, normalized_path):
            ignored = not negated
            matched_rule = line
    return ignored, matched_rule


def dockerignore_pattern_matches(pattern: str, path: str) -> bool:
    normalized_pattern = pattern.strip()
    if not normalized_pattern:
        return False
    normalized_pattern = normalized_pattern.lstrip("/")
    if normalized_pattern.endswith("/"):
        directory = normalized_pattern.rstrip("/")
        return path == directory or path.startswith(f"{directory}/")
    if "/" not in normalized_pattern:
        return fnmatch.fnmatchcase(Path(path).name, normalized_pattern) or fnmatch.fnmatchcase(path, normalized_pattern)
    return fnmatch.fnmatchcase(path, normalized_pattern)


def audit_dockerfile_supply_chain(repo_root: Path) -> list[str]:
    dockerfile = repo_root / "IMServer/Dockerfile"
    if not dockerfile.is_file():
        return ["IMServer/Dockerfile:missing_dockerfile"]
    text = dockerfile.read_text(encoding="utf-8")
    errors: list[str] = []
    forbidden_snippets = [
        "gh-proxy.com",
        'url."https://',
    ]
    for snippet in forbidden_snippets:
        if snippet in text:
            errors.append(f"IMServer/Dockerfile:forbidden_supply_chain_proxy:{snippet}")
    required_snippets = GOVERNANCE_REQUIRED.get("IMServer/Dockerfile", [])
    for snippet in required_snippets:
        if snippet not in text:
            errors.append(f"IMServer/Dockerfile:missing_supply_chain_control:{snippet}")
    if text.count("rm -rf /var/lib/apt/lists/*") < 2:
        errors.append("IMServer/Dockerfile:insufficient_apt_lists_cleanup_count")
    return errors


def inside_git_worktree(repo_root: Path) -> bool:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=repo_root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return False
    return result.returncode == 0 and result.stdout.strip() == "true"


def git_check_ignore(repo_root: Path, path: str, *, no_index: bool = False) -> tuple[bool, str]:
    command = ["git", "check-ignore", "-v"]
    if no_index:
        command.append("--no-index")
    command.append(path)
    try:
        result = subprocess.run(
            command,
            cwd=repo_root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as exc:
        return False, f"git_check_ignore_unavailable:{exc}"
    output = (result.stdout or result.stderr or "").strip()
    return result.returncode == 0, output


def git_ls_files(repo_root: Path) -> list[str]:
    try:
        result = subprocess.run(
            ["git", "ls-files"],
            cwd=repo_root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError:
        return []
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def is_allowed_env_template(path: str) -> bool:
    return path.endswith(".env.example") or path.endswith(".example.env")


def is_env_like_path(path: str) -> bool:
    name = Path(path).name
    return name == ".env" or name.startswith(".env.") or name.endswith(".env") or ".env." in name


def sensitive_local_secret_kind(path: str) -> str | None:
    name = Path(path).name
    suffix = Path(path).suffix.lower()
    if suffix in {".pem", ".key", ".p12", ".pfx", ".mobileprovision"}:
        return "tracked_local_secret_file"
    if any(name.startswith(prefix) for prefix in ("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")):
        return "tracked_local_secret_file"
    return None


def tracked_generated_artifact_kind(path: str) -> str | None:
    generated_roots = {
        "IMServer/LoadTests/accounts/": "tracked_account_file",
        "IMServer/LoadTests/login-cache/": "tracked_login_cache_file",
        "IMServer/LoadTests/login_cache/": "tracked_login_cache_file",
        "IMServer/LoadTests/token-cache/": "tracked_login_cache_file",
        "IMServer/LoadTests/token_cache/": "tracked_login_cache_file",
        "IMServer/LoadTests/results/": "tracked_load_test_result",
        "IMServer/reports/": "tracked_imserver_report",
    }
    for root, kind in generated_roots.items():
        if path.startswith(root):
            return kind
    if not path.startswith("IMServer/LoadTests/"):
        return None
    normalized_parts = {part.lower() for part in Path(path).parts}
    if normalized_parts.intersection({"login-cache", "login_cache", "token-cache", "token_cache"}):
        return "tracked_login_cache_file"
    name = Path(path).name.lower()
    generated_cache_prefixes = (
        "tcp-login-cache",
        "tcp_login_cache",
        "access-token-cache",
        "access_token_cache",
    )
    if name.startswith(generated_cache_prefixes) or "token-cache" in name or "token_cache" in name:
        return "tracked_login_cache_file"
    return None


def gitignore_detail_is_negation(detail: str) -> bool:
    if "\t" not in detail:
        return False
    metadata = detail.split("\t", 1)[0]
    parts = metadata.split(":", 2)
    if len(parts) != 3:
        return False
    return parts[2].startswith("!")


def audit_gitignore_behavior(repo_root: Path) -> list[str]:
    if not inside_git_worktree(repo_root):
        return []

    errors: list[str] = []
    for path in git_ls_files(repo_root):
        if is_env_like_path(path) and not is_allowed_env_template(path):
            errors.append(f".gitignore:tracked_env_file:{path}")
        secret_kind = sensitive_local_secret_kind(path)
        if secret_kind is not None:
            errors.append(f".gitignore:{secret_kind}:{path}")
        artifact_kind = tracked_generated_artifact_kind(path)
        if artifact_kind is not None:
            errors.append(f".gitignore:{artifact_kind}:{path}")

    ignored_paths = [
        "IMServer/LoadTests/production-acceptance.env",
        "IMServer/LoadTests/staging-baseline.env",
        "IMServer/LoadTests/accounts/load-10000.csv",
        "IMServer/LoadTests/login-cache/tcp-login-cache-lg1-1000.json",
        "IMServer/LoadTests/custom/tcp-login-cache-lg1-1000.json",
        "IMServer/LoadTests/login_cache/cache.json",
        "IMServer/LoadTests/custom/tcp_login_cache-lg1-1000.json",
        "IMServer/LoadTests/token-cache/cache.json",
        "IMServer/LoadTests/token-cache/access-token-cache-lg1-1000.json",
        "IMServer/LoadTests/token_cache/cache.json",
        "IMServer/LoadTests/custom/access_token_cache-lg1-1000.json",
        "IMServer/LoadTests/results/production-acceptance/receipt.json",
        "IMServer/reports/latest-production-release-gate.json",
        "test01.pem",
        "deploy/ubuntu/private.key",
        "ios-distribution.p12",
        "tls-bundle.pfx",
        "IMApp/Profiles/AppStore.mobileprovision",
        "id_rsa",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
    ]
    for path in ignored_paths:
        ignored, detail = git_check_ignore(repo_root, path)
        if not ignored:
            errors.append(f".gitignore:not_ignored:{path}:{detail or '-'}")

    template_paths = [
        "IMServer/LoadTests/production-acceptance.env.example",
        "IMServer/LoadTests/staging-baseline.env.example",
        "deploy/multinode/inventory.example.env",
    ]
    for path in template_paths:
        matched, detail = git_check_ignore(repo_root, path, no_index=True)
        if matched and not gitignore_detail_is_negation(detail):
            errors.append(f".gitignore:template_ignored:{path}:{detail or '-'}")

    return errors


def copy_required_files(source_root: Path, target_root: Path) -> None:
    for workflow in REQUIRED:
        source = source_root / workflow
        target = target_root / workflow
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    for document in GOVERNANCE_REQUIRED:
        source = source_root / document
        target = target_root / document
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    for relative_path in AUTH_SAFETY_REQUIRED:
        source = source_root / relative_path
        target = target_root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    inventory_source = source_root / "IMServer/LoadTests/perf_validation_inventory.py"
    inventory_target = target_root / "IMServer/LoadTests/perf_validation_inventory.py"
    inventory_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(inventory_source, inventory_target)


def initialize_git_repo(path: Path) -> bool:
    try:
        result = subprocess.run(
            ["git", "init", "-q"],
            cwd=path,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError:
        return False
    return result.returncode == 0


def git_force_add(path: Path, relative_path: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "add", "-f", relative_path],
            cwd=path,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError:
        return False
    return result.returncode == 0


def run_self_test(repo_root: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="production-workflow-audit-") as tmp:
        test_root = Path(tmp)
        copy_required_files(repo_root, test_root)

        if not initialize_git_repo(test_root):
            print(
                "production-workflow-audit-self-test result=fail phase=setup reason=git_init_failed",
                file=sys.stderr,
            )
            return 1

        errors = audit_repo(test_root)
        if errors:
            for error in errors:
                print(f"production-workflow-audit-self-test result=fail phase=positive reason={error}", file=sys.stderr)
            return 1

        inventory = test_root / "IMServer/LoadTests/perf_validation_inventory.py"
        inventory.unlink()
        errors = audit_repo(test_root)
        if not any(
            "IMServer/LoadTests/perf_validation_inventory.py:missing_required_inventory_source" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_required_inventory_source_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        inventory = test_root / "IMServer/LoadTests/perf_validation_inventory.py"
        inventory.write_text("REQUIRED_INVENTORY_RECORDS = {}\n", encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/LoadTests/perf_validation_inventory.py:required_inventory_records_empty" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=empty_required_inventory_records_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        inventory = test_root / "IMServer/LoadTests/perf_validation_inventory.py"
        inventory.write_text("raise RuntimeError('inventory import broke')\n", encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/LoadTests/perf_validation_inventory.py:required_inventory_import_failed:" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=broken_required_inventory_import_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        inventory = test_root / "IMServer/LoadTests/perf_validation_inventory.py"
        inventory.write_text("REQUIRED_INVENTORY_RECORDS = {'shell': 'not-a-record-set'}\n", encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/LoadTests/perf_validation_inventory.py:required_inventory_group_invalid:shell" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=invalid_required_inventory_group_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            "run: make validate-production-static",
            "run: make test-all",
            1,
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("missing_command:run: make validate-production-static" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_static_gate_command_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        release_workflow = test_root / ".github/workflows/imserver-production-release-gate.yml"
        broken = release_workflow.read_text(encoding="utf-8").replace(
            "./scripts/production_release_gate.sh",
            "./scripts/test.sh",
        )
        release_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            ".github/workflows/imserver-production-release-gate.yml:missing_command:./scripts/production_release_gate.sh"
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_imserver_release_gate_command_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        smoke_workflow = test_root / ".github/workflows/imserver-production-smoke.yml"
        broken = smoke_workflow.read_text(encoding="utf-8").replace(
            "make run-imserver-production-smoke",
            "make check-imserver-production-smoke",
            1,
        )
        smoke_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            ".github/workflows/imserver-production-smoke.yml:missing_governance_text:"
            "make run-imserver-production-smoke" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_imserver_production_smoke_make_run_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        imapp_workflow = test_root / ".github/workflows/imapp-production-config-gate.yml"
        broken = imapp_workflow.read_text(encoding="utf-8").replace(
            "run: make validate-ios-production-config",
            "run: make validate-ios-network-config",
            1,
        )
        imapp_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            ".github/workflows/imapp-production-config-gate.yml:missing_command:run: make validate-ios-production-config"
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_imapp_production_config_command_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        imapp_workflow = test_root / ".github/workflows/imapp-production-config-gate.yml"
        broken = imapp_workflow.read_text(encoding="utf-8").replace(
            "run: make validate-ios-debug-network-defaults",
            "run: make validate-ios-network-config",
            1,
        )
        imapp_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            ".github/workflows/imapp-production-config-gate.yml:missing_command:run: make validate-ios-debug-network-defaults"
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_imapp_debug_network_defaults_command_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        pr_template = test_root / ".github/pull_request_template.md"
        broken = pr_template.read_text(encoding="utf-8").replace(
            "- [ ] iOS Debug network defaults, when touching IMApp network config or Xcode settings:\n"
            "  `make validate-ios-debug-network-defaults`\n",
            "",
            1,
        )
        pr_template.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            ".github/pull_request_template.md:missing_governance_text:make validate-ios-debug-network-defaults"
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_pr_ios_debug_network_defaults_check_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "app/src/main/java/com/xmtx/imappandroid/di/**"\n',
            "",
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_path:"app/src/main/java/com/xmtx/imappandroid/di/**"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_android_network_config_workflow_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "IMServer/scripts/production_smoke.sh"\n',
            "",
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_path:"IMServer/scripts/production_smoke.sh"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_script_workflow_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        smoke_compose = test_root / "IMServer/docker-compose.production-smoke.yml"
        broken = smoke_compose.read_text(encoding="utf-8").replace(
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE: timeline-pull",
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE: owner-records",
            1,
        )
        smoke_compose.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/docker-compose.production-smoke.yml:missing_governance_text:"
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE: timeline-pull" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_timeline_pull_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        smoke_compose = test_root / "IMServer/docker-compose.production-smoke.yml"
        broken = smoke_compose.read_text(encoding="utf-8").replace(
            "x-imserver-worker-healthcheck: &imserver_worker_healthcheck",
            "x-imserver-worker-healthcheck-disabled: &imserver_worker_healthcheck_disabled",
            1,
        )
        smoke_compose.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/docker-compose.production-smoke.yml:missing_governance_text:"
            "x-imserver-worker-healthcheck: &imserver_worker_healthcheck" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_worker_healthcheck_anchor_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        smoke_script = test_root / "IMServer/scripts/production_smoke.sh"
        broken = smoke_script.read_text(encoding="utf-8").replace(
            "runtime_services_not_started:",
            "runtime_services_check_removed:",
            1,
        )
        smoke_script.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/scripts/production_smoke.sh:missing_governance_text:runtime_services_not_started:" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_runtime_services_check_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        smoke_script = test_root / "IMServer/scripts/production_smoke.sh"
        broken = smoke_script.read_text(encoding="utf-8").replace(
            "runtime_services_not_health_waited:",
            "runtime_services_health_wait_check_removed:",
            1,
        )
        smoke_script.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/scripts/production_smoke.sh:missing_governance_text:runtime_services_not_health_waited:" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_runtime_health_wait_check_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        smoke_script = test_root / "IMServer/scripts/production_smoke.sh"
        broken = smoke_script.read_text(encoding="utf-8").replace(
            'if curl -fsS "${url}/health" >/dev/null 2>&1; then',
            'if curl -fsS "${url}/hello" >/dev/null 2>&1; then',
            1,
        )
        smoke_script.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            'IMServer/scripts/production_smoke.sh:missing_governance_text:if curl -fsS "${url}/health" >/dev/null 2>&1; then'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_health_readiness_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        smoke_script = test_root / "IMServer/scripts/production_smoke.sh"
        broken = smoke_script.read_text(encoding="utf-8").replace(
            "outbox_inspect_must_use_smoke_env:",
            "outbox_inspect_env_check_removed:",
            1,
        )
        smoke_script.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/scripts/production_smoke.sh:missing_governance_text:"
            "outbox_inspect_must_use_smoke_env:" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_outbox_inspect_env_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        smoke_script = test_root / "IMServer/scripts/production_smoke.sh"
        broken = smoke_script.read_text(encoding="utf-8").replace(
            "worker_service_missing_worker_healthcheck:",
            "worker_healthcheck_check_removed:",
            1,
        )
        smoke_script.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/scripts/production_smoke.sh:missing_governance_text:"
            "worker_service_missing_worker_healthcheck:" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_worker_healthcheck_check_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        debug_defaults_script = test_root / "IMApp/Scripts/validate_debug_network_defaults.sh"
        broken = debug_defaults_script.read_text(encoding="utf-8").replace(
            "debug_api_must_be_local_http",
            "debug_api_policy_removed",
        )
        debug_defaults_script.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMApp/Scripts/validate_debug_network_defaults.sh:missing_governance_text:debug_api_must_be_local_http"
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_imapp_debug_network_defaults_policy_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "IMServer/LoadTests/verify_local_acceptance.py"\n',
            "",
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_path:"IMServer/LoadTests/verify_local_acceptance.py"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_local_acceptance_workflow_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "IMServer/LoadTests/run_current_production_readiness.sh"\n',
            "",
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_path:"IMServer/LoadTests/run_current_production_readiness.sh"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_current_production_readiness_workflow_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "IMServer/LoadTests/assert_production_ready.sh"\n',
            "",
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_path:"IMServer/LoadTests/assert_production_ready.sh"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_assert_production_ready_workflow_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "IMServer/LoadTests/production_readiness_status.sh"\n',
            "",
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_path:"IMServer/LoadTests/production_readiness_status.sh"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_readiness_status_workflow_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "IMServer/LoadTests/production_target_policy.py"\n',
            "",
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_path:"IMServer/LoadTests/production_target_policy.py"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_target_policy_workflow_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "IMServer/LoadTests/perf_scenario_status.py"\n',
            "",
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_path:"IMServer/LoadTests/perf_scenario_status.py"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_inventory_required_workflow_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        broken = static_workflow.read_text(encoding="utf-8").replace(
            '      - "IMServer/LoadTests/run_production_acceptance.sh"\n',
            "",
            1,
        )
        static_workflow.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_pull_request_path:"IMServer/LoadTests/run_production_acceptance.sh"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=single_trigger_production_acceptance_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        static_workflow = test_root / ".github/workflows/production-static-gate.yml"
        static_text = static_workflow.read_text(encoding="utf-8")
        marker = '      - "IMServer/LoadTests/run_production_acceptance.sh"\n'
        prefix, separator, suffix = static_text.rpartition(marker)
        if not separator:
            print(
                "production-workflow-audit-self-test result=fail phase=setup "
                "reason=push_path_marker_missing",
                file=sys.stderr,
            )
            return 1
        static_workflow.write_text(prefix + suffix, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            '.github/workflows/production-static-gate.yml:missing_push_path:"IMServer/LoadTests/run_production_acceptance.sh"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=single_push_trigger_production_acceptance_path_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        auth_configuration = test_root / "IMServer/Sources/IMServer/Auth/AuthConfiguration.swift"
        broken_auth_configuration = auth_configuration.read_text(encoding="utf-8").replace(
            "secret: developmentFallbackJWTSecret",
            'secret: "dev-jwt-secret-change-me"',
            1,
        )
        auth_configuration.write_text(broken_auth_configuration, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            'IMServer/Sources/IMServer/Auth/AuthConfiguration.swift:forbidden_auth_force_try:secret: "dev-jwt-secret-change-me"'
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=fixed_development_jwt_secret_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        auth_service = test_root / "IMServer/Sources/IMServer/Auth/AuthService.swift"
        broken_auth_service = auth_service.read_text(encoding="utf-8").replace(
            "private static let credentialMaskingHashResult: Result<String, any Error> = Result",
            "private static let credentialMaskingHash = try! Bcrypt.hash",
            1,
        )
        auth_service.write_text(broken_auth_service, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/Sources/IMServer/Auth/AuthService.swift:forbidden_auth_force_try:try! Bcrypt.hash" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=auth_force_try_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        common_feature_controller = test_root / "IMServer/Sources/IMServer/Controllers/IMConversationCommonFeatureController.swift"
        broken_common_feature_controller = common_feature_controller.read_text(encoding="utf-8").replace(
            "if let conversationID = query.conversationID",
            "if query.conversationID != nil",
            1,
        ).replace(
            "strongReadDatabase(forConversationID: conversationID)",
            "strongReadDatabase(forConversationID: query.conversationID!)",
            1,
        )
        common_feature_controller.write_text(broken_common_feature_controller, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/Sources/IMServer/Controllers/IMConversationCommonFeatureController.swift:forbidden_auth_force_try:query.conversationID!" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=conversation_query_force_unwrap_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        gateway_support = test_root / "IMServer/Sources/IMServer/IM/IMGatewaySessionRuntimeSupports.swift"
        broken_gateway_support = gateway_support.read_text(encoding="utf-8").replace(
            "guard let emptyResponse = EmptyGatewayRelayResponse() as? Response else",
            "return EmptyGatewayRelayResponse() as! Response\n            //",
            1,
        )
        gateway_support.write_text(broken_gateway_support, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(
            "IMServer/Sources/IMServer/IM/IMGatewaySessionRuntimeSupports.swift:forbidden_auth_force_try:as! Response" in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=gateway_response_force_cast_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        readme = test_root / "README.md"
        broken_readme = readme.read_text(encoding="utf-8").replace(
            "do not replace real production evidence",
            "are enough for production claims",
            1,
        )
        readme.write_text(broken_readme, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("README.md:missing_governance_text:do not replace real production evidence" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_governance_evidence_warning_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        makefile = test_root / "Makefile"
        broken_makefile = makefile.read_text(encoding="utf-8").replace(
            "verify-local-acceptance:",
            "verify-local-acceptance-disabled:",
            1,
        )
        makefile.write_text(broken_makefile, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("Makefile:missing_governance_text:verify-local-acceptance:" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_local_acceptance_verifier_target_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        makefile = test_root / "Makefile"
        broken_makefile = makefile.read_text(encoding="utf-8").replace(
            "  make run-restore-drill | install-restore-drill-timer | sync-offsite-backup",
            "  make install-restore-drill-timer | sync-offsite-backup",
            1,
        )
        makefile.write_text(broken_makefile, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("Makefile:missing_help_target:run-restore-drill" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_make_help_target_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        makefile = test_root / "Makefile"
        broken_makefile = makefile.read_text(encoding="utf-8").replace(
            " check-production-ops ",
            " ",
            1,
        )
        makefile.write_text(broken_makefile, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("Makefile:missing_phony_target:check-production-ops" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_make_phony_target_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        makefile = test_root / "Makefile"
        broken_makefile = makefile.read_text(encoding="utf-8").replace(
            "check-imserver-production-smoke:",
            "check-imserver-production-smoke-disabled:",
            1,
        )
        makefile.write_text(broken_makefile, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("Makefile:missing_make_target:check-imserver-production-smoke" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_make_target_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        makefile = test_root / "Makefile"
        broken_makefile = makefile.read_text(encoding="utf-8").replace(
            "run-imserver-production-smoke:",
            "run-imserver-production-smoke-disabled:",
            1,
        )
        makefile.write_text(broken_makefile, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("Makefile:missing_make_target:run-imserver-production-smoke" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_runtime_make_target_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        makefile = test_root / "Makefile"
        broken_makefile = makefile.read_text(encoding="utf-8").replace(
            "verify-imserver-production-smoke:",
            "verify-imserver-production-smoke-disabled:",
            1,
        )
        makefile.write_text(broken_makefile, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("Makefile:missing_make_target:verify-imserver-production-smoke" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_verify_make_target_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        makefile = test_root / "Makefile"
        broken_makefile = makefile.read_text(encoding="utf-8").replace(
            "install-production-smoke-receipt:",
            "install-production-smoke-receipt-disabled:",
            1,
        )
        makefile.write_text(broken_makefile, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("Makefile:missing_make_target:install-production-smoke-receipt" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_production_smoke_install_make_target_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        makefile = test_root / "Makefile"
        broken_makefile = makefile.read_text(encoding="utf-8").replace(
            "run-current-production-readiness:",
            "run-current-production-readiness-disabled:",
            1,
        )
        makefile.write_text(broken_makefile, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("Makefile:missing_governance_text:run-current-production-readiness:" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_current_production_readiness_target_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        if not initialize_git_repo(test_root):
            print(
                "production-workflow-audit-self-test result=fail phase=setup reason=git_reinit_failed",
                file=sys.stderr,
            )
            return 1
        gitignore = test_root / ".gitignore"
        broken_gitignore = gitignore.read_text(encoding="utf-8").replace(
            "*.env",
            "# *.env",
            1,
        )
        gitignore.write_text(broken_gitignore, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(".gitignore:not_ignored:IMServer/LoadTests/production-acceptance.env" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_gitignore_env_behavior_not_detected",
                file=sys.stderr,
            )
            return 1

        generated_ignore_cases = [
            (
                "IMServer/LoadTests/accounts/",
                "IMServer/LoadTests/accounts/load-10000.csv",
                "accounts_ignore",
            ),
            (
                "IMServer/LoadTests/**/*login-cache*",
                "IMServer/LoadTests/custom/tcp-login-cache-lg1-1000.json",
                "login_cache_file_ignore",
            ),
            (
                "IMServer/LoadTests/**/login_cache/*",
                "IMServer/LoadTests/login_cache/cache.json",
                "login_cache_dir_ignore",
            ),
            (
                "IMServer/LoadTests/**/*tcp_login_cache*",
                "IMServer/LoadTests/custom/tcp_login_cache-lg1-1000.json",
                "tcp_login_cache_file_ignore",
            ),
            (
                "IMServer/LoadTests/**/*token-cache*",
                "IMServer/LoadTests/token-cache/access-token-cache-lg1-1000.json",
                "token_cache_hyphen_file_ignore",
            ),
            (
                "IMServer/LoadTests/**/*token_cache*",
                "IMServer/LoadTests/custom/access_token_cache-lg1-1000.json",
                "token_cache_underscore_file_ignore",
            ),
            (
                "IMServer/LoadTests/results/",
                "IMServer/LoadTests/results/production-acceptance/receipt.json",
                "load_test_results_ignore",
            ),
            (
                "IMServer/reports/",
                "IMServer/reports/latest-production-release-gate.json",
                "imserver_reports_ignore",
            ),
        ]
        secret_ignore_cases = [
            ("*.pem", "test01.pem", "pem_ignore"),
            ("*.key", "deploy/ubuntu/private.key", "key_ignore"),
            ("*.p12", "ios-distribution.p12", "p12_ignore"),
            ("*.pfx", "tls-bundle.pfx", "pfx_ignore"),
            ("*.mobileprovision", "IMApp/Profiles/AppStore.mobileprovision", "mobileprovision_ignore"),
            ("id_rsa*", "id_rsa", "id_rsa_ignore"),
            ("id_dsa*", "id_dsa", "id_dsa_ignore"),
            ("id_ecdsa*", "id_ecdsa", "id_ecdsa_ignore"),
            ("id_ed25519*", "id_ed25519", "id_ed25519_ignore"),
        ]
        for ignore_pattern, probe_path, reason in generated_ignore_cases + secret_ignore_cases:
            copy_required_files(repo_root, test_root)
            if not initialize_git_repo(test_root):
                print(
                    f"production-workflow-audit-self-test result=fail phase=setup reason={reason}_reinit_failed",
                    file=sys.stderr,
                )
                return 1
            gitignore = test_root / ".gitignore"
            broken_gitignore = gitignore.read_text(encoding="utf-8").replace(
                ignore_pattern,
                f"# {ignore_pattern}",
                1,
            )
            gitignore.write_text(broken_gitignore, encoding="utf-8")
            errors = audit_repo(test_root)
            if not any(f".gitignore:not_ignored:{probe_path}" in error for error in errors):
                print(
                    "production-workflow-audit-self-test result=fail phase=negative "
                    f"reason=missing_gitignore_{reason}_not_detected",
                    file=sys.stderr,
                )
                return 1

        copy_required_files(repo_root, test_root)
        if not initialize_git_repo(test_root):
            print(
                "production-workflow-audit-self-test result=fail phase=setup reason=git_template_reinit_failed",
                file=sys.stderr,
            )
            return 1
        gitignore = test_root / ".gitignore"
        broken_template_gitignore = gitignore.read_text(encoding="utf-8").replace(
            "!*.example.env",
            "# !*.example.env",
            1,
        )
        gitignore.write_text(broken_template_gitignore, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any(".gitignore:template_ignored:deploy/multinode/inventory.example.env" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_gitignore_template_behavior_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        if not initialize_git_repo(test_root):
            print(
                "production-workflow-audit-self-test result=fail phase=setup reason=git_tracked_env_reinit_failed",
                file=sys.stderr,
            )
            return 1
        tracked_env = test_root / "IMServer/LoadTests/production-acceptance.env"
        tracked_env.parent.mkdir(parents=True, exist_ok=True)
        tracked_env.write_text("IM_INTERNAL_SECRET=do-not-commit\n", encoding="utf-8")
        if not git_force_add(test_root, "IMServer/LoadTests/production-acceptance.env"):
            print(
                "production-workflow-audit-self-test result=fail phase=setup reason=git_force_add_tracked_env_failed",
                file=sys.stderr,
            )
            return 1
        errors = audit_repo(test_root)
        if not any(".gitignore:tracked_env_file:IMServer/LoadTests/production-acceptance.env" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_tracked_env_file_not_detected",
                file=sys.stderr,
            )
            return 1

        dockerignore_cases = [
            ("*.pem", "pem"),
            ("**/*.key", "nested_key"),
            ("LoadTests/accounts/", "accounts"),
            ("LoadTests/**/*login-cache*", "login_cache"),
            ("LoadTests/login_cache/*", "login_cache_direct"),
            ("LoadTests/**/login_cache/*", "login_cache_dir"),
            ("LoadTests/**/*tcp_login_cache*", "tcp_login_cache"),
            ("LoadTests/token-cache/*", "token_cache_hyphen_direct"),
            ("LoadTests/**/token-cache/*", "token_cache_hyphen_dir"),
            ("LoadTests/**/*token-cache*", "token_cache_hyphen"),
            ("LoadTests/token_cache/*", "token_cache_underscore_direct"),
            ("LoadTests/**/token_cache/*", "token_cache_underscore_dir"),
            ("LoadTests/**/*token_cache*", "token_cache_underscore"),
            ("LoadTests/results/", "results"),
            ("reports/", "reports"),
        ]
        for dockerignore_pattern, reason in dockerignore_cases:
            copy_required_files(repo_root, test_root)
            dockerignore = test_root / "IMServer/.dockerignore"
            broken_dockerignore = dockerignore.read_text(encoding="utf-8").replace(
                dockerignore_pattern,
                f"# {dockerignore_pattern}",
                1,
            )
            dockerignore.write_text(broken_dockerignore, encoding="utf-8")
            errors = audit_repo(test_root)
            expected_error = f"IMServer/.dockerignore:missing_dockerignore_rule:{dockerignore_pattern}"
            if not any(expected_error in error for error in errors):
                print(
                    "production-workflow-audit-self-test result=fail phase=negative "
                    f"reason=missing_dockerignore_{reason}_rule_not_detected",
                    file=sys.stderr,
                )
                return 1

        copy_required_files(repo_root, test_root)
        dockerignore = test_root / "IMServer/.dockerignore"
        dockerignore.write_text(
            dockerignore.read_text(encoding="utf-8")
            + "\n!LoadTests/**/*login-cache*\n!LoadTests/**/*token-cache*\n!LoadTests/**/*token_cache*\n",
            encoding="utf-8",
        )
        errors = audit_repo(test_root)
        if not any(
            "IMServer/.dockerignore:not_ignored:LoadTests/login-cache/tcp-login-cache-lg1-1000.json"
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_dockerignore_login_cache_reinclude_not_detected",
                file=sys.stderr,
            )
            return 1
        if not any(
            "IMServer/.dockerignore:not_ignored:LoadTests/token-cache/access-token-cache-lg1-1000.json"
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_dockerignore_token_cache_reinclude_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        dockerignore = test_root / "IMServer/.dockerignore"
        dockerignore.write_text(
            dockerignore.read_text(encoding="utf-8") + "\n!*.env.example\n",
            encoding="utf-8",
        )
        errors = audit_repo(test_root)
        if any(
            "IMServer/.dockerignore:required_source_ignored:config/env/gateway.production.env.example"
            in error
            for error in errors
        ):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=dockerignore_env_example_reinclude_rejected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        dockerfile = test_root / "IMServer/Dockerfile"
        hardcoded_proxy = dockerfile.read_text(encoding="utf-8").replace(
            'url."${GIT_HTTPS_PROXY_PREFIX}".insteadOf "https://github.com/";',
            'url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/";',
            1,
        )
        dockerfile.write_text(hardcoded_proxy, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("IMServer/Dockerfile:forbidden_supply_chain_proxy:gh-proxy.com" in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=hardcoded_dockerfile_proxy_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        dockerfile = test_root / "IMServer/Dockerfile"
        missing_arg = dockerfile.read_text(encoding="utf-8").replace(
            'ARG GIT_HTTPS_PROXY_PREFIX=""',
            '# ARG GIT_HTTPS_PROXY_PREFIX removed',
            1,
        )
        dockerfile.write_text(missing_arg, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any('IMServer/Dockerfile:missing_supply_chain_control:ARG GIT_HTTPS_PROXY_PREFIX=""' in error for error in errors):
            print(
                "production-workflow-audit-self-test result=fail phase=negative "
                "reason=missing_dockerfile_proxy_arg_not_detected",
                file=sys.stderr,
            )
            return 1

        dockerfile_hygiene_cases = [
            (
                "apt-get install -y --no-install-recommends",
                "apt-get install -y",
                "apt-get install -y --no-install-recommends",
                "missing_build_no_install_recommends_not_detected",
            ),
            (
                "apt-get -q install -y --no-install-recommends",
                "apt-get -q install -y",
                "apt-get -q install -y --no-install-recommends",
                "missing_runtime_no_install_recommends_not_detected",
            ),
            (
                "curl \\",
                "# curl removed \\",
                "curl \\",
                "missing_runtime_curl_not_detected",
            ),
            (
                "rm -rf /var/lib/apt/lists/*",
                "rm -r /var/lib/apt/lists/*",
                "insufficient_apt_lists_cleanup_count",
                "missing_apt_lists_cleanup_not_detected",
            ),
            (
                "HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD curl -fsS",
                "# HEALTHCHECK removed",
                "HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD curl -fsS",
                "missing_healthcheck_not_detected",
            ),
        ]
        for good_snippet, bad_snippet, expected_missing, reason in dockerfile_hygiene_cases:
            copy_required_files(repo_root, test_root)
            dockerfile = test_root / "IMServer/Dockerfile"
            broken_dockerfile = dockerfile.read_text(encoding="utf-8").replace(
                good_snippet,
                bad_snippet,
                1,
            )
            dockerfile.write_text(broken_dockerfile, encoding="utf-8")
            errors = audit_repo(test_root)
            if expected_missing == "insufficient_apt_lists_cleanup_count":
                expected_error = "IMServer/Dockerfile:insufficient_apt_lists_cleanup_count"
            else:
                expected_error = f"IMServer/Dockerfile:missing_supply_chain_control:{expected_missing}"
            if not any(expected_error in error for error in errors):
                print(
                    "production-workflow-audit-self-test result=fail phase=negative "
                    f"reason={reason}",
                    file=sys.stderr,
                )
                return 1

        tracked_secret_cases = [
            (
                "test01.pem",
                "-----BEGIN PRIVATE KEY-----\ndo-not-commit\n-----END PRIVATE KEY-----\n",
                ".gitignore:tracked_local_secret_file:test01.pem",
                "tracked_pem_file",
            ),
            (
                "deploy/ubuntu/private.key",
                "-----BEGIN PRIVATE KEY-----\ndo-not-commit\n-----END PRIVATE KEY-----\n",
                ".gitignore:tracked_local_secret_file:deploy/ubuntu/private.key",
                "tracked_key_file",
            ),
            (
                "ios-distribution.p12",
                "do-not-commit\n",
                ".gitignore:tracked_local_secret_file:ios-distribution.p12",
                "tracked_p12_file",
            ),
            (
                "tls-bundle.pfx",
                "do-not-commit\n",
                ".gitignore:tracked_local_secret_file:tls-bundle.pfx",
                "tracked_pfx_file",
            ),
            (
                "IMApp/Profiles/AppStore.mobileprovision",
                "do-not-commit\n",
                ".gitignore:tracked_local_secret_file:IMApp/Profiles/AppStore.mobileprovision",
                "tracked_mobileprovision_file",
            ),
            (
                "id_ed25519",
                "-----BEGIN OPENSSH PRIVATE KEY-----\ndo-not-commit\n-----END OPENSSH PRIVATE KEY-----\n",
                ".gitignore:tracked_local_secret_file:id_ed25519",
                "tracked_ssh_private_key",
            ),
        ]
        for relative_path, contents, expected_error, reason in tracked_secret_cases:
            copy_required_files(repo_root, test_root)
            if not initialize_git_repo(test_root):
                print(
                    f"production-workflow-audit-self-test result=fail phase=setup reason={reason}_reinit_failed",
                    file=sys.stderr,
                )
                return 1
            secret_file = test_root / relative_path
            secret_file.parent.mkdir(parents=True, exist_ok=True)
            secret_file.write_text(contents, encoding="utf-8")
            if not git_force_add(test_root, relative_path):
                print(
                    f"production-workflow-audit-self-test result=fail phase=setup reason={reason}_force_add_failed",
                    file=sys.stderr,
                )
                return 1
            errors = audit_repo(test_root)
            if not any(expected_error in error for error in errors):
                print(
                    "production-workflow-audit-self-test result=fail phase=negative "
                    f"reason=missing_{reason}_not_detected",
                    file=sys.stderr,
                )
                return 1

        tracked_generated_cases = [
            (
                "IMServer/LoadTests/accounts/load-10000.csv",
                "email,password\nload000001@example.com,do-not-commit\n",
                ".gitignore:tracked_account_file:IMServer/LoadTests/accounts/load-10000.csv",
                "tracked_account_file",
            ),
            (
                "IMServer/LoadTests/results/production-acceptance/receipt.json",
                '{"status":"PASS"}\n',
                ".gitignore:tracked_load_test_result:IMServer/LoadTests/results/production-acceptance/receipt.json",
                "tracked_load_test_result",
            ),
            (
                "IMServer/LoadTests/login-cache/tcp-login-cache-lg1-1000.json",
                '[{"email":"load000001@example.com","accessToken":"do-not-commit"}]\n',
                ".gitignore:tracked_login_cache_file:IMServer/LoadTests/login-cache/tcp-login-cache-lg1-1000.json",
                "tracked_login_cache_file",
            ),
            (
                "IMServer/LoadTests/token-cache/access-token-cache-lg1-1000.json",
                '[{"email":"load000001@example.com","accessToken":"do-not-commit"}]\n',
                ".gitignore:tracked_login_cache_file:IMServer/LoadTests/token-cache/access-token-cache-lg1-1000.json",
                "tracked_token_cache_file",
            ),
            (
                "IMServer/reports/latest-production-release-gate.json",
                '{"status":"PASS"}\n',
                ".gitignore:tracked_imserver_report:IMServer/reports/latest-production-release-gate.json",
                "tracked_imserver_report",
            ),
        ]
        for relative_path, contents, expected_error, reason in tracked_generated_cases:
            copy_required_files(repo_root, test_root)
            if not initialize_git_repo(test_root):
                print(
                    f"production-workflow-audit-self-test result=fail phase=setup reason={reason}_reinit_failed",
                    file=sys.stderr,
                )
                return 1
            generated_file = test_root / relative_path
            generated_file.parent.mkdir(parents=True, exist_ok=True)
            generated_file.write_text(contents, encoding="utf-8")
            if not git_force_add(test_root, relative_path):
                print(
                    f"production-workflow-audit-self-test result=fail phase=setup reason={reason}_force_add_failed",
                    file=sys.stderr,
                )
                return 1
            errors = audit_repo(test_root)
            if not any(expected_error in error for error in errors):
                print(
                    "production-workflow-audit-self-test result=fail phase=negative "
                    f"reason=missing_{reason}_not_detected",
                    file=sys.stderr,
                )
                return 1

    print("production-workflow-audit-self-test result=pass")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit production GitHub Actions and governance wiring.")
    parser.add_argument("--repo-root", default=str(REPO_ROOT), help="repository root to audit")
    parser.add_argument("--self-test", action="store_true", help="run positive and negative audit self-tests")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    if args.self_test:
        return run_self_test(repo_root)

    errors = audit_repo(repo_root)

    if errors:
        for error in errors:
            print(f"production-workflow-audit result=fail reason={error}", file=sys.stderr)
        return 1

    print("production-workflow-audit result=pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
