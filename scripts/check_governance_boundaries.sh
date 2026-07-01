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
require_file "docs/domain-boundaries.md"
require_file "docs/complexity-budgets.tsv"

require_match "/IMServer/Sources/IMServer/IM/" ".github/CODEOWNERS"
require_match "/IMApp/" ".github/CODEOWNERS"
require_match "/IMClientKitAndroid/" ".github/CODEOWNERS"
require_match "/imclientkit/" ".github/CODEOWNERS"
require_match "Touched domains" ".github/pull_request_template.md"
require_match "AI stream message/index writes go through the stream state store" ".github/pull_request_template.md"
require_match "AIStreamRequestGuardrails" ".github/pull_request_template.md"
require_match "complexity-budgets.tsv" ".github/pull_request_template.md"
require_match "App/UI layers must not directly parse TCP packets" "docs/architecture-boundaries.md"
require_match "real Redis staging and capacity data" "docs/architecture-boundaries.md"
require_match "complexity-budgets.tsv" "docs/architecture-boundaries.md"
require_match "AIStreamProviderPolicyService" "docs/domain-boundaries.md"
require_match "only component allowed to atomically update" "docs/domain-boundaries.md"

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

check_complexity_budgets() {
  local budgets="${ROOT_DIR}/docs/complexity-budgets.tsv"
  while IFS=$'\t' read -r path max_lines category owner_note; do
    [[ -z "${path}" || "${path}" =~ ^# ]] && continue
    [[ -n "${max_lines}" && -n "${category}" && -n "${owner_note}" ]] || {
      echo "Complexity budget row must include path, max_lines, category, owner_note: ${path}" >&2
      exit 1
    }
    local file="${ROOT_DIR}/${path}"
    [[ -f "${file}" ]] || {
      echo "Complexity budget references missing file: ${path}" >&2
      exit 1
    }
    local line_count
    line_count="$(wc -l < "${file}" | tr -d ' ')"
    if (( line_count > max_lines )); then
      echo "Complexity budget exceeded: ${path} has ${line_count} lines, budget ${max_lines}" >&2
      exit 1
    fi
  done < "${budgets}"
}

check_no_unbudgeted_large_files() {
  local threshold=400
  local budgets="${ROOT_DIR}/docs/complexity-budgets.tsv"
  local budget_paths
  budget_paths="$(mktemp)"
  trap "rm -f '${budget_paths}'" EXIT
  awk -F '\t' 'NF && $1 !~ /^#/ { print $1 }' "${budgets}" > "${budget_paths}"

  git -C "${ROOT_DIR}" ls-files | \
    rg '^(IMServer/Sources|IMApp/IMApp/|IMClientKit/Sources|app/src|imclientkit/src|IMClientKitAndroid).*\.(swift|kt)$' | \
    while IFS= read -r path; do
      [[ -z "${path}" ]] && continue
      [[ "${path}" == *"/Generated/"* ]] && continue
      local file="${ROOT_DIR}/${path}"
      [[ -f "${file}" ]] || continue
      local line_count
      line_count="$(wc -l < "${file}" | tr -d ' ')"
      if (( line_count > threshold )) && ! grep -Fxq "${path}" "${budget_paths}"; then
        echo "Large file lacks complexity budget: ${path} has ${line_count} lines, threshold ${threshold}" >&2
        exit 1
      fi
    done
}

check_ios_ui_boundaries() {
  git -C "${ROOT_DIR}" ls-files | \
    rg '^IMApp/IMApp/Features/.*\.swift$' | \
    while IFS= read -r path; do
      [[ -z "${path}" ]] && continue
      local matches
      matches="$(
        rg -n '(^import (GRDB|SQLite|NIO|PostgresNIO|Vapor)\b|IMTCPClient|SocketIMTCPTransport|AIMessageStreamStateStore|conversationWriteCoordinator)' \
          "${ROOT_DIR}/${path}" || true
      )"
      if [[ -n "${matches}" ]]; then
        echo "iOS Feature/UI code must stay behind app/runtime facades:" >&2
        echo "${matches}" >&2
        exit 1
      fi
    done
}

check_android_ui_boundaries() {
  git -C "${ROOT_DIR}" ls-files | \
    rg '^app/src/main/java/com/xmtx/imappandroid/(ui|viewmodel)/.*\.kt$' | \
    while IFS= read -r path; do
      [[ -z "${path}" ]] && continue
      local matches
      matches="$(
        rg -n '(^import io\.ktor\.|^import androidx\.room\.|^import com\.xmtx\.imclientkit\.networking\.imtcp\.|^import com\.xmtx\.imclientkit\.persistence\.imcache\.)' \
          "${ROOT_DIR}/${path}" || true
      )"
      if [[ -n "${matches}" ]]; then
        echo "Android UI/ViewModel code must stay behind gateway/core facades:" >&2
        echo "${matches}" >&2
        exit 1
      fi
    done
}

check_complexity_budgets
check_no_unbudgeted_large_files
check_ios_ui_boundaries
check_android_ui_boundaries

echo "Governance boundary checks passed."
