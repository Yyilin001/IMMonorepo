#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
env_file="${1:-${v2_dir}/.env.local}"

fail_contract() {
  printf 'local V2 environment does not match the current contract: %s\n' "${env_file}" >&2
  printf '%s\n' "$1" >&2
  printf 'Correct the listed fields while preserving existing secrets. For obsolete IM_V2_PASSWORD_DUMMY_BCRYPT_HASH, remove only that key. Fresh disposable stacks may generate a new file with run_v2_local_account_stack.sh.\n' >&2
  exit 1
}

command -v openssl >/dev/null 2>&1 || {
  printf 'missing required command: openssl\n' >&2
  exit 1
}

[[ -f "${env_file}" && ! -L "${env_file}" ]] || fail_contract 'expected a regular, non-symlink configuration file'

if permissions="$(stat -f '%Lp' "${env_file}" 2>/dev/null)"; then
  :
elif permissions="$(stat -c '%a' "${env_file}" 2>/dev/null)"; then
  :
else
  fail_contract 'could not inspect configuration file permissions'
fi
[[ "${permissions}" =~ ^[0-7]{3,4}$ ]] || fail_contract 'configuration file permissions are not an octal mode'
(( (8#${permissions} & 077) == 0 )) || fail_contract 'configuration file must not be readable or writable by group/other users'

required_env_keys=(
  IM_V2_LOCAL_POSTGRES_PASSWORD
  IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64
  IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64
  IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64
  IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64
  IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64
  IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64
  IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64
  IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64
  IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64
  IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64
)

invalid_lines="$(awk '!/^[A-Z0-9_]+=[^[:space:]]+$/ { print NR }' "${env_file}")"
duplicate_keys="$(sed -nE 's/^([A-Z0-9_]+)=.*$/\1/p' "${env_file}" | sort | uniq -d)"
actual_keys="$(sed -nE 's/^([A-Z0-9_]+)=.*$/\1/p' "${env_file}" | sort)"
expected_keys="$(printf '%s\n' "${required_env_keys[@]}" | sort)"

[[ -z "${invalid_lines}" ]] || fail_contract "invalid, blank, commented, whitespace-containing, or empty-value lines: ${invalid_lines//$'\n'/, }"
[[ -z "${duplicate_keys}" ]] || fail_contract "duplicate keys: ${duplicate_keys//$'\n'/, }"
[[ "${actual_keys}" == "${expected_keys}" ]] || fail_contract 'the key set must exactly match the current generated configuration'

value_for_key() {
  local key="$1"
  awk -v key="${key}" 'index($0, key "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "${env_file}"
}

postgres_password="$(value_for_key IM_V2_LOCAL_POSTGRES_PASSWORD)"
[[ "${postgres_password}" =~ ^[A-Za-z0-9_-]{32}$ ]] || fail_contract 'IM_V2_LOCAL_POSTGRES_PASSWORD must be the current 32-character URL-safe generated form'

base64_keys=(
  IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64
  IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64
  IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64
  IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64
  IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64
  IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64
  IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64
  IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64
  IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64
  IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64
)
for key in "${base64_keys[@]}"; do
  value="$(value_for_key "${key}")"
  [[ "${value}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail_contract "${key} must be canonical Base64 for exactly 32 bytes"
  if ! decoded_bytes="$(printf '%s' "${value}" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]')"; then
    fail_contract "${key} is not valid Base64"
  fi
  [[ "${decoded_bytes}" == '32' ]] || fail_contract "${key} must decode to exactly 32 bytes"
done


printf 'V2 local environment contract verified: %s\n' "${env_file}"
