#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULT_ROOT="${RESULT_ROOT:-${SCRIPT_DIR}/results}"
RUN_DIR="${RUN_DIR:-${RESULT_ROOT}/${RUN_ID}}"
DEFAULT_SCENARIOS="login-smoke account-lifecycle-smoke auth-session-smoke auth-session-management-smoke auth-token-rotation-smoke auth-failure-recovery-smoke push-token-smoke client-sync-mix-smoke user-journey-smoke mixed-workload-smoke offline-catchup-smoke inbox-fanout-smoke multi-device-sync-smoke client-health-smoke cold-start-smoke timeline-pagination-smoke timeline-history-scroll-smoke domain-events-smoke read-state-smoke direct-message-lifecycle-smoke search-sync-smoke group-admin-smoke group-membership-smoke group-invite-smoke governance-smoke conversation-preferences-smoke conversation-visibility-smoke message-forward-smoke ai-stream-smoke contact-request-smoke contact-sync-smoke profile-sync-smoke safety-block-smoke safety-block-enforcement-smoke access-control-enforcement-smoke admin-report-smoke media-file-smoke media-failure-recovery-smoke conversation-convergence-smoke small-group-smoke group-delivery-50-5 online-idle-1000 pair-delivery-1000-50"
SCENARIOS="${SCENARIOS:-}"
SCENARIO_GROUPS="${SCENARIO_GROUPS:-}"
PERF_DRY_RUN="${PERF_DRY_RUN:-false}"
STOP_ON_FAILURE="${STOP_ON_FAILURE:-false}"
PERF_PREFLIGHT="${PERF_PREFLIGHT:-true}"
PERF_GATE="${PERF_GATE:-false}"
PERF_GATE_ALLOW_UNKNOWN="${PERF_GATE_ALLOW_UNKNOWN:-false}"
PERF_GATE_ALLOW_ENTRYPOINT_FAILURE="${PERF_GATE_ALLOW_ENTRYPOINT_FAILURE:-false}"
PERF_GATE_ALLOW_UNKNOWN_CATEGORIES="${PERF_GATE_ALLOW_UNKNOWN_CATEGORIES:-}"
PERF_AUDITS="${PERF_AUDITS:-true}"
PERF_TRIAGE="${PERF_TRIAGE:-true}"
PERF_EVIDENCE="${PERF_EVIDENCE:-true}"
PERF_SLO="${PERF_SLO:-true}"
PERF_GLOBAL_STATUS="${PERF_GLOBAL_STATUS:-true}"
PERF_RUN_PLAN="${PERF_RUN_PLAN:-true}"
PERF_PRODUCTION_GATE="${PERF_PRODUCTION_GATE:-true}"
PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE:-normal-product-baseline}"
PERF_PRODUCTION_GATE_REQUIRE_RUN_ARTIFACTS="${PERF_PRODUCTION_GATE_REQUIRE_RUN_ARTIFACTS:-true}"
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS:-604800}"
PERF_CURRENT_READINESS_JSON_EXPLICIT=false
if [[ "${PERF_CURRENT_READINESS_JSON+x}" == "x" || "${CURRENT_PRODUCTION_READINESS_JSON+x}" == "x" ]]; then
  PERF_CURRENT_READINESS_JSON_EXPLICIT=true
fi
PERF_CURRENT_READINESS_JSON="${PERF_CURRENT_READINESS_JSON:-${CURRENT_PRODUCTION_READINESS_JSON:-${RESULT_ROOT}/current-production-readiness/current-production-readiness.json}}"
PERF_CURRENT_READINESS_MAX_AGE_SECONDS="${PERF_CURRENT_READINESS_MAX_AGE_SECONDS:-${CURRENT_PRODUCTION_MAX_AGE_SECONDS:-86400}}"
PERF_CURRENT_READINESS_FUTURE_SKEW_SECONDS="${PERF_CURRENT_READINESS_FUTURE_SKEW_SECONDS:-${CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS:-300}}"
PERF_PRODUCTION_ACCEPTANCE_JSON_EXPLICIT=false
if [[ "${PERF_PRODUCTION_ACCEPTANCE_JSON+x}" == "x" || "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON+x}" == "x" ]]; then
  PERF_PRODUCTION_ACCEPTANCE_JSON_EXPLICIT=true
fi
PERF_PRODUCTION_ACCEPTANCE_JSON="${PERF_PRODUCTION_ACCEPTANCE_JSON:-${PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-${RESULT_ROOT}/production-acceptance/production-acceptance.json}}"

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
IM_COMMAND_BASE_URL="${IM_COMMAND_BASE_URL:-${BASE_URL}}"
TCP_HOST="${TCP_HOST:-}"
TCP_PORT="${TCP_PORT:-9000}"
IM_EMAIL="${IM_EMAIL:-demo@example.com}"
IM_PASSWORD="${IM_PASSWORD:-password1234}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}"
IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}"
K6_BIN="${K6_BIN:-k6}"

host_from_url() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse
import sys

parsed = urlparse(sys.argv[1])
print(parsed.hostname or "")
PY
}

if [[ -z "${TCP_HOST}" ]]; then
  TCP_HOST="$(host_from_url "${BASE_URL}")"
fi
TCP_HOST="${TCP_HOST:-127.0.0.1}"

PERF_PLAN_BASE_URL="${PERF_PLAN_BASE_URL:-${BASE_URL}}"
PERF_PLAN_TCP_HOST="${PERF_PLAN_TCP_HOST:-${TCP_HOST}}"
PERF_PLAN_TCP_PORT="${PERF_PLAN_TCP_PORT:-${TCP_PORT}}"
PERF_PLAN_ACCOUNT_FILE="${PERF_PLAN_ACCOUNT_FILE:-${ACCOUNT_FILE}}"
PERF_PLAN_CONVERSATION_ID="${PERF_PLAN_CONVERSATION_ID:-${IM_CONVERSATION_ID}}"
PERF_PLAN_INTERNAL_SECRET="${PERF_PLAN_INTERNAL_SECRET:-${IM_INTERNAL_SECRET}}"
PERF_PLAN_AUTH_EMAIL_WEBHOOK_URL="${PERF_PLAN_AUTH_EMAIL_WEBHOOK_URL:-${IM_AUTH_EMAIL_WEBHOOK_SINK_URL:-}}"
PERF_PLAN_ACCOUNT_VERIFICATION_CODE="${PERF_PLAN_ACCOUNT_VERIFICATION_CODE:-${IM_ACCOUNT_VERIFICATION_CODE:-}}"
PERF_PLAN_PASSWORD_RESET_CODE="${PERF_PLAN_PASSWORD_RESET_CODE:-${IM_ACCOUNT_PASSWORD_RESET_CODE:-}}"
PERF_PLAN_BLOCKER_MAX_AGE_SECONDS="${PERF_PLAN_BLOCKER_MAX_AGE_SECONDS:-0}"
PERF_PLAN_IGNORE_BLOCKERS_FOR_DIFFERENT_TARGET="${PERF_PLAN_IGNORE_BLOCKERS_FOR_DIFFERENT_TARGET:-false}"
PERF_STATUS_FILTER_TARGET="${PERF_STATUS_FILTER_TARGET:-false}"

ONLINE_HOLD_SECONDS="${ONLINE_HOLD_SECONDS:-600}"
ONLINE_CONNECT_RAMP_SECONDS="${ONLINE_CONNECT_RAMP_SECONDS:-180}"
ONLINE_HEARTBEAT_INTERVAL_SECONDS="${ONLINE_HEARTBEAT_INTERVAL_SECONDS:-30}"
ONLINE_TIMEOUT_SECONDS="${ONLINE_TIMEOUT_SECONDS:-240}"
RECONNECT_HOLD_SECONDS="${RECONNECT_HOLD_SECONDS:-${ONLINE_HOLD_SECONDS}}"
RECONNECT_CONNECT_RAMP_SECONDS="${RECONNECT_CONNECT_RAMP_SECONDS:-${ONLINE_CONNECT_RAMP_SECONDS}}"
RECONNECT_HEARTBEAT_INTERVAL_SECONDS="${RECONNECT_HEARTBEAT_INTERVAL_SECONDS:-15}"
RECONNECT_TIMEOUT_SECONDS="${RECONNECT_TIMEOUT_SECONDS:-${ONLINE_TIMEOUT_SECONDS}}"
RECONNECT_MAX_RECONNECTS="${RECONNECT_MAX_RECONNECTS:-3}"
RECONNECT_DELAY_MS="${RECONNECT_DELAY_MS:-1000}"

MESSAGE_HOLD_SECONDS="${MESSAGE_HOLD_SECONDS:-600}"
MESSAGE_CONNECT_RAMP_SECONDS="${MESSAGE_CONNECT_RAMP_SECONDS:-180}"
MESSAGE_HEARTBEAT_INTERVAL_SECONDS="${MESSAGE_HEARTBEAT_INTERVAL_SECONDS:-15}"
MESSAGE_COMPLETION_MODE="${MESSAGE_COMPLETION_MODE:-full}"
GROUP_DELIVERY_HOLD_SECONDS="${GROUP_DELIVERY_HOLD_SECONDS:-${MESSAGE_HOLD_SECONDS}}"
GROUP_DELIVERY_CONNECT_RAMP_SECONDS="${GROUP_DELIVERY_CONNECT_RAMP_SECONDS:-${MESSAGE_CONNECT_RAMP_SECONDS}}"
GROUP_DELIVERY_COMPLETION_MODE="${GROUP_DELIVERY_COMPLETION_MODE:-full}"

LARGE_GROUP_HOLD_SECONDS="${LARGE_GROUP_HOLD_SECONDS:-600}"
LARGE_GROUP_CONNECT_RAMP_SECONDS="${LARGE_GROUP_CONNECT_RAMP_SECONDS:-300}"
LARGE_GROUP_COMPLETION_MODE="${LARGE_GROUP_COMPLETION_MODE:-ack-only}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

latest_existing_file() {
  python3 - "$@" <<'PY'
from __future__ import annotations

import glob
import sys
from pathlib import Path

candidates: list[tuple[float, str]] = []
for pattern in sys.argv[1:]:
    for raw in glob.glob(pattern):
        path = Path(raw).expanduser()
        if not path.is_file():
            continue
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        candidates.append((mtime, str(path)))
if candidates:
    print(sorted(candidates)[-1][1])
PY
}

current_readiness_receipt_for_state_summary() {
  if [[ -f "${PERF_CURRENT_READINESS_JSON}" ]]; then
    printf '%s\n' "${PERF_CURRENT_READINESS_JSON}"
    return 0
  fi
  if bool_enabled "${PERF_CURRENT_READINESS_JSON_EXPLICIT}"; then
    return 0
  fi
  latest_existing_file \
    "${RESULT_ROOT}/current-production-readiness*/current-production-readiness.json" \
    "${RESULT_ROOT}/production-acceptance/*/current-production-readiness.json"
}

production_acceptance_receipt_for_state_summary() {
  if [[ -f "${PERF_PRODUCTION_ACCEPTANCE_JSON}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_ACCEPTANCE_JSON}"
    return 0
  fi
  if bool_enabled "${PERF_PRODUCTION_ACCEPTANCE_JSON_EXPLICIT}"; then
    return 0
  fi
  latest_existing_file \
    "${RESULT_ROOT}/production-acceptance/*/production-acceptance.json" \
    "${RESULT_ROOT}/production-acceptance*/production-acceptance.json"
}

scenario_group_items() {
  case "$1" in
    http-smoke)
      printf '%s\n' "login-smoke account-lifecycle-smoke auth-session-smoke auth-session-management-smoke auth-token-rotation-smoke auth-failure-recovery-smoke push-token-smoke client-sync-mix-smoke user-journey-smoke mixed-workload-smoke offline-catchup-smoke inbox-fanout-smoke multi-device-sync-smoke client-health-smoke cold-start-smoke timeline-pagination-smoke timeline-history-scroll-smoke domain-events-smoke read-state-smoke direct-message-lifecycle-smoke search-sync-smoke group-admin-smoke group-membership-smoke group-invite-smoke governance-smoke conversation-preferences-smoke conversation-visibility-smoke message-forward-smoke ai-stream-smoke contact-request-smoke contact-sync-smoke profile-sync-smoke safety-block-smoke safety-block-enforcement-smoke access-control-enforcement-smoke admin-report-smoke media-file-smoke media-failure-recovery-smoke conversation-convergence-smoke direct-convergence-smoke small-group-smoke hot-write-smoke"
      ;;
    http-baseline)
      printf '%s\n' "login-baseline account-lifecycle-baseline auth-session-baseline auth-session-management-baseline auth-token-rotation-baseline auth-failure-recovery-baseline push-token-baseline client-sync-mix-baseline user-journey-baseline mixed-workload-baseline offline-catchup-baseline inbox-fanout-baseline multi-device-sync-baseline client-health-baseline cold-start-baseline timeline-pagination-baseline timeline-history-scroll-baseline domain-events-baseline read-state-baseline direct-message-lifecycle-baseline search-sync-baseline group-admin-baseline group-membership-baseline group-invite-baseline governance-baseline conversation-preferences-baseline conversation-visibility-baseline message-forward-baseline ai-stream-baseline contact-request-baseline contact-sync-baseline profile-sync-baseline safety-block-baseline safety-block-enforcement-baseline access-control-enforcement-baseline admin-report-baseline media-file-baseline media-failure-recovery-baseline direct-convergence-baseline conversation-convergence-baseline small-group-baseline hot-write-baseline"
      ;;
    http-capacity)
      printf '%s\n' "login-capacity account-lifecycle-capacity auth-session-capacity auth-session-management-capacity auth-token-rotation-capacity auth-failure-recovery-capacity push-token-capacity client-sync-mix-capacity user-journey-capacity mixed-workload-capacity offline-catchup-capacity inbox-fanout-capacity multi-device-sync-capacity client-health-capacity cold-start-capacity timeline-pagination-capacity timeline-history-scroll-capacity domain-events-capacity read-state-capacity direct-message-lifecycle-capacity search-sync-capacity group-admin-capacity group-membership-capacity group-invite-capacity governance-capacity conversation-preferences-capacity conversation-visibility-capacity message-forward-capacity ai-stream-capacity contact-request-capacity contact-sync-capacity profile-sync-capacity safety-block-capacity safety-block-enforcement-capacity access-control-enforcement-capacity admin-report-capacity media-file-capacity media-failure-recovery-capacity conversation-convergence-capacity direct-convergence-capacity small-group-capacity hot-write-capacity"
      ;;
    auth-confirm)
      printf '%s\n' "account-lifecycle-confirm-smoke account-lifecycle-confirm-baseline account-lifecycle-confirm-capacity"
      ;;
    account-security)
      printf '%s\n' "login-smoke auth-session-smoke auth-session-management-smoke auth-token-rotation-smoke auth-failure-recovery-smoke push-token-smoke account-lifecycle-smoke"
      ;;
    account-security-baseline)
      printf '%s\n' "login-baseline auth-session-baseline auth-session-management-baseline auth-token-rotation-baseline auth-failure-recovery-baseline push-token-baseline account-lifecycle-baseline"
      ;;
    direct-chat)
      printf '%s\n' "direct-convergence-smoke direct-message-lifecycle-smoke read-state-smoke conversation-preferences-smoke conversation-visibility-smoke message-forward-smoke pair-delivery-1000-10 multi-device-delivery-100x2-10"
      ;;
    direct-chat-baseline)
      printf '%s\n' "direct-convergence-baseline direct-message-lifecycle-baseline read-state-baseline conversation-preferences-baseline conversation-visibility-baseline message-forward-baseline pair-delivery-1000-50 multi-device-delivery-100x2-10"
      ;;
    daily-core-smoke)
      printf '%s\n' "login-smoke auth-session-smoke push-token-smoke client-sync-mix-smoke user-journey-smoke offline-catchup-smoke inbox-fanout-smoke direct-convergence-smoke direct-message-lifecycle-smoke read-state-smoke small-group-smoke contact-sync-smoke online-idle-1000 pair-delivery-1000-10"
      ;;
    daily-core-baseline)
      printf '%s\n' "login-baseline auth-session-baseline push-token-baseline client-sync-mix-baseline user-journey-baseline offline-catchup-baseline inbox-fanout-baseline direct-convergence-baseline direct-message-lifecycle-baseline read-state-baseline small-group-baseline contact-sync-baseline online-idle-5000 pair-delivery-1000-50"
      ;;
    daily-traffic-smoke)
      printf '%s\n' "user-journey-smoke mixed-workload-smoke inbox-fanout-smoke offline-catchup-smoke direct-message-lifecycle-smoke read-state-smoke small-group-smoke online-idle-1000 pair-delivery-1000-10 multi-device-delivery-100x2-10"
      ;;
    daily-traffic-baseline)
      printf '%s\n' "user-journey-baseline mixed-workload-baseline inbox-fanout-baseline offline-catchup-baseline direct-message-lifecycle-baseline read-state-baseline small-group-baseline online-idle-5000 online-chat-mix-5000-10 pair-delivery-1000-50 multi-device-delivery-500x2-20"
      ;;
    message-spike-smoke)
      printf '%s\n' "direct-convergence-smoke direct-message-lifecycle-smoke hot-write-smoke pair-delivery-1000-50 direct-burst-1000-100"
      ;;
    message-spike)
      printf '%s\n' "$(scenario_group_items message-spike-smoke)"
      ;;
    message-spike-baseline)
      printf '%s\n' "direct-convergence-baseline direct-message-lifecycle-baseline hot-write-baseline pair-delivery-2000-50 direct-burst-1000-200"
      ;;
    reliability-recovery-smoke)
      printf '%s\n' "auth-token-rotation-smoke auth-failure-recovery-smoke offline-catchup-smoke multi-device-sync-smoke client-health-smoke cold-start-smoke timeline-pagination-smoke timeline-history-scroll-smoke domain-events-smoke media-failure-recovery-smoke reconnect-soak-1000 reconnect-drill-1000"
      ;;
    reliability-recovery)
      printf '%s\n' "$(scenario_group_items reliability-recovery-smoke)"
      ;;
    reliability-recovery-baseline)
      printf '%s\n' "auth-token-rotation-baseline auth-failure-recovery-baseline offline-catchup-baseline multi-device-sync-baseline client-health-baseline cold-start-baseline timeline-pagination-baseline timeline-history-scroll-baseline domain-events-baseline media-failure-recovery-baseline reconnect-soak-5000"
      ;;
    lifecycle-governance-smoke)
      printf '%s\n' "account-lifecycle-smoke auth-session-management-smoke contact-request-smoke contact-sync-smoke profile-sync-smoke group-admin-smoke group-membership-smoke group-invite-smoke governance-smoke conversation-preferences-smoke conversation-visibility-smoke safety-block-smoke safety-block-enforcement-smoke access-control-enforcement-smoke admin-report-smoke"
      ;;
    lifecycle-governance)
      printf '%s\n' "$(scenario_group_items lifecycle-governance-smoke)"
      ;;
    lifecycle-governance-baseline)
      printf '%s\n' "account-lifecycle-baseline auth-session-management-baseline contact-request-baseline contact-sync-baseline profile-sync-baseline group-admin-baseline group-membership-baseline group-invite-baseline governance-baseline conversation-preferences-baseline conversation-visibility-baseline safety-block-baseline safety-block-enforcement-baseline access-control-enforcement-baseline admin-report-baseline"
      ;;
    sync-read)
      printf '%s\n' "client-sync-mix-smoke user-journey-smoke mixed-workload-smoke offline-catchup-smoke inbox-fanout-smoke multi-device-sync-smoke cold-start-smoke timeline-pagination-smoke timeline-history-scroll-smoke domain-events-smoke client-health-smoke"
      ;;
    sync-read-baseline)
      printf '%s\n' "client-sync-mix-baseline user-journey-baseline mixed-workload-baseline offline-catchup-baseline inbox-fanout-baseline multi-device-sync-baseline cold-start-baseline timeline-pagination-baseline timeline-history-scroll-baseline domain-events-baseline client-health-baseline"
      ;;
    group-workflow)
      printf '%s\n' "small-group-smoke conversation-convergence-smoke group-admin-smoke group-membership-smoke group-invite-smoke governance-smoke access-control-enforcement-smoke group-delivery-50-5"
      ;;
    group-workflow-baseline)
      printf '%s\n' "small-group-baseline conversation-convergence-baseline group-admin-baseline group-membership-baseline group-invite-baseline governance-baseline access-control-enforcement-baseline group-delivery-500-10"
      ;;
    contacts-social)
      printf '%s\n' "contact-request-smoke contact-sync-smoke profile-sync-smoke safety-block-smoke safety-block-enforcement-smoke"
      ;;
    contacts-social-baseline)
      printf '%s\n' "contact-request-baseline contact-sync-baseline profile-sync-baseline safety-block-baseline safety-block-enforcement-baseline"
      ;;
    media-ai-admin)
      printf '%s\n' "media-file-smoke media-failure-recovery-smoke ai-stream-smoke admin-report-smoke search-sync-smoke"
      ;;
    media-ai-admin-baseline)
      printf '%s\n' "media-file-baseline media-failure-recovery-baseline ai-stream-baseline admin-report-baseline search-sync-baseline"
      ;;
    product-smoke)
      printf '%s\n' "$(scenario_group_items account-security) $(scenario_group_items sync-read) $(scenario_group_items direct-chat) $(scenario_group_items group-workflow) $(scenario_group_items contacts-social) $(scenario_group_items media-ai-admin) online-idle-1000 reconnect-soak-1000"
      ;;
    product-baseline)
      printf '%s\n' "$(scenario_group_items account-security-baseline) $(scenario_group_items sync-read-baseline) $(scenario_group_items direct-chat-baseline) $(scenario_group_items group-workflow-baseline) $(scenario_group_items contacts-social-baseline) $(scenario_group_items media-ai-admin-baseline) online-idle-5000 reconnect-soak-5000"
      ;;
    product-breadth-smoke)
      printf '%s\n' "$(scenario_group_items http-smoke) $(scenario_group_items tcp-smoke)"
      ;;
    product-breadth-baseline)
      printf '%s\n' "$(scenario_group_items http-baseline) online-idle-5000 reconnect-soak-5000 multi-device-online-100x2 multi-device-delivery-100x2-10 group-delivery-500-10 pair-delivery-1000-50 pair-delivery-2000-50"
      ;;
    product-breadth-capacity)
      printf '%s\n' "$(scenario_group_items http-capacity) online-idle-5000 reconnect-soak-5000 multi-device-online-100x2 multi-device-delivery-100x2-10 group-delivery-500-30 pair-delivery-1000-100 pair-delivery-3000-50"
      ;;
    normal-product-smoke)
      printf '%s\n' "$(scenario_group_items product-breadth-smoke)"
      ;;
    normal-product-baseline)
      printf '%s\n' "$(scenario_group_items product-breadth-baseline)"
      ;;
    normal-product-capacity)
      printf '%s\n' "$(scenario_group_items product-breadth-capacity)"
      ;;
    tcp-smoke)
      printf '%s\n' "online-idle-1000 reconnect-soak-1000 multi-device-online-1x5 multi-device-online-100x2 multi-device-delivery-100x2-10 group-delivery-50-5 pair-delivery-1000-10"
      ;;
    tcp-baseline)
      printf '%s\n' "online-idle-5000 reconnect-soak-5000 multi-device-online-100x2 multi-device-delivery-100x2-10 group-delivery-500-10 pair-delivery-1000-50 pair-delivery-2000-50 large-group-1000-50"
      ;;
    real-world-smoke)
      printf '%s\n' "login-smoke auth-session-smoke auth-token-rotation-smoke auth-failure-recovery-smoke push-token-smoke client-sync-mix-smoke user-journey-smoke mixed-workload-smoke offline-catchup-smoke inbox-fanout-smoke multi-device-sync-smoke direct-convergence-smoke direct-message-lifecycle-smoke read-state-smoke conversation-preferences-smoke conversation-visibility-smoke contact-sync-smoke profile-sync-smoke media-file-smoke media-failure-recovery-smoke online-idle-1000 multi-device-delivery-100x2-10 group-delivery-50-5 pair-delivery-1000-10"
      ;;
    real-world-baseline)
      printf '%s\n' "login-baseline auth-session-baseline auth-token-rotation-baseline auth-failure-recovery-baseline push-token-baseline client-sync-mix-baseline user-journey-baseline mixed-workload-baseline offline-catchup-baseline inbox-fanout-baseline multi-device-sync-baseline direct-convergence-baseline direct-message-lifecycle-baseline read-state-baseline conversation-preferences-baseline conversation-visibility-baseline contact-sync-baseline profile-sync-baseline media-file-baseline media-failure-recovery-baseline online-idle-5000 multi-device-delivery-100x2-10 group-delivery-500-10 pair-delivery-1000-50"
      ;;
    real-world-capacity)
      printf '%s\n' "login-capacity auth-session-capacity auth-token-rotation-capacity auth-failure-recovery-capacity push-token-capacity client-sync-mix-capacity user-journey-capacity mixed-workload-capacity offline-catchup-capacity inbox-fanout-capacity multi-device-sync-capacity direct-convergence-capacity direct-message-lifecycle-capacity read-state-capacity conversation-preferences-capacity conversation-visibility-capacity contact-sync-capacity profile-sync-capacity media-file-capacity media-failure-recovery-capacity online-idle-5000 reconnect-soak-5000 multi-device-delivery-100x2-10 group-delivery-500-30 pair-delivery-1000-100 pair-delivery-3000-50"
      ;;
    non-large-group-smoke)
      printf '%s\n' "$(scenario_group_items account-security) $(scenario_group_items sync-read) $(scenario_group_items direct-chat) $(scenario_group_items group-workflow) $(scenario_group_items contacts-social) $(scenario_group_items media-ai-admin) $(scenario_group_items tcp-smoke)"
      ;;
    non-large-group-baseline)
      printf '%s\n' "$(scenario_group_items account-security-baseline) $(scenario_group_items sync-read-baseline) $(scenario_group_items direct-chat-baseline) $(scenario_group_items group-workflow-baseline) $(scenario_group_items contacts-social-baseline) $(scenario_group_items media-ai-admin-baseline) online-idle-5000 reconnect-soak-5000 multi-device-online-100x2 multi-device-delivery-100x2-10 group-delivery-500-10 pair-delivery-1000-50 pair-delivery-2000-50"
      ;;
    non-large-group-capacity)
      printf '%s\n' "$(scenario_group_items http-capacity) online-idle-5000 reconnect-soak-5000 multi-device-online-100x2 multi-device-delivery-100x2-10 group-delivery-500-30 pair-delivery-1000-100 pair-delivery-3000-50"
      ;;
    sync-recovery)
      printf '%s\n' "client-sync-mix-smoke mixed-workload-smoke offline-catchup-smoke inbox-fanout-smoke multi-device-sync-smoke cold-start-smoke timeline-pagination-smoke timeline-history-scroll-smoke domain-events-smoke read-state-smoke client-health-smoke"
      ;;
    sync-recovery-baseline)
      printf '%s\n' "client-sync-mix-baseline mixed-workload-baseline offline-catchup-baseline inbox-fanout-baseline multi-device-sync-baseline cold-start-baseline timeline-pagination-baseline timeline-history-scroll-baseline domain-events-baseline read-state-baseline client-health-baseline reconnect-soak-5000"
      ;;
    message-workflow)
      printf '%s\n' "direct-convergence-smoke direct-message-lifecycle-smoke conversation-convergence-smoke offline-catchup-smoke read-state-smoke search-sync-smoke governance-smoke conversation-preferences-smoke conversation-visibility-smoke message-forward-smoke small-group-smoke group-delivery-50-5 pair-delivery-1000-10"
      ;;
    message-workflow-baseline)
      printf '%s\n' "direct-convergence-baseline direct-message-lifecycle-baseline conversation-convergence-baseline offline-catchup-baseline read-state-baseline search-sync-baseline governance-baseline conversation-preferences-baseline conversation-visibility-baseline message-forward-baseline small-group-baseline group-delivery-500-10 online-chat-mix-5000-10 pair-delivery-1000-50 pair-delivery-2000-50"
      ;;
    social-profile)
      printf '%s\n' "contact-request-smoke contact-sync-smoke profile-sync-smoke safety-block-smoke safety-block-enforcement-smoke access-control-enforcement-smoke"
      ;;
    social-profile-baseline)
      printf '%s\n' "contact-request-baseline contact-sync-baseline profile-sync-baseline safety-block-baseline safety-block-enforcement-baseline access-control-enforcement-baseline"
      ;;
    realtime-direct)
      printf '%s\n' "online-idle-1000 reconnect-soak-1000 reconnect-drill-1000 multi-device-online-1x5 multi-device-online-100x2 multi-device-delivery-100x2-10 pair-delivery-1000-10 pair-delivery-1000-50"
      ;;
    realtime-direct-baseline)
      printf '%s\n' "online-idle-5000 reconnect-soak-5000 multi-device-online-100x2 multi-device-delivery-100x2-10 multi-device-delivery-500x2-20 online-chat-mix-5000-10 pair-delivery-1000-50 pair-delivery-2000-50 pair-delivery-5000-50"
      ;;
    group-delivery-smoke)
      printf '%s\n' "group-delivery-50-5 group-delivery-100-10"
      ;;
    group-delivery)
      printf '%s\n' "$(scenario_group_items group-delivery-smoke)"
      ;;
    group-delivery-baseline)
      printf '%s\n' "group-delivery-100-10 group-delivery-500-10"
      ;;
    group-delivery-capacity)
      printf '%s\n' "group-delivery-500-10 group-delivery-500-30"
      ;;
    im-scenario-breadth-smoke)
      printf '%s\n' "$(scenario_group_items product-breadth-smoke)"
      ;;
    im-scenario-breadth-baseline)
      printf '%s\n' "$(scenario_group_items product-breadth-baseline)"
      ;;
    im-scenario-breadth-capacity)
      printf '%s\n' "$(scenario_group_items product-breadth-capacity)"
      ;;
    large-group)
      printf '%s\n' "large-group-1000-10 large-group-1000-50 large-group-5000-50 large-group-10000-5 large-group-10000-10 large-group-10000-200"
      ;;
    all-smoke)
      printf '%s\n' "$(scenario_group_items http-smoke) $(scenario_group_items tcp-smoke)"
      ;;
    all-baseline)
      printf '%s\n' "$(scenario_group_items http-baseline) $(scenario_group_items tcp-baseline)"
      ;;
    *)
      echo "Unknown scenario group: $1" >&2
      echo "Use --list to see available groups." >&2
      return 2
      ;;
  esac
}

expand_scenario_groups() {
  local expanded=()
  local group item
  for group in "$@"; do
    for item in $(scenario_group_items "${group}"); do
      expanded+=("${item}")
    done
  done
  if ((${#expanded[@]} == 0)); then
    return 0
  fi
  printf '%s\n' "${expanded[@]}" | awk '!seen[$0]++' | paste -sd' ' -
}

usage() {
  cat <<'EOF'
Usage:
  run_perf_scenarios.sh [--list|--expand-groups]

Common env:
  RESULT_ROOT=IMServer/LoadTests/results
  RUN_ID=manual-001
  SCENARIOS="login-smoke cold-start-smoke online-idle-1000 pair-delivery-1000-50"
  SCENARIO_GROUPS="http-smoke tcp-smoke"
  PERF_DRY_RUN=true|false
  PERF_PREFLIGHT=true|false
  PERF_GATE=true|false
  PERF_GATE_ALLOW_UNKNOWN=true|false
  PERF_GATE_ALLOW_ENTRYPOINT_FAILURE=true|false
  PERF_GATE_ALLOW_UNKNOWN_CATEGORIES="category-a category-b"
  PERF_AUDITS=true|false
  PERF_TRIAGE=true|false
  PERF_EVIDENCE=true|false
  PERF_SLO=true|false
  PERF_GLOBAL_STATUS=true|false
  PERF_RUN_PLAN=true|false
  PERF_PRODUCTION_GATE=true|false
  PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline
  PERF_PRODUCTION_GATE_REQUIRE_RUN_ARTIFACTS=true|false
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=604800
  PERF_PLAN_BASE_URL=http://host:8080
  PERF_PLAN_TCP_HOST=host
  PERF_PLAN_ACCOUNT_FILE=/path/load-5000.csv
  PERF_PLAN_BLOCKER_MAX_AGE_SECONDS=0
  PERF_PLAN_IGNORE_BLOCKERS_FOR_DIFFERENT_TARGET=false
  PERF_STATUS_FILTER_TARGET=false
  STOP_ON_FAILURE=true|false
  BASE_URL=http://host:8080
  TCP_HOST=host
  TCP_PORT=9000
  ACCOUNT_FILE=/path/load-5000.csv
  IM_CONVERSATION_ID=<uuid>
  IM_INTERNAL_SECRET=<secret>

Available scenario groups:
  http-smoke
  http-baseline
  http-capacity
  auth-confirm
  account-security
  account-security-baseline
  direct-chat
  direct-chat-baseline
  daily-core-smoke
  daily-core-baseline
  reliability-recovery-smoke
  reliability-recovery
  reliability-recovery-baseline
  lifecycle-governance-smoke
  lifecycle-governance
  lifecycle-governance-baseline
  sync-read
  sync-read-baseline
  group-workflow
  group-workflow-baseline
  contacts-social
  contacts-social-baseline
  media-ai-admin
  media-ai-admin-baseline
  product-smoke
  product-baseline
  product-breadth-smoke
  product-breadth-baseline
  product-breadth-capacity
  normal-product-smoke
  normal-product-baseline
  normal-product-capacity
  daily-traffic-smoke
  daily-traffic-baseline
  message-spike-smoke
  message-spike
  message-spike-baseline
  tcp-smoke
  tcp-baseline
  real-world-smoke
  real-world-baseline
  real-world-capacity
  non-large-group-smoke
  non-large-group-baseline
  non-large-group-capacity
  sync-recovery
  sync-recovery-baseline
  message-workflow
  message-workflow-baseline
  social-profile
  social-profile-baseline
  realtime-direct
  realtime-direct-baseline
  group-delivery-smoke
  group-delivery
  group-delivery-baseline
  group-delivery-capacity
  im-scenario-breadth-smoke
  im-scenario-breadth-baseline
  im-scenario-breadth-capacity
  large-group
  all-smoke
  all-baseline

Available scenarios:
  login-smoke
  login-baseline
  login-capacity
  account-lifecycle-smoke
  account-lifecycle-baseline
  account-lifecycle-capacity
  account-lifecycle-confirm-smoke
  account-lifecycle-confirm-baseline
  account-lifecycle-confirm-capacity
  auth-session-smoke
  auth-session-baseline
  auth-session-capacity
  auth-session-management-smoke
  auth-session-management-baseline
  auth-session-management-capacity
  auth-token-rotation-smoke
  auth-token-rotation-baseline
  auth-token-rotation-capacity
  auth-failure-recovery-smoke
  auth-failure-recovery-baseline
  auth-failure-recovery-capacity
  push-token-smoke
  push-token-baseline
  push-token-capacity
  client-health-smoke
  client-health-baseline
  client-health-capacity
  client-sync-mix-smoke
  client-sync-mix-baseline
  client-sync-mix-capacity
  user-journey-smoke
  user-journey-baseline
  user-journey-capacity
  mixed-workload-smoke
  mixed-workload-baseline
  mixed-workload-capacity
  offline-catchup-smoke
  offline-catchup-baseline
  offline-catchup-capacity
  inbox-fanout-smoke
  inbox-fanout-baseline
  inbox-fanout-capacity
  multi-device-sync-smoke
  multi-device-sync-baseline
  multi-device-sync-capacity
  conversation-convergence-smoke
  conversation-convergence-baseline
  conversation-convergence-capacity
  direct-convergence-smoke
  direct-convergence-baseline
  direct-convergence-capacity
  cold-start-smoke
  cold-start-baseline
  cold-start-capacity
  timeline-pagination-smoke
  timeline-pagination-baseline
  timeline-pagination-capacity
  timeline-history-scroll-smoke
  timeline-history-scroll-baseline
  timeline-history-scroll-capacity
  domain-events-smoke
  domain-events-baseline
  domain-events-capacity
  read-state-smoke
  read-state-baseline
  read-state-capacity
  direct-message-lifecycle-smoke
  direct-message-lifecycle-baseline
  direct-message-lifecycle-capacity
  search-sync-smoke
  search-sync-baseline
  search-sync-capacity
  group-admin-smoke
  group-admin-baseline
  group-admin-capacity
  group-membership-smoke
  group-membership-baseline
  group-membership-capacity
  group-invite-smoke
  group-invite-baseline
  group-invite-capacity
  governance-smoke
  governance-baseline
  governance-capacity
  conversation-preferences-smoke
  conversation-preferences-baseline
  conversation-preferences-capacity
  conversation-visibility-smoke
  conversation-visibility-baseline
  conversation-visibility-capacity
  message-forward-smoke
  message-forward-baseline
  message-forward-capacity
  ai-stream-smoke
  ai-stream-baseline
  ai-stream-capacity
  contact-request-smoke
  contact-request-baseline
  contact-request-capacity
  contact-sync-smoke
  contact-sync-baseline
  contact-sync-capacity
  profile-sync-smoke
  profile-sync-baseline
  profile-sync-capacity
  safety-block-smoke
  safety-block-baseline
  safety-block-capacity
  safety-block-enforcement-smoke
  safety-block-enforcement-baseline
  safety-block-enforcement-capacity
  access-control-enforcement-smoke
  access-control-enforcement-baseline
  access-control-enforcement-capacity
  admin-report-smoke
  admin-report-baseline
  admin-report-capacity
  media-file-smoke
  media-file-baseline
  media-file-capacity
  media-failure-recovery-smoke
  media-failure-recovery-baseline
  media-failure-recovery-capacity
  small-group-smoke
  small-group-baseline
  small-group-capacity
  hot-write-smoke
  hot-write-baseline
  hot-write-capacity
  online-idle-1000
  online-idle-5000
  online-idle-10000
  reconnect-soak-1000
  reconnect-soak-5000
  reconnect-drill-1000
  multi-device-online-1x5
  multi-device-online-100x2
  multi-device-delivery-100x2-10
  multi-device-delivery-500x2-20
  pair-delivery-1000-10
  pair-delivery-1000-50
  pair-delivery-1000-100
  pair-delivery-2000-50
  pair-delivery-3000-50
  pair-delivery-5000-50
  online-chat-mix-5000-10
  direct-burst-1000-100
  direct-burst-1000-200
  group-delivery-50-5
  group-delivery-100-10
  group-delivery-500-10
  group-delivery-500-30
  large-group-1000-10
  large-group-1000-50
  large-group-5000-50
  large-group-10000-5
  large-group-10000-10
  large-group-10000-200
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--list" ]]; then
  usage | sed -n '/Available scenario groups:/,$p'
  exit 0
fi

if [[ "${1:-}" == "--expand-groups" ]]; then
  if [[ -z "${SCENARIO_GROUPS}" ]]; then
    echo "SCENARIO_GROUPS is required for --expand-groups." >&2
    exit 2
  fi
  expand_scenario_groups ${SCENARIO_GROUPS}
  exit 0
fi

if [[ -z "${SCENARIOS}" ]]; then
  if [[ -n "${SCENARIO_GROUPS}" ]]; then
    SCENARIOS="$(expand_scenario_groups ${SCENARIO_GROUPS})"
  else
    SCENARIOS="${DEFAULT_SCENARIOS}"
  fi
fi

mkdir -p "${RUN_DIR}"
printf '%s\n' "${SCENARIOS}" >"${RUN_DIR}/scenarios.txt"

write_json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

first_account_email() {
  if [[ -n "${ACCOUNT_FILE}" && -f "${ACCOUNT_FILE}" ]]; then
    awk -F',' 'NF >= 2 && $1 !~ /^#/ { print $1; exit }' "${ACCOUNT_FILE}"
  else
    printf '%s\n' "${IM_EMAIL}"
  fi
}

first_account_password() {
  if [[ -n "${ACCOUNT_FILE}" && -f "${ACCOUNT_FILE}" ]]; then
    awk -F',' 'NF >= 2 && $1 !~ /^#/ { print $2; exit }' "${ACCOUNT_FILE}"
  else
    printf '%s\n' "${IM_PASSWORD}"
  fi
}

generate_post_report_artifacts() {
  if [[ ! -f "${RUN_DIR}/report.json" ]]; then
    return 0
  fi

  if bool_enabled "${PERF_AUDITS}"; then
    python3 "${SCRIPT_DIR}/perf_coverage.py" \
      --output "${RUN_DIR}/coverage.md" \
      --json-output "${RUN_DIR}/coverage.json" \
      --csv-output "${RUN_DIR}/coverage.csv" \
      --strict >"${RUN_DIR}/coverage.log" 2>&1 || true
    python3 "${SCRIPT_DIR}/perf_route_audit.py" \
      --output "${RUN_DIR}/route-audit.md" \
      --json-output "${RUN_DIR}/route-audit.json" \
      --csv-output "${RUN_DIR}/route-audit.csv" \
      --strict \
      --fail-on-orphan >"${RUN_DIR}/route-audit.log" 2>&1 || true
    python3 "${SCRIPT_DIR}/perf_matrix_audit.py" \
      --script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      --k6-dir "${SCRIPT_DIR}/k6" \
      --output "${RUN_DIR}/matrix-audit.md" \
      --json-output "${RUN_DIR}/matrix-audit.json" \
      --csv-output "${RUN_DIR}/matrix-audit.csv" \
      --strict >"${RUN_DIR}/matrix-audit.log" 2>&1 || true
    python3 "${SCRIPT_DIR}/perf_scenario_catalog.py" \
      --script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      --output "${RUN_DIR}/scenario-catalog.md" \
      --json-output "${RUN_DIR}/scenario-catalog.json" \
      --csv-output "${RUN_DIR}/scenario-catalog.csv" >"${RUN_DIR}/scenario-catalog.log" 2>&1 || true
  fi

  if bool_enabled "${PERF_TRIAGE}"; then
    python3 "${SCRIPT_DIR}/perf_triage.py" \
      --report "${RUN_DIR}/report.json" \
      --output "${RUN_DIR}/triage.md" \
      --json-output "${RUN_DIR}/triage.json" \
      --csv-output "${RUN_DIR}/triage.csv" >"${RUN_DIR}/triage.log" 2>&1 || true
  fi

  if bool_enabled "${PERF_SLO}"; then
    python3 "${SCRIPT_DIR}/perf_slo_report.py" \
      --report "${RUN_DIR}/report.json" \
      --output "${RUN_DIR}/slo.md" \
      --json-output "${RUN_DIR}/slo.json" \
      --csv-output "${RUN_DIR}/slo.csv" >"${RUN_DIR}/slo.log" 2>&1 || true
  fi

  if bool_enabled "${PERF_EVIDENCE}"; then
    local evidence_args=(
      --report "${RUN_DIR}/report.json"
      --output "${RUN_DIR}/evidence.md"
      --json-output "${RUN_DIR}/evidence.json"
    )
    [[ -f "${RUN_DIR}/triage.json" ]] && evidence_args+=(--triage-json "${RUN_DIR}/triage.json")
    [[ -f "${RUN_DIR}/coverage.json" ]] && evidence_args+=(--coverage-json "${RUN_DIR}/coverage.json")
    [[ -f "${RUN_DIR}/route-audit.json" ]] && evidence_args+=(--route-audit-json "${RUN_DIR}/route-audit.json")
    [[ -f "${RUN_DIR}/matrix-audit.json" ]] && evidence_args+=(--matrix-audit-json "${RUN_DIR}/matrix-audit.json")
    python3 "${SCRIPT_DIR}/perf_evidence_bundle.py" "${evidence_args[@]}" >"${RUN_DIR}/evidence.log" 2>&1 || true
  fi

  if bool_enabled "${PERF_GLOBAL_STATUS}"; then
    scenario_status_args=(
      --results-dir "${RESULT_ROOT}"
      --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh"
      --output "${RESULT_ROOT}/scenario-status.md"
      --json-output "${RESULT_ROOT}/scenario-status.json"
      --csv-output "${RESULT_ROOT}/scenario-status.csv"
    )
    if bool_enabled "${PERF_STATUS_FILTER_TARGET}"; then
      scenario_status_args+=(
        --filter-target
        --base-url "${BASE_URL}"
        --tcp-host "${TCP_HOST}"
        --tcp-port "${TCP_PORT}"
      )
    fi
    python3 "${SCRIPT_DIR}/perf_scenario_status.py" "${scenario_status_args[@]}" >"${RUN_DIR}/scenario-status.log" 2>&1 || true
    if bool_enabled "${PERF_SLO}"; then
      slo_status_args=(
        --results-dir "${RESULT_ROOT}"
        --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh"
        --output "${RESULT_ROOT}/slo-status.md"
        --json-output "${RESULT_ROOT}/slo-status.json"
        --csv-output "${RESULT_ROOT}/slo-status.csv"
      )
      if bool_enabled "${PERF_STATUS_FILTER_TARGET}"; then
        slo_status_args+=(
          --filter-target
          --base-url "${BASE_URL}"
          --tcp-host "${TCP_HOST}"
          --tcp-port "${TCP_PORT}"
        )
      fi
      python3 "${SCRIPT_DIR}/perf_slo_status.py" "${slo_status_args[@]}" >"${RUN_DIR}/slo-status.log" 2>&1 || true
      if [[ -f "${RESULT_ROOT}/slo-status.json" ]]; then
        python3 "${SCRIPT_DIR}/perf_slo_domain_scorecard.py" \
          --slo-status-json "${RESULT_ROOT}/slo-status.json" \
          --output "${RESULT_ROOT}/slo-domain-scorecard.md" \
          --json-output "${RESULT_ROOT}/slo-domain-scorecard.json" \
          --csv-output "${RESULT_ROOT}/slo-domain-scorecard.csv" >"${RUN_DIR}/slo-domain-scorecard.log" 2>&1 || true
        if bool_enabled "${PERF_PRODUCTION_GATE}"; then
          rm -f \
            "${RESULT_ROOT}/production-gate.md" \
            "${RESULT_ROOT}/production-gate.json" \
            "${RESULT_ROOT}/production-gate.csv"
          production_gate_args=(
            --slo-status-json "${RESULT_ROOT}/slo-status.json"
            --profile "${PERF_PRODUCTION_GATE_PROFILE}"
            --output "${RESULT_ROOT}/production-gate.md"
            --json-output "${RESULT_ROOT}/production-gate.json"
            --csv-output "${RESULT_ROOT}/production-gate.csv"
            --max-evidence-age-seconds "${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}"
          )
          if bool_enabled "${PERF_PRODUCTION_GATE_REQUIRE_RUN_ARTIFACTS}"; then
            production_gate_args+=(--require-run-artifacts)
          fi
          local production_gate_rc=0
          set +e
          python3 "${SCRIPT_DIR}/perf_production_gate.py" \
            "${production_gate_args[@]}" >"${RUN_DIR}/production-gate.log" 2>&1
          production_gate_rc=$?
          set -e
          if [[ "${production_gate_rc}" -ne 0 && ! -f "${RESULT_ROOT}/production-gate.json" ]]; then
            printf 'run_perf_scenarios result=fail reason=production_gate_artifact_missing rc=%s log=%s\n' \
              "${production_gate_rc}" \
              "${RUN_DIR}/production-gate.log" >&2
            return "${production_gate_rc}"
          fi
        fi
        slo_plan_args=(
          --slo-status-json "${RESULT_ROOT}/slo-status.json"
          --output "${RESULT_ROOT}/slo-domain-run-plan.md"
          --json-output "${RESULT_ROOT}/slo-domain-run-plan.json"
          --base-url "${PERF_PLAN_BASE_URL}"
          --tcp-host "${PERF_PLAN_TCP_HOST}"
          --tcp-port "${PERF_PLAN_TCP_PORT}"
          --account-file "${PERF_PLAN_ACCOUNT_FILE}"
          --conversation-id "${PERF_PLAN_CONVERSATION_ID}"
          --internal-secret "${PERF_PLAN_INTERNAL_SECRET}"
        )
        [[ -f "${RESULT_ROOT}/slo-domain-scorecard.json" ]] && slo_plan_args+=(--slo-domain-scorecard-json "${RESULT_ROOT}/slo-domain-scorecard.json")
        python3 "${SCRIPT_DIR}/perf_slo_domain_run_plan.py" "${slo_plan_args[@]}" >"${RUN_DIR}/slo-domain-run-plan.log" 2>&1 || true
      fi
    fi
    if [[ -f "${RESULT_ROOT}/scenario-status.json" ]]; then
      python3 "${SCRIPT_DIR}/perf_next_actions.py" \
        --scenario-status "${RESULT_ROOT}/scenario-status.json" \
        --output "${RESULT_ROOT}/next-actions.md" \
        --json-output "${RESULT_ROOT}/next-actions.json" \
        --csv-output "${RESULT_ROOT}/next-actions.csv" >"${RUN_DIR}/next-actions.log" 2>&1 || true
      python3 "${SCRIPT_DIR}/perf_scenario_catalog.py" \
        --script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
        --scenario-status "${RESULT_ROOT}/scenario-status.json" \
        --output "${RESULT_ROOT}/scenario-catalog.md" \
        --json-output "${RESULT_ROOT}/scenario-catalog.json" \
        --csv-output "${RESULT_ROOT}/scenario-catalog.csv" >"${RUN_DIR}/scenario-catalog-global.log" 2>&1 || true
    fi
    if [[ -f "${RESULT_ROOT}/scenario-catalog.json" && -f "${RESULT_ROOT}/next-actions.json" ]]; then
      python3 "${SCRIPT_DIR}/perf_domain_backlog.py" \
        --scenario-catalog "${RESULT_ROOT}/scenario-catalog.json" \
        --next-actions "${RESULT_ROOT}/next-actions.json" \
        --output "${RESULT_ROOT}/domain-backlog.md" \
        --json-output "${RESULT_ROOT}/domain-backlog.json" \
        --csv-output "${RESULT_ROOT}/domain-backlog.csv" >"${RUN_DIR}/domain-backlog.log" 2>&1 || true
    fi
    if [[ -f "${RESULT_ROOT}/domain-backlog.json" ]]; then
      domain_plan_args=(
        "${SCRIPT_DIR}/perf_domain_run_plan.py"
        --domain-backlog "${RESULT_ROOT}/domain-backlog.json"
        --base-url "${PERF_PLAN_BASE_URL}"
        --tcp-host "${PERF_PLAN_TCP_HOST}"
        --tcp-port "${PERF_PLAN_TCP_PORT}"
        --account-file "${PERF_PLAN_ACCOUNT_FILE}"
        --conversation-id "${PERF_PLAN_CONVERSATION_ID}"
        --internal-secret "${PERF_PLAN_INTERNAL_SECRET}"
        --blocker-max-age-seconds "${PERF_PLAN_BLOCKER_MAX_AGE_SECONDS}"
        --output "${RESULT_ROOT}/domain-run-plan.md"
        --json-output "${RESULT_ROOT}/domain-run-plan.json"
      )
      bool_enabled "${PERF_PLAN_IGNORE_BLOCKERS_FOR_DIFFERENT_TARGET}" && domain_plan_args+=(--ignore-blockers-for-different-target)
      python3 "${domain_plan_args[@]}" >"${RUN_DIR}/domain-run-plan.log" 2>&1 || true
    fi
    if [[ -f "${RESULT_ROOT}/domain-backlog.json" ]]; then
      scorecard_args=(
        --domain-backlog "${RESULT_ROOT}/domain-backlog.json"
        --output "${RESULT_ROOT}/domain-scorecard.md"
        --json-output "${RESULT_ROOT}/domain-scorecard.json"
        --csv-output "${RESULT_ROOT}/domain-scorecard.csv"
      )
      [[ -f "${RESULT_ROOT}/domain-run-plan.json" ]] && scorecard_args+=(--domain-run-plan "${RESULT_ROOT}/domain-run-plan.json")
      python3 "${SCRIPT_DIR}/perf_domain_scorecard.py" "${scorecard_args[@]}" >"${RUN_DIR}/domain-scorecard.log" 2>&1 || true
    fi
    if [[ -f "${RESULT_ROOT}/scenario-catalog.json" ]]; then
      prereq_args=(
        --scenario-catalog "${RESULT_ROOT}/scenario-catalog.json"
        --base-url "${PERF_PLAN_BASE_URL}"
        --tcp-host "${PERF_PLAN_TCP_HOST}"
        --tcp-port "${PERF_PLAN_TCP_PORT}"
        --account-file "${PERF_PLAN_ACCOUNT_FILE}"
        --conversation-id "${PERF_PLAN_CONVERSATION_ID}"
        --internal-secret "${PERF_PLAN_INTERNAL_SECRET}"
        --auth-email-webhook-url "${PERF_PLAN_AUTH_EMAIL_WEBHOOK_URL}"
        --verification-code "${PERF_PLAN_ACCOUNT_VERIFICATION_CODE}"
        --password-reset-code "${PERF_PLAN_PASSWORD_RESET_CODE}"
        --output "${RESULT_ROOT}/prereq-audit.md"
        --json-output "${RESULT_ROOT}/prereq-audit.json"
        --csv-output "${RESULT_ROOT}/prereq-audit.csv"
      )
      [[ -f "${RESULT_ROOT}/domain-run-plan.json" ]] && prereq_args+=(--domain-run-plan "${RESULT_ROOT}/domain-run-plan.json")
      python3 "${SCRIPT_DIR}/perf_prereq_audit.py" "${prereq_args[@]}" >"${RUN_DIR}/prereq-audit.log" 2>&1 || true
    fi
    readiness_args=(
      --output "${RESULT_ROOT}/readiness-gate.txt"
      --json-output "${RESULT_ROOT}/readiness-gate.json"
    )
    [[ -f "${RUN_DIR}/coverage.json" ]] && readiness_args+=(--coverage-json "${RUN_DIR}/coverage.json")
    [[ -f "${RUN_DIR}/route-audit.json" ]] && readiness_args+=(--route-audit-json "${RUN_DIR}/route-audit.json")
    [[ -f "${RUN_DIR}/matrix-audit.json" ]] && readiness_args+=(--matrix-audit-json "${RUN_DIR}/matrix-audit.json")
    [[ -f "${RESULT_ROOT}/domain-scorecard.json" ]] && readiness_args+=(--domain-scorecard-json "${RESULT_ROOT}/domain-scorecard.json")
    [[ -f "${RESULT_ROOT}/prereq-audit.json" ]] && readiness_args+=(--prereq-audit-json "${RESULT_ROOT}/prereq-audit.json")
    [[ -f "${RESULT_ROOT}/slo-status.json" ]] && readiness_args+=(--slo-status-json "${RESULT_ROOT}/slo-status.json")
    [[ -f "${RESULT_ROOT}/slo-domain-scorecard.json" ]] && readiness_args+=(--slo-domain-scorecard-json "${RESULT_ROOT}/slo-domain-scorecard.json")
    [[ -f "${RESULT_ROOT}/production-gate.json" ]] && readiness_args+=(--production-gate-json "${RESULT_ROOT}/production-gate.json")
    python3 "${SCRIPT_DIR}/perf_readiness_gate.py" "${readiness_args[@]}" >"${RUN_DIR}/readiness-gate.log" 2>&1 || true
    if bool_enabled "${PERF_RUN_PLAN}" && [[ -f "${RESULT_ROOT}/next-actions.json" ]]; then
      python3 "${SCRIPT_DIR}/perf_run_plan.py" \
        --next-actions "${RESULT_ROOT}/next-actions.json" \
        --base-url "${PERF_PLAN_BASE_URL}" \
        --tcp-host "${PERF_PLAN_TCP_HOST}" \
        --tcp-port "${PERF_PLAN_TCP_PORT}" \
        --account-file "${PERF_PLAN_ACCOUNT_FILE}" \
        --conversation-id "${PERF_PLAN_CONVERSATION_ID}" \
        --internal-secret "${PERF_PLAN_INTERNAL_SECRET}" \
        --output "${RESULT_ROOT}/run-plan.md" \
        --json-output "${RESULT_ROOT}/run-plan.json" >"${RUN_DIR}/run-plan.log" 2>&1 || true
    fi
    dashboard_args=(
      --output "${RESULT_ROOT}/dashboard.md"
      --json-output "${RESULT_ROOT}/dashboard.json"
    )
    [[ -f "${RESULT_ROOT}/scenario-status.json" ]] && dashboard_args+=(--scenario-status-json "${RESULT_ROOT}/scenario-status.json")
    [[ -f "${RESULT_ROOT}/slo-status.json" ]] && dashboard_args+=(--slo-status-json "${RESULT_ROOT}/slo-status.json")
    [[ -f "${RESULT_ROOT}/slo-domain-scorecard.json" ]] && dashboard_args+=(--slo-domain-scorecard-json "${RESULT_ROOT}/slo-domain-scorecard.json")
    [[ -f "${RESULT_ROOT}/slo-domain-run-plan.json" ]] && dashboard_args+=(--slo-domain-run-plan-json "${RESULT_ROOT}/slo-domain-run-plan.json")
    [[ -f "${RESULT_ROOT}/next-actions.json" ]] && dashboard_args+=(--next-actions-json "${RESULT_ROOT}/next-actions.json")
    [[ -f "${RESULT_ROOT}/scenario-catalog.json" ]] && dashboard_args+=(--scenario-catalog-json "${RESULT_ROOT}/scenario-catalog.json")
    [[ -f "${RESULT_ROOT}/domain-backlog.json" ]] && dashboard_args+=(--domain-backlog-json "${RESULT_ROOT}/domain-backlog.json")
    [[ -f "${RESULT_ROOT}/run-plan.json" ]] && dashboard_args+=(--run-plan-json "${RESULT_ROOT}/run-plan.json")
    [[ -f "${RESULT_ROOT}/domain-run-plan.json" ]] && dashboard_args+=(--domain-run-plan-json "${RESULT_ROOT}/domain-run-plan.json")
    [[ -f "${RESULT_ROOT}/domain-scorecard.json" ]] && dashboard_args+=(--domain-scorecard-json "${RESULT_ROOT}/domain-scorecard.json")
    [[ -f "${RESULT_ROOT}/prereq-audit.json" ]] && dashboard_args+=(--prereq-audit-json "${RESULT_ROOT}/prereq-audit.json")
    [[ -f "${RESULT_ROOT}/readiness-gate.json" ]] && dashboard_args+=(--readiness-gate-json "${RESULT_ROOT}/readiness-gate.json")
    [[ -f "${RESULT_ROOT}/production-gate.json" ]] && dashboard_args+=(--production-gate-json "${RESULT_ROOT}/production-gate.json")
    [[ -f "${RESULT_ROOT}/current-node-access-rescue/summary.txt" ]] && dashboard_args+=(--entrypoint-rescue-summary "${RESULT_ROOT}/current-node-access-rescue/summary.txt")
    python3 "${SCRIPT_DIR}/perf_dashboard.py" "${dashboard_args[@]}" >"${RUN_DIR}/dashboard.log" 2>&1 || true
    if [[ -f "${RESULT_ROOT}/domain-backlog.json" ]]; then
      playbook_args=(
        --domain-backlog-json "${RESULT_ROOT}/domain-backlog.json"
        --output "${RESULT_ROOT}/optimization-playbook.md"
        --json-output "${RESULT_ROOT}/optimization-playbook.json"
        --csv-output "${RESULT_ROOT}/optimization-playbook.csv"
      )
      [[ -f "${RESULT_ROOT}/dashboard.json" ]] && playbook_args+=(--dashboard-json "${RESULT_ROOT}/dashboard.json")
      [[ -f "${RESULT_ROOT}/run-plan.json" ]] && playbook_args+=(--run-plan-json "${RESULT_ROOT}/run-plan.json")
      [[ -f "${RESULT_ROOT}/domain-run-plan.json" ]] && playbook_args+=(--domain-run-plan-json "${RESULT_ROOT}/domain-run-plan.json")
      [[ -f "${RESULT_ROOT}/prereq-audit.json" ]] && playbook_args+=(--prereq-audit-json "${RESULT_ROOT}/prereq-audit.json")
      [[ -f "${RESULT_ROOT}/readiness-gate.json" ]] && playbook_args+=(--readiness-gate-json "${RESULT_ROOT}/readiness-gate.json")
      [[ -f "${RESULT_ROOT}/slo-status.json" ]] && playbook_args+=(--slo-status-json "${RESULT_ROOT}/slo-status.json")
      [[ -f "${RESULT_ROOT}/production-gate.json" ]] && playbook_args+=(--production-gate-json "${RESULT_ROOT}/production-gate.json")
      python3 "${SCRIPT_DIR}/perf_optimization_playbook.py" "${playbook_args[@]}" >"${RUN_DIR}/optimization-playbook.log" 2>&1 || true
    fi
    state_summary_args=(
      --output "${RESULT_ROOT}/state-summary.md"
      --json-output "${RESULT_ROOT}/state-summary.json"
      --csv-output "${RESULT_ROOT}/state-summary.csv"
      --current-readiness-max-age-seconds "${PERF_CURRENT_READINESS_MAX_AGE_SECONDS}"
      --current-readiness-future-skew-seconds "${PERF_CURRENT_READINESS_FUTURE_SKEW_SECONDS}"
    )
    [[ -f "${RESULT_ROOT}/scenario-status.json" ]] && state_summary_args+=(--scenario-status-json "${RESULT_ROOT}/scenario-status.json")
    [[ -f "${RESULT_ROOT}/slo-status.json" ]] && state_summary_args+=(--slo-status-json "${RESULT_ROOT}/slo-status.json")
    [[ -f "${RESULT_ROOT}/slo-domain-scorecard.json" ]] && state_summary_args+=(--slo-domain-scorecard-json "${RESULT_ROOT}/slo-domain-scorecard.json")
    [[ -f "${RESULT_ROOT}/readiness-gate.json" ]] && state_summary_args+=(--readiness-gate-json "${RESULT_ROOT}/readiness-gate.json")
    [[ -f "${RESULT_ROOT}/next-actions.json" ]] && state_summary_args+=(--next-actions-json "${RESULT_ROOT}/next-actions.json")
    [[ -f "${RESULT_ROOT}/scenario-catalog.json" ]] && state_summary_args+=(--scenario-catalog-json "${RESULT_ROOT}/scenario-catalog.json")
    [[ -f "${RESULT_ROOT}/dashboard.json" ]] && state_summary_args+=(--dashboard-json "${RESULT_ROOT}/dashboard.json")
    [[ -f "${RESULT_ROOT}/run-plan.json" ]] && state_summary_args+=(--run-plan-json "${RESULT_ROOT}/run-plan.json")
    [[ -f "${RESULT_ROOT}/production-gate.json" ]] && state_summary_args+=(--production-gate-json "${RESULT_ROOT}/production-gate.json")
    [[ -f "${RESULT_ROOT}/current-node-access-rescue/summary.txt" ]] && state_summary_args+=(--entrypoint-rescue-summary "${RESULT_ROOT}/current-node-access-rescue/summary.txt")
    current_readiness_receipt="$(current_readiness_receipt_for_state_summary)"
    production_acceptance_receipt="$(production_acceptance_receipt_for_state_summary)"
    [[ -f "${current_readiness_receipt}" ]] && state_summary_args+=(--current-readiness-json "${current_readiness_receipt}")
    [[ -f "${production_acceptance_receipt}" ]] && state_summary_args+=(--production-acceptance-json "${production_acceptance_receipt}")
    python3 "${SCRIPT_DIR}/perf_state_summary.py" "${state_summary_args[@]}" >"${RUN_DIR}/state-summary.log" 2>&1 || true
  fi
}

print_evidence_summary() {
  if [[ ! -f "${RUN_DIR}/evidence.json" ]]; then
    return 0
  fi
  python3 - "${RUN_DIR}/evidence.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
outcome = data.get("outcome", "UNKNOWN")
issues = data.get("openIssueCount", 0)
priorities = data.get("priorityCounts") or {}
recommendation = data.get("recommendation") or ""
priority_text = ",".join(f"{key}:{priorities[key]}" for key in sorted(priorities)) or "-"
print(f"Evidence outcome: {outcome} openIssues={issues} priorities={priority_text}")
if recommendation:
    print(f"Evidence recommendation: {recommendation}")
PY
}

usable_account_count() {
  if [[ -z "${ACCOUNT_FILE}" || ! -f "${ACCOUNT_FILE}" ]]; then
    printf '0\n'
    return 0
  fi
  awk -F',' 'NF >= 2 && $1 !~ /^#/ && $1 != "" && $2 != "" { count += 1 } END { print count + 0 }' "${ACCOUNT_FILE}"
}

scenario_needs_account_file() {
  case "$1" in
    online-idle-*|reconnect-soak-*|reconnect-drill-*|multi-device-online-*|multi-device-delivery-*|pair-delivery-*|group-delivery-*|large-group-*|online-chat-mix-*|direct-burst-*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

scenario_needs_conversation_id() {
  case "$1" in
    multi-device-delivery-*|pair-delivery-*|group-delivery-*|large-group-*|online-chat-mix-*|direct-burst-*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

scenario_account_minimum() {
  local scenario="$1"
  if [[ "${scenario}" =~ ^online-idle-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "${scenario}" =~ ^reconnect-(soak|drill)-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  elif [[ "${scenario}" =~ ^multi-device-(online|delivery)-([0-9]+)x([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  elif [[ "${scenario}" =~ ^pair-delivery-([0-9]+)-[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "${scenario}" =~ ^group-delivery-([0-9]+)-[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "${scenario}" =~ ^large-group-([0-9]+)-[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "${scenario}" =~ ^online-chat-mix-([0-9]+)-[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "${scenario}" =~ ^direct-burst-([0-9]+)-[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '0\n'
  fi
}

write_preflight_requirement_failure() {
  local reason="$1"
  local detail="$2"
  local scenario_dir="${RUN_DIR}/preflight-scenario-requirements"
  mkdir -p "${scenario_dir}"
  cat >"${scenario_dir}/scenario.json" <<EOF
{
  "name": "preflight-scenario-requirements",
  "category": "preflight",
  "target": "local scenario input requirements before performance matrix",
  "baseURL": $(write_json_string "${BASE_URL}"),
  "tcpHost": $(write_json_string "${TCP_HOST}"),
  "tcpPort": $(write_json_string "${TCP_PORT}"),
  "startedAt": $(write_json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
}
EOF
  printf '%s\n' "2" >"${scenario_dir}/exit-code.txt"
  {
    printf 'Scenario requirement preflight failed: %s\n' "${reason}"
    printf '%s\n' "${detail}"
    printf 'Selected scenarios: %s\n' "${SCENARIOS}"
    printf 'ACCOUNT_FILE: %s\n' "${ACCOUNT_FILE:-<unset>}"
    printf 'IM_CONVERSATION_ID: %s\n' "$([[ -n "${IM_CONVERSATION_ID}" ]] && printf '<set>' || printf '<unset>')"
    printf 'No scenarios were started. Fix the matrix inputs or set PERF_PREFLIGHT=false to bypass this guard.\n'
  } >"${scenario_dir}/stdout.log"
  python3 "${SCRIPT_DIR}/perf_report.py" \
    --run-dir "${RUN_DIR}" \
    --output "${RUN_DIR}/report.md" \
    --json-output "${RUN_DIR}/report.json" \
    --csv-output "${RUN_DIR}/report.csv" >/dev/null || true
  generate_post_report_artifacts
}

preflight_scenario_requirements() {
  if ! bool_enabled "${PERF_PREFLIGHT}"; then
    return 0
  fi

  local scenario account_required=false conversation_required=false
  local max_account_minimum=0 account_minimum account_rows=0 failed=false
  local failure_reason="" failure_detail=""
  local account_scenarios=()
  local conversation_scenarios=()

  for scenario in ${SCENARIOS}; do
    if scenario_needs_account_file "${scenario}"; then
      account_required=true
      account_scenarios+=("${scenario}")
      account_minimum="$(scenario_account_minimum "${scenario}")"
      if (( account_minimum > max_account_minimum )); then
        max_account_minimum="${account_minimum}"
      fi
    fi
    if scenario_needs_conversation_id "${scenario}"; then
      conversation_required=true
      conversation_scenarios+=("${scenario}")
    fi
  done

  if [[ "${account_required}" == true ]]; then
    if [[ -z "${ACCOUNT_FILE}" ]]; then
      echo "Scenario requirement preflight failed: ACCOUNT_FILE is required before running this matrix." >&2
      printf 'ACCOUNT_FILE scenarios: %s\n' "${account_scenarios[*]}" >&2
      failure_reason="ACCOUNT_FILE is required before running this matrix."
      failure_detail="ACCOUNT_FILE scenarios: ${account_scenarios[*]}"
      failed=true
    elif [[ ! -f "${ACCOUNT_FILE}" ]]; then
      echo "Scenario requirement preflight failed: ACCOUNT_FILE does not exist: ${ACCOUNT_FILE}" >&2
      printf 'ACCOUNT_FILE scenarios: %s\n' "${account_scenarios[*]}" >&2
      failure_reason="ACCOUNT_FILE does not exist: ${ACCOUNT_FILE}"
      failure_detail="ACCOUNT_FILE scenarios: ${account_scenarios[*]}"
      failed=true
    else
      account_rows="$(usable_account_count)"
      if (( account_rows <= 0 )); then
        echo "Scenario requirement preflight failed: ACCOUNT_FILE has no usable email,password rows: ${ACCOUNT_FILE}" >&2
        failure_reason="ACCOUNT_FILE has no usable email,password rows: ${ACCOUNT_FILE}"
        failure_detail="ACCOUNT_FILE scenarios: ${account_scenarios[*]}"
        failed=true
      elif (( max_account_minimum > 0 && account_rows < max_account_minimum )); then
        echo "Scenario requirement preflight failed: ACCOUNT_FILE needs >= ${max_account_minimum} usable rows for this matrix; found ${account_rows}: ${ACCOUNT_FILE}" >&2
        printf 'Highest account requirement comes from: %s\n' "${account_scenarios[*]}" >&2
        failure_reason="ACCOUNT_FILE needs >= ${max_account_minimum} usable rows for this matrix; found ${account_rows}: ${ACCOUNT_FILE}"
        failure_detail="Highest account requirement comes from: ${account_scenarios[*]}"
        failed=true
      fi
    fi
  fi

  if [[ "${conversation_required}" == true && -z "${IM_CONVERSATION_ID}" ]]; then
    echo "Scenario requirement preflight failed: IM_CONVERSATION_ID is required before running TCP delivery scenarios." >&2
    printf 'IM_CONVERSATION_ID scenarios: %s\n' "${conversation_scenarios[*]}" >&2
    if [[ -n "${failure_detail}" ]]; then
      failure_detail="${failure_detail}; IM_CONVERSATION_ID scenarios: ${conversation_scenarios[*]}"
    else
      failure_detail="IM_CONVERSATION_ID scenarios: ${conversation_scenarios[*]}"
    fi
    if [[ -z "${failure_reason}" ]]; then
      failure_reason="IM_CONVERSATION_ID is required before running TCP delivery scenarios."
    fi
    failed=true
  fi

  if [[ "${failed}" == true ]]; then
    write_preflight_requirement_failure "${failure_reason:-scenario input requirements are missing}" "${failure_detail:-missing scenario input requirements}"
    print_evidence_summary >&2
    echo "No scenarios were started. Fix the matrix inputs or set PERF_PREFLIGHT=false to bypass this guard." >&2
    echo "Report: ${RUN_DIR}/report.md" >&2
    return 2
  fi
}

preflight_http_login() {
  if ! bool_enabled "${PERF_PREFLIGHT}" || bool_enabled "${PERF_DRY_RUN}"; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl unavailable; skipping HTTP login preflight." >&2
    return 0
  fi

  local email password status body_file status_file payload_file rc=0
  email="$(first_account_email)"
  password="$(first_account_password)"
  body_file="${RUN_DIR}/preflight-login-body.txt"
  status_file="${RUN_DIR}/preflight-login-status.txt"
  payload_file="${RUN_DIR}/preflight-login-payload.json"
  python3 - "${email}" "${password}" "${RUN_ID}" >"${payload_file}" <<'PY'
import json
import sys

email, password, run_id = sys.argv[1:4]
print(json.dumps({
    "email": email,
    "password": password,
    "device": {
        "deviceID": f"perf-preflight-{run_id}",
        "deviceName": "perf-preflight",
        "platform": "load-test",
        "appVersion": "load-test",
    },
}, separators=(",", ":")))
PY
  status="$(
    curl -sS \
      --connect-timeout 5 \
      --max-time 15 \
      -o "${body_file}" \
      -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data-binary "@${payload_file}" \
      "${BASE_URL%/}/api/auth/login"
  )" || rc=$?
  printf '%s\n' "${status:-curl-error-${rc}}" >"${status_file}"
  if [[ "${rc}" != "0" || "${status}" != "200" ]]; then
    local scenario_dir="${RUN_DIR}/preflight-http-login"
    mkdir -p "${scenario_dir}"
    cat >"${scenario_dir}/scenario.json" <<EOF
{
  "name": "preflight-http-login",
  "category": "preflight",
  "target": "single HTTP login before performance matrix",
  "baseURL": $(write_json_string "${BASE_URL}"),
  "tcpHost": $(write_json_string "${TCP_HOST}"),
  "tcpPort": $(write_json_string "${TCP_PORT}"),
  "startedAt": $(write_json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
}
EOF
    printf '%s\n' "1" >"${scenario_dir}/exit-code.txt"
    printf 'HTTP login preflight failed: status=%s curlExit=%s url=%s account=%s\n' \
      "${status:-curl-error-${rc}}" \
      "${rc}" \
      "${BASE_URL%/}/api/auth/login" \
      "${email}" >"${scenario_dir}/stdout.log"
    if [[ -s "${body_file}" ]]; then
      printf 'HTTP login preflight response body: ' >>"${scenario_dir}/stdout.log"
      python3 - "${body_file}" >>"${scenario_dir}/stdout.log" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
text = re.sub(r"\s+", " ", text).strip()
print(text[:1000] if text else "<empty>")
PY
    else
      printf 'HTTP login preflight response body: <empty>\n' >>"${scenario_dir}/stdout.log"
    fi
    for endpoint in "/" "/health" "/api/auth/login"; do
      local probe_body probe_status probe_rc=0 probe_size
      probe_body="${RUN_DIR}/preflight-probe-${endpoint//\//_}.txt"
      probe_status="$(
        curl -sS \
          --connect-timeout 5 \
          --max-time 10 \
          -o "${probe_body}" \
          -w '%{http_code}' \
          "${BASE_URL%/}${endpoint}"
      )" || probe_rc=$?
      probe_size="$(wc -c <"${probe_body}" 2>/dev/null | tr -d ' ' || printf '0')"
      printf 'HTTP endpoint probe: method=GET path=%s status=%s curlExit=%s bodyBytes=%s\n' \
        "${endpoint}" \
        "${probe_status:-curl-error-${probe_rc}}" \
        "${probe_rc}" \
        "${probe_size:-0}" >>"${scenario_dir}/stdout.log"
    done
    if [[ -x "${SCRIPT_DIR}/http_entrypoint_probe.sh" ]]; then
      printf 'HTTP structured entrypoint probe:\n' >>"${scenario_dir}/stdout.log"
      env \
        "BASE_URL=${BASE_URL}" \
        "ACCOUNT_FILE=${ACCOUNT_FILE}" \
        "IM_EMAIL=${email}" \
        "IM_PASSWORD=${password}" \
        "CONNECT_TIMEOUT_SECONDS=5" \
        "REQUEST_TIMEOUT_SECONDS=10" \
        "PROBE_FAIL_ON_ENTRYPOINT_ERROR=false" \
        "${SCRIPT_DIR}/http_entrypoint_probe.sh" >>"${scenario_dir}/stdout.log" 2>&1 || true
    fi
    python3 "${SCRIPT_DIR}/perf_report.py" \
      --run-dir "${RUN_DIR}" \
      --output "${RUN_DIR}/report.md" \
      --json-output "${RUN_DIR}/report.json" \
      --csv-output "${RUN_DIR}/report.csv" >/dev/null || true
    generate_post_report_artifacts
    print_evidence_summary >&2
    echo "HTTP login preflight failed: status=${status:-curl-error-${rc}} curlExit=${rc} url=${BASE_URL%/}/api/auth/login account=${email}" >&2
    echo "Report: ${RUN_DIR}/report.md" >&2
    if [[ -f "${RUN_DIR}/slo.md" ]]; then
      echo "SLO: ${RUN_DIR}/slo.md" >&2
    fi
    if [[ -f "${RESULT_ROOT}/slo-status.md" ]]; then
      echo "SLO status: ${RESULT_ROOT}/slo-status.md" >&2
    fi
    if [[ -f "${RUN_DIR}/evidence.md" ]]; then
      echo "Evidence: ${RUN_DIR}/evidence.md" >&2
    fi
    echo "Set PERF_PREFLIGHT=false to run scenarios anyway." >&2
    return 1
  fi
}

preflight_scenario_requirements
preflight_http_login

write_scenario_metadata() {
  local scenario_dir="$1"
  local name="$2"
  local category="$3"
  local target="$4"
  cat >"${scenario_dir}/scenario.json" <<EOF
{
  "name": $(write_json_string "${name}"),
  "category": $(write_json_string "${category}"),
  "target": $(write_json_string "${target}"),
  "baseURL": $(write_json_string "${BASE_URL}"),
  "tcpHost": $(write_json_string "${TCP_HOST}"),
  "tcpPort": $(write_json_string "${TCP_PORT}"),
  "startedAt": $(write_json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
}
EOF
}

quote_command() {
  local first=true
  for arg in "$@"; do
    if [[ "${first}" == true ]]; then
      first=false
    else
      printf ' '
    fi
    printf '%q' "${arg}"
  done
  printf '\n'
}

quote_command_redacted() {
  local first=true
  local arg name value
  for arg in "$@"; do
    if [[ "${first}" == true ]]; then
      first=false
    else
      printf ' '
    fi
    name="${arg%%=*}"
    value="${arg#*=}"
    case "${name}" in
      IM_INTERNAL_SECRET|IM_PASSWORD)
        if [[ "${arg}" == *=* && -n "${value}" ]]; then
          printf '%s=${%s:?set-%s}' "${name}" "${name}" "${name}"
        else
          printf '%q' "${arg}"
        fi
        ;;
      IM_INTERNAL_SHARED_SECRET)
        if [[ "${arg}" == *=* && -n "${value}" ]]; then
          printf '%s=${%s:-${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}}' "${name}" "${name}"
        else
          printf '%q' "${arg}"
        fi
        ;;
      *)
        printf '%q' "${arg}"
        ;;
    esac
  done
  printf '\n'
}

run_command() {
  local name="$1"
  local category="$2"
  local target="$3"
  shift 3
  local scenario_dir="${RUN_DIR}/${name}"
  mkdir -p "${scenario_dir}"
  write_scenario_metadata "${scenario_dir}" "${name}" "${category}" "${target}"
  quote_command_redacted "$@" >"${scenario_dir}/command.sh"
  chmod +x "${scenario_dir}/command.sh"

  echo
  echo "== scenario: ${name} (${target}) =="
  if bool_enabled "${PERF_DRY_RUN}"; then
    cat "${scenario_dir}/command.sh"
    printf '0\n' >"${scenario_dir}/exit-code.txt"
    printf '%s\n' "dry-run" >"${scenario_dir}/stdout.log"
    return 0
  fi

  set +e
  "$@" >"${scenario_dir}/stdout.log" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "${rc}" >"${scenario_dir}/exit-code.txt"
  if (( rc != 0 )); then
    echo "scenario failed: ${name} rc=${rc}" >&2
    tail -100 "${scenario_dir}/stdout.log" >&2 || true
    if bool_enabled "${STOP_ON_FAILURE}"; then
      exit "${rc}"
    fi
  fi
}

require_account_file() {
  if [[ -z "${ACCOUNT_FILE}" ]]; then
    echo "ACCOUNT_FILE is required for ${1}." >&2
    exit 2
  fi
}

require_conversation_id() {
  if [[ -z "${IM_CONVERSATION_ID}" ]]; then
    echo "IM_CONVERSATION_ID is required for ${1}." >&2
    exit 2
  fi
}

run_k6() {
  local name="$1"
  local category="$2"
  local target="$3"
  local profile="$4"
  local script="$5"
  local conversation_kind="${6:-}"
  local scenario_dir="${RUN_DIR}/${name}"
  mkdir -p "${scenario_dir}"
  run_command "${name}" "${category}" "${target}" \
    env \
      "BASE_URL=${BASE_URL}" \
      "IM_COMMAND_BASE_URL=${IM_COMMAND_BASE_URL}" \
      "IM_EMAIL=${IM_EMAIL}" \
      "IM_PASSWORD=${IM_PASSWORD}" \
      "PROFILE=${profile}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "IM_ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "IM_CONVERSATION_ID=${IM_CONVERSATION_ID}" \
      "IM_CONVERSATION_KIND=${conversation_kind}" \
      "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET}" \
      "IM_INTERNAL_SHARED_SECRET=${IM_INTERNAL_SECRET}" \
      "${K6_BIN}" run \
      --summary-export "${scenario_dir}/k6-summary.json" \
      "${SCRIPT_DIR}/k6/${script}"
}

run_online_idle() {
  local name="$1"
  local connections="$2"
  require_account_file "${name}"
  run_command "${name}" "tcp-online" "${connections} online, no messages" \
    env \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "LADDER=${connections}" \
      "MESSAGES=0" \
      "HOLD_SECONDS=${ONLINE_HOLD_SECONDS}" \
      "CONNECT_RAMP_SECONDS=${ONLINE_CONNECT_RAMP_SECONDS}" \
      "TIMEOUT_SECONDS=${ONLINE_TIMEOUT_SECONDS}" \
      "HEARTBEAT_INTERVAL_SECONDS=${ONLINE_HEARTBEAT_INTERVAL_SECONDS}" \
      "CONNECTION_LOG_DIR=${RUN_DIR}/${name}/tcp-logs" \
      "LOGIN_CACHE_DIR=${RUN_DIR}/${name}/login-cache" \
      "PREWARM_LOGIN_CACHE=${PREWARM_LOGIN_CACHE:-true}" \
      "REQUIRE_LOGIN_CACHE=${REQUIRE_LOGIN_CACHE:-true}" \
      "IM_METRICS_GATE_MODE=${IM_METRICS_GATE_MODE:-fail}" \
      "${SCRIPT_DIR}/tcp_capacity_ladder.sh"
}

run_reconnect_online() {
  local name="$1"
  local connections="$2"
  local min_reconnects="$3"
  require_account_file "${name}"
  run_command "${name}" "tcp-reconnect" "${connections} online reconnect recovery, minReconnects=${min_reconnects}" \
    env \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "LADDER=${connections}" \
      "MESSAGES=0" \
      "HOLD_SECONDS=${RECONNECT_HOLD_SECONDS}" \
      "CONNECT_RAMP_SECONDS=${RECONNECT_CONNECT_RAMP_SECONDS}" \
      "TIMEOUT_SECONDS=${RECONNECT_TIMEOUT_SECONDS}" \
      "HEARTBEAT_INTERVAL_SECONDS=${RECONNECT_HEARTBEAT_INTERVAL_SECONDS}" \
      "CONNECTION_QUEUE_POOL_SIZE=${CONNECTION_QUEUE_POOL_SIZE:-256}" \
      "MAX_RECONNECTS=${RECONNECT_MAX_RECONNECTS}" \
      "MIN_RECONNECTS=${min_reconnects}" \
      "RECONNECT_DELAY_MS=${RECONNECT_DELAY_MS}" \
      "CONNECTION_LOG_DIR=${RUN_DIR}/${name}/tcp-logs" \
      "LOGIN_CACHE_DIR=${RUN_DIR}/${name}/login-cache" \
      "PREWARM_LOGIN_CACHE=${PREWARM_LOGIN_CACHE:-true}" \
      "REQUIRE_LOGIN_CACHE=${REQUIRE_LOGIN_CACHE:-true}" \
      "IM_METRICS_GATE_MODE=${IM_METRICS_GATE_MODE:-fail}" \
      "${SCRIPT_DIR}/tcp_capacity_ladder.sh"
}

run_multi_device_online() {
  local name="$1"
  local users="$2"
  local devices="$3"
  local connections=$((users * devices))
  require_account_file "${name}"
  run_command "${name}" "tcp-multi-device-online" "${users} users x ${devices} devices online, no messages" \
    env \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "ACCOUNT_DEVICES_PER_USER=${devices}" \
      "LADDER=${connections}" \
      "MESSAGES=0" \
      "HOLD_SECONDS=${ONLINE_HOLD_SECONDS}" \
      "CONNECT_RAMP_SECONDS=${ONLINE_CONNECT_RAMP_SECONDS}" \
      "TIMEOUT_SECONDS=${ONLINE_TIMEOUT_SECONDS}" \
      "HEARTBEAT_INTERVAL_SECONDS=${ONLINE_HEARTBEAT_INTERVAL_SECONDS}" \
      "CONNECTION_LOG_DIR=${RUN_DIR}/${name}/tcp-logs" \
      "LOGIN_CACHE_DIR=${RUN_DIR}/${name}/login-cache" \
      "PREWARM_LOGIN_CACHE=${PREWARM_LOGIN_CACHE:-true}" \
      "REQUIRE_LOGIN_CACHE=${REQUIRE_LOGIN_CACHE:-true}" \
      "IM_METRICS_GATE_MODE=${IM_METRICS_GATE_MODE:-fail}" \
      "${SCRIPT_DIR}/tcp_capacity_ladder.sh"
}

run_multi_device_delivery() {
  local name="$1"
  local users="$2"
  local devices="$3"
  local rate="$4"
  local connections=$((users * devices))
  require_account_file "${name}"
  require_conversation_id "${name}"
  run_command "${name}" "tcp-multi-device-delivery" "${users} users x ${devices} devices, ${rate} msg/s same-account device delivery" \
    env \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "IM_CONVERSATION_ID=${IM_CONVERSATION_ID}" \
      "ONLINE_LADDER=${connections}" \
      "MESSAGE_RATES=${rate}" \
      "MESSAGE_HOLD_SECONDS=${MESSAGE_HOLD_SECONDS}" \
      "MESSAGE_CONNECT_RAMP_SECONDS=${MESSAGE_CONNECT_RAMP_SECONDS}" \
      "MESSAGE_HEARTBEAT_INTERVAL_SECONDS=${MESSAGE_HEARTBEAT_INTERVAL_SECONDS}" \
      "MESSAGE_COMPLETION_MODE=${MESSAGE_COMPLETION_MODE}" \
      "MESSAGE_ACCOUNT_DEVICES_PER_USER=${devices}" \
      "MESSAGE_SENDER_EVERY=${devices}" \
      "MESSAGE_RECEIVER_OFFSET=1" \
      "MESSAGE_CONNECTION_LOG_DIR=${RUN_DIR}/${name}/tcp-logs" \
      "MESSAGE_LOGIN_CACHE_DIR=${RUN_DIR}/${name}/login-cache" \
      "MESSAGE_PREWARM_LOGIN_CACHE=${PREWARM_LOGIN_CACHE:-true}" \
      "MESSAGE_REQUIRE_LOGIN_CACHE=${REQUIRE_LOGIN_CACHE:-true}" \
      "MESSAGE_METRICS_GATE_MODE=${IM_METRICS_GATE_MODE:-fail}" \
      "${SCRIPT_DIR}/tcp_message_send_ladder.sh"
}

run_pair_delivery() {
  local name="$1"
  local connections="$2"
  local rate="$3"
  require_account_file "${name}"
  require_conversation_id "${name}"
  run_command "${name}" "tcp-pair-delivery" "${connections} online, ${rate} msg/s pair delivery" \
    env \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "IM_CONVERSATION_ID=${IM_CONVERSATION_ID}" \
      "ONLINE_LADDER=${connections}" \
      "MESSAGE_RATES=${rate}" \
      "MESSAGE_HOLD_SECONDS=${MESSAGE_HOLD_SECONDS}" \
      "MESSAGE_CONNECT_RAMP_SECONDS=${MESSAGE_CONNECT_RAMP_SECONDS}" \
      "MESSAGE_HEARTBEAT_INTERVAL_SECONDS=${MESSAGE_HEARTBEAT_INTERVAL_SECONDS}" \
      "MESSAGE_COMPLETION_MODE=${MESSAGE_COMPLETION_MODE}" \
      "MESSAGE_CONNECTION_LOG_DIR=${RUN_DIR}/${name}/tcp-logs" \
      "MESSAGE_LOGIN_CACHE_DIR=${RUN_DIR}/${name}/login-cache" \
      "MESSAGE_PREWARM_LOGIN_CACHE=${PREWARM_LOGIN_CACHE:-true}" \
      "MESSAGE_REQUIRE_LOGIN_CACHE=${REQUIRE_LOGIN_CACHE:-true}" \
      "MESSAGE_METRICS_GATE_MODE=${IM_METRICS_GATE_MODE:-fail}" \
      "${SCRIPT_DIR}/tcp_message_send_ladder.sh"
}

run_group_delivery() {
  local name="$1"
  local connections="$2"
  local rate="$3"
  require_account_file "${name}"
  require_conversation_id "${name}"
  run_command "${name}" "tcp-group-delivery" "${connections} active group users, ${rate} msg/s full realtime delivery" \
    env \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "IM_CONVERSATION_ID=${IM_CONVERSATION_ID}" \
      "ONLINE_LADDER=${connections}" \
      "MESSAGE_RATES=${rate}" \
      "MESSAGE_HOLD_SECONDS=${GROUP_DELIVERY_HOLD_SECONDS}" \
      "MESSAGE_CONNECT_RAMP_SECONDS=${GROUP_DELIVERY_CONNECT_RAMP_SECONDS}" \
      "MESSAGE_HEARTBEAT_INTERVAL_SECONDS=${MESSAGE_HEARTBEAT_INTERVAL_SECONDS}" \
      "MESSAGE_COMPLETION_MODE=${GROUP_DELIVERY_COMPLETION_MODE}" \
      "MESSAGE_ACTIVE_CONVERSATION_USERS=${connections}" \
      "MESSAGE_CONNECTION_LOG_DIR=${RUN_DIR}/${name}/tcp-logs" \
      "MESSAGE_LOGIN_CACHE_DIR=${RUN_DIR}/${name}/login-cache" \
      "MESSAGE_PREWARM_LOGIN_CACHE=${PREWARM_LOGIN_CACHE:-true}" \
      "MESSAGE_REQUIRE_LOGIN_CACHE=${REQUIRE_LOGIN_CACHE:-true}" \
      "MESSAGE_METRICS_GATE_MODE=${IM_METRICS_GATE_MODE:-fail}" \
      "${SCRIPT_DIR}/tcp_message_send_ladder.sh"
}

run_large_group() {
  local name="$1"
  local connections="$2"
  local rate="$3"
  require_account_file "${name}"
  require_conversation_id "${name}"
  run_command "${name}" "tcp-large-group" "${connections} active users, ${rate} msg/s compact/timeline-pull" \
    env \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "IM_CONVERSATION_ID=${IM_CONVERSATION_ID}" \
      "ONLINE_LADDER=${connections}" \
      "MESSAGE_RATES=${rate}" \
      "MESSAGE_HOLD_SECONDS=${LARGE_GROUP_HOLD_SECONDS}" \
      "MESSAGE_CONNECT_RAMP_SECONDS=${LARGE_GROUP_CONNECT_RAMP_SECONDS}" \
      "MESSAGE_HEARTBEAT_INTERVAL_SECONDS=${MESSAGE_HEARTBEAT_INTERVAL_SECONDS}" \
      "MESSAGE_COMPLETION_MODE=${LARGE_GROUP_COMPLETION_MODE}" \
      "MESSAGE_ACTIVE_CONVERSATION_USERS=${connections}" \
      "MESSAGE_CONNECTION_LOG_DIR=${RUN_DIR}/${name}/tcp-logs" \
      "MESSAGE_LOGIN_CACHE_DIR=${RUN_DIR}/${name}/login-cache" \
      "MESSAGE_PREWARM_LOGIN_CACHE=${PREWARM_LOGIN_CACHE:-true}" \
      "MESSAGE_REQUIRE_LOGIN_CACHE=${REQUIRE_LOGIN_CACHE:-true}" \
      "MESSAGE_METRICS_GATE_MODE=${IM_METRICS_GATE_MODE:-fail}" \
      "${SCRIPT_DIR}/tcp_message_send_ladder.sh"
}

for scenario in ${SCENARIOS}; do
  case "${scenario}" in
    login-smoke)
      run_k6 "${scenario}" "http-login" "login smoke" "login-smoke" "http-auth-login.js"
      ;;
    login-baseline)
      run_k6 "${scenario}" "http-login" "login baseline" "login-baseline" "http-auth-login.js"
      ;;
    login-capacity)
      run_k6 "${scenario}" "http-login" "login capacity" "login-capacity" "http-auth-login.js"
      ;;
    account-lifecycle-smoke)
      run_k6 "${scenario}" "http-account-lifecycle" "register + verification resend + password reset request smoke" "account-lifecycle-smoke" "http-auth-account-lifecycle.js"
      ;;
    account-lifecycle-baseline)
      run_k6 "${scenario}" "http-account-lifecycle" "register + verification resend + password reset request baseline" "account-lifecycle-baseline" "http-auth-account-lifecycle.js"
      ;;
    account-lifecycle-capacity)
      run_k6 "${scenario}" "http-account-lifecycle" "register + verification resend + password reset request capacity" "account-lifecycle-capacity" "http-auth-account-lifecycle.js"
      ;;
    account-lifecycle-confirm-smoke)
      run_k6 "${scenario}" "http-account-lifecycle-confirm" "register + email confirm + password reset confirm smoke" "account-lifecycle-confirm-smoke" "http-auth-account-lifecycle.js"
      ;;
    account-lifecycle-confirm-baseline)
      run_k6 "${scenario}" "http-account-lifecycle-confirm" "register + email confirm + password reset confirm baseline" "account-lifecycle-confirm-baseline" "http-auth-account-lifecycle.js"
      ;;
    account-lifecycle-confirm-capacity)
      run_k6 "${scenario}" "http-account-lifecycle-confirm" "register + email confirm + password reset confirm capacity" "account-lifecycle-confirm-capacity" "http-auth-account-lifecycle.js"
      ;;
    auth-session-smoke)
      run_k6 "${scenario}" "http-auth-session" "login + refresh + sessions + push token + logout smoke" "auth-session-smoke" "http-auth-session-device.js"
      ;;
    auth-session-baseline)
      run_k6 "${scenario}" "http-auth-session" "login + refresh + sessions + push token + logout baseline" "auth-session-baseline" "http-auth-session-device.js"
      ;;
    auth-session-capacity)
      run_k6 "${scenario}" "http-auth-session" "login + refresh + sessions + push token + logout capacity" "auth-session-capacity" "http-auth-session-device.js"
      ;;
    auth-session-management-smoke)
      run_k6 "${scenario}" "http-auth-session-management" "multi-device session list + kick + logout-all smoke" "auth-session-management-smoke" "http-auth-session-management.js"
      ;;
    auth-session-management-baseline)
      run_k6 "${scenario}" "http-auth-session-management" "multi-device session list + kick + logout-all baseline" "auth-session-management-baseline" "http-auth-session-management.js"
      ;;
    auth-session-management-capacity)
      run_k6 "${scenario}" "http-auth-session-management" "multi-device session list + kick + logout-all capacity" "auth-session-management-capacity" "http-auth-session-management.js"
      ;;
    auth-token-rotation-smoke)
      run_k6 "${scenario}" "http-auth-token-rotation" "refresh token rotation + old token reuse rejection smoke" "auth-token-rotation-smoke" "http-auth-token-rotation.js"
      ;;
    auth-token-rotation-baseline)
      run_k6 "${scenario}" "http-auth-token-rotation" "refresh token rotation + old token reuse rejection baseline" "auth-token-rotation-baseline" "http-auth-token-rotation.js"
      ;;
    auth-token-rotation-capacity)
      run_k6 "${scenario}" "http-auth-token-rotation" "refresh token rotation + old token reuse rejection capacity" "auth-token-rotation-capacity" "http-auth-token-rotation.js"
      ;;
    auth-failure-recovery-smoke)
      run_k6 "${scenario}" "http-auth-failure-recovery" "auth rejection paths + successful recovery login smoke" "auth-failure-recovery-smoke" "http-auth-failure-recovery.js"
      ;;
    auth-failure-recovery-baseline)
      run_k6 "${scenario}" "http-auth-failure-recovery" "auth rejection paths + successful recovery login baseline" "auth-failure-recovery-baseline" "http-auth-failure-recovery.js"
      ;;
    auth-failure-recovery-capacity)
      run_k6 "${scenario}" "http-auth-failure-recovery" "auth rejection paths + successful recovery login capacity" "auth-failure-recovery-capacity" "http-auth-failure-recovery.js"
      ;;
    push-token-smoke)
      run_k6 "${scenario}" "http-push-token" "push device token register + upsert + delete smoke" "push-token-smoke" "http-push-token-lifecycle.js"
      ;;
    push-token-baseline)
      run_k6 "${scenario}" "http-push-token" "push device token register + upsert + delete baseline" "push-token-baseline" "http-push-token-lifecycle.js"
      ;;
    push-token-capacity)
      run_k6 "${scenario}" "http-push-token" "push device token register + upsert + delete capacity" "push-token-capacity" "http-push-token-lifecycle.js"
      ;;
    client-health-smoke)
      run_k6 "${scenario}" "http-client-health" "client health + timeline catch-up diagnostics smoke" "client-health-smoke" "http-client-health-sync.js"
      ;;
    client-health-baseline)
      run_k6 "${scenario}" "http-client-health" "client health + timeline catch-up diagnostics baseline" "client-health-baseline" "http-client-health-sync.js"
      ;;
    client-health-capacity)
      run_k6 "${scenario}" "http-client-health" "client health + timeline catch-up diagnostics capacity" "client-health-capacity" "http-client-health-sync.js"
      ;;
    client-sync-mix-smoke)
      run_k6 "${scenario}" "http-client-sync-mix" "foreground app sync read mix smoke" "client-sync-mix-smoke" "http-client-sync-mix.js"
      ;;
    client-sync-mix-baseline)
      run_k6 "${scenario}" "http-client-sync-mix" "foreground app sync read mix baseline" "client-sync-mix-baseline" "http-client-sync-mix.js"
      ;;
    client-sync-mix-capacity)
      run_k6 "${scenario}" "http-client-sync-mix" "foreground app sync read mix capacity" "client-sync-mix-capacity" "http-client-sync-mix.js"
      ;;
    user-journey-smoke)
      run_k6 "${scenario}" "http-user-journey" "real user journey mix: sync reads + contacts + optional timeline/write + health smoke" "user-journey-smoke" "http-user-journey-mix.js"
      ;;
    user-journey-baseline)
      run_k6 "${scenario}" "http-user-journey" "real user journey mix: sync reads + contacts + optional timeline/write + health baseline" "user-journey-baseline" "http-user-journey-mix.js"
      ;;
    user-journey-capacity)
      run_k6 "${scenario}" "http-user-journey" "real user journey mix: sync reads + contacts + optional timeline/write + health capacity" "user-journey-capacity" "http-user-journey-mix.js"
      ;;
    mixed-workload-smoke)
      run_k6 "${scenario}" "http-mixed-workload" "weighted daily-active HTTP mix: conversation list/changes, contacts, domain events, timeline, optional writes, health smoke" "mixed-workload-smoke" "http-mixed-workload.js"
      ;;
    mixed-workload-baseline)
      run_k6 "${scenario}" "http-mixed-workload" "weighted daily-active HTTP mix: conversation list/changes, contacts, domain events, timeline, optional writes, health baseline" "mixed-workload-baseline" "http-mixed-workload.js"
      ;;
    mixed-workload-capacity)
      run_k6 "${scenario}" "http-mixed-workload" "weighted daily-active HTTP mix: conversation list/changes, contacts, domain events, timeline, optional writes, health capacity" "mixed-workload-capacity" "http-mixed-workload.js"
      ;;
    offline-catchup-smoke)
      run_k6 "${scenario}" "http-offline-catchup" "offline message writes followed by foreground conversation/timeline/domain-event catch-up smoke" "offline-catchup-smoke" "http-offline-catchup.js"
      ;;
    offline-catchup-baseline)
      run_k6 "${scenario}" "http-offline-catchup" "offline message writes followed by foreground conversation/timeline/domain-event catch-up baseline" "offline-catchup-baseline" "http-offline-catchup.js"
      ;;
    offline-catchup-capacity)
      run_k6 "${scenario}" "http-offline-catchup" "offline message writes followed by foreground conversation/timeline/domain-event catch-up capacity" "offline-catchup-capacity" "http-offline-catchup.js"
      ;;
    inbox-fanout-smoke)
      run_k6 "${scenario}" "http-inbox-fanout" "multi-conversation inbox writes + list/changes/messages-since smoke" "inbox-fanout-smoke" "http-inbox-fanout-sync.js"
      ;;
    inbox-fanout-baseline)
      run_k6 "${scenario}" "http-inbox-fanout" "multi-conversation inbox writes + list/changes/messages-since baseline" "inbox-fanout-baseline" "http-inbox-fanout-sync.js"
      ;;
    inbox-fanout-capacity)
      run_k6 "${scenario}" "http-inbox-fanout" "multi-conversation inbox writes + list/changes/messages-since capacity" "inbox-fanout-capacity" "http-inbox-fanout-sync.js"
      ;;
    multi-device-sync-smoke)
      run_k6 "${scenario}" "http-multi-device-sync" "same account two-device timeline + summary + unread/read changes smoke" "multi-device-sync-smoke" "http-multi-device-sync.js"
      ;;
    multi-device-sync-baseline)
      run_k6 "${scenario}" "http-multi-device-sync" "same account two-device timeline + summary + unread/read changes baseline" "multi-device-sync-baseline" "http-multi-device-sync.js"
      ;;
    multi-device-sync-capacity)
      run_k6 "${scenario}" "http-multi-device-sync" "same account two-device timeline + summary + unread/read changes capacity" "multi-device-sync-capacity" "http-multi-device-sync.js"
      ;;
    conversation-convergence-smoke)
      run_k6 "${scenario}" "http-convergence" "group message accept + timeline + conversation list smoke" "local-convergence-smoke" "http-message-convergence.js" "group"
      ;;
    conversation-convergence-baseline)
      run_k6 "${scenario}" "http-convergence" "group message accept + timeline + conversation list baseline" "staging-convergence-baseline" "http-message-convergence.js" "group"
      ;;
    conversation-convergence-capacity)
      run_k6 "${scenario}" "http-convergence" "group message accept + timeline + conversation list capacity" "staging-convergence-capacity" "http-message-convergence.js" "group"
      ;;
    direct-convergence-smoke)
      run_k6 "${scenario}" "http-direct-convergence" "direct message accept + timeline + conversation list smoke" "local-convergence-smoke" "http-message-convergence.js" "direct"
      ;;
    direct-convergence-baseline)
      run_k6 "${scenario}" "http-direct-convergence" "direct message accept + timeline + conversation list baseline" "staging-convergence-baseline" "http-message-convergence.js" "direct"
      ;;
    direct-convergence-capacity)
      run_k6 "${scenario}" "http-direct-convergence" "direct message accept + timeline + conversation list capacity" "staging-convergence-capacity" "http-message-convergence.js" "direct"
      ;;
    cold-start-smoke)
      run_k6 "${scenario}" "http-cold-start" "cold start conversations + changes + messages/since smoke" "cold-start-smoke" "http-cold-start-sync.js"
      ;;
    cold-start-baseline)
      run_k6 "${scenario}" "http-cold-start" "cold start conversations + changes + messages/since baseline" "cold-start-baseline" "http-cold-start-sync.js"
      ;;
    cold-start-capacity)
      run_k6 "${scenario}" "http-cold-start" "cold start conversations + changes + messages/since capacity" "cold-start-capacity" "http-cold-start-sync.js"
      ;;
    timeline-pagination-smoke)
      run_k6 "${scenario}" "http-timeline-pagination" "timeline latest + history page + since catch-up + member search smoke" "timeline-pagination-smoke" "http-timeline-pagination-sync.js"
      ;;
    timeline-pagination-baseline)
      run_k6 "${scenario}" "http-timeline-pagination" "timeline latest + history page + since catch-up + member search baseline" "timeline-pagination-baseline" "http-timeline-pagination-sync.js"
      ;;
    timeline-pagination-capacity)
      run_k6 "${scenario}" "http-timeline-pagination" "timeline latest + history page + since catch-up + member search capacity" "timeline-pagination-capacity" "http-timeline-pagination-sync.js"
      ;;
    timeline-history-scroll-smoke)
      run_k6 "${scenario}" "http-timeline-history-scroll" "timeline history scroll page consistency smoke" "timeline-history-scroll-smoke" "http-timeline-history-scroll.js"
      ;;
    timeline-history-scroll-baseline)
      run_k6 "${scenario}" "http-timeline-history-scroll" "timeline history scroll page consistency baseline" "timeline-history-scroll-baseline" "http-timeline-history-scroll.js"
      ;;
    timeline-history-scroll-capacity)
      run_k6 "${scenario}" "http-timeline-history-scroll" "timeline history scroll page consistency capacity" "timeline-history-scroll-capacity" "http-timeline-history-scroll.js"
      ;;
    domain-events-smoke)
      run_k6 "${scenario}" "http-domain-events" "owner domain-events outbox catch-up smoke" "domain-events-smoke" "http-domain-events-sync.js"
      ;;
    domain-events-baseline)
      run_k6 "${scenario}" "http-domain-events" "owner domain-events outbox catch-up baseline" "domain-events-baseline" "http-domain-events-sync.js"
      ;;
    domain-events-capacity)
      run_k6 "${scenario}" "http-domain-events" "owner domain-events outbox catch-up capacity" "domain-events-capacity" "http-domain-events-sync.js"
      ;;
    read-state-smoke)
      run_k6 "${scenario}" "http-read-state" "unread growth + mark read + changes sync smoke" "read-state-smoke" "http-read-state-sync.js"
      ;;
    read-state-baseline)
      run_k6 "${scenario}" "http-read-state" "unread growth + mark read + changes sync baseline" "read-state-baseline" "http-read-state-sync.js"
      ;;
    read-state-capacity)
      run_k6 "${scenario}" "http-read-state" "unread growth + mark read + changes sync capacity" "read-state-capacity" "http-read-state-sync.js"
      ;;
    direct-message-lifecycle-smoke)
      run_k6 "${scenario}" "http-direct-message-lifecycle" "direct chat send + list + unread + read + changes lifecycle smoke" "direct-message-lifecycle-smoke" "http-direct-message-lifecycle.js"
      ;;
    direct-message-lifecycle-baseline)
      run_k6 "${scenario}" "http-direct-message-lifecycle" "direct chat send + list + unread + read + changes lifecycle baseline" "direct-message-lifecycle-baseline" "http-direct-message-lifecycle.js"
      ;;
    direct-message-lifecycle-capacity)
      run_k6 "${scenario}" "http-direct-message-lifecycle" "direct chat send + list + unread + read + changes lifecycle capacity" "direct-message-lifecycle-capacity" "http-direct-message-lifecycle.js"
      ;;
    search-sync-smoke)
      run_k6 "${scenario}" "http-search-sync" "message write to search visible smoke" "search-sync-smoke" "http-search-sync.js"
      ;;
    search-sync-baseline)
      run_k6 "${scenario}" "http-search-sync" "message write to search visible baseline" "search-sync-baseline" "http-search-sync.js"
      ;;
    search-sync-capacity)
      run_k6 "${scenario}" "http-search-sync" "message write to search visible capacity" "search-sync-capacity" "http-search-sync.js"
      ;;
    group-admin-smoke)
      run_k6 "${scenario}" "http-group-admin" "group preferences + metadata + member changes smoke" "group-admin-smoke" "http-group-admin-sync.js"
      ;;
    group-admin-baseline)
      run_k6 "${scenario}" "http-group-admin" "group preferences + metadata + member changes baseline" "group-admin-baseline" "http-group-admin-sync.js"
      ;;
    group-admin-capacity)
      run_k6 "${scenario}" "http-group-admin" "group preferences + metadata + member changes capacity" "group-admin-capacity" "http-group-admin-sync.js"
      ;;
    group-membership-smoke)
      run_k6 "${scenario}" "http-group-membership" "group member profile + role + remove + leave smoke" "group-membership-smoke" "http-group-membership-lifecycle.js"
      ;;
    group-membership-baseline)
      run_k6 "${scenario}" "http-group-membership" "group member profile + role + remove + leave baseline" "group-membership-baseline" "http-group-membership-lifecycle.js"
      ;;
    group-membership-capacity)
      run_k6 "${scenario}" "http-group-membership" "group member profile + role + remove + leave capacity" "group-membership-capacity" "http-group-membership-lifecycle.js"
      ;;
    group-invite-smoke)
      run_k6 "${scenario}" "http-group-invite" "group invite create + join + revoke smoke" "group-invite-smoke" "http-group-invite-sync.js"
      ;;
    group-invite-baseline)
      run_k6 "${scenario}" "http-group-invite" "group invite create + join + revoke baseline" "group-invite-baseline" "http-group-invite-sync.js"
      ;;
    group-invite-capacity)
      run_k6 "${scenario}" "http-group-invite" "group invite create + join + revoke capacity" "group-invite-capacity" "http-group-invite-sync.js"
      ;;
    governance-smoke)
      run_k6 "${scenario}" "http-governance" "conversation preferences + message lifecycle + receipt smoke" "governance-smoke" "http-conversation-governance-sync.js"
      ;;
    governance-baseline)
      run_k6 "${scenario}" "http-governance" "conversation preferences + message lifecycle + receipt baseline" "governance-baseline" "http-conversation-governance-sync.js"
      ;;
    governance-capacity)
      run_k6 "${scenario}" "http-governance" "conversation preferences + message lifecycle + receipt capacity" "governance-capacity" "http-conversation-governance-sync.js"
      ;;
    conversation-preferences-smoke)
      run_k6 "${scenario}" "http-conversation-preferences" "conversation pin/mute preferences + list order + changes smoke" "conversation-preferences-smoke" "http-conversation-preferences-sync.js"
      ;;
    conversation-preferences-baseline)
      run_k6 "${scenario}" "http-conversation-preferences" "conversation pin/mute preferences + list order + changes baseline" "conversation-preferences-baseline" "http-conversation-preferences-sync.js"
      ;;
    conversation-preferences-capacity)
      run_k6 "${scenario}" "http-conversation-preferences" "conversation pin/mute preferences + list order + changes capacity" "conversation-preferences-capacity" "http-conversation-preferences-sync.js"
      ;;
    conversation-visibility-smoke)
      run_k6 "${scenario}" "http-conversation-visibility" "conversation clear/delete visibility + changes removed smoke" "conversation-visibility-smoke" "http-conversation-visibility-sync.js"
      ;;
    conversation-visibility-baseline)
      run_k6 "${scenario}" "http-conversation-visibility" "conversation clear/delete visibility + changes removed baseline" "conversation-visibility-baseline" "http-conversation-visibility-sync.js"
      ;;
    conversation-visibility-capacity)
      run_k6 "${scenario}" "http-conversation-visibility" "conversation clear/delete visibility + changes removed capacity" "conversation-visibility-capacity" "http-conversation-visibility-sync.js"
      ;;
    message-forward-smoke)
      run_k6 "${scenario}" "http-message-forward" "source message forward to target timeline + summary smoke" "message-forward-smoke" "http-message-forward-sync.js"
      ;;
    message-forward-baseline)
      run_k6 "${scenario}" "http-message-forward" "source message forward to target timeline + summary baseline" "message-forward-baseline" "http-message-forward-sync.js"
      ;;
    message-forward-capacity)
      run_k6 "${scenario}" "http-message-forward" "source message forward to target timeline + summary capacity" "message-forward-capacity" "http-message-forward-sync.js"
      ;;
    ai-stream-smoke)
      run_k6 "${scenario}" "http-ai-stream" "AI stream start + snapshot complete + cancel smoke" "ai-stream-smoke" "http-ai-stream-sync.js"
      ;;
    ai-stream-baseline)
      run_k6 "${scenario}" "http-ai-stream" "AI stream start + snapshot complete + cancel baseline" "ai-stream-baseline" "http-ai-stream-sync.js"
      ;;
    ai-stream-capacity)
      run_k6 "${scenario}" "http-ai-stream" "AI stream start + snapshot complete + cancel capacity" "ai-stream-capacity" "http-ai-stream-sync.js"
      ;;
    contact-request-smoke)
      run_k6 "${scenario}" "http-contact-request" "contact request list + decline + cancel smoke" "contact-request-smoke" "http-contact-request-moderation.js"
      ;;
    contact-request-baseline)
      run_k6 "${scenario}" "http-contact-request" "contact request list + decline + cancel baseline" "contact-request-baseline" "http-contact-request-moderation.js"
      ;;
    contact-request-capacity)
      run_k6 "${scenario}" "http-contact-request" "contact request list + decline + cancel capacity" "contact-request-capacity" "http-contact-request-moderation.js"
      ;;
    contact-sync-smoke)
      run_k6 "${scenario}" "http-contact-sync" "friend request + contacts/changes lifecycle smoke" "contact-sync-smoke" "http-contact-sync.js"
      ;;
    contact-sync-baseline)
      run_k6 "${scenario}" "http-contact-sync" "friend request + contacts/changes lifecycle baseline" "contact-sync-baseline" "http-contact-sync.js"
      ;;
    contact-sync-capacity)
      run_k6 "${scenario}" "http-contact-sync" "friend request + contacts/changes lifecycle capacity" "contact-sync-capacity" "http-contact-sync.js"
      ;;
    profile-sync-smoke)
      run_k6 "${scenario}" "http-profile-sync" "profile update to direct-peer summary changes smoke" "profile-sync-smoke" "http-profile-sync.js"
      ;;
    profile-sync-baseline)
      run_k6 "${scenario}" "http-profile-sync" "profile update to direct-peer summary changes baseline" "profile-sync-baseline" "http-profile-sync.js"
      ;;
    profile-sync-capacity)
      run_k6 "${scenario}" "http-profile-sync" "profile update to direct-peer summary changes capacity" "profile-sync-capacity" "http-profile-sync.js"
      ;;
    safety-block-smoke)
      run_k6 "${scenario}" "http-safety-block" "block + report + unblock lifecycle smoke" "safety-block-smoke" "http-safety-block-sync.js"
      ;;
    safety-block-baseline)
      run_k6 "${scenario}" "http-safety-block" "block + report + unblock lifecycle baseline" "safety-block-baseline" "http-safety-block-sync.js"
      ;;
    safety-block-capacity)
      run_k6 "${scenario}" "http-safety-block" "block + report + unblock lifecycle capacity" "safety-block-capacity" "http-safety-block-sync.js"
      ;;
    safety-block-enforcement-smoke)
      run_k6 "${scenario}" "http-safety-block-enforcement" "block/unblock direct conversation enforcement smoke" "safety-block-enforcement-smoke" "http-safety-block-enforcement.js"
      ;;
    safety-block-enforcement-baseline)
      run_k6 "${scenario}" "http-safety-block-enforcement" "block/unblock direct conversation enforcement baseline" "safety-block-enforcement-baseline" "http-safety-block-enforcement.js"
      ;;
    safety-block-enforcement-capacity)
      run_k6 "${scenario}" "http-safety-block-enforcement" "block/unblock direct conversation enforcement capacity" "safety-block-enforcement-capacity" "http-safety-block-enforcement.js"
      ;;
    access-control-enforcement-smoke)
      run_k6 "${scenario}" "http-access-control-enforcement" "group membership access-control and role enforcement smoke" "access-control-enforcement-smoke" "http-access-control-enforcement.js"
      ;;
    access-control-enforcement-baseline)
      run_k6 "${scenario}" "http-access-control-enforcement" "group membership access-control and role enforcement baseline" "access-control-enforcement-baseline" "http-access-control-enforcement.js"
      ;;
    access-control-enforcement-capacity)
      run_k6 "${scenario}" "http-access-control-enforcement" "group membership access-control and role enforcement capacity" "access-control-enforcement-capacity" "http-access-control-enforcement.js"
      ;;
    admin-report-smoke)
      run_k6 "${scenario}" "http-admin-report" "internal report list + review + resolve smoke" "admin-report-smoke" "http-admin-report-moderation.js"
      ;;
    admin-report-baseline)
      run_k6 "${scenario}" "http-admin-report" "internal report list + review + resolve baseline" "admin-report-baseline" "http-admin-report-moderation.js"
      ;;
    admin-report-capacity)
      run_k6 "${scenario}" "http-admin-report" "internal report list + review + resolve capacity" "admin-report-capacity" "http-admin-report-moderation.js"
      ;;
    media-file-smoke)
      run_k6 "${scenario}" "http-media-file" "file upload/download + media upload/download smoke" "media-file-smoke" "http-media-file-sync.js"
      ;;
    media-file-baseline)
      run_k6 "${scenario}" "http-media-file" "file upload/download + media upload/download baseline" "media-file-baseline" "http-media-file-sync.js"
      ;;
    media-file-capacity)
      run_k6 "${scenario}" "http-media-file" "file upload/download + media upload/download capacity" "media-file-capacity" "http-media-file-sync.js"
      ;;
    media-failure-recovery-smoke)
      run_k6 "${scenario}" "http-media-failure-recovery" "media/file rejection paths + recovery upload/download smoke" "media-failure-recovery-smoke" "http-media-failure-recovery.js"
      ;;
    media-failure-recovery-baseline)
      run_k6 "${scenario}" "http-media-failure-recovery" "media/file rejection paths + recovery upload/download baseline" "media-failure-recovery-baseline" "http-media-failure-recovery.js"
      ;;
    media-failure-recovery-capacity)
      run_k6 "${scenario}" "http-media-failure-recovery" "media/file rejection paths + recovery upload/download capacity" "media-failure-recovery-capacity" "http-media-failure-recovery.js"
      ;;
    small-group-smoke)
      run_k6 "${scenario}" "http-small-group" "small group HTTP smoke" "local-smoke" "http-small-group.js"
      ;;
    small-group-baseline)
      run_k6 "${scenario}" "http-small-group" "small group HTTP baseline" "staging-baseline" "http-small-group.js"
      ;;
    small-group-capacity)
      run_k6 "${scenario}" "http-small-group" "small group HTTP capacity" "capacity-target" "http-small-group.js"
      ;;
    hot-write-smoke)
      run_k6 "${scenario}" "http-hot-write" "hot conversation write smoke" "local-hot-smoke" "http-hot-conversation-write.js"
      ;;
    hot-write-baseline)
      run_k6 "${scenario}" "http-hot-write" "hot conversation write baseline" "staging-hot-baseline" "http-hot-conversation-write.js"
      ;;
    hot-write-capacity)
      run_k6 "${scenario}" "http-hot-write" "hot conversation write capacity" "capacity-hot-target" "http-hot-conversation-write.js"
      ;;
    online-idle-1000)
      run_online_idle "${scenario}" "1000"
      ;;
    online-idle-5000)
      run_online_idle "${scenario}" "5000"
      ;;
    online-idle-10000)
      run_online_idle "${scenario}" "10000"
      ;;
    reconnect-soak-1000)
      run_reconnect_online "${scenario}" "1000" "0"
      ;;
    reconnect-soak-5000)
      run_reconnect_online "${scenario}" "5000" "0"
      ;;
    reconnect-drill-1000)
      run_reconnect_online "${scenario}" "1000" "${RECONNECT_DRILL_MIN_RECONNECTS:-1}"
      ;;
    multi-device-online-1x5)
      run_multi_device_online "${scenario}" "1" "5"
      ;;
    multi-device-online-100x2)
      run_multi_device_online "${scenario}" "100" "2"
      ;;
    multi-device-delivery-100x2-10)
      run_multi_device_delivery "${scenario}" "100" "2" "10"
      ;;
    multi-device-delivery-500x2-20)
      run_multi_device_delivery "${scenario}" "500" "2" "20"
      ;;
    pair-delivery-1000-10)
      run_pair_delivery "${scenario}" "1000" "10"
      ;;
    pair-delivery-1000-50)
      run_pair_delivery "${scenario}" "1000" "50"
      ;;
    pair-delivery-1000-100)
      run_pair_delivery "${scenario}" "1000" "100"
      ;;
    pair-delivery-2000-50)
      run_pair_delivery "${scenario}" "2000" "50"
      ;;
    pair-delivery-3000-50)
      run_pair_delivery "${scenario}" "3000" "50"
      ;;
    pair-delivery-5000-50)
      run_pair_delivery "${scenario}" "5000" "50"
      ;;
    online-chat-mix-5000-10)
      run_pair_delivery "${scenario}" "5000" "10"
      ;;
    direct-burst-1000-100)
      run_pair_delivery "${scenario}" "1000" "100"
      ;;
    direct-burst-1000-200)
      run_pair_delivery "${scenario}" "1000" "200"
      ;;
    group-delivery-50-5)
      run_group_delivery "${scenario}" "50" "5"
      ;;
    group-delivery-100-10)
      run_group_delivery "${scenario}" "100" "10"
      ;;
    group-delivery-500-10)
      run_group_delivery "${scenario}" "500" "10"
      ;;
    group-delivery-500-30)
      run_group_delivery "${scenario}" "500" "30"
      ;;
    large-group-1000-10)
      run_large_group "${scenario}" "1000" "10"
      ;;
    large-group-1000-50)
      run_large_group "${scenario}" "1000" "50"
      ;;
    large-group-5000-50)
      run_large_group "${scenario}" "5000" "50"
      ;;
    large-group-10000-5)
      run_large_group "${scenario}" "10000" "5"
      ;;
    large-group-10000-10)
      run_large_group "${scenario}" "10000" "10"
      ;;
    large-group-10000-200)
      run_large_group "${scenario}" "10000" "200"
      ;;
    *)
      echo "Unknown scenario: ${scenario}" >&2
      exit 2
      ;;
  esac
done

python3 "${SCRIPT_DIR}/perf_report.py" \
  --run-dir "${RUN_DIR}" \
  --output "${RUN_DIR}/report.md" \
  --json-output "${RUN_DIR}/report.json" \
  --csv-output "${RUN_DIR}/report.csv"

generate_post_report_artifacts

if bool_enabled "${PERF_GATE}"; then
  gate_args=(
    --report "${RUN_DIR}/report.json"
  )
  if bool_enabled "${PERF_GATE_ALLOW_UNKNOWN}"; then
    gate_args+=(--allow-unknown)
  fi
  if bool_enabled "${PERF_GATE_ALLOW_ENTRYPOINT_FAILURE}"; then
    gate_args+=(--allow-entrypoint-failure)
  fi
  for category in ${PERF_GATE_ALLOW_UNKNOWN_CATEGORIES}; do
    gate_args+=(--allow-unknown-category "${category}")
  done
  python3 "${SCRIPT_DIR}/perf_gate.py" "${gate_args[@]}" | tee "${RUN_DIR}/gate.log"
fi

echo
echo "Performance run directory: ${RUN_DIR}"
echo "Report: ${RUN_DIR}/report.md"
echo "JSON: ${RUN_DIR}/report.json"
echo "CSV: ${RUN_DIR}/report.csv"
if bool_enabled "${PERF_TRIAGE}" && [[ -f "${RUN_DIR}/triage.md" ]]; then
  echo "Triage: ${RUN_DIR}/triage.md"
fi
if bool_enabled "${PERF_SLO}" && [[ -f "${RUN_DIR}/slo.md" ]]; then
  echo "SLO: ${RUN_DIR}/slo.md"
fi
if bool_enabled "${PERF_EVIDENCE}" && [[ -f "${RUN_DIR}/evidence.md" ]]; then
  echo "Evidence: ${RUN_DIR}/evidence.md"
  print_evidence_summary
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/dashboard.md" ]]; then
  echo "Dashboard: ${RESULT_ROOT}/dashboard.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/optimization-playbook.md" ]]; then
  echo "Optimization playbook: ${RESULT_ROOT}/optimization-playbook.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/state-summary.md" ]]; then
  echo "State summary: ${RESULT_ROOT}/state-summary.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/scenario-status.md" ]]; then
  echo "Scenario status: ${RESULT_ROOT}/scenario-status.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && bool_enabled "${PERF_SLO}" && [[ -f "${RESULT_ROOT}/slo-status.md" ]]; then
  echo "SLO status: ${RESULT_ROOT}/slo-status.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && bool_enabled "${PERF_SLO}" && [[ -f "${RESULT_ROOT}/slo-domain-scorecard.md" ]]; then
  echo "SLO domain scorecard: ${RESULT_ROOT}/slo-domain-scorecard.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/production-gate.md" ]]; then
  echo "Production gate: ${RESULT_ROOT}/production-gate.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && bool_enabled "${PERF_SLO}" && [[ -f "${RESULT_ROOT}/slo-domain-run-plan.md" ]]; then
  echo "SLO domain run plan: ${RESULT_ROOT}/slo-domain-run-plan.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/next-actions.md" ]]; then
  echo "Next actions: ${RESULT_ROOT}/next-actions.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/scenario-catalog.md" ]]; then
  echo "Scenario catalog: ${RESULT_ROOT}/scenario-catalog.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/domain-backlog.md" ]]; then
  echo "Domain backlog: ${RESULT_ROOT}/domain-backlog.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/domain-run-plan.md" ]]; then
  echo "Domain run plan: ${RESULT_ROOT}/domain-run-plan.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/domain-scorecard.md" ]]; then
  echo "Domain scorecard: ${RESULT_ROOT}/domain-scorecard.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/prereq-audit.md" ]]; then
  echo "Prerequisite audit: ${RESULT_ROOT}/prereq-audit.md"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && [[ -f "${RESULT_ROOT}/readiness-gate.txt" ]]; then
  echo "Readiness gate: ${RESULT_ROOT}/readiness-gate.txt"
fi
if bool_enabled "${PERF_GLOBAL_STATUS}" && bool_enabled "${PERF_RUN_PLAN}" && [[ -f "${RESULT_ROOT}/run-plan.md" ]]; then
  echo "Run plan: ${RESULT_ROOT}/run-plan.md"
fi
if bool_enabled "${PERF_GATE}"; then
  echo "Gate: ${RUN_DIR}/gate.log"
fi
