#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

bash "${repo_root}/scripts/check_v2_sql_migration_manifest.sh"
bash "${repo_root}/scripts/check_v2_sql_migration_baseline_lock.sh"
bash "${repo_root}/scripts/test_v2_sql_migration_baseline_lock.sh"

for package in IMV2Core IMV2ClientKit IMV2Server; do
  # Let the selected Swift toolchain run Swift Testing itself. Invoking
  # Xcode's xctest directly loses the selected toolchain's libTesting.dylib.
  swift test --package-path "${repo_root}/${package}"
done
