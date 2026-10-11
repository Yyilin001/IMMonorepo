#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

python3 "${repo_root}/scripts/check_v2_postgres_vendor.py"
python3 "${repo_root}/scripts/check_v2_server_boundaries.py"
python3 "${repo_root}/scripts/check_actor_serialization_boundaries.py"

for package in IMV2Core IMV2ClientKit IMV2Server; do
  # Let the selected Swift toolchain run Swift Testing itself. Invoking
  # Xcode's xctest directly loses the selected toolchain's libTesting.dylib.
  test_args=(--disable-automatic-resolution --package-path "${repo_root}/${package}")
  if [[ "${package}" != "IMV2Core" ]]; then
    # ClientKit has shared timing windows, and Server's database suites install
    # and drop one schema. Preserve those contracts by running tests serially.
    test_args+=(--no-parallel)
  fi
  swift test "${test_args[@]}"
done

# Keep generated protocol code, clean PostgreSQL bootstrap, startup schema
# coverage and strict deployment examples in the same required gate as the
# code they describe. A green unit suite must not permit deployment drift.
bash "${repo_root}/scripts/check_v2_protobuf_generated.sh"
bash "${repo_root}/scripts/check_actor_protobuf_generated.sh"
bash "${repo_root}/IMV2/scripts/test_v2_local_environment_contract.sh"
bash "${repo_root}/scripts/check_v2_schema_readiness_tables.sh"
if [[ "${V2_SCHEMA_BOOTSTRAP_COVERED_BY_POSTGRES_INTEGRATION:-0}" == "1" ]]; then
  printf '%s\n' 'Standalone Docker bootstrap/drift drill skipped; the provisioned integration gate installs the canonical schema.'
else
  bash "${repo_root}/scripts/test_v2_postgres_schema_bootstrap.sh"
fi
bash "${repo_root}/scripts/check_v2_runtime_env_examples.sh"
bash "${repo_root}/scripts/check_v2_document_links.sh"
bash "${repo_root}/scripts/check_v2_document_structure.sh"
