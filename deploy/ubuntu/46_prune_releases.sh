#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

IMSERVER_RELEASE_KEEP="${IMSERVER_RELEASE_KEEP:-5}"
PRESERVE_RELEASE_IDS="${PRESERVE_RELEASE_IDS:-}"
DRY_RUN="${DRY_RUN:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

if ! [[ "${IMSERVER_RELEASE_KEEP}" =~ ^[0-9]+$ ]] || (( IMSERVER_RELEASE_KEEP < 2 )); then
  echo "IMSERVER_RELEASE_KEEP must be an integer >= 2 so rollback keeps at least one previous release." >&2
  exit 1
fi

if [[ ! -d "${IMSERVER_RELEASES_DIR}" ]]; then
  echo "Release directory does not exist: ${IMSERVER_RELEASES_DIR}"
  exit 0
fi

preserve_dirs=()
if [[ -L "${IMSERVER_CURRENT_LINK}" ]]; then
  current_release_dir="$(readlink -f "${IMSERVER_CURRENT_LINK}" || true)"
  if [[ -n "${current_release_dir}" ]]; then
    preserve_dirs+=("${current_release_dir}")
  fi
fi

for release_id in ${PRESERVE_RELEASE_IDS}; do
  [[ -z "${release_id}" ]] && continue
  preserve_dirs+=("${IMSERVER_RELEASES_DIR}/${release_id}")
done

is_preserved_release() {
  local candidate="$1"
  local preserved
  for preserved in "${preserve_dirs[@]}"; do
    if [[ "$(readlink -f "${candidate}")" == "$(readlink -f "${preserved}" 2>/dev/null || printf '%s' "${preserved}")" ]]; then
      return 0
    fi
  done
  return 1
}

mapfile -t releases < <(find "${IMSERVER_RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d | sort -r)
if (( ${#releases[@]} <= IMSERVER_RELEASE_KEEP )); then
  printf 'release prune result=skipped count=%s keep=%s\n' "${#releases[@]}" "${IMSERVER_RELEASE_KEEP}"
  exit 0
fi

deleted=0
kept=0
for release_dir in "${releases[@]}"; do
  canonical="$(readlink -f "${release_dir}")"
  if (( kept < IMSERVER_RELEASE_KEEP )) || is_preserved_release "${canonical}"; then
    kept=$((kept + 1))
    continue
  fi

  if bool_enabled "${DRY_RUN}"; then
    printf 'release prune dryRun=true delete=%s\n' "${release_dir}"
  else
    rm -rf "${release_dir}"
    printf 'release prune deleted=%s\n' "${release_dir}"
  fi
  deleted=$((deleted + 1))
done

printf 'release prune result=pass total=%s keptAtLeast=%s deleted=%s dryRun=%s\n' \
  "${#releases[@]}" \
  "${IMSERVER_RELEASE_KEEP}" \
  "${deleted}" \
  "${DRY_RUN}"
