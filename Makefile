.PHONY: help test-client build-app build-app-local-device print-local-client-config local-dev local-server-start local-server-stop local-server-status local-server-health validate-ios-network-config validate-ios-debug-network-defaults validate-ios-debug-network-defaults-self-test validate-ios-production-config validate-android-network-config validate-production-static validate-production-gates verify-production-static-receipt production-worktree-inventory production-worktree-inventory-json production-worktree-plan production-worktree-plan-json verify-production-worktree-plan-json production-worktree-commit-runbook verify-production-worktree-commit-runbook production-worktree-stage-dry-run verify-production-worktree-stage-dry-run production-worktree-stage-dry-run-batch verify-production-worktree-stage-dry-run-batch verify-production-worktree-staging verify-production-worktree-staged-group check-production-worktree-inventory check-imserver-production-release-gate check-imserver-production-smoke run-imserver-production-smoke verify-imserver-production-smoke install-production-smoke-receipt run-imserver-production-release-gate verify-imserver-production-release-gate production-completion-status verify-production-completion-status production-evidence-recovery-plan production-evidence-recovery-plan-diagnostic verify-production-evidence-recovery-plan verify-production-evidence-recovery-plan-diagnostic check-production-evidence-recovery-diagnostic-paths validate-production-evidence-recovery-env production-readiness-status validate-production-acceptance-env run-current-production-readiness verify-current-production-readiness run-production-acceptance verify-production-acceptance assert-production-ready verify-production-ready-assertion package-production-ready-assertion verify-production-ready-archive check-production-ops run-production-readiness-gate run-operational-audit install-operational-audit-timer send-operational-alert install-backup-timer create-backup-single-node verify-backup run-restore-drill install-restore-drill-timer sync-offsite-backup run-non-large-group-regression-plan check-non-large-group-regression run-non-large-group-regression run-product-test-plan-plan check-product-test-plan run-product-test-plan run-product-scenario-suite-plan check-product-scenario-suite run-product-scenario-suite run-local-acceptance-plan check-local-acceptance run-local-acceptance verify-local-acceptance test-server test-all

CURRENT_PRODUCTION_READINESS_JSON ?= IMServer/LoadTests/results/current-production-readiness/current-production-readiness.json
IMSERVER_PRODUCTION_RELEASE_GATE_JSON ?= IMServer/reports/latest-production-release-gate.json
IMSERVER_PRODUCTION_SMOKE_JSON ?= IMServer/reports/latest-production-smoke.json
PRODUCTION_READY_ASSERTION_JSON ?= IMServer/LoadTests/results/production-ready/latest.json
PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT ?=
PRODUCTION_READY_ASSERTION_ARCHIVE_DIR ?= IMServer/LoadTests/results/production-ready/archive
PRODUCTION_READY_ASSERTION_ARCHIVE_FILE ?=
PRODUCTION_STATIC_GATE_RECEIPT_JSON ?= IMServer/LoadTests/results/production-static/latest.json
PRODUCTION_WORKTREE_INVENTORY_JSON ?= IMServer/LoadTests/results/production-worktree-inventory/latest.json
PRODUCTION_WORKTREE_PLAN_JSON ?= IMServer/LoadTests/results/production-worktree-inventory/plan.json
PRODUCTION_WORKTREE_COMMIT_RUNBOOK ?= IMServer/LoadTests/results/production-worktree-inventory/commit-runbook.sh
PRODUCTION_WORKTREE_STAGE_DRY_RUN_JSON ?= IMServer/LoadTests/results/production-worktree-inventory/stage-dry-run.json
PRODUCTION_WORKTREE_STAGE_DRY_RUN_BATCH_JSON ?= IMServer/LoadTests/results/production-worktree-inventory/stage-dry-run-batch.json
PRODUCTION_WORKTREE_INVENTORY_ARGS ?=
PRODUCTION_COMPLETION_STATUS_JSON ?= IMServer/LoadTests/results/production-completion-status/latest.json
PRODUCTION_COMPLETION_STATUS_MD ?= IMServer/LoadTests/results/production-completion-status/latest.md
PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_JSON ?= IMServer/LoadTests/results/production-completion-status/diagnostic-latest.json
PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_MD ?= IMServer/LoadTests/results/production-completion-status/diagnostic-latest.md
# strict recovery plan JSON
PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON ?= IMServer/LoadTests/results/production-completion-status/evidence-recovery-plan.json
PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD ?= IMServer/LoadTests/results/production-completion-status/evidence-recovery-plan.md
PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT ?= IMServer/LoadTests/results/production-completion-status/evidence-recovery-run.sh
# diagnostic recovery plan JSON
PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_JSON ?= IMServer/LoadTests/results/production-completion-status/diagnostic-evidence-recovery-plan.json
PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_MD ?= IMServer/LoadTests/results/production-completion-status/diagnostic-evidence-recovery-plan.md
PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT ?= IMServer/LoadTests/results/production-completion-status/diagnostic-evidence-recovery-run.sh
PRODUCTION_EVIDENCE_RECOVERY_ALLOW_LOCAL_INCOMPLETE ?= false

help:
	@printf '%s\n' 'IMMonorepo make targets'
	@printf '%s\n' ''
	@printf '%s\n' 'Local development:'
	@printf '%s\n' '  make local-dev'
	@printf '%s\n' '  make local-server-start | local-server-stop | local-server-status | local-server-health'
	@printf '%s\n' '  make run-local-acceptance-plan | check-local-acceptance | run-local-acceptance | verify-local-acceptance'
	@printf '%s\n' ''
	@printf '%s\n' 'Client/config gates:'
	@printf '%s\n' '  make validate-ios-network-config | validate-ios-debug-network-defaults | validate-ios-production-config'
	@printf '%s\n' '  make validate-android-network-config'
	@printf '%s\n' ''
	@printf '%s\n' 'Production gates and evidence:'
	@printf '%s\n' '  make validate-production-static | verify-production-static-receipt | validate-production-gates'
	@printf '%s\n' '  make production-worktree-inventory | production-worktree-inventory-json | production-worktree-plan | production-worktree-plan-json | verify-production-worktree-plan-json | production-worktree-commit-runbook | verify-production-worktree-commit-runbook | production-worktree-stage-dry-run | verify-production-worktree-stage-dry-run | production-worktree-stage-dry-run-batch | verify-production-worktree-stage-dry-run-batch | verify-production-worktree-staging | verify-production-worktree-staged-group | check-production-worktree-inventory'
	@printf '%s\n' '  make check-imserver-production-release-gate | run-imserver-production-release-gate | verify-imserver-production-release-gate'
	@printf '%s\n' '  make check-imserver-production-smoke | run-imserver-production-smoke | verify-imserver-production-smoke | install-production-smoke-receipt'
	@printf '%s\n' '  make production-completion-status | verify-production-completion-status | production-evidence-recovery-plan | production-evidence-recovery-plan-diagnostic | verify-production-evidence-recovery-plan | verify-production-evidence-recovery-plan-diagnostic | validate-production-evidence-recovery-env | production-readiness-status | run-current-production-readiness | verify-current-production-readiness'
	@printf '%s\n' '  make validate-production-acceptance-env | run-production-acceptance | verify-production-acceptance | assert-production-ready | verify-production-ready-assertion | package-production-ready-assertion | verify-production-ready-archive'
	@printf '%s\n' ''
	@printf '%s\n' 'Production operations:'
	@printf '%s\n' '  make check-production-ops'
	@printf '%s\n' '  make run-production-readiness-gate | run-operational-audit'
	@printf '%s\n' '  make install-operational-audit-timer | send-operational-alert'
	@printf '%s\n' '  make install-backup-timer | create-backup-single-node | verify-backup'
	@printf '%s\n' '  make run-restore-drill | install-restore-drill-timer | sync-offsite-backup'
	@printf '%s\n' ''
	@printf '%s\n' 'Performance/product scenarios:'
	@printf '%s\n' '  make run-non-large-group-regression-plan | check-non-large-group-regression | run-non-large-group-regression'
	@printf '%s\n' '  make run-product-test-plan-plan | check-product-test-plan | run-product-test-plan'
	@printf '%s\n' '  make run-product-scenario-suite-plan | check-product-scenario-suite | run-product-scenario-suite'
	@printf '%s\n' ''
	@printf '%s\n' 'Build/test:'
	@printf '%s\n' '  make test-client | build-app | build-app-local-device | test-server | test-all'

test-client:
	cd IMClientKit && swift test --no-parallel

build-app:
	xcodebuild \
		-project IMApp/IMApp.xcodeproj \
		-scheme IMApp \
		-sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' \
		build-for-testing

print-local-client-config:
	IMApp/Scripts/local_debug_network.sh print

build-app-local-device:
	IMApp/Scripts/local_debug_network.sh xcodebuild build-for-testing

local-dev:
	$(MAKE) local-server-start
	$(MAKE) local-server-health
	$(MAKE) validate-ios-debug-network-defaults
	$(MAKE) check-local-acceptance
	$(MAKE) print-local-client-config

local-server-start:
	IMServer/scripts/local_service.sh start

local-server-stop:
	IMServer/scripts/local_service.sh stop

local-server-status:
	IMServer/scripts/local_service.sh status

local-server-health:
	IMServer/scripts/local_service.sh health

validate-ios-network-config:
	IMAPP_NETWORK_CONFIG_SELF_TEST=true IMApp/Scripts/validate_network_configuration.sh

validate-ios-debug-network-defaults:
	IMApp/Scripts/validate_debug_network_defaults.sh

validate-ios-debug-network-defaults-self-test:
	IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST=true IMApp/Scripts/validate_debug_network_defaults.sh

validate-ios-production-config:
	IMAPP_NETWORK_CONFIG_MODE=production IMApp/Scripts/validate_network_configuration.sh

validate-android-network-config:
	python3 scripts/validate_android_network_configuration.py --self-test
	python3 scripts/validate_android_network_configuration.py

validate-production-static: validate-ios-network-config
	IMAPP_DEBUG_NETWORK_DEFAULTS_SELF_TEST=true IMApp/Scripts/validate_debug_network_defaults.sh
	python3 scripts/validate_android_network_configuration.py --self-test
	python3 scripts/validate_production_workflows.py --self-test
	python3 scripts/validate_production_workflows.py
	PRODUCTION_RELEASE_GATE_SELF_TEST=true bash IMServer/scripts/production_release_gate.sh
	python3 IMServer/scripts/verify_production_release_gate.py --self-test
	python3 IMServer/LoadTests/perf_forbidden_artifacts.py --self-test
	python3 IMServer/LoadTests/perf_secret_scan.py --self-test
	python3 IMServer/LoadTests/perf_production_acceptance_verify.py --self-test
	python3 IMServer/LoadTests/perf_current_production_readiness_verify.py --self-test
	python3 IMServer/LoadTests/perf_evidence_manifest.py --self-test
	python3 IMServer/LoadTests/perf_matrix_audit.py --self-test
	python3 IMServer/LoadTests/perf_coverage.py --self-test
	python3 IMServer/LoadTests/perf_route_audit.py --self-test
	python3 IMServer/LoadTests/perf_scenario_status.py --self-test
	python3 IMServer/LoadTests/perf_scenario_catalog.py --self-test
	python3 IMServer/LoadTests/perf_run_plan.py --self-test
	python3 IMServer/LoadTests/perf_default_profile_audit.py --self-test
	python3 IMServer/LoadTests/perf_docs_audit.py --self-test
	python3 IMServer/LoadTests/perf_validation_inventory.py --self-test
	python3 IMServer/LoadTests/perf_production_profiles_audit.py --self-test
	python3 IMServer/LoadTests/perf_product_scenario_suite_verify.py --self-test
	python3 IMServer/LoadTests/perf_product_plan_artifacts_verify.py --self-test
	python3 IMServer/LoadTests/perf_product_campaign_artifacts_verify.py --self-test
	python3 IMServer/LoadTests/perf_product_campaign_audit.py --self-test
	python3 IMServer/LoadTests/perf_product_profile_gate.py --self-test
	python3 IMServer/LoadTests/perf_profile_artifacts_verify.py --self-test
	PRODUCTION_EVIDENCE_SELF_TEST=true bash IMServer/LoadTests/package_production_evidence.sh
	python3 IMServer/LoadTests/production_target_policy.py --self-test
	CURRENT_PRODUCTION_SELF_TEST=true bash IMServer/LoadTests/run_current_production_readiness.sh
	PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=true bash IMServer/LoadTests/validate_production_acceptance_env.sh
	PRODUCTION_ACCEPTANCE_SELF_TEST=true bash IMServer/LoadTests/run_production_acceptance.sh
	VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=true bash IMServer/LoadTests/verify_production_acceptance.sh
	ASSERT_PRODUCTION_READY_SELF_TEST=true bash IMServer/LoadTests/assert_production_ready.sh
	python3 IMServer/LoadTests/verify_production_ready_assertion.py --self-test
	python3 IMServer/LoadTests/package_production_ready_assertion.py --self-test
	python3 IMServer/LoadTests/verify_deploy_readiness_receipt.py --self-test
	python3 IMServer/LoadTests/production_completion_status.py --self-test
	python3 IMServer/LoadTests/verify_production_completion_status.py --self-test
	python3 IMServer/LoadTests/production_evidence_recovery_plan.py --self-test
	python3 IMServer/LoadTests/verify_production_evidence_recovery_paths.py --self-test
	$(MAKE) check-production-worktree-inventory
	$(MAKE) check-production-evidence-recovery-diagnostic-paths
	python3 IMServer/LoadTests/production_static_gate_receipt.py --self-test
	PRODUCTION_READINESS_STATUS_SELF_TEST=true bash IMServer/LoadTests/production_readiness_status.sh
	$(MAKE) check-imserver-production-smoke
	$(MAKE) check-production-ops
	cd IMServer && ./scripts/production_env_preflight_test.sh
	python3 IMServer/LoadTests/production_static_gate_receipt.py --receipt-json "$(PRODUCTION_STATIC_GATE_RECEIPT_JSON)"
	PRODUCTION_COMPLETION_STATUS_STATIC_RECEIPT_BOOTSTRAP=true $(MAKE) production-completion-status
	python3 IMServer/LoadTests/production_evidence_recovery_plan.py --status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --repo-root "$(CURDIR)" --output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --json-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --script-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"
	python3 IMServer/LoadTests/production_evidence_recovery_plan.py --verify --status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --repo-root "$(CURDIR)" --output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --json-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --script-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"
	python3 IMServer/LoadTests/production_static_gate_receipt.py --receipt-json "$(PRODUCTION_STATIC_GATE_RECEIPT_JSON)" --completion-status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --completion-status-markdown "$(PRODUCTION_COMPLETION_STATUS_MD)" --recovery-plan-json "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --recovery-plan-markdown "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --recovery-plan-script "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"
	$(MAKE) production-completion-status
	$(MAKE) verify-production-completion-status
	python3 IMServer/LoadTests/production_evidence_recovery_plan.py --status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --repo-root "$(CURDIR)" --output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --json-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --script-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"
	python3 IMServer/LoadTests/production_evidence_recovery_plan.py --verify --status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --repo-root "$(CURDIR)" --output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --json-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --script-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"
	python3 IMServer/LoadTests/production_static_gate_receipt.py --receipt-json "$(PRODUCTION_STATIC_GATE_RECEIPT_JSON)" --completion-status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --completion-status-markdown "$(PRODUCTION_COMPLETION_STATUS_MD)" --recovery-plan-json "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --recovery-plan-markdown "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --recovery-plan-script "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"
	$(MAKE) verify-production-static-receipt

validate-production-gates: validate-production-static
	bash IMServer/LoadTests/validate_load_tests.sh

verify-production-static-receipt:
	python3 IMServer/LoadTests/production_static_gate_receipt.py --verify --receipt-json "$(PRODUCTION_STATIC_GATE_RECEIPT_JSON)" --require-completion-status --require-recovery-plan --expect-repo-root "$(CURDIR)" --require-current-git --require-clean-git

production-worktree-inventory:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

production-worktree-inventory-json:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --json-output "$(PRODUCTION_WORKTREE_INVENTORY_JSON)" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

production-worktree-plan:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --plan $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

production-worktree-plan-json:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --plan-json-output "$(PRODUCTION_WORKTREE_PLAN_JSON)" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

verify-production-worktree-plan-json:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --verify-plan-json "$(PRODUCTION_WORKTREE_PLAN_JSON)" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

production-worktree-commit-runbook:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --commit-runbook-output "$(PRODUCTION_WORKTREE_COMMIT_RUNBOOK)" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

verify-production-worktree-commit-runbook:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --verify-commit-runbook "$(PRODUCTION_WORKTREE_COMMIT_RUNBOOK)" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

production-worktree-stage-dry-run:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --stage-dry-run --stage-dry-run-json-output "$(PRODUCTION_WORKTREE_STAGE_DRY_RUN_JSON)" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

verify-production-worktree-stage-dry-run:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --verify-stage-dry-run-json "$(PRODUCTION_WORKTREE_STAGE_DRY_RUN_JSON)" $(PRODUCTION_WORKTREE_INVENTORY_ARGS)

production-worktree-stage-dry-run-batch:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --stage-dry-run-batch --stage-dry-run-batch-json-output "$(PRODUCTION_WORKTREE_STAGE_DRY_RUN_BATCH_JSON)"

verify-production-worktree-stage-dry-run-batch:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --verify-stage-dry-run-batch-json "$(PRODUCTION_WORKTREE_STAGE_DRY_RUN_BATCH_JSON)"

verify-production-worktree-staging:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --verify-staged-source-only

verify-production-worktree-staged-group:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --repo-root "$(CURDIR)" --verify-staged-single-group

check-production-worktree-inventory:
	@python3 IMServer/LoadTests/production_worktree_inventory.py --self-test

check-imserver-production-release-gate:
	PRODUCTION_RELEASE_GATE_SELF_TEST=true bash IMServer/scripts/production_release_gate.sh

check-imserver-production-smoke:
	bash -n IMServer/scripts/production_smoke.sh
	bash IMServer/scripts/production_smoke.sh self-test
	python3 IMServer/scripts/verify_production_smoke.py --self-test
	bash -n deploy/ubuntu/72_install_topology_smoke_receipt.sh
	TOPOLOGY_SMOKE_INSTALL_SELF_TEST=true bash deploy/ubuntu/72_install_topology_smoke_receipt.sh

run-imserver-production-smoke:
	cd IMServer && ./scripts/production_smoke.sh run
	$(MAKE) verify-imserver-production-smoke

verify-imserver-production-smoke:
	python3 IMServer/scripts/verify_production_smoke.py --receipt-json "$(IMSERVER_PRODUCTION_SMOKE_JSON)" --require-pass --require-artifacts-exist

install-production-smoke-receipt:
	TOPOLOGY_SMOKE_RECEIPT_SOURCE="$(IMSERVER_PRODUCTION_SMOKE_JSON)" bash deploy/ubuntu/72_install_topology_smoke_receipt.sh

run-imserver-production-release-gate:
	cd IMServer && ./scripts/production_release_gate.sh && python3 scripts/verify_production_release_gate.py --receipt-json reports/latest-production-release-gate.json --require-pass --require-release-run --require-swift-tests

verify-imserver-production-release-gate:
	python3 IMServer/scripts/verify_production_release_gate.py --receipt-json "$(IMSERVER_PRODUCTION_RELEASE_GATE_JSON)" --require-pass --require-release-run --require-swift-tests

production-completion-status:
	python3 IMServer/LoadTests/production_completion_status.py --json-output "$(PRODUCTION_COMPLETION_STATUS_JSON)" --markdown-output "$(PRODUCTION_COMPLETION_STATUS_MD)"

verify-production-completion-status:
	python3 IMServer/LoadTests/verify_production_completion_status.py --status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --markdown-report "$(PRODUCTION_COMPLETION_STATUS_MD)" --expect-repo-root "$(CURDIR)" --require-local-complete

production-evidence-recovery-plan: production-completion-status
	@if [ "$(PRODUCTION_EVIDENCE_RECOVERY_ALLOW_LOCAL_INCOMPLETE)" = "true" ]; then \
		python3 IMServer/LoadTests/production_evidence_recovery_plan.py --status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --repo-root "$(CURDIR)" --output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --json-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --script-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)" --allow-local-incomplete; \
	else \
		$(MAKE) --no-print-directory verify-production-completion-status && \
		python3 IMServer/LoadTests/production_evidence_recovery_plan.py --status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --repo-root "$(CURDIR)" --output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --json-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --script-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"; \
	fi

check-production-evidence-recovery-diagnostic-paths:
	python3 IMServer/LoadTests/verify_production_evidence_recovery_paths.py \
		--strict-completion-status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" \
		--strict-completion-status-markdown "$(PRODUCTION_COMPLETION_STATUS_MD)" \
		--strict-recovery-plan-json "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" \
		--strict-recovery-plan-markdown "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" \
		--strict-recovery-script "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)" \
		--diagnostic-completion-status-json "$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_JSON)" \
		--diagnostic-completion-status-markdown "$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_MD)" \
		--diagnostic-recovery-plan-json "$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_JSON)" \
		--diagnostic-recovery-plan-markdown "$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_MD)" \
		--diagnostic-recovery-script "$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT)"

production-evidence-recovery-plan-diagnostic: check-production-evidence-recovery-diagnostic-paths
	PRODUCTION_EVIDENCE_RECOVERY_ALLOW_LOCAL_INCOMPLETE=true \
	PRODUCTION_COMPLETION_STATUS_JSON="$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_JSON)" \
	PRODUCTION_COMPLETION_STATUS_MD="$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_MD)" \
	PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON="$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_JSON)" \
	PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD="$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_MD)" \
	PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT="$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT)" \
	$(MAKE) --no-print-directory production-evidence-recovery-plan

verify-production-evidence-recovery-plan:
	python3 IMServer/LoadTests/production_evidence_recovery_plan.py --verify --status-json "$(PRODUCTION_COMPLETION_STATUS_JSON)" --repo-root "$(CURDIR)" --output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_MD)" --json-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_JSON)" --script-output "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"

verify-production-evidence-recovery-plan-diagnostic: check-production-evidence-recovery-diagnostic-paths
	python3 IMServer/LoadTests/verify_production_completion_status.py --status-json "$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_JSON)" --markdown-report "$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_MD)" --expect-repo-root "$(CURDIR)"
	python3 IMServer/LoadTests/production_evidence_recovery_plan.py --verify --status-json "$(PRODUCTION_COMPLETION_STATUS_DIAGNOSTIC_JSON)" --repo-root "$(CURDIR)" --output "$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_MD)" --json-output "$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_JSON)" --script-output "$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT)"
	bash -n "$(PRODUCTION_EVIDENCE_RECOVERY_DIAGNOSTIC_PLAN_SCRIPT)"

validate-production-evidence-recovery-env:
	$(MAKE) --no-print-directory verify-production-static-receipt >/dev/null
	$(MAKE) --no-print-directory verify-production-evidence-recovery-plan >/dev/null
	PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true bash "$(PRODUCTION_EVIDENCE_RECOVERY_PLAN_SCRIPT)"

production-readiness-status:
	bash IMServer/LoadTests/production_readiness_status.sh

validate-production-acceptance-env:
	bash IMServer/LoadTests/validate_production_acceptance_env.sh

run-current-production-readiness:
	bash IMServer/LoadTests/run_current_production_readiness.sh

verify-current-production-readiness:
	python3 IMServer/LoadTests/perf_current_production_readiness_verify.py --readiness-json "$(CURRENT_PRODUCTION_READINESS_JSON)"

run-production-acceptance:
	bash IMServer/LoadTests/run_production_acceptance.sh

verify-production-acceptance:
	bash IMServer/LoadTests/verify_production_acceptance.sh

assert-production-ready:
	bash IMServer/LoadTests/assert_production_ready.sh

verify-production-ready-assertion:
	python3 IMServer/LoadTests/verify_production_ready_assertion.py --receipt-json "$(PRODUCTION_READY_ASSERTION_JSON)" --require-pass --require-artifacts-exist $(if $(PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT),--artifact-root "$(PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT)",)

package-production-ready-assertion:
	python3 IMServer/LoadTests/package_production_ready_assertion.py --receipt-json "$(PRODUCTION_READY_ASSERTION_JSON)" --output-dir "$(PRODUCTION_READY_ASSERTION_ARCHIVE_DIR)" $(if $(PRODUCTION_READY_ASSERTION_ARCHIVE_FILE),--archive-file "$(PRODUCTION_READY_ASSERTION_ARCHIVE_FILE)",) $(if $(PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT),--artifact-root "$(PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT)",)

verify-production-ready-archive:
	@test -n "$(PRODUCTION_READY_ASSERTION_ARCHIVE_FILE)" || (printf '%s\n' 'set PRODUCTION_READY_ASSERTION_ARCHIVE_FILE=/path/to/production-ready-assertion.tar.gz' >&2; exit 1)
	python3 IMServer/LoadTests/package_production_ready_assertion.py --verify-archive --archive-file "$(PRODUCTION_READY_ASSERTION_ARCHIVE_FILE)"

check-production-ops:
	bash -n deploy/ubuntu/00_install_dependencies.sh
	INSTALL_DEPENDENCIES_SELF_TEST=true bash deploy/ubuntu/00_install_dependencies.sh
	bash -n deploy/ubuntu/40_build_imserver.sh
	BUILD_IMSERVER_SELF_TEST=true bash deploy/ubuntu/40_build_imserver.sh
	bash -n deploy/ubuntu/50_install_systemd_units.sh
	SYSTEMD_UNITS_RENDER_SELF_TEST=true bash deploy/ubuntu/50_install_systemd_units.sh
	SYSTEMD_UNIT_VERIFY_SELF_TEST=true bash deploy/ubuntu/52_verify_systemd_units.sh
	READINESS_DEFAULTS_SELF_TEST=true bash deploy/ubuntu/95_production_readiness_gate.sh
	READINESS_PUBLIC_TARGET_SELF_TEST=true bash deploy/ubuntu/95_production_readiness_gate.sh
	READINESS_TOPOLOGY_SMOKE_SELF_TEST=true bash deploy/ubuntu/95_production_readiness_gate.sh
	READINESS_RECEIPT_SELF_TEST=true bash deploy/ubuntu/95_production_readiness_gate.sh
	READINESS_PERFORMANCE_EVIDENCE_SUMMARY_SELF_TEST=true bash deploy/ubuntu/95_production_readiness_gate.sh
	READINESS_AUDIT_ENV_SELF_TEST=true READINESS_REQUIRE_PERFORMANCE_GATE=true READINESS_REQUIRE_ALERT_WEBHOOK=true BACKUP_ROOT=/tmp/readiness-backups PERF_PRODUCTION_GATE_JSON=/tmp/readiness-gate.json PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT=true PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=true PUBLIC_BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com TCP_PORT=9000 PERF_PRODUCTION_EVIDENCE_CURRENT_LINK=/tmp/current-evidence PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=false bash deploy/ubuntu/95_production_readiness_gate.sh
	IM_HOST_SECURITY_SELF_TEST=true bash deploy/ubuntu/25_setup_host_security.sh
	AUDIT_DEFAULTS_SELF_TEST=true bash deploy/ubuntu/77_operational_audit.sh
	AUDIT_UNIT_SELF_TEST=true bash deploy/ubuntu/77_operational_audit.sh
	AUDIT_PERFORMANCE_SUMMARY_SELF_TEST=true bash deploy/ubuntu/77_operational_audit.sh
	bash -n deploy/ubuntu/30_setup_kafka.sh
	KAFKA_SETUP_SELF_TEST=true bash deploy/ubuntu/30_setup_kafka.sh
	AUDIT_TIMER_RENDER_SELF_TEST=true bash deploy/ubuntu/78_install_operational_audit_timer.sh
	AUDIT_ALERT_SELF_TEST=true bash deploy/ubuntu/79_send_operational_alert.sh
	BACKUP_TIMER_RENDER_SELF_TEST=true bash deploy/ubuntu/85_install_backup_timer.sh
	BACKUP_CREATE_SELF_TEST=true bash deploy/ubuntu/80_backup_single_node.sh
	BACKUP_VERIFY_SELF_TEST=true bash deploy/ubuntu/81_verify_backup.sh
	OFFSITE_BACKUP_SYNC_SELF_TEST=true bash deploy/ubuntu/86_sync_backup_offsite.sh
	RESTORE_DRILL_SAFETY_SELF_TEST=true bash deploy/ubuntu/82_restore_drill_single_node.sh
	RESTORE_DRILL_TIMER_RENDER_SELF_TEST=true bash deploy/ubuntu/83_install_restore_drill_timer.sh
	bash -n deploy/ubuntu/92_package_deploy_failure_artifacts.sh
	DEPLOY_FAILURE_ARTIFACT_PACKAGE_SELF_TEST=true bash deploy/ubuntu/92_package_deploy_failure_artifacts.sh

run-production-readiness-gate:
	bash deploy/ubuntu/95_production_readiness_gate.sh

run-operational-audit:
	bash deploy/ubuntu/77_operational_audit.sh

install-operational-audit-timer:
	bash deploy/ubuntu/78_install_operational_audit_timer.sh

send-operational-alert:
	bash deploy/ubuntu/79_send_operational_alert.sh

install-backup-timer:
	bash deploy/ubuntu/85_install_backup_timer.sh

create-backup-single-node:
	bash deploy/ubuntu/80_backup_single_node.sh

verify-backup:
	bash deploy/ubuntu/81_verify_backup.sh

run-restore-drill:
	bash deploy/ubuntu/82_restore_drill_single_node.sh

install-restore-drill-timer:
	bash deploy/ubuntu/83_install_restore_drill_timer.sh

sync-offsite-backup:
	bash deploy/ubuntu/86_sync_backup_offsite.sh

run-non-large-group-regression-plan:
	bash IMServer/LoadTests/run_non_large_group_regression.sh --print-plan

check-non-large-group-regression:
	bash IMServer/LoadTests/run_non_large_group_regression.sh --validate-plan

run-non-large-group-regression:
	bash IMServer/LoadTests/run_non_large_group_regression.sh

run-product-test-plan-plan:
	bash IMServer/LoadTests/run_product_test_plan.sh --print-plan

check-product-test-plan:
	bash IMServer/LoadTests/run_product_test_plan.sh --validate-plan

run-product-test-plan:
	bash IMServer/LoadTests/run_product_test_plan.sh

run-product-scenario-suite-plan:
	bash IMServer/LoadTests/run_product_scenario_suite.sh --print-plan

check-product-scenario-suite:
	bash IMServer/LoadTests/run_product_scenario_suite.sh --validate-plan

run-product-scenario-suite:
	bash IMServer/LoadTests/run_product_scenario_suite.sh

run-local-acceptance-plan:
	bash IMServer/LoadTests/run_local_acceptance.sh --print-plan

check-local-acceptance:
	bash IMServer/LoadTests/run_local_acceptance.sh --check

run-local-acceptance:
	bash IMServer/LoadTests/run_local_acceptance.sh run

verify-local-acceptance:
	python3 IMServer/LoadTests/verify_local_acceptance.py

test-server:
	cd IMServer && swift test --no-parallel

test-all: test-client build-app test-server
