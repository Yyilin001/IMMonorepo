#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 4 ]]; then
  printf 'usage: %s <account-base-url> <ca-path> <credential-count> <output-jsonl>\n' "$0" >&2
  exit 64
fi

account_base_url="${1%/}"
ca_path="$2"
credential_count="$3"
output_path="$4"
credential_pacing_seconds="${IM_V2_LOAD_CREDENTIAL_PACING_SECONDS:-0.5}"

[[ "${credential_count}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'credential-count must be a positive integer\n' >&2
  exit 64
}
(( credential_count <= 5000 )) || {
  printf 'credential-count must not exceed 5000\n' >&2
  exit 64
}
[[ -f "${ca_path}" ]] || {
  printf 'CA file does not exist: %s\n' "${ca_path}" >&2
  exit 66
}

umask 077
mkdir -p "$(dirname "${output_path}")"
touch "${output_path}"
chmod 600 "${output_path}"

existing_count="$(awk 'NF { count += 1 } END { print count + 0 }' "${output_path}")"
(( existing_count <= credential_count )) || {
  printf 'output already contains more credentials than requested\n' >&2
  exit 65
}

for ((index = existing_count; index < credential_count; index += 1)); do
  suffix="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  account_handle="load-${suffix:0:20}"
  public_handle="load${suffix:0:20}"
  device_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  password="load-$(openssl rand -hex 18)"

  assertion="$(curl --silent --show-error --fail \
    --cacert "${ca_path}" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$(jq -cn \
      --arg accountHandle "${account_handle}" \
      --arg password "${password}" \
      --arg deviceID "${device_id}" \
      --arg publicHandle "${public_handle}" \
      '{accountHandle:$accountHandle,password:$password,deviceID:$deviceID,publicHandle:$publicHandle,displayName:"Load Test"}')" \
    "${account_base_url}/v2/account-auth/password/register" | jq -er '.accountAssertion')"

  issued="$(curl --silent --show-error --fail \
    --cacert "${ca_path}" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$(jq -cn \
      --arg accountAssertion "${assertion}" \
      --arg deviceID "${device_id}" \
      --arg operationID "${operation_id}" \
      '{accountAssertion:$accountAssertion,deviceID:$deviceID,operationID:$operationID,deviceName:"Load Generator",platform:"macOS"}')" \
    "${account_base_url}/v2/device-credentials")"

  printf '%s\n' "$(printf '%s' "${issued}" | jq -c '{userID,deviceID,accessToken,accessTokenExpiresAtMilliseconds,refreshCredential}')" >> "${output_path}"
  completed=$((index + 1))
  if (( completed % 10 == 0 || completed == credential_count )); then
    printf 'credentials prepared: %d/%d\n' "${completed}" "${credential_count}"
  fi
  sleep "${credential_pacing_seconds}"
done

printf 'credential preparation complete: %d records\n' "${credential_count}"
