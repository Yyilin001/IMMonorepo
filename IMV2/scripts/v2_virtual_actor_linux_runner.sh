#!/usr/bin/env bash
set -Eeuo pipefail

# Runs only in the pinned Linux image from Dockerfile.isolated-tests.
repo_root=/workspace
[[ -d "$repo_root/IMV2Server" && -f "$repo_root/IMV2Server/Package.resolved" ]] || {
  printf 'missing read-only IMV2Server checkout or lockfile\n' >&2
  exit 66
}
[[ ! -w "$repo_root/IMV2Server/Package.swift" ]] || {
  printf 'source mount must be read-only\n' >&2
  exit 65
}
jobs="${V2_SWIFTPM_JOBS:-1}"
timeout_seconds="${V2_TEST_TIMEOUT_SECONDS:-10800}"
[[ "$jobs" =~ ^[1-9][0-9]*$ && "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  printf 'V2_SWIFTPM_JOBS and V2_TEST_TIMEOUT_SECONDS must be positive integers\n' >&2
  exit 64
}
mkdir -p "${HOME}/.swiftpm" "${XDG_CACHE_HOME:-/tmp/cache}" "${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"

action="${1:-}"
shift || true
case "$action" in
  build)
    (( $# > 0 )) || { printf 'release product list is empty\n' >&2; exit 64; }
    scratch=/tmp/swiftpm/IMV2Server-release
    mkdir -p "$scratch"
    for product in "$@"; do
      printf '[va-linux] release build: %s\n' "$product"
      timeout --signal=TERM --kill-after=20s "${timeout_seconds}s" \
        swift build --disable-automatic-resolution --jobs "$jobs" -c release \
        --package-path "$repo_root/IMV2Server" --scratch-path "$scratch" --product "$product"
    done
    ;;
  test)
    (( $# == 2 )) || { printf 'test requires package and filter\n' >&2; exit 64; }
    package="$1"
    filter="$2"
    [[ "$package" == IMV2Core || "$package" == IMV2Server ]] && [[ -n "$filter" ]] || exit 64
    scratch="/tmp/swiftpm/${package}"
    mkdir -p "$scratch"
    list_output="$scratch/va-test-list.log"
    timeout --signal=TERM --kill-after=20s "${timeout_seconds}s" \
      swift test list --disable-automatic-resolution --jobs "$jobs" \
        --package-path "$repo_root/$package" --scratch-path "$scratch" > "$list_output"
    # SwiftPM accepts a zero-match --filter and exits 0. Check actual test
    # identifiers before running the requested suite; rg uses the same common
    # regular-expression subset used in our test filters.
    if ! rg -q -- "$filter" "$list_output"; then
      printf 'test filter matched no listed tests: %s (%s)\n' "$filter" "$package" >&2
      exit 65
    fi
    printf '[va-linux] tests: %s / %s\n' "$package" "$filter"
    timeout --signal=TERM --kill-after=20s "${timeout_seconds}s" \
      swift test --disable-automatic-resolution --jobs "$jobs" --no-parallel \
        --package-path "$repo_root/$package" --scratch-path "$scratch" --filter "$filter"
    ;;
  *) printf 'unknown action: %s\n' "$action" >&2; exit 64 ;;
esac
