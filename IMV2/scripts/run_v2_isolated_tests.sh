#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=/workspace
timeout_seconds="${V2_TEST_TIMEOUT_SECONDS:-1200}"
# The test container uses an explicit resource envelope. SwiftPM otherwise
# derives a much larger host-dependent default, which can OOM while compiling
# the Server test target before any regression executes.
swiftpm_jobs="${V2_SWIFTPM_JOBS:-4}"
if ! [[ "${swiftpm_jobs}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'V2_SWIFTPM_JOBS must be a positive integer: %s\n' "${swiftpm_jobs}" >&2
  exit 2
fi

# SwiftPM and Clang compile package manifests before `--scratch-path` applies.
# Keep those implementation caches writable without making the image or source
# mount writable.
mkdir -p "${HOME}/.swiftpm" "${XDG_CACHE_HOME:-/tmp/cache}" "${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"

# ClientKit deliberately runs natively on macOS: its production transport and
# Keychain integration are Apple-platform APIs. The container owns only the
# portable core and server/PostgreSQL regression boundary. The package/filter
# controls are intentionally opt-in so a costly capacity correctness run can
# select one Server test without weakening the default whole-suite gate.
packages="${V2_TEST_PACKAGES:-IMV2Core IMV2Server}"
read -r -a package_list <<<"${packages}"
for package in "${package_list[@]}"; do
  scratch_path="/tmp/swiftpm/${package}"
  mkdir -p "$scratch_path"
  echo "[isolated] testing ${package}"
  # The source tree is mounted read-only.  Automatic resolution would try to
  # rewrite Package.resolved inside that mount, making a test depend on an
  # accidental writable checkout instead of the repository's lock file.
  test_command=(swift test --disable-automatic-resolution --jobs "$swiftpm_jobs" --package-path "${repo_root}/${package}" --scratch-path "$scratch_path")
  if [[ "${package}" == "IMV2Server" && -n "${V2_SERVER_TEST_FILTER:-}" ]]; then
    test_command+=(--filter "${V2_SERVER_TEST_FILTER}")
    filtered_output="${scratch_path}/filtered-test-output.log"
    set +e
    timeout --signal=TERM --kill-after=20s "${timeout_seconds}s" \
      "${test_command[@]}" 2>&1 | tee "${filtered_output}"
    test_status="${PIPESTATUS[0]}"
    set -e
    test "${test_status}" -eq 0 || exit "${test_status}"
    # Swift Testing treats a non-matching filter as a successful zero-test
    # invocation. A requested capacity or focused regression must never be
    # allowed to report that result as evidence.
    if grep -Fq 'Test run with 0 tests in 0 suites' "${filtered_output}"; then
      printf 'V2_SERVER_TEST_FILTER matched no tests: %s\n' "${V2_SERVER_TEST_FILTER}" >&2
      exit 1
    fi
    continue
  fi
  timeout --signal=TERM --kill-after=20s "${timeout_seconds}s" \
    "${test_command[@]}"
done

bash "${repo_root}/scripts/check_v2_sql_migration_manifest.sh"
bash "${repo_root}/scripts/check_v2_sql_migration_baseline_lock.sh"
bash "${repo_root}/scripts/test_v2_sql_migration_baseline_lock.sh"
bash "${repo_root}/scripts/check_v2_protobuf_generated.sh"
bash "${repo_root}/scripts/check_v2_local_schema_migration_markers.sh"
bash "${repo_root}/scripts/check_v2_schema_readiness_tables.sh"
bash "${repo_root}/scripts/check_v2_prometheus_rules.sh"
bash "${repo_root}/scripts/check_v2_runtime_env_examples.sh"
