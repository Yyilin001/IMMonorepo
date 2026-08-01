#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

bash "${script_dir}/run_v2_swift_tests.sh"
bash "${script_dir}/run_v2_postgres_integration.sh"
bash "${repo_root}/IMApp/Scripts/verify_generic_simulator_build.sh"

printf 'verify-v2 result=pass\n'
