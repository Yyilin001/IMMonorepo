#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="${script_dir}/validate_v2_local_environment.sh"
temporary_directory="$(mktemp -d)"

cleanup() {
  rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT

base64_key="$(openssl rand -base64 32 | tr -d '\n')"
bcrypt_suffix="$(printf '%053d' 0 | tr '0' '.')"

write_valid_environment() {
  local destination="$1"
  {
    printf 'IM_V2_LOCAL_POSTGRES_PASSWORD=0123456789abcdef0123456789abcdef\n'
    printf 'IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64=%s\n' "${base64_key}"
    printf 'IM_V2_PASSWORD_DUMMY_BCRYPT_HASH=$$2b$$12$$%s\n' "${bcrypt_suffix}"
  } > "${destination}"
  chmod 600 "${destination}"
}

replace_value() {
  local path="$1"
  local key="$2"
  local value="$3"
  awk -v key="${key}" -v value="${value}" '
    index($0, key "=") == 1 { $0 = key "=" value }
    { print }
  ' "${path}" > "${path}.next"
  mv "${path}.next" "${path}"
  chmod 600 "${path}"
}

expect_rejected() {
  local name="$1"
  local path="$2"
  if "${validator}" "${path}" >"${temporary_directory}/${name}.log" 2>&1; then
    printf 'validator unexpectedly accepted case: %s\n' "${name}" >&2
    exit 1
  fi
}

valid_path="${temporary_directory}/valid.env"
write_valid_environment "${valid_path}"
"${validator}" "${valid_path}" >/dev/null

missing_path="${temporary_directory}/missing.env"
write_valid_environment "${missing_path}"
awk '!/^IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64=/' "${missing_path}" > "${missing_path}.next"
mv "${missing_path}.next" "${missing_path}"
chmod 600 "${missing_path}"
expect_rejected missing "${missing_path}"

unknown_path="${temporary_directory}/unknown.env"
write_valid_environment "${unknown_path}"
printf 'IM_V2_UNKNOWN_KEY=value\n' >> "${unknown_path}"
expect_rejected unknown "${unknown_path}"

duplicate_path="${temporary_directory}/duplicate.env"
write_valid_environment "${duplicate_path}"
printf 'IM_V2_LOCAL_POSTGRES_PASSWORD=0123456789abcdef0123456789abcdef\n' >> "${duplicate_path}"
expect_rejected duplicate "${duplicate_path}"

empty_path="${temporary_directory}/empty.env"
write_valid_environment "${empty_path}"
replace_value "${empty_path}" IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64 ''
expect_rejected empty "${empty_path}"

short_key_path="${temporary_directory}/short-key.env"
write_valid_environment "${short_key_path}"
replace_value "${short_key_path}" IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64 'YQ=='
expect_rejected short-key "${short_key_path}"

bcrypt_path="${temporary_directory}/bcrypt.env"
write_valid_environment "${bcrypt_path}"
replace_value "${bcrypt_path}" IM_V2_PASSWORD_DUMMY_BCRYPT_HASH '$2b$10$invalid'
expect_rejected bcrypt "${bcrypt_path}"

permissions_path="${temporary_directory}/permissions.env"
write_valid_environment "${permissions_path}"
chmod 640 "${permissions_path}"
expect_rejected permissions "${permissions_path}"

printf 'V2 local environment current-contract regression passed.\n'
