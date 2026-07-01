#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-${IM_HTTP_BASE_URL:-http://127.0.0.1:8080}}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
CONNECTIONS="${CONNECTIONS:-}"
LOGIN_CACHE_DIR="${LOGIN_CACHE_DIR:-/tmp/imtcp-login-cache-slow}"
LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE:-}"
BATCH_SIZE="${BATCH_SIZE:-50}"
BATCH_PAUSE_SECONDS="${BATCH_PAUSE_SECONDS:-5}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-30}"
LOGIN_RETRIES="${LOGIN_RETRIES:-2}"
LOGIN_RETRY_DELAY_MS="${LOGIN_RETRY_DELAY_MS:-1000}"
LOAD_GENERATOR_ID="${LOAD_GENERATOR_ID:-1}"
LOAD_GENERATOR_COUNT="${LOAD_GENERATOR_COUNT:-1}"
ACCOUNT_SHARD_OFFSET="${ACCOUNT_SHARD_OFFSET:-}"
ACCOUNT_SHARD_LIMIT="${ACCOUNT_SHARD_LIMIT:-}"
DEVICE_ID_PREFIX="${DEVICE_ID_PREFIX:-tcp-load-driver}"

if [[ -z "${ACCOUNT_FILE}" ]]; then
  echo "ACCOUNT_FILE is required." >&2
  exit 1
fi
if [[ ! -f "${ACCOUNT_FILE}" ]]; then
  echo "ACCOUNT_FILE does not exist: ${ACCOUNT_FILE}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

bool_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 0 ))
}

if ! bool_positive_int "${BATCH_SIZE}"; then
  echo "BATCH_SIZE must be a positive integer." >&2
  exit 1
fi
if ! bool_positive_int "${REQUEST_TIMEOUT_SECONDS}"; then
  echo "REQUEST_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/im-login-cache-slow.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

usable_accounts="${tmp_dir}/accounts.csv"
grep -v '^[[:space:]]*#' "${ACCOUNT_FILE}" | sed '/^[[:space:]]*$/d' >"${usable_accounts}"
total_accounts="$(wc -l <"${usable_accounts}" | tr -d ' ')"
if (( total_accounts == 0 )); then
  echo "ACCOUNT_FILE has no usable rows: ${ACCOUNT_FILE}" >&2
  exit 1
fi

if [[ -n "${ACCOUNT_SHARD_OFFSET}" ]]; then
  shard_offset="${ACCOUNT_SHARD_OFFSET}"
else
  shard_offset=$(( (LOAD_GENERATOR_ID - 1) * ((total_accounts + LOAD_GENERATOR_COUNT - 1) / LOAD_GENERATOR_COUNT) ))
fi
if [[ -n "${ACCOUNT_SHARD_LIMIT}" ]]; then
  shard_limit="${ACCOUNT_SHARD_LIMIT}"
else
  shard_limit=$(( (total_accounts + LOAD_GENERATOR_COUNT - 1) / LOAD_GENERATOR_COUNT ))
fi
if (( shard_offset < 0 || shard_offset >= total_accounts )); then
  echo "Account shard offset is out of range: offset=${shard_offset}, total=${total_accounts}" >&2
  exit 1
fi

if [[ -n "${CONNECTIONS}" ]]; then
  if ! bool_positive_int "${CONNECTIONS}"; then
    echo "CONNECTIONS must be a positive integer." >&2
    exit 1
  fi
  requested_connections="${CONNECTIONS}"
else
  requested_connections="${shard_limit}"
fi
if (( shard_limit < requested_connections )); then
  echo "Account shard limit ${shard_limit} is smaller than requested connections ${requested_connections}." >&2
  exit 1
fi
if (( shard_offset + requested_connections > total_accounts )); then
  echo "Requested account range exceeds ACCOUNT_FILE rows: offset=${shard_offset}, connections=${requested_connections}, total=${total_accounts}" >&2
  exit 1
fi

if [[ -z "${LOGIN_CACHE_FILE}" ]]; then
  LOGIN_CACHE_FILE="${LOGIN_CACHE_DIR}/tcp-login-cache-lg${LOAD_GENERATOR_ID}-${requested_connections}.json"
fi
mkdir -p "$(dirname "${LOGIN_CACHE_FILE}")"

shard_accounts="${tmp_dir}/shard.csv"
awk -v offset="${shard_offset}" -v limit="${requested_connections}" 'NR > offset && NR <= offset + limit { print }' "${usable_accounts}" >"${shard_accounts}"
shard_count="$(wc -l <"${shard_accounts}" | tr -d ' ')"
if (( shard_count != requested_connections )); then
  echo "Expected ${requested_connections} sharded accounts, got ${shard_count}." >&2
  exit 1
fi

records_jsonl="${tmp_dir}/records.jsonl"
touch "${records_jsonl}"

login_one() {
  local login_index="$1"
  local email="$2"
  local password="$3"
  local device_id="${DEVICE_ID_PREFIX}-${login_index}"
  local device_name="${DEVICE_ID_PREFIX}-${login_index}"
  local attempt=1
  local max_attempts=$(( LOGIN_RETRIES + 1 ))
  local response_file status payload access_token expires_in user_id now_ms expires_at_ms

  payload="$(jq -nc \
    --arg email "${email}" \
    --arg password "${password}" \
    --arg deviceID "${device_id}" \
    --arg deviceName "${device_name}" \
    '{email:$email,password:$password,device:{deviceID:$deviceID,deviceName:$deviceName,platform:"load-test",appVersion:"load-test"}}')"

  while (( attempt <= max_attempts )); do
    response_file="${tmp_dir}/login-${login_index}-${attempt}.json"
    status="$(curl -sS --max-time "${REQUEST_TIMEOUT_SECONDS}" -o "${response_file}" -w '%{http_code}' \
      -X POST "${BASE_URL%/}/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d "${payload}" || true)"
    if [[ "${status}" == "200" ]]; then
      access_token="$(jq -er '.accessToken' "${response_file}")"
      expires_in="$(jq -er '.expiresIn' "${response_file}")"
      user_id="$(jq -er '.user.id' "${response_file}")"
      now_ms=$(( $(date +%s) * 1000 ))
      expires_at_ms=$(( now_ms + expires_in * 1000 ))
      jq -nc \
        --argjson loginIndex "${login_index}" \
        --arg email "${email}" \
        --arg deviceID "${device_id}" \
        --arg deviceName "${device_name}" \
        --arg userID "${user_id}" \
        --arg accessToken "${access_token}" \
        --argjson expiresAtMs "${expires_at_ms}" \
        '{loginIndex:$loginIndex,email:$email,deviceID:$deviceID,deviceName:$deviceName,userID:$userID,accessToken:$accessToken,expiresAtMs:$expiresAtMs}' \
        >>"${records_jsonl}"
      return 0
    fi

    echo "login failed index=${login_index} email=${email} attempt=${attempt}/${max_attempts} status=${status}" >&2
    if (( attempt == max_attempts )); then
      echo "last response:" >&2
      tail -c 1000 "${response_file}" >&2 || true
      echo >&2
      return 1
    fi
    sleep "$(awk -v ms="${LOGIN_RETRY_DELAY_MS}" 'BEGIN { printf "%.3f", ms / 1000 }')"
    attempt=$(( attempt + 1 ))
  done
}

echo "Prewarming login cache slowly:"
echo "  baseURL=${BASE_URL%/}"
echo "  accounts=${shard_accounts}"
echo "  connections=${requested_connections}"
echo "  shardOffset=${shard_offset}"
echo "  batchSize=${BATCH_SIZE}"
echo "  batchPauseSeconds=${BATCH_PAUSE_SECONDS}"
echo "  requestTimeoutSeconds=${REQUEST_TIMEOUT_SECONDS}"
echo "  cacheFile=${LOGIN_CACHE_FILE}"

processed=0
while IFS=, read -r email password; do
  email="$(printf '%s' "${email}" | xargs)"
  password="$(printf '%s' "${password}" | xargs)"
  login_index=$(( shard_offset + processed ))
  login_one "${login_index}" "${email}" "${password}"
  processed=$(( processed + 1 ))

  if (( processed % BATCH_SIZE == 0 && processed < requested_connections )); then
    echo "prewarm progress ${processed}/${requested_connections}; sleeping ${BATCH_PAUSE_SECONDS}s"
    sleep "${BATCH_PAUSE_SECONDS}"
  elif (( processed % 10 == 0 || processed == requested_connections )); then
    echo "prewarm progress ${processed}/${requested_connections}"
  fi
done <"${shard_accounts}"

jq -s 'sort_by(.loginIndex)' "${records_jsonl}" >"${LOGIN_CACHE_FILE}.tmp"
mv "${LOGIN_CACHE_FILE}.tmp" "${LOGIN_CACHE_FILE}"

now_ms=$(( $(date +%s) * 1000 ))
min_valid_for_seconds="$(jq -r --argjson nowMs "${now_ms}" '[.[].expiresAtMs - $nowMs] | min / 1000 | floor' "${LOGIN_CACHE_FILE}")"
record_count="$(jq 'length' "${LOGIN_CACHE_FILE}")"
echo "login-cache complete records=${record_count} cacheFile=${LOGIN_CACHE_FILE} minValidForSeconds=${min_valid_for_seconds}"
