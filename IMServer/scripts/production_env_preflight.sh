#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND_API_ENV="${ROOT_DIR}/config/env/command-api.production.env.example"
GATEWAY_ENV="${ROOT_DIR}/config/env/gateway.production.env.example"
QUERY_API_ENV="${ROOT_DIR}/config/env/query-api.production.env.example"
OUTBOX_RELAY_ENV="${ROOT_DIR}/config/env/outbox-relay.production.env.example"
OPS_ENV="${ROOT_DIR}/config/env/ops.production.env.example"
STREAM_CONSUMER_ENVS=("${ROOT_DIR}/config/env/stream-consumer.production.env.example")
REQUIRED_GROUPS=()
STRICT_SECRETS=false
failures=()
ENV_FILE_CACHE_FILES=()
ENV_CACHE_FILE_INDEX=""
MAX_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT=128
MAX_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS=100
MAX_ACTIVE_COMPACT_HINT_PREVIEW_CHARS=120
MAX_GATEWAY_LOCAL_FANOUT_BATCH_SIZE=1024
MAX_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS=256
MAX_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT=64
MAX_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE=2048
MAX_GATEWAY_RELAY_DOMAIN_EVENT_BODY_BYTES=$((16 * 1024 * 1024))
MIN_TIMELINE_SINCE_HOT_CACHE_TTL_MS=50
MAX_TIMELINE_SINCE_HOT_CACHE_TTL_MS=5000
MIN_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES=1024
MIN_TIMELINE_SINCE_RECENT_CACHE_TTL_MS=1000
MAX_TIMELINE_SINCE_RECENT_CACHE_TTL_MS=30000
MIN_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS=512
MIN_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION=128
MAX_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS=50
MIN_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS=50
MAX_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS=1000

usage() {
  cat <<'USAGE'
Usage: production_env_preflight.sh [--command-api file] [--gateway file] [--query-api file] [--outbox-relay file] [--ops file] [--stream-consumer file ...] [--require-groups csv] [--strict-secrets]

Checks cross-role production env consistency before deployment. By default it
validates the production env templates under config/env.

Examples:
  scripts/production_env_preflight.sh
  scripts/production_env_preflight.sh \
    --command-api /etc/im/command-api.env \
    --gateway /etc/im/gateway.env \
    --query-api /etc/im/query-api.env \
    --outbox-relay /etc/im/outbox-relay.env \
    --ops /etc/im/ops.env \
    --stream-consumer /etc/im/stream-summary.env \
    --stream-consumer /etc/im/stream-domain.env \
    --stream-consumer /etc/im/stream-realtime.env \
    --strict-secrets \
    --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,notification-consumer
USAGE
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --command-api)
      COMMAND_API_ENV="${2:?missing --command-api value}"
      shift 2
      ;;
    --gateway)
      GATEWAY_ENV="${2:?missing --gateway value}"
      shift 2
      ;;
    --query-api)
      QUERY_API_ENV="${2:?missing --query-api value}"
      shift 2
      ;;
    --outbox-relay)
      OUTBOX_RELAY_ENV="${2:?missing --outbox-relay value}"
      shift 2
      ;;
    --ops)
      OPS_ENV="${2:?missing --ops value}"
      shift 2
      ;;
    --stream-consumer)
      if [[ "${#STREAM_CONSUMER_ENVS[@]}" -eq 1
        && "${STREAM_CONSUMER_ENVS[0]}" == "${ROOT_DIR}/config/env/stream-consumer.production.env.example" ]]; then
        STREAM_CONSUMER_ENVS=()
      fi
      STREAM_CONSUMER_ENVS+=("${2:?missing --stream-consumer value}")
      shift 2
      ;;
    --require-groups)
      IFS=',' read -ra requested_groups <<< "${2:?missing --require-groups value}"
      for group in "${requested_groups[@]}"; do
        group="$(trim "${group}")"
        [[ -n "${group}" ]] && REQUIRED_GROUPS+=("${group}")
      done
      shift 2
      ;;
    --strict-secrets)
      STRICT_SECRETS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

record_failure() {
  failures+=("$1")
  echo "PREFLIGHT FAILURE: $1" >&2
}

env_cache_find_file_index() {
  local file="$1"
  local index
  ENV_CACHE_FILE_INDEX=""
  if (( ${#ENV_FILE_CACHE_FILES[@]} > 0 )); then
    for index in "${!ENV_FILE_CACHE_FILES[@]}"; do
      if [[ "${ENV_FILE_CACHE_FILES[${index}]}" == "${file}" ]]; then
        ENV_CACHE_FILE_INDEX="${index}"
        return 0
      fi
    done
  fi
  return 1
}

env_cache_get() {
  local file="$1"
  local key="$2"
  local variable_name
  env_cache_find_file_index "${file}" || return 1
  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  variable_name="__IM_ENV_CACHE_${ENV_CACHE_FILE_INDEX}_${key}"
  eval '[[ -n "${'"${variable_name}"'+set}" ]]' || return 1
  eval 'printf "%s" "${'"${variable_name}"'}"'
}

env_cache_set_if_absent() {
  local file_index="$1"
  local key="$2"
  local value="$3"
  local variable_name
  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  variable_name="__IM_ENV_CACHE_${file_index}_${key}"
  printf -v "${variable_name}" '%s' "${value}"
}

load_env_file_cache() {
  local file="$1"
  local key value file_index
  if env_cache_find_file_index "${file}"; then
    return 0
  fi
  ENV_FILE_CACHE_FILES+=("${file}")
  file_index="$((${#ENV_FILE_CACHE_FILES[@]} - 1))"
  [[ -f "${file}" ]] || return 0
  while IFS=$'\034' read -r key value || [[ -n "${key}" ]]; do
    [[ -n "${key}" ]] || continue
    env_cache_set_if_absent "${file_index}" "${key}" "${value}"
  done < <(
    awk '
      function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
      }
      {
        line = trim($0)
        if (line == "" || line ~ /^#/) next
        sub(/^export[[:space:]]+/, "", line)
        pos = index(line, "=")
        if (pos == 0) next
        key = trim(substr(line, 1, pos - 1))
        if (key == "") next
        value = trim(substr(line, pos + 1))
        if ((value ~ /^".*"$/) || (value ~ /^'\''.*'\''$/)) {
          value = substr(value, 2, length(value) - 2)
        }
        printf "%s\034%s\n", key, value
      }
    ' "${file}"
  )
}

env_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 1
  load_env_file_cache "${file}"
  if env_cache_get "${file}" "${key}"; then
    return 0
  fi
  return 1
}

is_placeholder_value() {
  local value lowered
  value="$(trim "$1")"
  lowered="$(to_lower "${value}")"
  case "${lowered}" in
    replace-me|change-me|changeme|password|secret|token|example)
      return 0
      ;;
  esac
  [[ "${lowered}" == *"replace-me"* ]] && return 0
  [[ "${lowered}" == *"user:pass"* ]] && return 0
  [[ "${lowered}" == *".example"* ]] && return 0
  [[ "${lowered}" == *"example:"* ]] && return 0
  [[ "${lowered}" == *"://example"* ]] && return 0
  return 1
}

validate_no_placeholder_values() {
  local file="$1"
  local label="$2"
  local line key value
  [[ "${STRICT_SECRETS}" == true ]] || return 0
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(trim "${line}")"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" == export\ * ]] && line="$(trim "${line#export }")"
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    value="$(trim "${value}")"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    if is_placeholder_value "${value}"; then
      record_failure "${label} strict secrets requires ${key} to not use placeholder value"
    fi
  done < "${file}"
}

require_file() {
  local label="$1"
  local file="$2"
  [[ -f "${file}" ]] || record_failure "${label} env file does not exist: ${file}"
}

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(to_lower "${1:-}")" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "$(to_lower "${1:-}")" in
    false) return 0 ;;
    *) return 1 ;;
  esac
}

is_private_or_loopback_tcp_host() {
  local host="$1"
  local first second
  host="$(to_lower "$(trim "${host}")")"
  case "${host}" in
    localhost|::1|127.*|10.*|192.168.*)
      return 0
      ;;
  esac
  IFS='.' read -r first second _ <<< "${host}"
  if [[ "${first}" == "172" ]] && is_integer "${second:-}" && (( second >= 16 && second <= 31 )); then
    return 0
  fi
  return 1
}

csv_contains() {
  local csv="$1"
  local needle="$2"
  local item
  IFS=',' read -ra items <<< "${csv}"
  for item in "${items[@]}"; do
    item="$(trim "${item}")"
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

csv_item_count() {
  local csv="$1"
  local item count=0
  IFS=',' read -ra items <<< "${csv}"
  for item in "${items[@]}"; do
    item="$(trim "${item}")"
    [[ -n "${item}" ]] && ((count += 1))
  done
  printf '%s' "${count}"
}

csv_pair_contains_key() {
  local csv="$1"
  local needle="$2"
  local item key
  IFS=',' read -ra items <<< "${csv}"
  for item in "${items[@]}"; do
    item="$(trim "${item}")"
    [[ -z "${item}" || "${item}" != *"="* ]] && continue
    key="$(trim "${item%%=*}")"
    [[ "${key}" == "${needle}" ]] && return 0
  done
  return 1
}

env_key_component() {
  local value="$1"
  value="$(printf '%s' "${value}" | tr '[:lower:]' '[:upper:]')"
  value="$(printf '%s' "${value}" | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//')"
  printf '%s' "${value}"
}

require_non_empty() {
  local file="$1"
  local key="$2"
  local label="$3"
  local value
  if ! value="$(env_value "${file}" "${key}")" || [[ -z "${value}" ]]; then
    record_failure "${label} requires ${key}"
    return 1
  fi
  return 0
}

require_true() {
  local file="$1"
  local key="$2"
  local label="$3"
  local value
  if ! value="$(env_value "${file}" "${key}")" || ! is_true "${value}"; then
    record_failure "${label} requires ${key}=true"
    return 1
  fi
  return 0
}

require_tcp_tls_termination_for_public_bind() {
  local file="$1"
  local label="$2"
  local enabled host requires_tls
  if enabled="$(env_value "${file}" "IM_TCP_ENABLED")" && is_false "${enabled}"; then
    return 0
  fi
  host="$(env_value "${file}" "IM_TCP_HOST" || printf '0.0.0.0')"
  if is_private_or_loopback_tcp_host "${host}"; then
    return 0
  fi
  if ! requires_tls="$(env_value "${file}" "IM_TCP_REQUIRES_TLS_TERMINATION")" || ! is_true "${requires_tls}"; then
    record_failure "${label} requires IM_TCP_REQUIRES_TLS_TERMINATION=true when IM_TCP_HOST binds a public address"
    return 1
  fi
  return 0
}

require_int_at_least() {
  local file="$1"
  local key="$2"
  local min="$3"
  local label="$4"
  local value
  if ! value="$(env_value "${file}" "${key}")" || ! is_integer "${value}" || (( value < min )); then
    record_failure "${label} requires ${key} >= ${min}"
    return 1
  fi
  return 0
}

require_int_at_most() {
  local file="$1"
  local key="$2"
  local max="$3"
  local label="$4"
  local value
  if ! value="$(env_value "${file}" "${key}")" || ! is_integer "${value}" || (( value > max )); then
    record_failure "${label} requires ${key} <= ${max}"
    return 1
  fi
  return 0
}

require_optional_int_between() {
  local file="$1"
  local key="$2"
  local min="$3"
  local max="$4"
  local label="$5"
  local value
  if ! value="$(env_value "${file}" "${key}")"; then
    return 0
  fi
  if ! is_integer "${value}" || (( value < min || value > max )); then
    record_failure "${label} requires ${key} between ${min} and ${max} when set"
    return 1
  fi
  return 0
}

require_int_key_at_most() {
  local file="$1"
  local key="$2"
  local max_key="$3"
  local label="$4"
  local value max
  if ! value="$(env_value "${file}" "${key}")" || ! is_integer "${value}"; then
    record_failure "${label} requires numeric ${key}"
    return 1
  fi
  if ! max="$(env_value "${file}" "${max_key}")" || ! is_integer "${max}"; then
    record_failure "${label} requires numeric ${max_key}"
    return 1
  fi
  if (( value > max )); then
    record_failure "${label} requires ${key} <= ${max_key}"
    return 1
  fi
  return 0
}

require_int_value_at_most() {
  local file="$1"
  local key="$2"
  local max="$3"
  local max_label="$4"
  local label="$5"
  local value
  if ! value="$(env_value "${file}" "${key}")" || ! is_integer "${value}"; then
    record_failure "${label} requires numeric ${key}"
    return 1
  fi
  if (( value > max )); then
    record_failure "${label} requires ${key} <= ${max_label}"
    return 1
  fi
  return 0
}

require_matching_int() {
  local left_file="$1"
  local left_key="$2"
  local right_file="$3"
  local right_key="$4"
  local label="$5"
  local left right
  if ! left="$(env_value "${left_file}" "${left_key}")" || ! is_integer "${left}"; then
    record_failure "${label} requires numeric ${left_key}"
    return 1
  fi
  if ! right="$(env_value "${right_file}" "${right_key}")" || ! is_integer "${right}"; then
    record_failure "${label} requires numeric ${right_key}"
    return 1
  fi
  if (( left != right )); then
    record_failure "${label} requires ${left_key} (${left}) to match ${right_key} (${right})"
    return 1
  fi
  return 0
}

require_equals() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local value
  if ! value="$(env_value "${file}" "${key}")" || [[ "${value}" != "${expected}" ]]; then
    record_failure "${label} requires ${key}=${expected}"
    return 1
  fi
  return 0
}

require_one_of() {
  local file="$1"
  local key="$2"
  local label="$3"
  shift 3
  local value expected
  if ! value="$(env_value "${file}" "${key}")"; then
    record_failure "${label} requires ${key}"
    return 1
  fi
  for expected in "$@"; do
    if [[ "${value}" == "${expected}" ]]; then
      return 0
    fi
  done
  record_failure "${label} requires ${key} to be one of: $*"
  return 1
}

require_jwt_rotation_configuration() {
  local file="$1"
  local label="$2"
  local jwt_secret jwt_secrets active_kid entry kid secret found_active=false valid_entries=0

  jwt_secret="$(env_value "${file}" "JWT_SECRET" || true)"
  jwt_secrets="$(env_value "${file}" "JWT_SECRETS" || true)"
  active_kid="$(env_value "${file}" "JWT_ACTIVE_KID" || true)"

  if [[ -n "${jwt_secret}" ]]; then
    record_failure "${label} must not set legacy JWT_SECRET in production; use JWT_SECRETS and JWT_ACTIVE_KID"
  fi
  if [[ -z "${jwt_secrets}" ]]; then
    record_failure "${label} requires JWT_SECRETS=kid:secret,..."
    return 1
  fi
  if [[ -z "${active_kid}" ]]; then
    record_failure "${label} requires JWT_ACTIVE_KID"
  fi

  IFS=',' read -ra entries <<< "${jwt_secrets}"
  for entry in "${entries[@]}"; do
    entry="$(trim "${entry}")"
    if [[ -z "${entry}" || "${entry}" != *:* ]]; then
      record_failure "${label} requires JWT_SECRETS entries to use kid:secret"
      continue
    fi
    kid="$(trim "${entry%%:*}")"
    secret="$(trim "${entry#*:}")"
    if [[ -z "${kid}" || -z "${secret}" ]]; then
      record_failure "${label} requires JWT_SECRETS entries to include non-empty kid and secret"
      continue
    fi
    ((valid_entries += 1))
    [[ "${kid}" == "${active_kid}" ]] && found_active=true
  done

  if (( valid_entries == 0 )); then
    record_failure "${label} requires at least one valid JWT_SECRETS entry"
  fi
  if [[ -n "${active_kid}" && "${found_active}" != true ]]; then
    record_failure "${label} requires JWT_ACTIVE_KID to match a JWT_SECRETS kid"
  fi
}

require_https_url_unless_allowed() {
  local file="$1"
  local key="$2"
  local allow_key="$3"
  local label="$4"
  local value allow_value
  if ! value="$(env_value "${file}" "${key}")" || [[ -z "${value}" ]]; then
    record_failure "${label} requires ${key}"
    return 1
  fi
  if allow_value="$(env_value "${file}" "${allow_key}")" && is_true "${allow_value}"; then
    record_failure "${label} must not set ${allow_key} in production"
    return 1
  fi
  if [[ "${value}" == https://* ]]; then
    require_https_dependency_url_value "${key}" "${value}" "${label}"
    return $?
  fi
  record_failure "${label} requires ${key} to use https"
  return 1
}

require_https_dependency_url() {
  local file="$1"
  local key="$2"
  local label="$3"
  local value
  if ! value="$(env_value "${file}" "${key}")" || [[ -z "${value}" ]]; then
    record_failure "${label} requires ${key}"
    return 1
  fi
  if [[ "${value}" != https://* ]]; then
    record_failure "${label} requires ${key} to use https"
    return 1
  fi
  require_https_dependency_url_value "${key}" "${value}" "${label}"
}

require_https_dependency_url_value() {
  local key="$1"
  local value="$2"
  local label="$3"
  local authority host lower
  authority="${value#https://}"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%#*}"
  if [[ -z "${authority}" || "${authority}" == \[* ]]; then
    record_failure "${label} requires ${key} to use a real non-placeholder DNS host"
    return 1
  fi
  host="${authority%%:*}"
  lower="$(to_lower "${host}")"
  if [[ -z "${lower}" || "${lower}" == "localhost" || "${lower}" == "ip6-localhost" || "${lower}" == *.local ]]; then
    record_failure "${label} requires ${key} to use a real non-placeholder DNS host"
    return 1
  fi
  if [[ "${lower}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    record_failure "${label} requires ${key} to use a real non-placeholder DNS host"
    return 1
  fi
  case "${lower}" in
    example|example.com|example.net|example.org|yourdomain.com|*.example|*.example.com|*.example.net|*.example.org|*.yourdomain.com|*.test|*.invalid)
      record_failure "${label} requires ${key} to use a real non-placeholder DNS host"
      return 1
      ;;
  esac
  return 0
}

require_matching_value() {
  local left_file="$1"
  local left_key="$2"
  local right_file="$3"
  local right_key="$4"
  local label="$5"
  local left right
  if ! left="$(env_value "${left_file}" "${left_key}")" || [[ -z "${left}" ]]; then
    record_failure "${label} requires ${left_key}"
    return 1
  fi
  if ! right="$(env_value "${right_file}" "${right_key}")" || [[ -z "${right}" ]]; then
    record_failure "${label} requires ${right_key}"
    return 1
  fi
  if [[ "${left}" != "${right}" ]]; then
    record_failure "${label} requires ${left_key} (${left}) to match ${right_key} (${right})"
    return 1
  fi
  return 0
}

require_active_compact_hint_configuration() {
  local file="$1"
  local label="$2"
  require_int_at_least "${file}" "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS" 1 "${label}" || true
  require_int_at_most "${file}" "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS" "${MAX_ACTIVE_COMPACT_HINT_PREVIEW_CHARS}" "${label}" || true
}

require_primary_database() {
  local file="$1"
  local label="$2"
  require_non_empty "${file}" "DATABASE_PRIMARY_HOST" "${label}" || true
  require_non_empty "${file}" "DATABASE_PRIMARY_NAME" "${label}" || true
  require_non_empty "${file}" "DATABASE_PRIMARY_USERNAME" "${label}" || true
  require_non_empty "${file}" "DATABASE_PRIMARY_PASSWORD" "${label}" || true
}

require_conversation_shards() {
  local file="$1"
  local label="$2"
  local shard_ids shard_id component prefix field
  require_non_empty "${file}" "IM_CONVERSATION_SHARD_IDS" "${label}" || true
  shard_ids="$(env_value "${file}" "IM_CONVERSATION_SHARD_IDS" || true)"
  IFS=',' read -ra shards <<< "${shard_ids}"
  for shard_id in "${shards[@]}"; do
    shard_id="$(trim "${shard_id}")"
    [[ -z "${shard_id}" ]] && continue
    component="$(env_key_component "${shard_id}")"
    prefix="DATABASE_CONVERSATION_${component}"
    for field in HOST PORT USERNAME PASSWORD NAME; do
      require_non_empty "${file}" "${prefix}_${field}" "${label} conversation shard ${shard_id}" || true
    done
  done
}

require_summary_shards() {
  local file="$1"
  local label="$2"
  local shard_ids shard_id component prefix field
  require_non_empty "${file}" "IM_SUMMARY_SHARD_IDS" "${label}" || true
  shard_ids="$(env_value "${file}" "IM_SUMMARY_SHARD_IDS" || true)"
  IFS=',' read -ra shards <<< "${shard_ids}"
  for shard_id in "${shards[@]}"; do
    shard_id="$(trim "${shard_id}")"
    [[ -z "${shard_id}" ]] && continue
    component="$(env_key_component "${shard_id}")"
    prefix="DATABASE_SUMMARY_${component}"
    for field in HOST PORT USERNAME PASSWORD NAME; do
      require_non_empty "${file}" "${prefix}_${field}" "${label} summary shard ${shard_id}" || true
    done
  done
}

require_kafka_stream() {
  local file="$1"
  local label="$2"
  require_equals "${file}" "IM_EVENT_STREAM_DRIVER" "kafka" "${label}" || true
  require_non_empty "${file}" "IM_KAFKA_BROKERS" "${label}" || true
  require_non_empty "${file}" "IM_KAFKA_TOPIC" "${label}" || true
  require_non_empty "${file}" "IM_KAFKA_DEAD_LETTER_TOPIC" "${label}" || true
  require_non_empty "${file}" "IM_KAFKA_CLIENT_ID" "${label}" || true
  require_equals "${file}" "IM_KAFKA_REQUIRED_ACKS" "all" "${label}" || true
  require_equals "${file}" "IM_KAFKA_AUTO_CREATE_TOPICS" "false" "${label}" || true
  require_equals "${file}" "IM_KAFKA_SECURITY_PROTOCOL" "sasl_tls" "${label}" || true
  require_equals "${file}" "IM_KAFKA_SASL_MECHANISM" "scram-sha-512" "${label}" || true
  require_non_empty "${file}" "IM_KAFKA_SASL_USERNAME" "${label}" || true
  require_non_empty "${file}" "IM_KAFKA_SASL_PASSWORD" "${label}" || true
  require_non_empty "${file}" "IM_KAFKA_TLS_CA_FILE" "${label}" || true
}

require_command_api_media_storage() {
  local file="$1"
  local label="$2"
  require_equals "${file}" "MEDIA_STORAGE_PROVIDER" "s3compatible" "${label}" || true
  require_https_url_unless_allowed "${file}" "MEDIA_STORAGE_S3_ENDPOINT" "IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT" "${label}" || true
  require_non_empty "${file}" "MEDIA_STORAGE_S3_BUCKET" "${label}" || true
  require_non_empty "${file}" "MEDIA_STORAGE_S3_ACCESS_KEY_ID" "${label}" || true
  require_non_empty "${file}" "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY" "${label}" || true
  require_non_empty "${file}" "MEDIA_STORAGE_S3_REGION" "${label}" || true
  require_one_of "${file}" "MEDIA_STORAGE_S3_FORCE_PATH_STYLE" "${label}" "true" "false" || true
}

require_command_api_write_path() {
  local file="$1"
  local label="$2"
  local node_id node_urls command_secret internal_secret
  require_int_at_least "${file}" "IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT" 1 "${label}" || true
  require_equals "${file}" "IM_SEQUENCE_ALLOCATION_MODE" "block" "${label}" || true
  require_int_at_least "${file}" "IM_SEQUENCE_BLOCK_SIZE" 1 "${label}" || true
  require_non_empty "${file}" "IM_COMMAND_NODE_ID" "${label}" || true
  require_non_empty "${file}" "IM_COMMAND_NODE_URLS" "${label}" || true
  node_id="$(env_value "${file}" "IM_COMMAND_NODE_ID" || true)"
  node_urls="$(env_value "${file}" "IM_COMMAND_NODE_URLS" || true)"
  if [[ -n "${node_id}" && -n "${node_urls}" ]] && ! csv_pair_contains_key "${node_urls}" "${node_id}"; then
    record_failure "${label} requires IM_COMMAND_NODE_ID to match an entry in IM_COMMAND_NODE_URLS"
  fi

  command_secret="$(env_value "${file}" "IM_COMMAND_INTERNAL_SHARED_SECRET" || true)"
  internal_secret="$(env_value "${file}" "IM_INTERNAL_SHARED_SECRET" || true)"
  if [[ -z "${command_secret}" && -z "${internal_secret}" ]]; then
    record_failure "${label} requires IM_COMMAND_INTERNAL_SHARED_SECRET or IM_INTERNAL_SHARED_SECRET"
  fi

  require_true "${file}" "IM_MESSAGE_WRITE_BATCH_ENABLED" "${label}" || true
  require_int_at_least "${file}" "IM_MESSAGE_WRITE_BATCH_MAX_SIZE" 2 "${label}" || true
  require_int_at_least "${file}" "IM_MESSAGE_WRITE_BATCH_MAX_DELAY_MS" 1 "${label}" || true
}

require_command_api_gateway_relay() {
  local file="$1"
  local label="$2"
  require_http_gateway_relay "${file}" "${label}"
}

require_http_gateway_relay() {
  local file="$1"
  local label="$2"
  require_equals "${file}" "IM_GATEWAY_RELAY_MODE" "http" "${label}" || true
  require_non_empty "${file}" "IM_GATEWAY_INTERNAL_BASE_URL" "${label}" || true
  require_non_empty "${file}" "IM_INTERNAL_SHARED_SECRET" "${label}" || true
  require_optional_int_between "${file}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES" 65536 "${MAX_GATEWAY_RELAY_DOMAIN_EVENT_BODY_BYTES}" "${label}" || true
  require_optional_int_between "${file}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES" 65536 "${MAX_GATEWAY_RELAY_DOMAIN_EVENT_BODY_BYTES}" "${label}" || true
  require_optional_int_between "${file}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKETS_MAX_BODY_BYTES" 65536 "${MAX_GATEWAY_RELAY_DOMAIN_EVENT_BODY_BYTES}" "${label}" || true
}

require_gateway_command_ingress() {
  local file="$1"
  local label="$2"
  require_non_empty "${file}" "IM_COMMAND_API_INTERNAL_BASE_URL" "${label}" || true
  require_non_empty "${file}" "IM_INTERNAL_SHARED_SECRET" "${label}" || true
}

require_search_configuration() {
  local file="$1"
  local label="$2"
  local driver
  require_non_empty "${file}" "IM_SEARCH_DRIVER" "${label}" || true
  driver="$(env_value "${file}" "IM_SEARCH_DRIVER" || true)"
  if [[ "${driver}" == "opensearch" ]]; then
    require_https_dependency_url "${file}" "IM_OPENSEARCH_ENDPOINT" "${label}" || true
  fi
}

require_summary_response_member_user_ids_limit() {
  local file="$1"
  local label="$2"
  require_int_at_least "${file}" "IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT" 1 "${label}" || true
}

require_timeline_since_cache_invalidation() {
  local file="$1"
  local label="$2"
  local redis_url dedicated_redis_url
  require_int_at_least "${file}" "IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS" "${MIN_TIMELINE_SINCE_HOT_CACHE_TTL_MS}" "${label}" || true
  require_int_at_most "${file}" "IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS" "${MAX_TIMELINE_SINCE_HOT_CACHE_TTL_MS}" "${label}" || true
  require_int_at_least "${file}" "IM_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES" "${MIN_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES}" "${label}" || true
  require_int_at_least "${file}" "IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS" "${MIN_TIMELINE_SINCE_RECENT_CACHE_TTL_MS}" "${label}" || true
  require_int_at_most "${file}" "IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS" "${MAX_TIMELINE_SINCE_RECENT_CACHE_TTL_MS}" "${label}" || true
  require_int_at_least "${file}" "IM_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS" "${MIN_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS}" "${label}" || true
  require_int_at_least "${file}" "IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION" "${MIN_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION}" "${label}" || true
  require_int_at_least "${file}" "IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS" 0 "${label}" || true
  require_int_at_most "${file}" "IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS" "${MAX_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS}" "${label}" || true
  require_equals "${file}" "IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE" "redis" "${label}" || true
  redis_url="$(env_value "${file}" "REDIS_URL" || true)"
  dedicated_redis_url="$(env_value "${file}" "IM_TIMELINE_SINCE_CACHE_INVALIDATION_REDIS_URL" || true)"
  if [[ -z "${redis_url}" && -z "${dedicated_redis_url}" ]]; then
    record_failure "${label} requires REDIS_URL or IM_TIMELINE_SINCE_CACHE_INVALIDATION_REDIS_URL for distributed timeline/since cache invalidation"
  fi
  require_int_at_least "${file}" "IM_TIMELINE_SINCE_CACHE_INVALIDATION_REDIS_MAX_CONNECTIONS" 2 "${label}" || true
}

validate_command_api() {
  local label="command-api"
  require_file "${label}" "${COMMAND_API_ENV}"
  require_non_empty "${COMMAND_API_ENV}" "IM_NODE_ID" "${label}" || true
  require_jwt_rotation_configuration "${COMMAND_API_ENV}" "${label}" || true
  require_primary_database "${COMMAND_API_ENV}" "${label}"
  require_conversation_shards "${COMMAND_API_ENV}" "${label}"
  require_kafka_stream "${COMMAND_API_ENV}" "${label}"
  require_command_api_media_storage "${COMMAND_API_ENV}" "${label}"
  require_command_api_write_path "${COMMAND_API_ENV}" "${label}"
  require_command_api_gateway_relay "${COMMAND_API_ENV}" "${label}"
  require_timeline_since_cache_invalidation "${COMMAND_API_ENV}" "${label}"
  require_int_at_least "${COMMAND_API_ENV}" "IM_GROUP_MEMBER_LIMIT" 2 "${label}" || true
  require_int_at_least "${COMMAND_API_ENV}" "IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD" 1 "${label}" || true
  require_int_at_least "${COMMAND_API_ENV}" "IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD" 1 "${label}" || true
  local group_limit inline_threshold
  if group_limit="$(env_value "${COMMAND_API_ENV}" "IM_GROUP_MEMBER_LIMIT")" \
    && inline_threshold="$(env_value "${COMMAND_API_ENV}" "IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD")" \
    && is_integer "${group_limit}" && is_integer "${inline_threshold}" \
    && (( inline_threshold > group_limit )); then
    record_failure "${label} requires IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD <= IM_GROUP_MEMBER_LIMIT"
  fi
  local dedup_threshold
  if dedup_threshold="$(env_value "${COMMAND_API_ENV}" "IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD")" \
    && inline_threshold="$(env_value "${COMMAND_API_ENV}" "IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD")" \
    && is_integer "${dedup_threshold}" && is_integer "${inline_threshold}" \
    && (( dedup_threshold > inline_threshold )); then
    record_failure "${label} requires IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD <= IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD"
  fi
}

validate_gateway() {
  local label="gateway"
  local group_limit
  require_file "${label}" "${GATEWAY_ENV}"
  require_non_empty "${GATEWAY_ENV}" "IM_NODE_ID" "${label}" || true
  require_jwt_rotation_configuration "${GATEWAY_ENV}" "${label}" || true
  require_primary_database "${GATEWAY_ENV}" "${label}"
  require_gateway_command_ingress "${GATEWAY_ENV}" "${label}"
  require_tcp_tls_termination_for_public_bind "${GATEWAY_ENV}" "${label}" || true
  require_true "${GATEWAY_ENV}" "IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE" "${label}" || true
  require_true "${GATEWAY_ENV}" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED" "${label}" || true
  require_int_at_least "${GATEWAY_ENV}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" 1 "${label}" || true
  require_int_at_most "${GATEWAY_ENV}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" "${MAX_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT}" "${label}" || true
  require_int_key_at_most "${GATEWAY_ENV}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" "${label}" || true
  require_equals "${GATEWAY_ENV}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE" "compact-only" "${label}" || true
  require_active_compact_hint_configuration "${GATEWAY_ENV}" "${label}"
  require_int_at_least "${GATEWAY_ENV}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_PAYLOAD_BYTE_BUDGET" 65536 "${label}" || true
  require_equals "${GATEWAY_ENV}" "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE" "pull-only" "${label}" || true
  require_int_at_least "${GATEWAY_ENV}" "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MAX_PENDING_RECIPIENTS" 1 "${label}" || true
  require_int_at_least "${GATEWAY_ENV}" "IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT" 2 "${label}" || true
  require_int_at_most "${GATEWAY_ENV}" "IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT" "${MAX_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT}" "${label}" || true
  require_int_at_most "${GATEWAY_ENV}" "IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE" "${MAX_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE}" "${label}" || true
  require_int_at_most "${GATEWAY_ENV}" "IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE" "${MAX_GATEWAY_LOCAL_FANOUT_BATCH_SIZE}" "${label}" || true
  require_int_at_most "${GATEWAY_ENV}" "IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS" "${MAX_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS}" "${label}" || true
  require_int_at_least "${GATEWAY_ENV}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES" 65536 "${label}" || true
  require_int_at_most "${GATEWAY_ENV}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES" "${MAX_GATEWAY_RELAY_DOMAIN_EVENT_BODY_BYTES}" "${label}" || true
  require_int_at_least "${GATEWAY_ENV}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES" 65536 "${label}" || true
  require_int_at_most "${GATEWAY_ENV}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES" "${MAX_GATEWAY_RELAY_DOMAIN_EVENT_BODY_BYTES}" "${label}" || true
  require_int_at_least "${GATEWAY_ENV}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKETS_MAX_BODY_BYTES" 65536 "${label}" || true
  require_int_at_most "${GATEWAY_ENV}" "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKETS_MAX_BODY_BYTES" "${MAX_GATEWAY_RELAY_DOMAIN_EVENT_BODY_BYTES}" "${label}" || true
  group_limit="$(env_value "${COMMAND_API_ENV}" "IM_GROUP_MEMBER_LIMIT" || true)"
  if is_integer "${group_limit:-}"; then
    require_int_at_most "${GATEWAY_ENV}" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" "${group_limit}" "${label}" || true
  fi

  local debounce_seconds debounce_ms
  debounce_seconds="$(env_value "${GATEWAY_ENV}" "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS" || true)"
  debounce_ms="$(env_value "${GATEWAY_ENV}" "IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_MS" || true)"
  if ! { is_integer "${debounce_seconds:-}" && (( debounce_seconds > 0 )); } \
    && ! { is_integer "${debounce_ms:-}" && (( debounce_ms > 0 )); }; then
    record_failure "${label} requires IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS or IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_MS > 0"
  fi
}

validate_query_api() {
  local label="query-api"
  require_file "${label}" "${QUERY_API_ENV}"
  require_non_empty "${QUERY_API_ENV}" "IM_NODE_ID" "${label}" || true
  require_jwt_rotation_configuration "${QUERY_API_ENV}" "${label}" || true
  require_primary_database "${QUERY_API_ENV}" "${label}"
  require_conversation_shards "${QUERY_API_ENV}" "${label}"
  require_summary_shards "${QUERY_API_ENV}" "${label}"
  require_equals "${QUERY_API_ENV}" "IM_SUMMARY_QUERY_READ_SOURCE" "sharded" "${label}" || true
  require_summary_response_member_user_ids_limit "${QUERY_API_ENV}" "${label}"
  require_search_configuration "${QUERY_API_ENV}" "${label}"
  require_timeline_since_cache_invalidation "${QUERY_API_ENV}" "${label}"
}

validate_outbox_relay() {
  local label="outbox-relay"
  require_file "${label}" "${OUTBOX_RELAY_ENV}"
  require_non_empty "${OUTBOX_RELAY_ENV}" "IM_NODE_ID" "${label}" || true
  require_primary_database "${OUTBOX_RELAY_ENV}" "${label}"
  require_conversation_shards "${OUTBOX_RELAY_ENV}" "${label}"
  require_kafka_stream "${OUTBOX_RELAY_ENV}" "${label}"
  require_int_at_least "${OUTBOX_RELAY_ENV}" "IM_OUTBOX_BATCH_SIZE" 1 "${label}" || true
  require_int_at_least "${OUTBOX_RELAY_ENV}" "IM_OUTBOX_CLAIM_TIMEOUT_MS" 1000 "${label}" || true
}

validate_ops() {
  local label="ops"
  require_file "${label}" "${OPS_ENV}"
  require_non_empty "${OPS_ENV}" "IM_NODE_ID" "${label}" || true
  require_primary_database "${OPS_ENV}" "${label}"
  require_conversation_shards "${OPS_ENV}" "${label}"
  require_summary_shards "${OPS_ENV}" "${label}"
  require_equals "${OPS_ENV}" "IM_SUMMARY_PROJECTION_WRITE_MODE" "sharded" "${label}" || true
  require_equals "${OPS_ENV}" "IM_SUMMARY_QUERY_READ_SOURCE" "sharded" "${label}" || true
  require_summary_response_member_user_ids_limit "${OPS_ENV}" "${label}"
  require_kafka_stream "${OPS_ENV}" "${label}"
  require_search_configuration "${OPS_ENV}" "${label}"
}

stream_file_has_group() {
  local file="$1"
  local group="$2"
  local groups
  groups="$(env_value "${file}" "IM_STREAM_CONSUMER_GROUPS" || true)"
  csv_contains "${groups}" "${group}"
}

validate_stream_consumer_file() {
  local file="$1"
  local label="stream-consumer:${file}"
  local command_group_limit group_limit groups relay_after_record
  require_file "stream-consumer" "${file}"
  require_non_empty "${file}" "IM_NODE_ID" "${label}" || true
  require_primary_database "${file}" "${label}"
  require_conversation_shards "${file}" "${label}"
  require_summary_shards "${file}" "${label}"
  require_kafka_stream "${file}" "${label}"
  require_equals "${file}" "IM_SUMMARY_PROJECTION_WRITE_MODE" "sharded" "${label}" || true
  require_matching_int "${file}" "IM_GROUP_MEMBER_LIMIT" "${COMMAND_API_ENV}" "IM_GROUP_MEMBER_LIMIT" "${label}" || true
  require_timeline_since_cache_invalidation "${file}" "${label}"
  command_group_limit="$(env_value "${COMMAND_API_ENV}" "IM_GROUP_MEMBER_LIMIT" || true)"
  group_limit="$(env_value "${file}" "IM_GROUP_MEMBER_LIMIT" || true)"
  groups="$(env_value "${file}" "IM_STREAM_CONSUMER_GROUPS" || true)"
  relay_after_record="$(env_value "${file}" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" || true)"

  local allow_multi_group group_count
  allow_multi_group="$(env_value "${file}" "IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP" || true)"
  group_count="$(csv_item_count "${groups}")"
  if (( group_count != 1 )) && ! is_true "${allow_multi_group}"; then
    record_failure "${label} requires exactly one IM_STREAM_CONSUMER_GROUPS entry per env file, or IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP=true for explicitly grouped test/runtime processes"
  fi

  require_true "${file}" "IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT" "${label}" || true
  require_int_at_least "${file}" "IM_STREAM_CONSUMER_RUN_BATCH_SIZE" 2 "${label}" || true
  require_int_at_least "${file}" "IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS" 1 "${label}" || true
  require_int_at_most "${file}" "IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS" 100 "${label}" || true
  local queue_capacity run_batch_size
  if queue_capacity="$(env_value "${file}" "IM_STREAM_CONSUMER_QUEUE_CAPACITY")" \
    && run_batch_size="$(env_value "${file}" "IM_STREAM_CONSUMER_RUN_BATCH_SIZE")" \
    && is_integer "${queue_capacity}" && is_integer "${run_batch_size}" \
    && (( queue_capacity < run_batch_size )); then
    record_failure "${label} requires IM_STREAM_CONSUMER_QUEUE_CAPACITY >= IM_STREAM_CONSUMER_RUN_BATCH_SIZE"
  fi

  if is_integer "${group_limit:-}"; then
    if stream_file_has_group "${file}" "summary-projection-consumer"; then
      require_int_at_least "${file}" "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD" 1 "${label}" || true
      require_int_at_least "${file}" "IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS" "${MIN_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS}" "${label}" || true
      require_int_at_most "${file}" "IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS" "${MAX_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS}" "${label}" || true
      require_int_at_most "${file}" "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD" "${group_limit}" "${label}" || true
    fi
    if stream_file_has_group "${file}" "domain-delivery-consumer"; then
      require_http_gateway_relay "${file}" "${label}"
      local skip_all large_group_mode skip_threshold
      skip_all="$(env_value "${file}" "IM_DOMAIN_DELIVERY_SKIP_MESSAGE_CREATED_OWNER_DELIVERY" || true)"
      large_group_mode="$(env_value "${file}" "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE" || true)"
      skip_threshold="$(env_value "${file}" "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD" || true)"
      if ! is_true "${skip_all}" && { ! is_integer "${skip_threshold:-}" || (( skip_threshold <= 0 )); }; then
        record_failure "${label} requires IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE=timeline-pull with IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD > 0, or IM_DOMAIN_DELIVERY_SKIP_MESSAGE_CREATED_OWNER_DELIVERY=true"
      fi
      if ! is_true "${skip_all}"; then
        require_equals "${file}" "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE" "timeline-pull" "${label}" || true
        require_int_at_most "${file}" "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD" "${group_limit}" "${label}" || true
      fi
      require_int_at_least "${file}" "IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS" 100 "${label}" || true
      require_int_at_most "${file}" "IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS" 5000 "${label}" || true
    fi
    if stream_file_has_group "${file}" "notification-consumer"; then
      local skip_all skip_threshold
      skip_all="$(env_value "${file}" "IM_NOTIFICATION_SKIP_MESSAGE_CREATED_OWNER_NOTIFICATIONS" || true)"
      skip_threshold="$(env_value "${file}" "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD" || true)"
      if ! is_true "${skip_all}" && { ! is_integer "${skip_threshold:-}" || (( skip_threshold <= 0 )); }; then
        record_failure "${label} requires IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD > 0 or IM_NOTIFICATION_SKIP_MESSAGE_CREATED_OWNER_NOTIFICATIONS=true"
      fi
      if ! is_true "${skip_all}"; then
        require_int_at_most "${file}" "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD" "${group_limit}" "${label}" || true
        if stream_file_has_group "${file}" "domain-delivery-consumer"; then
          require_int_key_at_most "${file}" "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD" "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD" "${label}" || true
        fi
      fi
    fi
    if stream_file_has_group "${file}" "realtime-delivery-consumer" || is_true "${relay_after_record}"; then
      require_http_gateway_relay "${file}" "${label}"
      require_non_empty "${file}" "REDIS_URL" "${label}" || true
      require_summary_response_member_user_ids_limit "${file}" "${label}"
      require_true "${file}" "IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED" "${label}" || true
      require_int_at_least "${file}" "IM_REALTIME_DELIVERY_ASYNC_MAX_IN_FLIGHT" 2 "${label}" || true
      require_int_at_least "${file}" "IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED" 1 "${label}" || true
      require_equals "${file}" "IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED" "false" "${label}" || true
      require_int_at_least "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS" 1 "${label}" || true
      require_int_at_least "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES" 1 "${label}" || true
      require_int_at_least "${file}" "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS" 1 "${label}" || true
      require_int_at_least "${file}" "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS" 1 "${label}" || true
      require_int_at_most "${file}" "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS" "${MAX_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS}" "${label}" || true
      require_active_compact_hint_configuration "${file}" "${label}"
      require_true "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED" "${label}" || true
      require_int_at_least "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" 1 "${label}" || true
      require_int_at_most "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" "${MAX_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT}" "${label}" || true
      require_int_key_at_most "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" "${label}" || true
      require_equals "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE" "compact-only" "${label}" || true
      require_int_at_least "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_PAYLOAD_BYTE_BUDGET" 65536 "${label}" || true
      require_equals "${file}" "IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE" "pull-only" "${label}" || true
      require_int_at_most "${file}" "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD" "${group_limit}" "${label}" || true
      require_int_at_most "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" "${group_limit}" "${label}" || true
    fi
  fi

}

deployment_has_stream_group() {
  local required_group="$1"
  local file groups
  for file in "${STREAM_CONSUMER_ENVS[@]}"; do
    groups="$(env_value "${file}" "IM_STREAM_CONSUMER_GROUPS" || true)"
    if csv_contains "${groups}" "${required_group}"; then
      return 0
    fi
  done
  return 1
}

validate_cross_stream_topology() {
  local has_domain_skip=false
  local has_realtime=false
  local has_domain_relay_after_record=false
  local min_domain_skip_threshold=""
  local file groups skip_all large_group_mode skip_threshold relay_after_record
  for file in "${STREAM_CONSUMER_ENVS[@]}"; do
    groups="$(env_value "${file}" "IM_STREAM_CONSUMER_GROUPS" || true)"
    relay_after_record="$(env_value "${file}" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" || true)"
    if csv_contains "${groups}" "realtime-delivery-consumer"; then
      has_realtime=true
    fi
    if csv_contains "${groups}" "domain-delivery-consumer"; then
      skip_all="$(env_value "${file}" "IM_DOMAIN_DELIVERY_SKIP_MESSAGE_CREATED_OWNER_DELIVERY" || true)"
      large_group_mode="$(env_value "${file}" "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE" || true)"
      skip_threshold="$(env_value "${file}" "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD" || true)"
      if is_true "${skip_all}" || { [[ "${large_group_mode}" == "timeline-pull" ]] && is_integer "${skip_threshold:-}" && (( skip_threshold > 0 )); }; then
        has_domain_skip=true
      fi
      if [[ "${large_group_mode}" == "timeline-pull" ]] && is_integer "${skip_threshold:-}" && (( skip_threshold > 0 )); then
        if [[ -z "${min_domain_skip_threshold}" ]] || (( skip_threshold < min_domain_skip_threshold )); then
          min_domain_skip_threshold="${skip_threshold}"
        fi
      fi
      if is_true "${relay_after_record}"; then
        has_domain_relay_after_record=true
      fi
    fi
  done

  if [[ "${has_domain_relay_after_record}" == true && "${has_realtime}" == true ]]; then
    record_failure "stream-consumer deployment must not combine realtime-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"
  fi
  if [[ "${has_domain_skip}" == true && "${has_realtime}" == false && "${has_domain_relay_after_record}" == false ]]; then
    record_failure "stream-consumer deployment with large-group owner delivery skip requires realtime-delivery-consumer or IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"
  fi
  if [[ -n "${min_domain_skip_threshold}" ]]; then
    local max_label="IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
    for file in "${STREAM_CONSUMER_ENVS[@]}"; do
      groups="$(env_value "${file}" "IM_STREAM_CONSUMER_GROUPS" || true)"
      relay_after_record="$(env_value "${file}" "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD" || true)"
      local label="stream-consumer:${file}"
      if csv_contains "${groups}" "summary-projection-consumer"; then
        require_int_value_at_most "${file}" "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD" "${min_domain_skip_threshold}" "${max_label}" "${label}" || true
      fi
      if csv_contains "${groups}" "realtime-delivery-consumer" || is_true "${relay_after_record}"; then
        require_int_value_at_most "${file}" "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD" "${min_domain_skip_threshold}" "${max_label}" "${label}" || true
        require_int_value_at_most "${file}" "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD" "${min_domain_skip_threshold}" "${max_label}" "${label}" || true
      fi
      if csv_contains "${groups}" "notification-consumer"; then
        skip_all="$(env_value "${file}" "IM_NOTIFICATION_SKIP_MESSAGE_CREATED_OWNER_NOTIFICATIONS" || true)"
        if ! is_true "${skip_all}"; then
          require_int_value_at_most "${file}" "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD" "${min_domain_skip_threshold}" "${max_label}" "${label}" || true
        fi
      fi
    done
  fi

  if [[ "${#REQUIRED_GROUPS[@]}" -gt 0 ]]; then
    local required_group
    for required_group in "${REQUIRED_GROUPS[@]}"; do
      if ! deployment_has_stream_group "${required_group}"; then
        record_failure "stream-consumer deployment requires missing group: ${required_group}"
      fi
    done
  fi
}

validate_cross_role_event_stream() {
  require_matching_value "${OUTBOX_RELAY_ENV}" "IM_KAFKA_TOPIC" "${COMMAND_API_ENV}" "IM_KAFKA_TOPIC" "outbox-relay/command-api Kafka" || true
  require_matching_value "${OUTBOX_RELAY_ENV}" "IM_KAFKA_DEAD_LETTER_TOPIC" "${COMMAND_API_ENV}" "IM_KAFKA_DEAD_LETTER_TOPIC" "outbox-relay/command-api Kafka" || true
  require_matching_value "${OPS_ENV}" "IM_KAFKA_TOPIC" "${COMMAND_API_ENV}" "IM_KAFKA_TOPIC" "ops/command-api Kafka" || true
  require_matching_value "${OPS_ENV}" "IM_KAFKA_DEAD_LETTER_TOPIC" "${COMMAND_API_ENV}" "IM_KAFKA_DEAD_LETTER_TOPIC" "ops/command-api Kafka" || true

  local file
  for file in "${STREAM_CONSUMER_ENVS[@]}"; do
    require_matching_value "${file}" "IM_KAFKA_TOPIC" "${COMMAND_API_ENV}" "IM_KAFKA_TOPIC" "stream-consumer/command-api Kafka" || true
    require_matching_value "${file}" "IM_KAFKA_DEAD_LETTER_TOPIC" "${COMMAND_API_ENV}" "IM_KAFKA_DEAD_LETTER_TOPIC" "stream-consumer/command-api Kafka" || true
  done
}

validate_strict_secret_files() {
  validate_no_placeholder_values "${COMMAND_API_ENV}" "command-api"
  validate_no_placeholder_values "${GATEWAY_ENV}" "gateway"
  validate_no_placeholder_values "${QUERY_API_ENV}" "query-api"
  validate_no_placeholder_values "${OUTBOX_RELAY_ENV}" "outbox-relay"
  validate_no_placeholder_values "${OPS_ENV}" "ops"

  local file
  for file in "${STREAM_CONSUMER_ENVS[@]}"; do
    validate_no_placeholder_values "${file}" "stream-consumer:${file}"
  done
}

validate_command_api
validate_gateway
validate_query_api
validate_outbox_relay
validate_ops
for stream_env in "${STREAM_CONSUMER_ENVS[@]}"; do
  validate_stream_consumer_file "${stream_env}"
done
validate_cross_stream_topology
validate_cross_role_event_stream
validate_strict_secret_files

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo "Production env preflight failed with ${#failures[@]} issue(s)." >&2
  exit 1
fi

echo "Production env preflight passed."
