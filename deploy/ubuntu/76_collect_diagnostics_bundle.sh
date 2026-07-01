#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

DIAGNOSTIC_ID="${DIAGNOSTIC_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
DIAGNOSTIC_OUTPUT_DIR="${DIAGNOSTIC_OUTPUT_DIR:-/tmp}"
DIAGNOSTIC_WORK_DIR="${DIAGNOSTIC_WORK_DIR:-${DIAGNOSTIC_OUTPUT_DIR}/imserver-diagnostics-${DIAGNOSTIC_ID}}"
DIAGNOSTIC_KEEP_DIR="${DIAGNOSTIC_KEEP_DIR:-false}"
DIAGNOSTIC_REDACTION_SELF_TEST="${DIAGNOSTIC_REDACTION_SELF_TEST:-false}"
DIAGNOSTIC_ENTRYPOINT_SELF_TEST="${DIAGNOSTIC_ENTRYPOINT_SELF_TEST:-false}"
DIAGNOSTIC_PERFORMANCE_SELF_TEST="${DIAGNOSTIC_PERFORMANCE_SELF_TEST:-false}"
DIAGNOSTIC_PERFORMANCE_GATE_JSON="${DIAGNOSTIC_PERFORMANCE_GATE_JSON:-/var/lib/imserver/performance/production-gate.json}"
DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK="${DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK:-/var/lib/imserver/performance/current-evidence}"
DIAGNOSTIC_PERFORMANCE_GATE_PROFILE="${DIAGNOSTIC_PERFORMANCE_GATE_PROFILE:-normal-product-baseline}"
DIAGNOSTIC_PERFORMANCE_GATE_MAX_AGE_SECONDS="${DIAGNOSTIC_PERFORMANCE_GATE_MAX_AGE_SECONDS:-604800}"
DIAGNOSTIC_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT="${DIAGNOSTIC_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT:-false}"
DIAGNOSTIC_PERFORMANCE_PROFILE_CATALOG="${DIAGNOSTIC_PERFORMANCE_PROFILE_CATALOG:-${SCRIPT_DIR}/../../IMServer/LoadTests/perf_production_profiles.json}"
JOURNAL_LINES="${JOURNAL_LINES:-300}"
HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_BASE_URL="${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_BASE_URL:-${PUBLIC_BASE_URL}}"
DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_TCP_HOST="${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_TCP_HOST:-}"
DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_TCP_PORT="${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_TCP_PORT:-${TCP_PORT:-9000}}"

service_units=(
  postgresql
  redis-server
  kafka
  nginx
  imserver-command-api
  imserver-gateway
  imserver-query-api
  imserver-outbox-relay
  imserver-stream-consumer
  imserver-domain-delivery-consumer
)

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

redact_stream() {
  sed -E \
    -e 's/((^|[^A-Z0-9_])(JWT_SECRET|JWT_SECRETS|IM_INTERNAL_SHARED_SECRET|IM_COMMAND_INTERNAL_SHARED_SECRET|DATABASE_PASSWORD|DATABASE_PRIMARY_PASSWORD|DATABASE_[A-Z0-9_]*_PASSWORD|MEDIA_STORAGE_S3_SECRET_ACCESS_KEY|IM_KAFKA_SASL_PASSWORD|AUDIT_ALERT_WEBHOOK_URL|AUDIT_ALERT_WEBHOOK_HEADER|SEED_USER_PASSWORD|PASSWORD|TOKEN|SECRET|SECRETS|ACCESS_KEY|AUTHORIZATION)[[:space:]]*=[[:space:]]*).*/\1<redacted>/Ig' \
    -e 's/(Authorization:[[:space:]]*(Bearer|Basic)[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1<redacted>/Ig' \
    -e 's/(accessToken|refreshToken|token|password|secret|secrets|jwtSecrets)"[[:space:]]*:[[:space:]]*"[^"]+"/\1":"<redacted>"/Ig' \
    -e 's/((^|[^A-Z0-9_])(password|token|secret|secrets|authorization|access_key)[[:space:]]*:[[:space:]]*`?)[^`[:space:]]+`?/\1<redacted>/Ig' \
    -e 's#(postgres(ql)?://[^:/@]+:)[^@/]+#\1<redacted>#Ig' \
    -e 's#(redis://([^:@/]*:)?)[^@/]+@#\1<redacted>@#Ig'
}

run_redaction_self_test() {
  local sample output
  sample="$(cat <<'EOF'
JWT_SECRET=jwt-secret-value
JWT_SECRETS=old:jwt-old-secret-value,active:jwt-active-secret-value
IM_INTERNAL_SHARED_SECRET=internal-secret-value
DATABASE_PASSWORD=db-password-value
DATABASE_CONVERSATION_SHARD_0_PASSWORD=shard-password-value
MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=s3-secret-value
IM_KAFKA_SASL_PASSWORD=kafka-secret-value
AUDIT_ALERT_WEBHOOK_URL=https://hooks.example.local/secret-webhook-token
AUDIT_ALERT_WEBHOOK_HEADER=Authorization: Bearer alert-token-value
SEED_USER_PASSWORD=seed-password-value
Authorization: Bearer bearer-token-value
Authorization: Basic basic-token-value
{"accessToken":"json-access-token","refreshToken":"json-refresh-token","password":"json-password","secret":"json-secret","jwtSecrets":"json-jwt-secrets"}
- secret: `markdown-secret-value`
- token: markdown-token-value
- password: markdown-password-value
DATABASE_URL=postgres://imserver:postgres-url-password@127.0.0.1:5432/imserver
REDIS_URL=redis://:redis-url-password@127.0.0.1:6379
plainText=not-secret
EOF
)"
  output="$(printf '%s\n' "${sample}" | redact_stream)"
  local leaked=0
  for forbidden in \
    jwt-secret-value \
    jwt-old-secret-value \
    jwt-active-secret-value \
    internal-secret-value \
    db-password-value \
    shard-password-value \
    s3-secret-value \
    kafka-secret-value \
    secret-webhook-token \
    alert-token-value \
    seed-password-value \
    bearer-token-value \
    basic-token-value \
    json-access-token \
    json-refresh-token \
    json-password \
    json-secret \
    json-jwt-secrets \
    markdown-secret-value \
    markdown-token-value \
    markdown-password-value \
    postgres-url-password \
    redis-url-password
  do
    if printf '%s\n' "${output}" | grep -Fq "${forbidden}"; then
      printf 'redaction self-test result=fail leaked=%s\n' "${forbidden}" >&2
      leaked=1
    fi
  done

  if ! printf '%s\n' "${output}" | grep -Fq 'plainText=not-secret'; then
    printf 'redaction self-test result=fail reason=non_secret_text_was_not_preserved\n' >&2
    leaked=1
  fi

  if [[ "${leaked}" != "0" ]]; then
    printf '%s\n' "${output}" >&2
    return 1
  fi

  printf 'redaction self-test result=pass\n'
}

run_capture() {
  local output="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@" 2>&1 || true
  } | redact_stream >"${output}"
}

run_shell_capture() {
  local output="$1"
  local command="$2"
  {
    printf '$ %s\n' "${command}"
    bash -c "${command}" 2>&1 || true
  } | redact_stream >"${output}"
}

copy_redacted_file() {
  local src="$1"
  local dst="$2"
  if [[ -f "${src}" ]]; then
    redact_stream <"${src}" >"${dst}"
  fi
}

current_release_dir() {
  if [[ -L "${IMSERVER_CURRENT_LINK}" ]]; then
    readlink -f "${IMSERVER_CURRENT_LINK}" || true
  elif [[ -L "${IMSERVER_BIN_DIR}/IMServer" ]]; then
    dirname "$(dirname "$(readlink -f "${IMSERVER_BIN_DIR}/IMServer")")"
  fi
}

canonical_path() {
  local path="$1"
  readlink -f "${path}" 2>/dev/null || python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${path}"
}

collect_performance_diagnostics() {
  install -d -m 0700 "${DIAGNOSTIC_WORK_DIR}/performance"

  if [[ -f "${DIAGNOSTIC_PERFORMANCE_GATE_JSON}" ]]; then
    copy_redacted_file "${DIAGNOSTIC_PERFORMANCE_GATE_JSON}" "${DIAGNOSTIC_WORK_DIR}/performance/production-gate.json.redacted"
  fi

  if [[ -e "${DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK}" ]]; then
    evidence_dir="$(canonical_path "${DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK}" || true)"
    {
      printf 'currentEvidenceLink=%s\n' "${DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK}"
      printf 'currentEvidenceTarget=%s\n' "${evidence_dir:-<unresolved>}"
      if [[ -f "${evidence_dir}/production-profile-runbook.json" ]]; then
        python3 - "${evidence_dir}/production-profile-runbook.json" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
plan = payload.get("plan") or {}
prereq = payload.get("prereq") or {}
print(f"runbookStatus={payload.get('status') or '-'}")
print(f"runbookProfile={payload.get('profile') or '-'}")
print(f"runbookSelectedSkippedBatches={plan.get('selectedScenarioCount') or 0}/{plan.get('skippedFreshPassCount') or 0}/{plan.get('batchCount') or 0}")
print(f"runbookMissingRequired={prereq.get('missingRequiredCount') or 0}")
PY
      else
        printf 'runbookStatus=<missing>\n'
      fi
      if [[ -f "${evidence_dir}/product-test-plan-preview.json" ]]; then
        python3 - "${evidence_dir}/product-test-plan-preview.json" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
summary = payload.get("summary") or {}
covered = summary.get("coveredProductDomains") or []
missing = summary.get("missingProductDomains") or []
print(f"productPlanScenarioCount={summary.get('uniqueScenarioCount', '-')}")
print(f"productPlanLargeGroupIncluded={summary.get('largeGroupIncluded', '-')}")
print(f"productPlanDomainCount={len(covered)}")
print(f"productPlanRequiredDomainsCovered={summary.get('requiredProductDomainsCovered', '-')}")
print(f"productPlanMissingDomains={','.join(str(item) for item in missing) or '-'}")
PY
      else
        printf 'productPlanScenarioCount=<missing>\n'
      fi
      if [[ -f "${evidence_dir}/product-campaign-run.json" ]]; then
        python3 - "${evidence_dir}/product-campaign-run.json" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
print(f"productCampaign={payload.get('campaign') or '-'}")
print(f"productCampaignStatus={payload.get('finalStatus') or '-'}")
print(
    "productCampaignFailuresRequiredAttemptedSkipped="
    f"{payload.get('failureCount', '-')}/{payload.get('requiredFailureCount', '-')}/"
    f"{payload.get('attemptedStageCount', '-')}/{payload.get('skippedStageCount', '-')}"
)
PY
      else
        printf 'productCampaign=<missing>\n'
      fi
    } >"${DIAGNOSTIC_WORK_DIR}/performance/current-evidence.txt"
    if [[ -n "${evidence_dir}" && -d "${evidence_dir}" ]]; then
      for file_name in \
        README.md \
        SHA256SUMS \
        docs-audit.json \
        docs-audit.md \
        production-evidence-manifest.json \
        production-profile-run.json \
        production-profile-entrypoint-probe.log \
        production-profile-entrypoint-probe.json \
        production-profile-runbook.json \
        production-profile-runbook.md \
        production-profile-plan.json \
        production-profile-prereq-plan.json \
        production-profile-prereq-audit.md \
        production-profile-prereq-audit.json \
        production-profile-scenario-catalog.json \
        product-test-plan-preview.json \
        product-campaign-run.json \
        product-campaign-runbook.md \
        perf_production_profiles.json \
        validation-inventory.json \
        validation-inventory.md
      do
        if [[ -f "${evidence_dir}/${file_name}" ]]; then
          copy_redacted_file "${evidence_dir}/${file_name}" "${DIAGNOSTIC_WORK_DIR}/performance/${file_name}.redacted"
        fi
      done
    fi
  else
    printf 'currentEvidenceLink=%s\ncurrentEvidenceTarget=<missing>\n' \
      "${DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK}" \
      >"${DIAGNOSTIC_WORK_DIR}/performance/current-evidence.txt"
  fi

  run_capture "${DIAGNOSTIC_WORK_DIR}/performance/performance-gate-verify.txt" \
    env \
    "PERF_PRODUCTION_GATE_JSON=${DIAGNOSTIC_PERFORMANCE_GATE_JSON}" \
    "PERF_PRODUCTION_GATE_PROFILE=${DIAGNOSTIC_PERFORMANCE_GATE_PROFILE}" \
    "PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=${DIAGNOSTIC_PERFORMANCE_GATE_MAX_AGE_SECONDS}" \
    "PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=${DIAGNOSTIC_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}" \
    "PERF_PRODUCTION_GATE_EXPECT_BASE_URL=${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_BASE_URL}" \
    "PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_TCP_HOST}" \
    "PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_TCP_PORT}" \
    "PERF_PRODUCTION_PROFILE_CATALOG=${DIAGNOSTIC_PERFORMANCE_PROFILE_CATALOG}" \
    bash "${SCRIPT_DIR}/67_verify_performance_gate.sh"

  run_capture "${DIAGNOSTIC_WORK_DIR}/performance/performance-evidence-verify.txt" \
    env \
    "PERF_PRODUCTION_EVIDENCE_CURRENT_LINK=${DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK}" \
    "PERF_PRODUCTION_GATE_JSON=${DIAGNOSTIC_PERFORMANCE_GATE_JSON}" \
    "PERF_PRODUCTION_GATE_PROFILE=${DIAGNOSTIC_PERFORMANCE_GATE_PROFILE}" \
    "PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=${DIAGNOSTIC_PERFORMANCE_GATE_MAX_AGE_SECONDS}" \
    "PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=${DIAGNOSTIC_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT}" \
    "PERF_PRODUCTION_GATE_EXPECT_BASE_URL=${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_BASE_URL}" \
    "PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_TCP_HOST}" \
    "PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=${DIAGNOSTIC_PERFORMANCE_GATE_EXPECT_TCP_PORT}" \
    "PERF_PRODUCTION_PROFILE_CATALOG=${DIAGNOSTIC_PERFORMANCE_PROFILE_CATALOG}" \
    bash "${SCRIPT_DIR}/70_verify_performance_evidence_package.sh"
}

collect_entrypoint_diagnostics() {
  install -d -m 0700 "${DIAGNOSTIC_WORK_DIR}/probes"
  HTTP_PORT="${HTTP_PORT}" \
  PUBLIC_BASE_URL="${PUBLIC_BASE_URL}" \
  JOURNAL_LINES="${JOURNAL_LINES}" \
    bash "${SCRIPT_DIR}/75_entrypoint_diagnose.sh" 2>&1 \
    | redact_stream >"${DIAGNOSTIC_WORK_DIR}/probes/entrypoint-diagnose.txt" || true
}

run_entrypoint_self_test() {
  local tmp_dir fake_bin secret
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN
  fake_bin="${tmp_dir}/bin"
  secret="diagnostic-entrypoint-secret-value"
  mkdir -p "${fake_bin}" "${tmp_dir}/bundle"
  cat >"${fake_bin}/curl" <<'SH'
#!/usr/bin/env bash
body_file=""
header_file=""
url=""
while (($#)); do
  case "$1" in
    -o)
      body_file="$2"
      shift 2
      ;;
    -D)
      header_file="$2"
      shift 2
      ;;
    -w|-m|--connect-timeout|--max-time|-X|-H|--data)
      shift 2
      ;;
    -sS)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
code=200
body="ok"
case "${url}" in
  *public-bad*)
    code=403
    body=""
    ;;
esac
if [[ -n "${body_file}" ]]; then
  printf '%s' "${body}" >"${body_file}"
fi
if [[ -n "${header_file}" ]]; then
  printf 'HTTP/1.1 %s Test\r\nAuthorization: Bearer diagnostic-entrypoint-secret-value\r\n\r\n' "${code}" >"${header_file}"
fi
printf '%s' "${code}"
SH
  cat >"${fake_bin}/nc" <<'SH'
#!/usr/bin/env bash
zero_check=false
host=""
port=""
while (($#)); do
  case "$1" in
    -z)
      zero_check=true
      shift
      ;;
    -w)
      shift 2
      ;;
    *)
      if [[ -z "${host}" ]]; then
        host="$1"
      else
        port="$1"
      fi
      shift
      ;;
  esac
done
if [[ "${zero_check}" == true ]]; then
  exit 0
fi
case "${host}" in
  public-bad)
    printf 'HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'
    ;;
esac
exit 0
SH
  chmod +x "${fake_bin}/curl" "${fake_bin}/nc"

  PATH="${fake_bin}:${PATH}" \
  DIAGNOSTIC_WORK_DIR="${tmp_dir}/bundle" \
  PUBLIC_BASE_URL=http://public-bad:8080 \
  HTTP_PORT=8080 \
  TCP_PORT=9000 \
  JOURNAL_LINES=1 \
  CURL_TIMEOUT_SECONDS=1 \
    collect_entrypoint_diagnostics

  if [[ ! -f "${tmp_dir}/bundle/probes/entrypoint-diagnose.txt" ]]; then
    printf 'diagnostic-entrypoint self-test result=fail reason=entrypoint_diagnose_missing\n' >&2
    return 1
  fi
  grep -q 'protocolProbeSummary=public sampled=3 http403=3 edgeIntercept=http_403_all_sampled_ports' "${tmp_dir}/bundle/probes/entrypoint-diagnose.txt" || {
    printf 'diagnostic-entrypoint self-test result=fail reason=protocol_summary_missing\n' >&2
    return 1
  }
  grep -q 'diagnosis=cloud_edge_http_403_intercept' "${tmp_dir}/bundle/probes/entrypoint-diagnose.txt" || {
    printf 'diagnostic-entrypoint self-test result=fail reason=cloud_edge_diagnosis_missing\n' >&2
    return 1
  }
  if grep -R -Fq "${secret}" "${tmp_dir}/bundle/probes"; then
    printf 'diagnostic-entrypoint self-test result=fail reason=secret_leaked\n' >&2
    return 1
  fi
  printf 'diagnostic-entrypoint self-test result=pass\n'
}

run_performance_self_test() {
  local tmp_dir secret
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN
  secret="diagnostic-performance-secret-value"
  DIAGNOSTIC_WORK_DIR="${tmp_dir}/bundle"
  DIAGNOSTIC_PERFORMANCE_GATE_JSON="${tmp_dir}/production-gate.json"
  DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK="${tmp_dir}/current-evidence"
  mkdir -p "${tmp_dir}/evidence" "${DIAGNOSTIC_WORK_DIR}"
  printf '{"status":"FAIL","profile":"minimum-smoke","secret":"%s"}\n' "${secret}" >"${DIAGNOSTIC_PERFORMANCE_GATE_JSON}"
  printf '{"schemaVersion":1,"profile":"minimum-smoke","source":{"gitCommit":"self-test","gitDirty":false},"profileCatalog":{"sha256":"self-test"},"requiredFiles":["README.md"],"files":[],"secret":"%s"}\n' "${secret}" >"${tmp_dir}/evidence/production-evidence-manifest.json"
  printf '{"schemaVersion":1,"profile":"minimum-smoke","finalStatus":"PASS","dryRun":false,"secret":"%s"}\n' "${secret}" >"${tmp_dir}/evidence/production-profile-run.json"
  printf 'diagnosis=ok secret=%s\n' "${secret}" >"${tmp_dir}/evidence/production-profile-entrypoint-probe.log"
  printf '{"schemaVersion":1,"diagnosis":"ok","failed":false,"secret":"%s"}\n' "${secret}" >"${tmp_dir}/evidence/production-profile-entrypoint-probe.json"
  printf '{"schemaVersion":1,"status":"READY","profile":"minimum-smoke","commands":{"profile":"./run_production_profile.sh"},"secret":"%s"}\n' "${secret}" >"${tmp_dir}/evidence/production-profile-runbook.json"
  printf '# Production Profile Runbook\n\n- status: `READY`\n- secret: `%s`\n' "${secret}" >"${tmp_dir}/evidence/production-profile-runbook.md"
  printf '{"profile":"minimum-smoke","secret":"%s"}\n' "${secret}" >"${tmp_dir}/evidence/production-profile-plan.json"
  printf '{"profile":"minimum-smoke","selectedScenarios":["login-smoke"]}\n' >"${tmp_dir}/evidence/production-profile-prereq-plan.json"
  printf '{"summary":{"overallStatus":"READY"},"secret":"%s"}\n' "${secret}" >"${tmp_dir}/evidence/production-profile-prereq-audit.json"
  printf '{"scenarios":[{"scenario":"login-smoke"}]}\n' >"${tmp_dir}/evidence/production-profile-scenario-catalog.json"
  printf '{"schemaVersion":1,"profiles":{"minimum-smoke":["login-smoke"]}}\n' >"${tmp_dir}/evidence/perf_production_profiles.json"
  cat >"${tmp_dir}/evidence/product-test-plan-preview.json" <<EOF
{
  "schemaVersion": 1,
  "summary": {
    "uniqueScenarioCount": 8,
    "largeGroupIncluded": false,
    "coveredProductDomains": [
      "account-security",
      "sync-read",
      "direct-chat",
      "group-workflow",
      "contacts-social",
      "media-ai-admin",
      "reliability-recovery",
      "realtime-direct"
    ],
    "missingProductDomains": [],
    "requiredProductDomainsCovered": true
  },
  "secret": "${secret}"
}
EOF
  printf '{"status":"PASS","secret":"%s"}\n' "${secret}" >"${tmp_dir}/evidence/docs-audit.json"
  printf '# Docs Audit\n\n- status: `PASS`\n' >"${tmp_dir}/evidence/docs-audit.md"
  printf '{"source":{"gitCommit":"self-test"},"secret":"%s"}\n' "${secret}" >"${tmp_dir}/evidence/validation-inventory.json"
  printf '# Validation Inventory\n\n- gitCommit: `self-test`\n' >"${tmp_dir}/evidence/validation-inventory.md"
  cat >"${tmp_dir}/evidence/product-campaign-run.json" <<EOF
{
  "schemaVersion": 1,
  "campaign": "non-large-group-release",
  "execute": true,
  "finalStatus": "PASS",
  "failureCount": 0,
  "requiredFailureCount": 0,
  "attemptedStageCount": 7,
  "skippedStageCount": 0,
  "stageCount": 7,
  "stages": []
}
EOF
  printf '# Product Campaign Runbook\n\n- campaign: `non-large-group-release`\n\nSecret values are represented as shell placeholders.\n' >"${tmp_dir}/evidence/product-campaign-runbook.md"
  printf 'checksum-placeholder\n' >"${tmp_dir}/evidence/SHA256SUMS"
  ln -s "${tmp_dir}/evidence" "${DIAGNOSTIC_PERFORMANCE_EVIDENCE_CURRENT_LINK}"
  collect_performance_diagnostics
  for required in \
    production-gate.json.redacted \
    current-evidence.txt \
    docs-audit.json.redacted \
    docs-audit.md.redacted \
    production-evidence-manifest.json.redacted \
    production-profile-run.json.redacted \
    production-profile-entrypoint-probe.log.redacted \
    production-profile-entrypoint-probe.json.redacted \
    production-profile-runbook.json.redacted \
    production-profile-runbook.md.redacted \
    production-profile-plan.json.redacted \
    production-profile-prereq-audit.json.redacted \
    product-test-plan-preview.json.redacted \
    product-campaign-run.json.redacted \
    product-campaign-runbook.md.redacted \
    perf_production_profiles.json.redacted \
    validation-inventory.json.redacted \
    performance-gate-verify.txt \
    performance-evidence-verify.txt
  do
    [[ -f "${DIAGNOSTIC_WORK_DIR}/performance/${required}" ]] || {
      printf 'diagnostic-performance self-test result=fail reason=missing_file file=%s\n' "${required}" >&2
      return 1
    }
  done
  grep -q 'productCampaign=non-large-group-release' "${DIAGNOSTIC_WORK_DIR}/performance/current-evidence.txt" || {
    printf 'diagnostic-performance self-test result=fail reason=campaign_summary_missing\n' >&2
    return 1
  }
  grep -q 'productPlanScenarioCount=8' "${DIAGNOSTIC_WORK_DIR}/performance/current-evidence.txt" || {
    printf 'diagnostic-performance self-test result=fail reason=product_plan_scenario_summary_missing\n' >&2
    return 1
  }
  grep -q 'productPlanDomainCount=8' "${DIAGNOSTIC_WORK_DIR}/performance/current-evidence.txt" || {
    printf 'diagnostic-performance self-test result=fail reason=product_plan_domain_summary_missing\n' >&2
    return 1
  }
  grep -q 'productPlanRequiredDomainsCovered=True' "${DIAGNOSTIC_WORK_DIR}/performance/current-evidence.txt" || {
    printf 'diagnostic-performance self-test result=fail reason=product_plan_domain_coverage_missing\n' >&2
    return 1
  }
  grep -q 'productCampaignFailuresRequiredAttemptedSkipped=0/0/7/0' "${DIAGNOSTIC_WORK_DIR}/performance/current-evidence.txt" || {
    printf 'diagnostic-performance self-test result=fail reason=campaign_counters_missing\n' >&2
    return 1
  }
  if grep -R -Fq "${secret}" "${DIAGNOSTIC_WORK_DIR}/performance"; then
    printf 'diagnostic-performance self-test result=fail reason=secret_leaked\n' >&2
    return 1
  fi
  printf 'diagnostic-performance self-test result=pass\n'
}

if bool_enabled "${DIAGNOSTIC_REDACTION_SELF_TEST}"; then
  run_redaction_self_test
  exit 0
fi

if bool_enabled "${DIAGNOSTIC_ENTRYPOINT_SELF_TEST}"; then
  run_entrypoint_self_test
  exit 0
fi

if bool_enabled "${DIAGNOSTIC_PERFORMANCE_SELF_TEST}"; then
  run_performance_self_test
  exit 0
fi

require_root

rm -rf "${DIAGNOSTIC_WORK_DIR}"
install -d -m 0700 "${DIAGNOSTIC_WORK_DIR}" \
  "${DIAGNOSTIC_WORK_DIR}/config" \
  "${DIAGNOSTIC_WORK_DIR}/release" \
  "${DIAGNOSTIC_WORK_DIR}/performance" \
  "${DIAGNOSTIC_WORK_DIR}/system" \
  "${DIAGNOSTIC_WORK_DIR}/logs" \
  "${DIAGNOSTIC_WORK_DIR}/network" \
  "${DIAGNOSTIC_WORK_DIR}/probes"

{
  printf 'diagnosticID=%s\n' "${DIAGNOSTIC_ID}"
  printf 'createdAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'hostname=%s\n' "$(hostname)"
  printf 'kernel=%s\n' "$(uname -a)"
  printf 'script=%s\n' "$0"
  printf 'publicBaseURL=%s\n' "${PUBLIC_BASE_URL:-<unset>}"
  printf 'redaction=enabled\n'
} >"${DIAGNOSTIC_WORK_DIR}/metadata.txt"

copy_redacted_file "${IMSERVER_ETC_DIR}/common.env" "${DIAGNOSTIC_WORK_DIR}/config/common.env.redacted"
if [[ -d "${IMSERVER_ETC_DIR}/roles" ]]; then
  for role_env in "${IMSERVER_ETC_DIR}"/roles/*.env; do
    [[ -f "${role_env}" ]] || continue
    copy_redacted_file "${role_env}" "${DIAGNOSTIC_WORK_DIR}/config/$(basename "${role_env}").redacted"
  done
fi
copy_redacted_file "${IMSERVER_ETC_DIR}/operational-alert.env" "${DIAGNOSTIC_WORK_DIR}/config/operational-alert.env.redacted"

release_dir="$(current_release_dir)"
if [[ -n "${release_dir}" && -d "${release_dir}" ]]; then
  for file_name in release.env release-manifest.json SHA256SUMS; do
    if [[ -f "${release_dir}/${file_name}" ]]; then
      copy_redacted_file "${release_dir}/${file_name}" "${DIAGNOSTIC_WORK_DIR}/release/${file_name}.redacted"
    fi
  done
  if [[ -x "${release_dir}/bin/IMServer" ]]; then
    sha256sum "${release_dir}/bin/IMServer" >"${DIAGNOSTIC_WORK_DIR}/release/current-binary.sha256"
  fi
fi

collect_performance_diagnostics

run_capture "${DIAGNOSTIC_WORK_DIR}/system/os-release.txt" cat /etc/os-release
run_capture "${DIAGNOSTIC_WORK_DIR}/system/uptime.txt" uptime
run_capture "${DIAGNOSTIC_WORK_DIR}/system/free.txt" free -h
run_capture "${DIAGNOSTIC_WORK_DIR}/system/df.txt" df -h
run_capture "${DIAGNOSTIC_WORK_DIR}/system/limits.txt" bash -lc 'ulimit -a'
run_capture "${DIAGNOSTIC_WORK_DIR}/system/sysctl.txt" sysctl fs.file-max fs.nr_open net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
run_capture "${DIAGNOSTIC_WORK_DIR}/system/systemctl-failed.txt" systemctl --no-pager --failed
run_capture "${DIAGNOSTIC_WORK_DIR}/system/timers.txt" systemctl --no-pager list-timers 'imserver-*'

for unit in "${service_units[@]}"; do
  run_capture "${DIAGNOSTIC_WORK_DIR}/system/status-${unit}.txt" systemctl --no-pager --lines=50 status "${unit}"
done

run_shell_capture "${DIAGNOSTIC_WORK_DIR}/network/listeners.txt" "ss -ltnp"
run_shell_capture "${DIAGNOSTIC_WORK_DIR}/network/tcp-established-summary.txt" "ss -Htan state established | awk '{print \$4}' | sed 's/.*://' | sort | uniq -c | sort -nr | head -50"
run_capture "${DIAGNOSTIC_WORK_DIR}/network/ufw.txt" ufw status verbose
run_shell_capture "${DIAGNOSTIC_WORK_DIR}/network/nft-head.txt" "nft list ruleset 2>/dev/null | head -n 200"

run_shell_capture "${DIAGNOSTIC_WORK_DIR}/system/nginx-summary.txt" "nginx -T 2>/dev/null | awk '/server \\{|listen |server_name |location |proxy_pass |allow |deny / {print}' | head -n 240"

for unit in "${service_units[@]}"; do
  run_capture "${DIAGNOSTIC_WORK_DIR}/logs/journal-${unit}.txt" journalctl -u "${unit}" -n "${JOURNAL_LINES}" --no-pager
done

AUDIT_REQUIRE_ENTRYPOINT=false \
  bash "${SCRIPT_DIR}/77_operational_audit.sh" 2>&1 \
  | redact_stream >"${DIAGNOSTIC_WORK_DIR}/probes/operational-audit.txt" || true

collect_entrypoint_diagnostics

archive_path="${DIAGNOSTIC_OUTPUT_DIR%/}/imserver-diagnostics-${DIAGNOSTIC_ID}.tar.gz"
tar -C "$(dirname "${DIAGNOSTIC_WORK_DIR}")" -czf "${archive_path}" "$(basename "${DIAGNOSTIC_WORK_DIR}")"
chmod 0600 "${archive_path}"

if ! bool_enabled "${DIAGNOSTIC_KEEP_DIR}"; then
  rm -rf "${DIAGNOSTIC_WORK_DIR}"
fi

printf 'diagnostics bundle=%s redaction=enabled keepDir=%s\n' "${archive_path}" "${DIAGNOSTIC_KEEP_DIR}"
