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

# Keep generated protocol code, retained-volume migration markers, startup
# schema coverage and strict deployment examples in the same required gate as
# the code they describe. A green unit suite must not permit deployment drift.
bash "${repo_root}/scripts/check_v2_protobuf_generated.sh"
bash "${repo_root}/scripts/check_v2_local_schema_migration_markers.sh"
bash "${repo_root}/scripts/check_v2_schema_readiness_tables.sh"
bash "${repo_root}/scripts/check_v2_runtime_env_examples.sh"
