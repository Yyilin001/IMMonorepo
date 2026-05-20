#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO_DIR="$(cd "${ROOT_DIR}/.." && pwd)"
ENV_FILE=""
PROFILE="local-smoke"
RUN_SERVER="true"
RUN_IOS="true"
RUN_IOS_APP_BUILD="true"
RUN_IOS_APP_TEST="true"
RUN_ANDROID="true"
RUN_REDIS="auto"
RUN_TCP_BUILD="true"
RUN_STAGING_BASELINE="false"
REQUIRE_STAGING_BASELINE="false"
REPORT_DIR="${ROOT_DIR}/reports"

usage() {
  cat <<'USAGE'
Usage: multidevice_release_gate.sh [options]

Options:
  --env-file path              Source staging/load-test environment variables.
  --profile name               local-smoke|staging-baseline|capacity-target. Default: local-smoke.
  --staging-baseline           Run staging_baseline.sh after local verification.
  --require-staging-baseline   Fail unless staging_baseline.sh is run and passes.
  --skip-server                Skip IMServer swift tests.
  --skip-ios                   Skip IMClientKit swift tests.
  --skip-ios-app-build         Skip IMApp simulator Debug build.
  --skip-ios-app-test          Skip IMApp simulator unit tests.
  --skip-android               Skip Android Gradle tests.
  --skip-redis                 Do not run optional Redis integration tests.
  --require-redis              Fail when IM_REDIS_INTEGRATION_URL is missing.
  --skip-tcp-build             Skip TCPDriver build.
  -h, --help                   Show this help.

Redis integration is opt-in by default:
  IM_REDIS_INTEGRATION_URL=redis://127.0.0.1:6379 swift test --filter RedisPresenceIntegrationTests

Staging baseline requires:
  BASE_URL, TCP_HOST, TCP_PORT, IM_EMAIL, IM_PASSWORD, IM_CONVERSATION_ID
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:?missing --env-file value}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:?missing --profile value}"
      shift 2
      ;;
    --staging-baseline)
      RUN_STAGING_BASELINE="true"
      shift
      ;;
    --require-staging-baseline)
      RUN_STAGING_BASELINE="true"
      REQUIRE_STAGING_BASELINE="true"
      RUN_REDIS="required"
      shift
      ;;
    --skip-server)
      RUN_SERVER="false"
      shift
      ;;
    --skip-ios)
      RUN_IOS="false"
      shift
      ;;
    --skip-ios-app-build)
      RUN_IOS_APP_BUILD="false"
      shift
      ;;
    --skip-ios-app-test)
      RUN_IOS_APP_TEST="false"
      shift
      ;;
    --skip-android)
      RUN_ANDROID="false"
      shift
      ;;
    --skip-redis)
      RUN_REDIS="false"
      shift
      ;;
    --require-redis)
      RUN_REDIS="required"
      shift
      ;;
    --skip-tcp-build)
      RUN_TCP_BUILD="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -n "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

mkdir -p "${REPORT_DIR}"
REPORT_FILE="${REPORT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-multidevice-release-gate.md"

run_step() {
  local name="$1"
  shift
  echo
  echo "==> ${name}"
  {
    echo
    echo "## ${name}"
    echo
    echo '```text'
    printf '$'
    printf ' %q' "$@"
    echo
    echo '```'
  } >> "${REPORT_FILE}"
  "$@"
  echo "- status: passed" >> "${REPORT_FILE}"
}

append_metrics_snapshot() {
  local metrics_url="${IM_METRICS_URL:-${BASE_URL:-}/internal/metrics}"
  if [[ -z "${metrics_url}" || "${metrics_url}" == "/internal/metrics" ]]; then
    {
      echo
      echo "## Prometheus metrics snapshot"
      echo
      echo "- status: skipped"
      echo "- reason: BASE_URL or IM_METRICS_URL not set"
    } >> "${REPORT_FILE}"
    return
  fi

  local secret="${IM_METRICS_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}"
  local metrics_file="${REPORT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-release-gate-metrics.prom"
  local curl_args=(-fsS "${metrics_url}")
  [[ -n "${secret}" ]] && curl_args=(-fsS -H "X-IM-Metrics-Secret: ${secret}" "${metrics_url}")

  if command -v curl >/dev/null 2>&1 && curl "${curl_args[@]}" > "${metrics_file}"; then
    {
      echo
      echo "## Prometheus metrics snapshot"
      echo
      echo "- url: ${metrics_url}"
      echo "- log: $(basename "${metrics_file}")"
      echo
      echo '```text'
      grep -E '^(im_tcp_connections|im_outbox_backlog_events|im_cross_node_dispatch_failures_total|im_session_count_query_failures_total|im_redis_presence_stale_cleanup_total|im_ai_stream_|im_stream_failed_events_total)' "${metrics_file}" || true
      echo '```'
    } >> "${REPORT_FILE}"
  else
    {
      echo
      echo "## Prometheus metrics snapshot"
      echo
      echo "- status: failed-to-fetch"
      echo "- url: ${metrics_url}"
    } >> "${REPORT_FILE}"
    if [[ "${REQUIRE_STAGING_BASELINE}" == "true" ]]; then
      echo "Failed to fetch required metrics snapshot from ${metrics_url}" >&2
      exit 2
    fi
  fi
}

{
  echo "# Multi-device release gate report"
  echo
  echo "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- git_sha: $(git -C "${MONOREPO_DIR}" rev-parse --short HEAD)"
  echo "- profile: ${PROFILE}"
  echo "- redis_mode: ${RUN_REDIS}"
  echo "- redis_integration_enabled: $([[ -n "${IM_REDIS_INTEGRATION_URL:-}" ]] && echo true || echo false)"
  echo "- staging_baseline: ${RUN_STAGING_BASELINE}"
  echo "- require_staging_baseline: ${REQUIRE_STAGING_BASELINE}"
} > "${REPORT_FILE}"

if [[ "${RUN_SERVER}" == "true" ]]; then
  run_step "IMServer full test suite" bash -lc "cd '${ROOT_DIR}' && swift test --no-parallel"
fi

if [[ "${RUN_REDIS}" != "false" ]]; then
  if [[ -n "${IM_REDIS_INTEGRATION_URL:-}" ]]; then
    run_step "Redis presence integration tests" bash -lc "cd '${ROOT_DIR}' && IM_REDIS_INTEGRATION_URL='${IM_REDIS_INTEGRATION_URL}' swift test --filter RedisPresenceIntegrationTests"
  elif [[ "${RUN_REDIS}" == "required" ]]; then
    echo "IM_REDIS_INTEGRATION_URL is required but not set." >&2
    exit 2
  else
    {
      echo
      echo "## Redis presence integration tests"
      echo
      echo "- status: skipped"
      echo "- reason: IM_REDIS_INTEGRATION_URL not set"
    } >> "${REPORT_FILE}"
    echo "Skipping Redis integration tests: IM_REDIS_INTEGRATION_URL not set"
  fi
fi

if [[ "${RUN_IOS}" == "true" ]]; then
  run_step "IMClientKit tests" bash -lc "cd '${MONOREPO_DIR}/IMClientKit' && swift test"
fi

if [[ "${RUN_IOS_APP_BUILD}" == "true" ]]; then
  run_step "IMApp Debug simulator build" bash -lc "cd '${MONOREPO_DIR}' && xcodebuild -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' build"
fi

if [[ "${RUN_IOS_APP_TEST}" == "true" ]]; then
  run_step "IMApp simulator unit tests" bash -lc "cd '${MONOREPO_DIR}' && xcodebuild -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' test -only-testing:IMAppTests -parallel-testing-enabled NO"
fi

if [[ "${RUN_ANDROID}" == "true" ]]; then
  run_step "Android tests and debug assemble" bash -lc "cd '${MONOREPO_DIR}' && ./gradlew :imclientkit:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug"
fi

if [[ "${RUN_TCP_BUILD}" == "true" ]]; then
  run_step "TCPDriver build" bash -lc "cd '${ROOT_DIR}/LoadTests/TCPDriver' && swift build"
fi

if [[ "${RUN_STAGING_BASELINE}" == "true" ]]; then
  STAGING_ARGS=(--profile "${PROFILE}")
  [[ -n "${ENV_FILE}" ]] && STAGING_ARGS+=(--env-file "${ENV_FILE}")
  [[ "${REQUIRE_STAGING_BASELINE}" == "true" ]] && STAGING_ARGS+=(--require-acceptance)
  run_step "Staging baseline" bash -lc "cd '${ROOT_DIR}' && ./scripts/staging_baseline.sh $(printf ' %q' "${STAGING_ARGS[@]}")"
elif [[ "${REQUIRE_STAGING_BASELINE}" == "true" ]]; then
  echo "Staging baseline is required but was not enabled." >&2
  exit 2
fi

append_metrics_snapshot

cat <<'EOF' >> "${REPORT_FILE}"

## Multi-device Acceptance Coverage

- automated: `IMServerTests+GatewayRouting.twoTCPDevicesReceiveCanonicalMessageEchoFromSender`
- automated: `IMServerTests+GatewayRouting.crossDeviceReadAdvancesUnreadStateOverSecondTCPConnection`
- automated: `IMServerTests+GatewayRouting.reconnectedDeviceRecoversMissedCanonicalMessagesOverMessagesSince`
- automated: `RedisPresenceIntegrationTests.redisAIStreamLeaseEnforcesDistributedLimitsAndCancellation` when `IM_REDIS_INTEGRATION_URL` is set
- scripted: staging baseline `1 user x 5 devices`
- scripted: staging baseline `100 users x 2 devices`
- scripted: staging baseline `1 group x 500 members x 2 devices`
- scripted: staging baseline `AI stream concurrency`
- scripted: staging baseline `reconnect storm` default recovery probe or custom `IM_RECONNECT_STORM_COMMAND`

## Manual Client Smoke

- iOS and Android can sign in with the same account on different device IDs.
- Canonical echo merges by clientMessageID and does not duplicate in UI.
- Cold start shows cache first, then TCP + HTTP sync converges without duplicate messages.
- Prometheus shows zero cross-node dispatch failures and zero session-count query failures during smoke.
- UI test runner stability is tracked separately; RC gate runs deterministic `IMAppTests` unit tests.
EOF

echo
echo "Release gate report: ${REPORT_FILE}"
