#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'usage: %s <account-base-url> <ca-path> <credentials-jsonl>\n' "$0" >&2
  exit 64
fi

account_base_url="${1%/}"
ca_path="$2"
credentials_path="$3"
refresh_pacing_seconds="${IM_V2_LOAD_CREDENTIAL_REFRESH_PACING_SECONDS:-0.3}"

[[ -f "${ca_path}" ]] || {
  printf 'CA file does not exist: %s\n' "${ca_path}" >&2
  exit 66
}
[[ -s "${credentials_path}" ]] || {
  printf 'credential file is missing or empty: %s\n' "${credentials_path}" >&2
  exit 66
}

umask 077
credential_directory="$(cd "$(dirname "${credentials_path}")" && pwd)"
temporary_path="$(mktemp "${credential_directory}/.credentials-refresh.XXXXXX")"
cleanup() {
  rm -f "${temporary_path}"
}
trap cleanup EXIT INT TERM

total="$(awk 'NF { count += 1 } END { print count + 0 }' "${credentials_path}")"
completed=0
while IFS= read -r credential; do
  [[ -n "${credential}" ]] || continue
  user_id="$(jq -er '.userID' <<<"${credential}")"
  device_id="$(jq -er '.deviceID' <<<"${credential}")"
  refresh_credential="$(jq -er '.refreshCredential' <<<"${credential}")"
  operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  refreshed="$(curl --silent --show-error --fail \
    --cacert "${ca_path}" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$(jq -cn \
      --arg userID "${user_id}" \
      --arg deviceID "${device_id}" \
      --arg refreshCredential "${refresh_credential}" \
      --arg operationID "${operation_id}" \
      '{userID:$userID,deviceID:$deviceID,refreshCredential:$refreshCredential,operationID:$operationID}')" \
    "${account_base_url}/v2/device-credentials/refresh")"

  printf '%s\n' "$(printf '%s' "${refreshed}" | jq -ce '{userID,deviceID,accessToken,accessTokenExpiresAtMilliseconds,refreshCredential}')" >> "${temporary_path}"
  completed=$((completed + 1))
  if (( completed % 25 == 0 || completed == total )); then
    printf 'credentials refreshed: %d/%d\n' "${completed}" "${total}"
  fi
  sleep "${refresh_pacing_seconds}"
done < "${credentials_path}"

[[ "${completed}" -eq "${total}" ]] || {
  printf 'credential refresh count mismatch: %d/%d\n' "${completed}" "${total}" >&2
  exit 65
}

chmod 600 "${temporary_path}"
mv "${temporary_path}" "${credentials_path}"
trap - EXIT INT TERM
printf 'credential refresh complete: %d records\n' "${total}"
