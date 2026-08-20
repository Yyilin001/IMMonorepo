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
parallelism="${IM_V2_LOAD_CREDENTIAL_PREPARE_PARALLELISM:-16}"
curl_resolve="${IM_V2_LOAD_CURL_RESOLVE:-}"
curl_options=()

if [[ -n "${curl_resolve}" ]]; then
  [[ "${curl_resolve}" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}:[0-9A-Fa-f:.]+$ ]] || {
    printf 'IM_V2_LOAD_CURL_RESOLVE must have host:port:address form\n' >&2
    exit 64
  }
  curl_options+=(--resolve "${curl_resolve}")
fi

curl_request() {
  if (( ${#curl_options[@]} > 0 )); then
    curl "${curl_options[@]}" "$@"
  else
    curl "$@"
  fi
}

[[ "${credential_count}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'credential-count must be a positive integer\n' >&2
  exit 64
}
(( credential_count <= 5000 )) || {
  printf 'credential-count must not exceed 5000\n' >&2
  exit 64
}
[[ "${parallelism}" =~ ^[1-9][0-9]*$ ]] && (( parallelism <= 64 )) || {
  printf 'IM_V2_LOAD_CREDENTIAL_PREPARE_PARALLELISM must be 1...64\n' >&2
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

temporary_directory="$(mktemp -d)"
cleanup() {
  rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT INT TERM

prepare_one() {
  local destination="$1"
  local suffix account_handle public_handle device_id operation_id password
  local assertion_payload assertion issue_payload issued
  suffix="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  account_handle="load-${suffix:0:20}"
  public_handle="load${suffix:0:20}"
  device_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  password="load-$(openssl rand -hex 18)"

  assertion_payload="$(jq -cn \
    --arg accountHandle "${account_handle}" \
    --arg password "${password}" \
    --arg deviceID "${device_id}" \
    --arg publicHandle "${public_handle}" \
    '{accountHandle:$accountHandle,password:$password,deviceID:$deviceID,publicHandle:$publicHandle,displayName:"Load Test"}')"
  assertion="$(printf '%s' "${assertion_payload}" | curl_request --silent --show-error --fail \
    --cacert "${ca_path}" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "${account_base_url}/v2/account-auth/password/register" | jq -er '.accountAssertion')"

  issue_payload="$(jq -cn \
    --arg accountAssertion "${assertion}" \
    --arg deviceID "${device_id}" \
    --arg operationID "${operation_id}" \
    '{accountAssertion:$accountAssertion,deviceID:$deviceID,operationID:$operationID,deviceName:"Load Generator",platform:"macOS"}')"
  issued="$(printf '%s' "${issue_payload}" | curl_request --silent --show-error --fail \
    --cacert "${ca_path}" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "${account_base_url}/v2/device-credentials")"

  printf '%s\n' "$(printf '%s' "${issued}" | jq -ce '{userID,deviceID,accessToken,accessTokenExpiresAtMilliseconds,refreshCredential}')" > "${destination}"
}

declare -a pids=()
for ((index = existing_count; index < credential_count; index += 1)); do
  prepare_one "${temporary_directory}/${index}" &
  pids+=("$!")
  if (( ${#pids[@]} >= parallelism )); then
    for pid in "${pids[@]}"; do wait "${pid}"; done
    pids=()
  fi
done
for pid in "${pids[@]}"; do wait "${pid}"; done

for ((index = existing_count; index < credential_count; index += 1)); do
  [[ -s "${temporary_directory}/${index}" ]] || {
    printf 'credential preparation did not produce record %d\n' "${index}" >&2
    exit 1
  }
  < "${temporary_directory}/${index}" tr -d '\n' >> "${output_path}"
  printf '\n' >> "${output_path}"
  completed=$((index + 1))
  if (( completed % 100 == 0 || completed == credential_count )); then
    printf 'credentials prepared: %d/%d\n' "${completed}" "${credential_count}"
  fi
done

printf 'credential preparation complete: %d records\n' "${credential_count}"
