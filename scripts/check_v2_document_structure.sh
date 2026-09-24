#!/usr/bin/env bash
set -euo pipefail

# Keep the documentation structure from collapsing back into an append-only log.
#
# The 2026-09 review effort produced 90 documents whose "current contract" and
# "implementation timeline" were interleaved: status and implementation-status
# grew by appending "最新补充" paragraphs, so no reader could tell which text was
# still authoritative. The structure is now:
#
#   docs/README.md               entry point
#   docs/reviews/README.md       contract index: which document is authoritative
#   docs/reviews/status.md       current issue status
#   docs/reviews/<topic>-*.md    one current contract per topic
#   docs/reviews/archive/        history; never authoritative
#
# This gate fails when a non-archived document grows a timeline again, or when a
# contract document is not reachable from the index.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
status=0

index="${repo_root}/docs/reviews/README.md"
if [[ ! -f "${index}" ]]; then
  printf 'missing contract index: docs/reviews/README.md\n' >&2
  exit 1
fi

# 1. No append-only timeline in a document that is still authoritative.
timeline_pattern='^(最新补充|最新进展|后续修复批补充|后续 schema [0-9]+ 批补充)'
while IFS= read -r -d '' document; do
  relative="${document#"${repo_root}/"}"
  case "${relative}" in
    */archive/*) continue ;;
  esac
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    printf 'timeline paragraph in authoritative document: %s:%s\n' "${relative}" "${hit}" >&2
    status=1
  done < <(grep -nE "${timeline_pattern}" "${document}" 2>/dev/null | cut -d: -f1 || true)
done < <(find "${repo_root}/docs" "${repo_root}/IMV2/docs" -name '*.md' -type f -print0)

# 2. Every current contract must be reachable from the index.
while IFS= read -r -d '' document; do
  name="$(basename "${document}")"
  case "${name}" in
    README.md|status.md|verification-records.md) continue ;;
  esac
  if ! grep -qF "${name}" "${index}"; then
    printf 'contract document not listed in docs/reviews/README.md: %s\n' "docs/reviews/${name}" >&2
    status=1
  fi
done < <(find "${repo_root}/docs/reviews" -maxdepth 1 -name '*.md' -type f -print0)

# 3. History stays history: every archived document must carry the history banner.
while IFS= read -r -d '' document; do
  [[ "$(basename "${document}")" == "README.md" ]] && continue
  # A short-circuiting grep can SIGPIPE head under pipefail on long lines.
  # Read the bounded prefix in one process so a present banner cannot fail.
  if ! awk 'NR <= 20 && /历史归档/ { found=1 } NR == 20 { exit } END { exit !found }' "${document}"; then
    printf 'archived document lacks the history banner: %s\n' "${document#"${repo_root}/"}" >&2
    status=1
  fi
done < <(find "${repo_root}/docs/reviews/archive" "${repo_root}/IMV2/docs/00-foundation/archive" "${repo_root}/IMV2/docs/09-capacity/archive" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)

if [[ "${status}" -ne 0 ]]; then
  exit "${status}"
fi

printf 'V2 document structure contract passed.\n'
