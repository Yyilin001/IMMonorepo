#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
config="$script_dir/virtual-actor-fixtures/capacity-main-v1.json"
command -v jq >/dev/null && command -v shasum >/dev/null || {
  printf 'jq and shasum are required\n' >&2; exit 69;
}
jq -e '.schemaVersion == 1 and
  .status == "configuration-frozen-measurements-pending" and
  .measurement.loaderWorkers == 1 and
  .measurement.latencyScope == "single-process-phase-samples" and
  .measurement.minimumRunsPerRevision == 3 and
  ([.measurement.roundOrder[] | select(. == "main")] | length) == 3 and
  ([.measurement.roundOrder[] | select(. == "candidate")] | length) == 3 and
  (.pendingActorSpecificScenarios | length) == 3 and
  (.existingScenarios | length) == 3' "$config" >/dev/null
while IFS=$'\t' read -r path expected; do
  [[ -f "$repo_root/$path" ]] || { printf 'missing scenario: %s\n' "$path" >&2; exit 66; }
  actual="$(shasum -a 256 "$repo_root/$path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    printf 'scenario digest changed: %s\n' "$path" >&2; exit 65;
  }
  jq -e '.seed != null and (.phases | length) > 0' "$repo_root/$path" >/dev/null
done < <(jq -r '.existingScenarios[] | [.path, .sha256] | @tsv' "$config")
printf 'main capacity configuration and scenario digests valid; measurements pending\n'
