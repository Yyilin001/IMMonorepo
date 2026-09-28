#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 3 && "$#" -ne 4 ]]; then
  printf 'usage: %s <account-base-url> <ca-path> <credentials-jsonl> [output-jsonl]\n' "$0" >&2
  exit 64
fi

account_base_url="${1%/}"
ca_path="$2"
input_path="$3"
output_path="${4:-}"
parallelism="${IM_V2_LOAD_CREDENTIAL_REFRESH_PARALLELISM:-16}"
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

[[ -f "${ca_path}" && -f "${input_path}" ]] || {
  printf 'CA or input credential file does not exist\n' >&2
  exit 66
}
[[ "${parallelism}" =~ ^[1-9][0-9]*$ ]] && (( parallelism <= 64 )) || {
  printf 'IM_V2_LOAD_CREDENTIAL_REFRESH_PARALLELISM must be 1...64\n' >&2
  exit 64
}

umask 077
temporary_directory="$(mktemp -d)"
replace_input=0
if [[ -z "${output_path}" ]]; then
  credential_directory="$(cd "$(dirname "${input_path}")" && pwd)"
  output_path="$(mktemp "${credential_directory}/.credentials-refresh.XXXXXX")"
  replace_input=1
else
  mkdir -p "$(dirname "${output_path}")"
fi
cleanup() {
  rm -rf -- "${temporary_directory}"
  if (( replace_input == 1 )); then rm -f -- "${output_path}"; fi
}
trap cleanup EXIT INT TERM
: > "${output_path}"
chmod 600 "${output_path}"

refresh_one() {
  local record="$1"
  local destination="$2"
  local operation_id payload issued http_status curl_exit response_path
  operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  if ! payload="$(printf '%s' "${record}" | jq -ce --arg operationID "${operation_id}" '{userID,deviceID,refreshCredential,revocationCredential,operationID:$operationID}' 2>/dev/null)"; then
    printf 'refresh failure stage=request_parse category=invalid_input\n' >&2
    return 1
  fi
  response_path="${temporary_directory}/response.$(basename "${destination}")"
  curl_exit=0
  http_status="$(printf '%s' "${payload}" | curl_request --silent --fail \
    --cacert "${ca_path}" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    --output "${response_path}" --write-out '%{http_code}' \
    "${account_base_url}/v2/device-credentials/refresh")" || curl_exit=$?
  if (( curl_exit != 0 )); then
    printf 'refresh failure stage=http curl_exit=%d http_status=%s\n' "${curl_exit}" "${http_status:-000}" >&2
    return 1
  fi
  if ! issued="$(jq -ce '
      select(.userID | type == "string")
      | select(.deviceID | type == "string")
      | select(.accessToken | type == "string" and length > 0)
      | select(.accessTokenExpiresAtMilliseconds | type == "number")
      | select(.refreshCredential | type == "string" and length > 0)
      | select(.revocationCredential | type == "string" and length > 0)
      | select(.revocationCredentialExpiresAtMilliseconds | type == "number")
      | {userID,deviceID,accessToken,accessTokenExpiresAtMilliseconds,refreshCredential,revocationCredential,revocationCredentialExpiresAtMilliseconds}
    ' "${response_path}" 2>/dev/null)" || [[ -z "${issued}" ]]; then
    printf 'refresh failure stage=response_parse category=invalid_shape http_status=%s\n' "${http_status:-000}" >&2
    return 1
  fi
  printf '%s\n' "${issued}" > "${destination}"
}

declare -a pids=()
failed=0
line_number=0
while IFS= read -r record || [[ -n "${record}" ]]; do
  [[ -n "${record}" ]] || continue
  refresh_one "${record}" "${temporary_directory}/${line_number}" &
  pids+=("$!")
  line_number=$((line_number + 1))
  if (( ${#pids[@]} >= parallelism )); then
    for pid in "${pids[@]}"; do
      if ! wait "${pid}"; then failed=$((failed + 1)); fi
    done
    pids=()
    # Drain the current batch, then stop issuing further credential rotations
    # once this invocation can no longer produce a complete output corpus.
    if (( failed > 0 )); then break; fi
  fi
done < "${input_path}"
if [[ -n "${pids[*]-}" ]]; then
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then failed=$((failed + 1)); fi
  done
fi
if (( failed > 0 )); then
  printf 'credential refresh failed: records=%d failed=%d; all launched requests drained\n' "${line_number}" "${failed}" >&2
  exit 1
fi

for ((index = 0; index < line_number; index += 1)); do
  [[ -s "${temporary_directory}/${index}" ]] || {
    printf 'credential refresh did not produce record %d\n' "${index}" >&2
    exit 1
  }
  < "${temporary_directory}/${index}" tr -d '\n' >> "${output_path}"
  printf '\n' >> "${output_path}"
done

if (( replace_input == 1 )); then
  mv "${output_path}" "${input_path}"
fi

printf 'credential refresh complete: %d records\n' "${line_number}"
