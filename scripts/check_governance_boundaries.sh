#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  local path="$1"
  [[ -f "${ROOT_DIR}/${path}" ]] || {
    echo "Missing required governance file: ${path}" >&2
    exit 1
  }
}

require_match() {
  local pattern="$1"
  local path="$2"
  rg -q "${pattern}" "${ROOT_DIR}/${path}" || {
    echo "Missing required governance pattern '${pattern}' in ${path}" >&2
    exit 1
  }
}

require_file ".github/CODEOWNERS"
require_file ".github/pull_request_template.md"
require_file "docs/architecture-boundaries.md"
require_file "docs/service-size-budgets.tsv"

require_match "/IMServer/Sources/IMServer/IM/" ".github/CODEOWNERS"
require_match "/IMApp/" ".github/CODEOWNERS"
require_match "/IMClientKitAndroid/" ".github/CODEOWNERS"
require_match "AI stream message/index writes go through the stream state store" ".github/pull_request_template.md"
require_match "AIStreamRequestGuardrails" ".github/pull_request_template.md"
require_match "App/UI layers must not directly parse TCP packets" "docs/architecture-boundaries.md"
require_match "real Redis staging and capacity data" "docs/architecture-boundaries.md"
require_match "service-size-budgets.tsv" "docs/architecture-boundaries.md"

check_ai_stream_state_write_boundaries() {
  local allowed='AIMessageStream(WriteStore|RepairStore|StateStore|MutationBuilder)\.swift$'
  local matches
  matches="$(
    rg -n \
      'AIMessageStreamIndex\(|withStreamState\(|lifecycleState\s*=' \
      "${ROOT_DIR}/IMServer/Sources/IMServer/IM" || true
  )"

  while IFS= read -r match; do
    [[ -z "${match}" ]] && continue
    local file="${match%%:*}"
    if [[ ! "${file}" =~ ${allowed} ]]; then
      echo "AI stream state mutation must stay behind the state/write/repair stores: ${match}" >&2
      exit 1
    fi
  done <<< "${matches}"
}

check_ai_stream_state_write_boundaries

check_service_size_budgets() {
  local budgets="${ROOT_DIR}/docs/service-size-budgets.tsv"
  while IFS=$'\t' read -r path max_lines _owner_note; do
    [[ -z "${path}" || "${path}" =~ ^# ]] && continue
    local file="${ROOT_DIR}/${path}"
    [[ -f "${file}" ]] || {
      echo "Size budget references missing file: ${path}" >&2
      exit 1
    }
    local line_count
    line_count="$(wc -l < "${file}" | tr -d ' ')"
    if (( line_count > max_lines )); then
      echo "Service size budget exceeded: ${path} has ${line_count} lines, budget ${max_lines}" >&2
      exit 1
    fi
  done < "${budgets}"
}

check_service_size_budgets

echo "Governance boundary checks passed."
