#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_ID="${LOCAL_MULTINODE_FAULT_CONTRACTS_RUN_ID:-local-multinode-fault-contracts-$(date +%Y%m%d-%H%M%S)}"
RESULT_DIR="${LOCAL_MULTINODE_FAULT_CONTRACTS_RESULT_DIR:-${SCRIPT_DIR}/results/local-multinode-fault-contracts/${RUN_ID}}"
SWIFT_BIN="${LOCAL_MULTINODE_FAULT_CONTRACTS_SWIFT_BIN:-swift}"

declare -a CONTRACT_NAMES=(
  "production-requires-redis-routing"
  "non-ops-role-cannot-auto-migrate"
  "gateway-route-lookup-fails-closed"
  "consumer-route-split-retries-stream-event"
  "domain-relay-route-split-retries-stream-event"
  "cell-ingress-role-routing"
  "malformed-cell-ingress-fails-startup"
  "outbox-publishes-durable-claim"
  "outbox-recovers-timed-out-claim"
  "client-message-retry-is-idempotent"
  "projection-replay-is-idempotent"
  "owner-delivery-replay-is-idempotent"
  "cross-cell-same-shard-name-is-valid"
  "cross-cell-transfer-page-is-idempotent"
  "migration-copy-verification-keeps-source-route"
  "cross-cell-outbox-persists-before-target-acceptance"
  "cross-cell-outbox-retains-target-failure-for-retry"
  "cross-cell-outbox-recovers-after-target-availability"
  "cross-cell-outbox-replay-is-deduplicated"
  "reliable-gateway-relay-fails-when-handoff-is-not-durable"
)

declare -a CONTRACT_FILTERS=(
  "IMServerTests.IMServerTests/productionRequiresRedisRouting()"
  "IMServerTests.IMServerTests/productionNonOpsRolesCannotEnableStartupAutoMigration()"
  "IMServerTests.IMServerTests/connectionRoutingDropsRemoteRealtimeFanoutWhenActiveRouteLookupFailsClosed()"
  "IMServerTests.IMServerTests/realtimeDeliveryRetriesStreamEventWhenRouteSplitFails()"
  "IMServerTests.IMServerTests/domainRelayAfterRecordRetriesStreamEventWhenRouteSplitFails()"
  "IMServerTests.IMServerTests/cellIngressConfigurationSelectsPurposeEndpoints()"
  "IMServerTests.IMServerTests/productionRuntimeRejectsMalformedCellIngressEndpointConfiguration()"
  "IMServerTests.IMServerTests/conversationOutboxRelayMarksPublishedEvents()"
  "IMServerTests.IMServerTests/conversationOutboxRelayRecoversTimedOutClaims()"
  "IMServerTests.IMServerTests/tcpMessagePersistenceIsIdempotentByClientMessageID()"
  "IMServerTests.IMServerTests/messageCreatedProjectionUsesEventMessageForLargeGroups()"
  "IMServerTests.IMServerTests/messageCreatedRunOwnerDeliveryPreservesPerOwnerEventOrder()"
  "IMServerTests.IMServerTests/crossCellMigrationAllowsSameShardName()"
  "IMServerTests.IMServerTests/remoteCellMigrationTransferPage()"
  "IMServerTests.IMServerTests/conversationShardMigrationCopyAndVerifyKeepsSourceRouteActive()"
  "IMServerTests.IMServerTests/crossCellRealtimeOutboxPersistsAndCompletesAfterTargetAcceptance()"
  "IMServerTests.IMServerTests/crossCellRealtimeOutboxRetainsFailedDeliveryForRetry()"
  "IMServerTests.IMServerTests/crossCellRealtimeOutboxDeliversRetainedDispatchAfterTargetRecovery()"
  "IMServerTests.IMServerTests/crossCellRealtimeOutboxDeduplicatesReplayedSourceHandoff()"
  "IMServerTests.IMServerTests/reliableGatewayRelayReturnsFailureWhenCellHandoffCannotBeRecorded()"
)

usage() {
  cat <<'EOF'
Usage: run_local_multinode_fault_contracts.sh [check|run|self-test]

Runs multi-node failure-policy contracts locally through the IMServer Swift test
suite. It never starts an IMServer process, connects to a remote host, or proves
production availability/capacity.

Optional environment:
  LOCAL_MULTINODE_FAULT_CONTRACTS_SWIFT_BIN=swift
  LOCAL_MULTINODE_FAULT_CONTRACTS_RUN_ID=local-multinode-fault-contracts-<id>
  LOCAL_MULTINODE_FAULT_CONTRACTS_RESULT_DIR=IMServer/LoadTests/results/local-multinode-fault-contracts/<run-id>
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'local_multinode_fault_contracts result=fail reason=command_missing command=%s\n' "$1" >&2
    exit 127
  }
}

check() {
  require_command "${SWIFT_BIN}"
  if [[ ! -f "${SERVER_DIR}/Package.swift" ]]; then
    printf 'local_multinode_fault_contracts result=fail reason=swift_package_missing path=%s\n' "${SERVER_DIR}/Package.swift" >&2
    exit 2
  fi
  printf 'local_multinode_fault_contracts result=pass mode=check contracts=%s productionEvidence=false localOnly=true\n' \
    "${#CONTRACT_FILTERS[@]}"
}

run() {
  check
  mkdir -p "${RESULT_DIR}"

  local summary="${RESULT_DIR}/summary.tsv"
  local available_tests="${RESULT_DIR}/available-tests.txt"
  local test_log="${RESULT_DIR}/all-contracts.log"
  local test_filter index name filter exit_code
  printf 'contract\tresult\texitCode\tfilter\tlog\n' >"${summary}"

  if ! "${SWIFT_BIN}" test --package-path "${SERVER_DIR}" list >"${available_tests}" 2>&1; then
    printf 'local_multinode_fault_contracts result=fail reason=test_bundle_prepare_failed productionEvidence=false localOnly=true log=%s\n' \
      "${available_tests}" >&2
    return 1
  fi

  for index in "${!CONTRACT_FILTERS[@]}"; do
    filter="${CONTRACT_FILTERS[${index}]}"
    if ! rg -Fqx "${filter}" "${available_tests}"; then
      printf 'local_multinode_fault_contracts result=fail reason=contract_test_missing filter=%s availableTests=%s\n' \
        "${filter}" "${available_tests}" >&2
      return 1
    fi
  done

  test_filter="$(IFS='|'; printf '%s' "${CONTRACT_FILTERS[*]}")"

  set +e
  "${SWIFT_BIN}" test --skip-build --package-path "${SERVER_DIR}" --filter "${test_filter}" \
    --enable-swift-testing --disable-xctest --no-parallel >"${test_log}" 2>&1
  exit_code=$?
  set -e

  for index in "${!CONTRACT_FILTERS[@]}"; do
    name="${CONTRACT_NAMES[${index}]}"
    filter="${CONTRACT_FILTERS[${index}]}"
    if [[ "${exit_code}" -eq 0 ]]; then
      printf '%s\tpass\t0\t%s\t%s\n' "${name}" "${filter}" "${test_log}" | tee -a "${summary}"
    else
      printf '%s\tfail\t%s\t%s\t%s\n' "${name}" "${exit_code}" "${filter}" "${test_log}" | tee -a "${summary}" >&2
    fi
  done

  if [[ "${exit_code}" -ne 0 ]]; then
    printf 'local_multinode_fault_contracts result=fail failedContracts=unknown totalContracts=%s productionEvidence=false localOnly=true summary=%s log=%s\n' \
      "${#CONTRACT_FILTERS[@]}" "${summary}" "${test_log}" >&2
    return 1
  fi

  printf 'local_multinode_fault_contracts result=pass contracts=%s productionEvidence=false localOnly=true summary=%s\n' \
    "${#CONTRACT_FILTERS[@]}" "${summary}"
}

self_test() {
  local output
  output="$(LOCAL_MULTINODE_FAULT_CONTRACTS_SWIFT_BIN=printf bash "${BASH_SOURCE[0]}" check)"
  [[ "${output}" == *"result=pass mode=check contracts=20 productionEvidence=false localOnly=true"* ]] || {
    printf 'local_multinode_fault_contracts_self_test result=fail reason=check_contract_invalid\n' >&2
    return 1
  }
  printf 'local_multinode_fault_contracts_self_test result=pass\n'
}

case "${1:-run}" in
  --help|-h)
    usage
    ;;
  check)
    check
    ;;
  run)
    run
    ;;
  self-test)
    self_test
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
