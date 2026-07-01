#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
ROLES_DIR="${ROLES_DIR:-${IMSERVER_ETC_DIR}/roles}"
VERIFY_REQUIRE_PRODUCTION="${VERIFY_REQUIRE_PRODUCTION:-false}"
IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL="${IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL:-false}"
IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT="${IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT:-false}"
PRODUCTION_ENV_VERIFY_SELF_TEST="${PRODUCTION_ENV_VERIFY_SELF_TEST:-false}"

failures=0

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

fail() {
  printf 'production-env-check=fail key=%s reason=%s\n' "$1" "$2"
  failures=$((failures + 1))
}

pass() {
  printf 'production-env-check=pass key=%s\n' "$1"
}

value_for() {
  local key="$1"
  printf '%s' "${!key:-}"
}

require_non_empty() {
  local key="$1"
  local value
  value="$(value_for "${key}")"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    fail "${key}" "missing_or_empty"
  else
    pass "${key}"
  fi
}

require_not_value() {
  local key="$1"
  local forbidden="$2"
  local value
  value="$(value_for "${key}")"
  if [[ "${value}" == "${forbidden}" ]]; then
    fail "${key}" "must_not_be_${forbidden}"
  else
    pass "${key}"
  fi
}

require_min_length() {
  local key="$1"
  local min_length="$2"
  local value
  value="$(value_for "${key}")"
  if (( ${#value} < min_length )); then
    fail "${key}" "min_length_${min_length}_got_${#value}"
  else
    pass "${key}"
  fi
}

require_integer_between() {
  local key="$1"
  local min_value="$2"
  local max_value="$3"
  local value
  value="$(value_for "${key}")"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    fail "${key}" "expected_integer"
    return 0
  fi
  if (( value < min_value || value > max_value )); then
    fail "${key}" "expected_${min_value}_to_${max_value}_got_${value}"
  else
    pass "${key}"
  fi
}

require_not_placeholder() {
  local key="$1"
  local value lower
  value="$(value_for "${key}")"
  lower="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    ""|change_me|changeme|replace-me|replace_me|password|password1234|test|demo|example|secret|prod-secret|prod-secret-key|prod-db-password|prod-kafka-password|prod-jwt-secret|prod-internal-secret|dev-jwt-secret-change-me|test-internal-secret|database-secret|im-password|secret-key|access-key)
      fail "${key}" "placeholder_or_default_value"
      ;;
    *)
      pass "${key}"
      ;;
  esac
}

validate_secret_value() {
  local key="$1"
  local value="$2"
  local min_length="$3"
  local lower
  if [[ -z "${value//[[:space:]]/}" ]]; then
    fail "${key}" "missing_or_empty"
    return 0
  fi
  if (( ${#value} < min_length )); then
    fail "${key}" "min_length_${min_length}_got_${#value}"
  else
    pass "${key}"
  fi
  lower="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    ""|change_me|changeme|replace-me|replace_me|password|password1234|test|demo|example|secret|prod-secret|prod-secret-key|prod-db-password|prod-kafka-password|prod-jwt-secret|prod-internal-secret|dev-jwt-secret-change-me|test-internal-secret|database-secret|im-password|secret-key|access-key)
      fail "${key}" "placeholder_or_default_value"
      ;;
    *)
      pass "${key}"
      ;;
  esac
}

require_jwt_secret_configuration() {
  local jwt_secrets jwt_secret active_kid entry kid secret found_active=false
  jwt_secrets="$(value_for "JWT_SECRETS")"
  jwt_secret="$(value_for "JWT_SECRET")"
  active_kid="$(value_for "JWT_ACTIVE_KID")"

  if [[ -n "${jwt_secret//[[:space:]]/}" ]]; then
    fail "JWT_SECRET" "legacy_single_secret_forbidden_for_long_term_production"
  else
    pass "JWT_SECRET"
  fi

  if [[ -n "${jwt_secrets//[[:space:]]/}" ]]; then
    pass "JWT_SECRETS"
    if [[ -z "${active_kid//[[:space:]]/}" ]]; then
      fail "JWT_ACTIVE_KID" "missing_or_empty"
    fi
    IFS=',' read -r -a entries <<<"${jwt_secrets}"
    for entry in "${entries[@]}"; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      if [[ "${entry}" != *:* ]]; then
        fail "JWT_SECRETS" "invalid_entry_missing_colon"
        continue
      fi
      kid="${entry%%:*}"
      secret="${entry#*:}"
      kid="${kid#"${kid%%[![:space:]]*}"}"
      kid="${kid%"${kid##*[![:space:]]}"}"
      secret="${secret#"${secret%%[![:space:]]*}"}"
      secret="${secret%"${secret##*[![:space:]]}"}"
      if [[ -z "${kid//[[:space:]]/}" || -z "${secret//[[:space:]]/}" ]]; then
        fail "JWT_SECRETS" "invalid_entry_blank_kid_or_secret"
        continue
      fi
      validate_secret_value "JWT_SECRETS[${kid}]" "${secret}" 32
      if [[ -n "${active_kid//[[:space:]]/}" && "${kid}" == "${active_kid}" ]]; then
        found_active=true
      fi
    done
    if [[ -n "${active_kid//[[:space:]]/}" ]]; then
      if [[ "${found_active}" == "true" ]]; then
        pass "JWT_ACTIVE_KID"
      else
        fail "JWT_ACTIVE_KID" "not_found_in_JWT_SECRETS"
      fi
    fi
    return 0
  fi

  fail "JWT_SECRETS" "missing_or_empty"
}

require_unset_or_empty() {
  local key="$1"
  local value
  value="$(value_for "${key}")"
  if [[ -n "${value//[[:space:]]/}" ]]; then
    fail "${key}" "must_be_unset_in_production"
  else
    pass "${key}"
  fi
}

require_equals() {
  local key="$1"
  local expected="$2"
  local value
  value="$(value_for "${key}")"
  if [[ "${value}" != "${expected}" ]]; then
    fail "${key}" "expected_${expected}_got_${value:-<empty>}"
  else
    pass "${key}"
  fi
}

require_one_of() {
  local key="$1"
  shift
  local value expected
  value="$(value_for "${key}")"
  for expected in "$@"; do
    if [[ "${value}" == "${expected}" ]]; then
      pass "${key}"
      return 0
    fi
  done
  fail "${key}" "unexpected_${value:-<empty>}"
}

require_url() {
  local key="$1"
  local value
  value="$(value_for "${key}")"
  if [[ "${value}" =~ ^https?://[^[:space:]]+ ]]; then
    pass "${key}"
  else
    fail "${key}" "expected_http_url"
  fi
}

require_https_url() {
  local key="$1"
  local value
  value="$(value_for "${key}")"
  require_url "${key}"
  if [[ "${value}" =~ ^https://[^[:space:]]+ ]]; then
    pass "${key}"
  else
    fail "${key}" "https_required"
  fi
}

require_https_dependency_url() {
  local key="$1"
  local value
  value="$(value_for "${key}")"
  require_https_url "${key}"
  python3 - "${key}" "${value}" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

key = sys.argv[1]
value = sys.argv[2]
parsed = urlparse(value)
host = (parsed.hostname or "").strip().lower()
if not host:
    raise SystemExit(f"production-env-check=fail key={key} reason=host_missing")
if host in {"localhost", "ip6-localhost"} or host.endswith(".local"):
    raise SystemExit(f"production-env-check=fail key={key} reason=host_must_not_be_local")
try:
    ipaddress.ip_address(host)
except ValueError:
    pass
else:
    raise SystemExit(f"production-env-check=fail key={key} reason=host_must_be_dns")
placeholder_hosts = {"example", "example.com", "example.net", "example.org", "yourdomain.com"}
placeholder_suffixes = (".example", ".example.com", ".example.net", ".example.org", ".yourdomain.com", ".test", ".invalid")
if host in placeholder_hosts or any(host.endswith(suffix) for suffix in placeholder_suffixes):
    raise SystemExit(f"production-env-check=fail key={key} reason=placeholder_domain")
print(f"production-env-check=pass key={key} host={host}")
PY
}

require_public_base_url() {
  local value source_key validation_output
  if bool_enabled "${IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL}"; then
    fail "IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL" "forbidden_for_long_term_production"
    return
  fi

  value="$(value_for "PUBLIC_BASE_URL")"
  source_key="PUBLIC_BASE_URL"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    value="$(value_for "IM_PUBLIC_BASE_URL")"
    source_key="IM_PUBLIC_BASE_URL"
  fi
  if [[ -z "${value//[[:space:]]/}" ]]; then
    fail "PUBLIC_BASE_URL" "missing_or_empty"
    return
  fi

  if validation_output="$(python3 - "${source_key}" "${value}" <<'PY'
import sys
from urllib.parse import urlparse

key, value = sys.argv[1:3]
parsed = urlparse(value)
if parsed.scheme != "https":
    raise SystemExit(f"production-env-check=fail key={key} reason=https_required")
if parsed.port not in {None, 443}:
    raise SystemExit(f"production-env-check=fail key={key} reason=default_https_port_required")
host = parsed.hostname or ""
if not host:
    raise SystemExit(f"production-env-check=fail key={key} reason=missing_host")
normalized = host.lower().strip("[]")
if normalized in {"localhost", "ip6-localhost"} or normalized.endswith(".local"):
    raise SystemExit(f"production-env-check=fail key={key} reason=host_not_public")
placeholder_hosts = {"example", "example.com", "example.net", "example.org", "yourdomain.com"}
placeholder_suffixes = (".example", ".example.com", ".example.net", ".example.org", ".yourdomain.com", ".test", ".invalid")
if normalized in placeholder_hosts or any(normalized.endswith(suffix) for suffix in placeholder_suffixes):
    raise SystemExit(f"production-env-check=fail key={key} reason=placeholder_domain")
try:
    import ipaddress
    ipaddress.ip_address(normalized)
except ValueError:
    if "." not in normalized:
        raise SystemExit(f"production-env-check=fail key={key} reason=host_not_public")
    raise SystemExit(0)
raise SystemExit(f"production-env-check=fail key={key} reason=host_must_be_dns")
PY
)"; then
    pass "${source_key}"
  else
    printf '%s\n' "${validation_output}"
    failures=$((failures + 1))
  fi
}

require_internal_url() {
  local key="$1"
  local value validation_output
  value="$(value_for "${key}")"
  if [[ ! "${value}" =~ ^https?://[^[:space:]]+ ]]; then
    fail "${key}" "expected_http_url"
    return
  fi
  if validation_output="$(python3 - "${key}" "${value}" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

key, value = sys.argv[1:3]
parsed = urlparse(value)
host = parsed.hostname or ""
if not host:
    raise SystemExit(f"production-env-check=fail key={key} reason=missing_host")
try:
    ip = ipaddress.ip_address(host)
except ValueError:
    if host in {"localhost"} or "." not in host:
        raise SystemExit(0)
    raise SystemExit(f"production-env-check=fail key={key} reason=host_not_private_or_single_label")
allowed_networks = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
]
if any(ip in network for network in allowed_networks):
    raise SystemExit(0)
raise SystemExit(f"production-env-check=fail key={key} reason=host_not_private")
PY
)"; then
    pass "${key}"
  else
    printf '%s\n' "${validation_output}"
    failures=$((failures + 1))
  fi
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

env_key_component() {
  local value="$1"
  value="$(printf '%s' "${value}" | tr '[:lower:]' '[:upper:]')"
  value="$(printf '%s' "${value}" | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//')"
  printf '%s' "${value}"
}

require_database_shards() {
  local ids_key="$1"
  local prefix_root="$2"
  local label="$3"
  local shard_ids shard_id component prefix field
  local -a shards

  require_non_empty "${ids_key}"
  shard_ids="$(value_for "${ids_key}")"
  IFS=',' read -r -a shards <<<"${shard_ids}"
  for shard_id in "${shards[@]}"; do
    shard_id="$(trim_value "${shard_id}")"
    [[ -z "${shard_id}" ]] && continue
    component="$(env_key_component "${shard_id}")"
    prefix="${prefix_root}_${component}"
    for field in HOST PORT NAME USERNAME PASSWORD; do
      require_non_empty "${prefix}_${field}"
    done
    require_integer_between "${prefix}_PORT" 1 65535
    require_min_length "${prefix}_PASSWORD" 16
    require_not_placeholder "${prefix}_PASSWORD"
    printf 'production-env-check=pass key=%s shard=%s\n' "${label}" "${shard_id}"
  done
}

run_checks() {
  failures=0

  if [[ ! -f "${ENV_FILE}" ]]; then
    printf 'production-env-check=fail key=ENV_FILE reason=not_found path=%s\n' "${ENV_FILE}" >&2
    exit 1
  fi

  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  if [[ -d "${ROLES_DIR}" ]]; then
    for role_env in "${ROLES_DIR}"/*.env; do
      [[ -f "${role_env}" ]] || continue
      # shellcheck source=/dev/null
      source "${role_env}"
    done
  fi
  set +a

  app_env="${APP_ENV:-development}"
  printf 'production-env-check appEnv=%s envFile=%s rolesDir=%s\n' "${app_env}" "${ENV_FILE}" "${ROLES_DIR}"

  if [[ "${app_env}" != "production" ]]; then
    if bool_enabled "${VERIFY_REQUIRE_PRODUCTION}"; then
      fail "APP_ENV" "expected_production_got_${app_env}"
    else
      printf 'production-env-check=skip reason=APP_ENV_is_not_production\n'
      exit 0
    fi
  fi

  require_jwt_secret_configuration
  require_public_base_url
  require_non_empty "IM_INTERNAL_SHARED_SECRET"
  require_min_length "IM_INTERNAL_SHARED_SECRET" 32
  require_not_placeholder "IM_INTERNAL_SHARED_SECRET"
  require_unset_or_empty "SEED_USER_EMAIL"
  require_unset_or_empty "SEED_USER_EMAILS"
  require_unset_or_empty "SEED_USER_PASSWORD"

  require_non_empty "DATABASE_PRIMARY_HOST"
  require_non_empty "DATABASE_PRIMARY_NAME"
  require_non_empty "DATABASE_PRIMARY_USERNAME"
  require_non_empty "DATABASE_PRIMARY_PASSWORD"
  require_min_length "DATABASE_PRIMARY_PASSWORD" 16
  require_not_placeholder "DATABASE_PRIMARY_PASSWORD"
  require_database_shards "IM_CONVERSATION_SHARD_IDS" "DATABASE_CONVERSATION" "conversation_shard"
  require_database_shards "IM_SUMMARY_SHARD_IDS" "DATABASE_SUMMARY" "summary_shard"

  require_equals "IM_EVENT_STREAM_DRIVER" "kafka"
  require_non_empty "IM_KAFKA_BROKERS"
  require_non_empty "IM_KAFKA_TOPIC"
  require_non_empty "IM_KAFKA_DEAD_LETTER_TOPIC"
  require_non_empty "IM_KAFKA_CLIENT_ID"
  require_one_of "IM_KAFKA_REQUIRED_ACKS" "all" "-1"
  require_equals "IM_KAFKA_AUTO_CREATE_TOPICS" "false"
  require_equals "IM_KAFKA_SECURITY_PROTOCOL" "sasl_tls"
  require_equals "IM_KAFKA_SASL_MECHANISM" "scram-sha-512"
  require_non_empty "IM_KAFKA_SASL_USERNAME"
  require_non_empty "IM_KAFKA_SASL_PASSWORD"
  require_min_length "IM_KAFKA_SASL_PASSWORD" 16
  require_not_placeholder "IM_KAFKA_SASL_PASSWORD"
  require_non_empty "IM_KAFKA_TLS_CA_FILE"

  require_equals "MEDIA_STORAGE_PROVIDER" "s3compatible"
  if bool_enabled "${IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT}"; then
    fail "IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT" "forbidden_for_long_term_production"
  fi
  require_https_dependency_url "MEDIA_STORAGE_S3_ENDPOINT"
  require_non_empty "MEDIA_STORAGE_S3_BUCKET"
  require_non_empty "MEDIA_STORAGE_S3_ACCESS_KEY_ID"
  require_non_empty "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY"
  require_non_empty "MEDIA_STORAGE_S3_REGION"
  require_one_of "MEDIA_STORAGE_S3_FORCE_PATH_STYLE" "true" "false"
  require_min_length "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY" 16
  require_not_placeholder "MEDIA_STORAGE_S3_ACCESS_KEY_ID"
  require_not_placeholder "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY"

  require_internal_url "IM_COMMAND_API_INTERNAL_BASE_URL"
  require_internal_url "IM_GATEWAY_INTERNAL_BASE_URL"
  if [[ "${IM_SEARCH_DRIVER:-}" == "opensearch" ]]; then
    require_https_dependency_url "IM_OPENSEARCH_ENDPOINT"
  fi
  require_equals "IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE" "true"
  require_equals "IM_TCP_REQUIRES_TLS_TERMINATION" "true"

  if [[ "${failures}" != "0" ]]; then
    printf 'production-env-check result=fail failures=%s\n' "${failures}" >&2
    exit 1
  fi

  printf 'production-env-check result=pass\n'
}

run_self_test() {
  local tmp_dir good_env missing_ca_log
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN
  mkdir -p "${tmp_dir}/roles"
  good_env="${tmp_dir}/common.env"
  cat >"${good_env}" <<'EOF'
APP_ENV=production
PUBLIC_BASE_URL=https://chat.myim-prod.com
JWT_SECRETS=active:0123456789abcdef0123456789abcdef
JWT_ACTIVE_KID=active
IM_INTERNAL_SHARED_SECRET=fedcba9876543210fedcba9876543210
DATABASE_PRIMARY_HOST=127.0.0.1
DATABASE_PRIMARY_NAME=imserver
DATABASE_PRIMARY_USERNAME=imserver
DATABASE_PRIMARY_PASSWORD=db-0123456789abcdef
IM_CONVERSATION_SHARD_IDS=shard-0,shard-1
DATABASE_CONVERSATION_SHARD_0_HOST=127.0.0.1
DATABASE_CONVERSATION_SHARD_0_PORT=5432
DATABASE_CONVERSATION_SHARD_0_NAME=imserver
DATABASE_CONVERSATION_SHARD_0_USERNAME=imserver
DATABASE_CONVERSATION_SHARD_0_PASSWORD=db-0123456789abcdef
DATABASE_CONVERSATION_SHARD_1_HOST=127.0.0.1
DATABASE_CONVERSATION_SHARD_1_PORT=5432
DATABASE_CONVERSATION_SHARD_1_NAME=imserver_shard_1
DATABASE_CONVERSATION_SHARD_1_USERNAME=imserver
DATABASE_CONVERSATION_SHARD_1_PASSWORD=db-1123456789abcdef
IM_SUMMARY_SHARD_IDS=summary-a,summary-b
DATABASE_SUMMARY_SUMMARY_A_HOST=127.0.0.1
DATABASE_SUMMARY_SUMMARY_A_PORT=5432
DATABASE_SUMMARY_SUMMARY_A_NAME=imserver
DATABASE_SUMMARY_SUMMARY_A_USERNAME=imserver
DATABASE_SUMMARY_SUMMARY_A_PASSWORD=db-0123456789abcdef
DATABASE_SUMMARY_SUMMARY_B_HOST=127.0.0.1
DATABASE_SUMMARY_SUMMARY_B_PORT=5432
DATABASE_SUMMARY_SUMMARY_B_NAME=imserver_summary_b
DATABASE_SUMMARY_SUMMARY_B_USERNAME=imserver
DATABASE_SUMMARY_SUMMARY_B_PASSWORD=db-b123456789abcdef
IM_EVENT_STREAM_DRIVER=kafka
IM_KAFKA_BROKERS=127.0.0.1:9092
IM_KAFKA_TOPIC=conversation-domain-events
IM_KAFKA_DEAD_LETTER_TOPIC=conversation-domain-events-dead-letter
IM_KAFKA_CLIENT_ID=im-production-env-self-test
IM_KAFKA_REQUIRED_ACKS=all
IM_KAFKA_AUTO_CREATE_TOPICS=false
IM_KAFKA_SECURITY_PROTOCOL=sasl_tls
IM_KAFKA_SASL_MECHANISM=scram-sha-512
IM_KAFKA_SASL_USERNAME=imserver
IM_KAFKA_SASL_PASSWORD=kafka-0123456789abcdef
IM_KAFKA_TLS_CA_FILE=/run/secrets/kafka-ca.pem
IM_SEARCH_DRIVER=opensearch
IM_OPENSEARCH_ENDPOINT=https://opensearch.internal
MEDIA_STORAGE_PROVIDER=s3compatible
MEDIA_STORAGE_S3_ENDPOINT=https://oss.myim-prod.com
MEDIA_STORAGE_S3_BUCKET=im-media
MEDIA_STORAGE_S3_ACCESS_KEY_ID=AKIA0123456789ABCDEF
MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=s3-0123456789abcdef0123456789abcdef
MEDIA_STORAGE_S3_REGION=cn-shenzhen
MEDIA_STORAGE_S3_FORCE_PATH_STYLE=true
IM_COMMAND_API_INTERNAL_BASE_URL=http://127.0.0.1:8081
IM_GATEWAY_INTERNAL_BASE_URL=http://127.0.0.1:18080
IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true
IM_TCP_REQUIRES_TLS_TERMINATION=true
EOF

  ENV_FILE="${good_env}" \
  ROLES_DIR="${tmp_dir}/roles" \
  PRODUCTION_ENV_VERIFY_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${tmp_dir}/pass.log"

  cp "${good_env}" "${tmp_dir}/legacy-jwt-secret.env"
  printf 'JWT_SECRET=0123456789abcdef0123456789abcdef\n' >>"${tmp_dir}/legacy-jwt-secret.env"
  if ENV_FILE="${tmp_dir}/legacy-jwt-secret.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/legacy-jwt-secret.log" 2>&1; then
    echo "production env self-test failed: legacy JWT_SECRET unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=JWT_SECRET reason=legacy_single_secret_forbidden_for_long_term_production' "${tmp_dir}/legacy-jwt-secret.log" || {
    echo "production env self-test failed: legacy JWT_SECRET reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/missing-active-jwt-kid.env"
  sed -i.bak -e '/^JWT_ACTIVE_KID=/d' "${tmp_dir}/missing-active-jwt-kid.env"
  if ENV_FILE="${tmp_dir}/missing-active-jwt-kid.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/missing-active-jwt-kid.log" 2>&1; then
    echo "production env self-test failed: missing JWT_ACTIVE_KID unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=JWT_ACTIVE_KID reason=missing_or_empty' "${tmp_dir}/missing-active-jwt-kid.log" || {
    echo "production env self-test failed: missing JWT_ACTIVE_KID reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/http-public-base-url.env"
  sed -i.bak -e 's#^PUBLIC_BASE_URL=.*#PUBLIC_BASE_URL=http://chat.myim-prod.com#' "${tmp_dir}/http-public-base-url.env"
  if ENV_FILE="${tmp_dir}/http-public-base-url.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/http-public-base-url.log" 2>&1; then
    echo "production env self-test failed: insecure public base URL unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=PUBLIC_BASE_URL reason=https_required' "${tmp_dir}/http-public-base-url.log" || {
    echo "production env self-test failed: insecure public base URL reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/insecure-public-base-url-override.env"
  if ENV_FILE="${tmp_dir}/insecure-public-base-url-override.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL=true \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/insecure-public-base-url-override.log" 2>&1; then
    echo "production env self-test failed: insecure public base URL override unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL reason=forbidden_for_long_term_production' "${tmp_dir}/insecure-public-base-url-override.log" || {
    echo "production env self-test failed: insecure public base URL override reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/ip-public-base-url.env"
  sed -i.bak -e 's#^PUBLIC_BASE_URL=.*#PUBLIC_BASE_URL=https://203.0.113.10#' "${tmp_dir}/ip-public-base-url.env"
  if ENV_FILE="${tmp_dir}/ip-public-base-url.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/ip-public-base-url.log" 2>&1; then
    echo "production env self-test failed: IP public base URL unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=PUBLIC_BASE_URL reason=host_must_be_dns' "${tmp_dir}/ip-public-base-url.log" || {
    echo "production env self-test failed: IP public base URL reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/port-public-base-url.env"
  sed -i.bak -e 's#^PUBLIC_BASE_URL=.*#PUBLIC_BASE_URL=https://chat.myim-prod.com:8443#' "${tmp_dir}/port-public-base-url.env"
  if ENV_FILE="${tmp_dir}/port-public-base-url.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/port-public-base-url.log" 2>&1; then
    echo "production env self-test failed: non-default public base URL port unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=PUBLIC_BASE_URL reason=default_https_port_required' "${tmp_dir}/port-public-base-url.log" || {
    echo "production env self-test failed: non-default public base URL port reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/placeholder-public-base-url.env"
  sed -i.bak -e 's#^PUBLIC_BASE_URL=.*#PUBLIC_BASE_URL=https://chat.example.com#' "${tmp_dir}/placeholder-public-base-url.env"
  if ENV_FILE="${tmp_dir}/placeholder-public-base-url.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/placeholder-public-base-url.log" 2>&1; then
    echo "production env self-test failed: placeholder public base URL unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=PUBLIC_BASE_URL reason=placeholder_domain' "${tmp_dir}/placeholder-public-base-url.log" || {
    echo "production env self-test failed: placeholder public base URL reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/yourdomain-public-base-url.env"
  sed -i.bak -e 's#^PUBLIC_BASE_URL=.*#PUBLIC_BASE_URL=https://chat.yourdomain.com#' "${tmp_dir}/yourdomain-public-base-url.env"
  if ENV_FILE="${tmp_dir}/yourdomain-public-base-url.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/yourdomain-public-base-url.log" 2>&1; then
    echo "production env self-test failed: yourdomain public base URL unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=PUBLIC_BASE_URL reason=placeholder_domain' "${tmp_dir}/yourdomain-public-base-url.log" || {
    echo "production env self-test failed: yourdomain public base URL reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/missing-ca.env"
  sed -i.bak -e '/^IM_KAFKA_TLS_CA_FILE=/d' "${tmp_dir}/missing-ca.env"
  missing_ca_log="${tmp_dir}/missing-ca.log"
  if ENV_FILE="${tmp_dir}/missing-ca.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${missing_ca_log}" 2>&1; then
    echo "production env self-test failed: missing Kafka TLS CA unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=IM_KAFKA_TLS_CA_FILE reason=missing_or_empty' "${missing_ca_log}" || {
    echo "production env self-test failed: missing Kafka TLS CA reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/missing-client-id.env"
  sed -i.bak -e '/^IM_KAFKA_CLIENT_ID=/d' "${tmp_dir}/missing-client-id.env"
  if ENV_FILE="${tmp_dir}/missing-client-id.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/missing-client-id.log" 2>&1; then
    echo "production env self-test failed: missing Kafka client id unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=IM_KAFKA_CLIENT_ID reason=missing_or_empty' "${tmp_dir}/missing-client-id.log" || {
    echo "production env self-test failed: missing Kafka client id reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/missing-conversation-shard.env"
  sed -i.bak -e '/^DATABASE_CONVERSATION_SHARD_1_PASSWORD=/d' "${tmp_dir}/missing-conversation-shard.env"
  if ENV_FILE="${tmp_dir}/missing-conversation-shard.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/missing-conversation-shard.log" 2>&1; then
    echo "production env self-test failed: missing conversation shard password unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=DATABASE_CONVERSATION_SHARD_1_PASSWORD reason=missing_or_empty' "${tmp_dir}/missing-conversation-shard.log" || {
    echo "production env self-test failed: missing conversation shard password reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/missing-summary-shard.env"
  sed -i.bak -e '/^DATABASE_SUMMARY_SUMMARY_B_HOST=/d' "${tmp_dir}/missing-summary-shard.env"
  if ENV_FILE="${tmp_dir}/missing-summary-shard.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/missing-summary-shard.log" 2>&1; then
    echo "production env self-test failed: missing summary shard host unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=DATABASE_SUMMARY_SUMMARY_B_HOST reason=missing_or_empty' "${tmp_dir}/missing-summary-shard.log" || {
    echo "production env self-test failed: missing summary shard host reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/bad-shard-port.env"
  sed -i.bak -e 's/^DATABASE_CONVERSATION_SHARD_1_PORT=.*/DATABASE_CONVERSATION_SHARD_1_PORT=not-a-port/' "${tmp_dir}/bad-shard-port.env"
  if ENV_FILE="${tmp_dir}/bad-shard-port.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/bad-shard-port.log" 2>&1; then
    echo "production env self-test failed: invalid shard port unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=DATABASE_CONVERSATION_SHARD_1_PORT reason=expected_integer' "${tmp_dir}/bad-shard-port.log" || {
    echo "production env self-test failed: invalid shard port reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/missing-s3-region.env"
  sed -i.bak -e '/^MEDIA_STORAGE_S3_REGION=/d' "${tmp_dir}/missing-s3-region.env"
  if ENV_FILE="${tmp_dir}/missing-s3-region.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/missing-s3-region.log" 2>&1; then
    echo "production env self-test failed: missing S3 region unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=MEDIA_STORAGE_S3_REGION reason=missing_or_empty' "${tmp_dir}/missing-s3-region.log" || {
    echo "production env self-test failed: missing S3 region reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/bad-s3-path-style.env"
  sed -i.bak -e 's/^MEDIA_STORAGE_S3_FORCE_PATH_STYLE=.*/MEDIA_STORAGE_S3_FORCE_PATH_STYLE=TRUE/' "${tmp_dir}/bad-s3-path-style.env"
  if ENV_FILE="${tmp_dir}/bad-s3-path-style.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/bad-s3-path-style.log" 2>&1; then
    echo "production env self-test failed: invalid S3 force path style unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=MEDIA_STORAGE_S3_FORCE_PATH_STYLE reason=unexpected_TRUE' "${tmp_dir}/bad-s3-path-style.log" || {
    echo "production env self-test failed: invalid S3 force path style reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/http-s3-endpoint.env"
  sed -i.bak -e 's#^MEDIA_STORAGE_S3_ENDPOINT=.*#MEDIA_STORAGE_S3_ENDPOINT=http://oss.example.com#' "${tmp_dir}/http-s3-endpoint.env"
  if ENV_FILE="${tmp_dir}/http-s3-endpoint.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/http-s3-endpoint.log" 2>&1; then
    echo "production env self-test failed: insecure S3 endpoint unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=MEDIA_STORAGE_S3_ENDPOINT reason=https_required' "${tmp_dir}/http-s3-endpoint.log" || {
    echo "production env self-test failed: insecure S3 endpoint reason absent" >&2
    exit 1
  }

  if ENV_FILE="${tmp_dir}/http-s3-endpoint.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT=true \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/http-s3-endpoint-override.log" 2>&1; then
    echo "production env self-test failed: insecure S3 endpoint override unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT reason=forbidden_for_long_term_production' "${tmp_dir}/http-s3-endpoint-override.log" || {
    echo "production env self-test failed: insecure S3 endpoint override reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/placeholder-s3-endpoint.env"
  sed -i.bak -e 's#^MEDIA_STORAGE_S3_ENDPOINT=.*#MEDIA_STORAGE_S3_ENDPOINT=https://oss.example.com#' "${tmp_dir}/placeholder-s3-endpoint.env"
  if ENV_FILE="${tmp_dir}/placeholder-s3-endpoint.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/placeholder-s3-endpoint.log" 2>&1; then
    echo "production env self-test failed: placeholder S3 endpoint unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=MEDIA_STORAGE_S3_ENDPOINT reason=placeholder_domain' "${tmp_dir}/placeholder-s3-endpoint.log" || {
    echo "production env self-test failed: placeholder S3 endpoint reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/http-opensearch-endpoint.env"
  sed -i.bak -e 's#^IM_OPENSEARCH_ENDPOINT=.*#IM_OPENSEARCH_ENDPOINT=http://opensearch.internal#' "${tmp_dir}/http-opensearch-endpoint.env"
  if ENV_FILE="${tmp_dir}/http-opensearch-endpoint.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/http-opensearch-endpoint.log" 2>&1; then
    echo "production env self-test failed: insecure OpenSearch endpoint unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=IM_OPENSEARCH_ENDPOINT reason=https_required' "${tmp_dir}/http-opensearch-endpoint.log" || {
    echo "production env self-test failed: insecure OpenSearch endpoint reason absent" >&2
    exit 1
  }

  cp "${good_env}" "${tmp_dir}/placeholder-opensearch-endpoint.env"
  sed -i.bak -e 's#^IM_OPENSEARCH_ENDPOINT=.*#IM_OPENSEARCH_ENDPOINT=https://search.example.com#' "${tmp_dir}/placeholder-opensearch-endpoint.env"
  if ENV_FILE="${tmp_dir}/placeholder-opensearch-endpoint.env" \
    ROLES_DIR="${tmp_dir}/roles" \
    PRODUCTION_ENV_VERIFY_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${tmp_dir}/placeholder-opensearch-endpoint.log" 2>&1; then
    echo "production env self-test failed: placeholder OpenSearch endpoint unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'key=IM_OPENSEARCH_ENDPOINT reason=placeholder_domain' "${tmp_dir}/placeholder-opensearch-endpoint.log" || {
    echo "production env self-test failed: placeholder OpenSearch endpoint reason absent" >&2
    exit 1
  }

  printf 'production-env-self-test result=pass\n'
}

if bool_enabled "${PRODUCTION_ENV_VERIFY_SELF_TEST}"; then
  run_self_test
  exit 0
fi

run_checks
