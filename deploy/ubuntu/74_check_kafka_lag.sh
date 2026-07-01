#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

KAFKA_LAG_SELF_TEST="${KAFKA_LAG_SELF_TEST:-false}"
KAFKA_BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVER:-${IM_KAFKA_BROKERS:-127.0.0.1:9092}}"
KAFKA_CONSUMER_GROUPS_CMD="${KAFKA_CONSUMER_GROUPS_CMD:-${KAFKA_HOME}/bin/kafka-consumer-groups.sh}"
KAFKA_LAG_GROUPS="${KAFKA_LAG_GROUPS:-summary-projection-consumer domain-delivery-consumer}"
KAFKA_LAG_MAX_TOTAL="${KAFKA_LAG_MAX_TOTAL:-10000}"
KAFKA_LAG_MAX_PARTITION="${KAFKA_LAG_MAX_PARTITION:-5000}"
KAFKA_LAG_REQUIRE_GROUPS="${KAFKA_LAG_REQUIRE_GROUPS:-true}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

parse_lag_summary() {
  python3 -c '
import json
import re
import sys

group, max_total_raw, max_partition_raw = sys.argv[1:4]
text = sys.stdin.read()
try:
    max_total = int(max_total_raw)
    max_partition = int(max_partition_raw)
except ValueError as exc:
    raise SystemExit("invalid_threshold") from exc
if max_total < 0 or max_partition < 0:
    raise SystemExit("invalid_threshold")

rows = []
for line in text.splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("GROUP ") or stripped.startswith("Consumer group "):
        continue
    parts = re.split(r"\s+", stripped)
    if len(parts) < 6:
        continue
    lag = parts[5]
    if lag == "-":
        continue
    try:
        lag_value = int(lag)
    except ValueError:
        continue
    rows.append({
        "group": parts[0],
        "topic": parts[1],
        "partition": parts[2],
        "lag": lag_value,
    })

total = sum(row["lag"] for row in rows)
max_seen = max((row["lag"] for row in rows), default=0)
status = "pass"
reason = "within_threshold"
if not rows:
    status = "empty"
    reason = "no_lag_rows"
elif total > max_total:
    status = "fail"
    reason = "total_lag_exceeded"
elif max_seen > max_partition:
    status = "fail"
    reason = "partition_lag_exceeded"

print(json.dumps({
    "group": group,
    "status": status,
    "reason": reason,
    "partitionCount": len(rows),
    "totalLag": total,
    "maxPartitionLag": max_seen,
    "maxTotalLag": max_total,
    "maxPartitionLagAllowed": max_partition,
}, sort_keys=True))
' "$@"
}

check_group_lag() {
  local group="$1"
  local output summary status reason total max_partition partitions
  output="$("${KAFKA_CONSUMER_GROUPS_CMD}" --bootstrap-server "${KAFKA_BOOTSTRAP_SERVER}" --describe --group "${group}" 2>&1)" || {
    printf 'kafka-lag result=fail group=%s reason=describe_failed detail=%s\n' "${group}" "${output//$'\n'/ }" >&2
    return 1
  }
  summary="$(parse_lag_summary "${group}" "${KAFKA_LAG_MAX_TOTAL}" "${KAFKA_LAG_MAX_PARTITION}" <<<"${output}")"
  status="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "${summary}")"
  reason="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["reason"])' "${summary}")"
  total="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["totalLag"])' "${summary}")"
  max_partition="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["maxPartitionLag"])' "${summary}")"
  partitions="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["partitionCount"])' "${summary}")"
  case "${status}" in
    pass)
      printf 'kafka-lag result=pass group=%s partitions=%s totalLag=%s maxPartitionLag=%s\n' "${group}" "${partitions}" "${total}" "${max_partition}"
      ;;
    empty)
      if bool_enabled "${KAFKA_LAG_REQUIRE_GROUPS}"; then
        printf 'kafka-lag result=fail group=%s reason=%s\n' "${group}" "${reason}" >&2
        return 1
      fi
      printf 'kafka-lag result=pass group=%s skipped=empty\n' "${group}"
      ;;
    *)
      printf 'kafka-lag result=fail group=%s reason=%s totalLag=%s maxPartitionLag=%s\n' "${group}" "${reason}" "${total}" "${max_partition}" >&2
      return 1
      ;;
  esac
}

run_lag_check() {
  if [[ ! "${KAFKA_LAG_MAX_TOTAL}" =~ ^[0-9]+$ || ! "${KAFKA_LAG_MAX_PARTITION}" =~ ^[0-9]+$ ]]; then
    echo "Invalid Kafka lag thresholds." >&2
    return 1
  fi
  if [[ ! -x "${KAFKA_CONSUMER_GROUPS_CMD}" ]]; then
    echo "Kafka consumer groups command not executable: ${KAFKA_CONSUMER_GROUPS_CMD}" >&2
    return 1
  fi
  local group failures=0
  for group in ${KAFKA_LAG_GROUPS}; do
    check_group_lag "${group}" || failures=$((failures + 1))
  done
  if (( failures > 0 )); then
    printf 'kafka-lag result=fail failures=%s\n' "${failures}" >&2
    return 1
  fi
  printf 'kafka-lag result=pass groups=%s\n' "$(wc -w <<<"${KAFKA_LAG_GROUPS}" | tr -d ' ')"
}

run_self_test() {
  local self_test_dir fake_cmd
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' RETURN
  fake_cmd="${self_test_dir}/kafka-consumer-groups.sh"
  cat >"${fake_cmd}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
group=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --group)
      group="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "${group}" in
  good)
    cat <<'OUT'
GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG CONSUMER-ID HOST CLIENT-ID
good conversation-domain-events 0 100 101 1 consumer /127.0.0.1 client
good conversation-domain-events 1 200 202 2 consumer /127.0.0.1 client
OUT
    ;;
  bad)
    cat <<'OUT'
GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG CONSUMER-ID HOST CLIENT-ID
bad conversation-domain-events 0 0 10000 10000 consumer /127.0.0.1 client
OUT
    ;;
  empty)
    cat <<'OUT'
Consumer group 'empty' has no active members.
OUT
    ;;
  *)
    exit 2
    ;;
esac
SH
  chmod +x "${fake_cmd}"
  KAFKA_CONSUMER_GROUPS_CMD="${fake_cmd}" KAFKA_LAG_GROUPS=good KAFKA_LAG_MAX_TOTAL=10 KAFKA_LAG_MAX_PARTITION=5 run_lag_check >/dev/null || {
    printf 'kafka-lag-self-test result=fail reason=good_group_rejected\n' >&2
    return 1
  }
  if KAFKA_CONSUMER_GROUPS_CMD="${fake_cmd}" KAFKA_LAG_GROUPS=bad KAFKA_LAG_MAX_TOTAL=10 KAFKA_LAG_MAX_PARTITION=5 run_lag_check >"${self_test_dir}/bad.log" 2>&1; then
    printf 'kafka-lag-self-test result=fail reason=bad_group_accepted\n' >&2
    return 1
  fi
  grep -q 'total_lag_exceeded' "${self_test_dir}/bad.log" || {
    printf 'kafka-lag-self-test result=fail reason=bad_reason_missing\n' >&2
    return 1
  }
  if KAFKA_CONSUMER_GROUPS_CMD="${fake_cmd}" KAFKA_LAG_GROUPS=empty KAFKA_LAG_REQUIRE_GROUPS=true run_lag_check >"${self_test_dir}/empty.log" 2>&1; then
    printf 'kafka-lag-self-test result=fail reason=empty_group_accepted\n' >&2
    return 1
  fi
  KAFKA_CONSUMER_GROUPS_CMD="${fake_cmd}" KAFKA_LAG_GROUPS=empty KAFKA_LAG_REQUIRE_GROUPS=false run_lag_check >/dev/null || {
    printf 'kafka-lag-self-test result=fail reason=empty_optional_rejected\n' >&2
    return 1
  }
  printf 'kafka-lag-self-test result=pass\n'
}

if bool_enabled "${KAFKA_LAG_SELF_TEST}"; then
  run_self_test
  exit 0
fi

run_lag_check
