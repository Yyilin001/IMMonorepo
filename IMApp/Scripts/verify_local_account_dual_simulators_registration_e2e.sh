#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
single_simulator_script="${script_dir}/verify_local_account_registration_e2e.sh"
first_simulator_id="${IMAPP_LOCAL_ACCOUNT_E2E_FIRST_SIMULATOR_ID:-}"
second_simulator_id="${IMAPP_LOCAL_ACCOUNT_E2E_SECOND_SIMULATOR_ID:-}"

if [[ -z "${first_simulator_id}" || -z "${second_simulator_id}" ]]; then
  printf '%s\n' 'missing IMAPP_LOCAL_ACCOUNT_E2E_FIRST_SIMULATOR_ID or IMAPP_LOCAL_ACCOUNT_E2E_SECOND_SIMULATOR_ID; choose two explicitly booted simulators.' >&2
  exit 2
fi

if [[ "${first_simulator_id}" == "${second_simulator_id}" ]]; then
  printf '%s\n' 'the two local-account E2E simulator IDs must be different.' >&2
  exit 2
fi

for simulator_id in "${first_simulator_id}" "${second_simulator_id}"; do
  printf 'running isolated local-account E2E on simulator=%s\n' "${simulator_id}"
  IMAPP_LOCAL_ACCOUNT_E2E_SIMULATOR_ID="${simulator_id}" "${single_simulator_script}"
done

printf '%s\n' 'dual-simulator local account registration E2E: pass'
printf '%s\n' 'scope: two independent Keychain-backed registrations only; this does not prove cross-client message delivery or offline replay.'
