#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
local_env="${repo_root}/IMV2/.env.local"
created_local_env=false

cleanup() {
  if [[ "${created_local_env}" == "true" ]]; then
    rm -f "${local_env}"
  fi
}
trap cleanup EXIT

bash "${script_dir}/run_v2_swift_tests.sh"
bash "${script_dir}/check_v2_prometheus_rules.sh"
if [[ ! -e "${local_env}" ]]; then
  cp "${repo_root}/IMV2/.env.local.example" "${local_env}"
  created_local_env=true
fi
bash "${repo_root}/IMV2/scripts/test_v2_local_compose_env_precedence.sh"
bash "${script_dir}/run_v2_postgres_integration.sh"
bash "${repo_root}/IMApp/Scripts/verify_generic_simulator_build.sh"
bash "${repo_root}/IMApp/Scripts/verify_unit_tests.sh"
bash "${repo_root}/IMApp/Scripts/verify_ui_tests.sh"

printf 'verify-v2 result=pass\n'
