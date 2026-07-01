#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

KAFKA_LIMIT_NOFILE="${KAFKA_LIMIT_NOFILE:-262144}"
KAFKA_TASKS_MAX="${KAFKA_TASKS_MAX:-16384}"
KAFKA_SETUP_SELF_TEST="${KAFKA_SETUP_SELF_TEST:-false}"
KAFKA_ARCHIVE_MEMBER_MAX_BYTES="${KAFKA_ARCHIVE_MEMBER_MAX_BYTES:-268435456}"
KAFKA_ARCHIVE_TOTAL_MAX_BYTES="${KAFKA_ARCHIVE_TOTAL_MAX_BYTES:-1073741824}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

sha512_file() {
  local path="$1"
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "${path}" | awk '{print $1}'
  else
    shasum -a 512 "${path}" | awk '{print $1}'
  fi
}

verify_kafka_archive_checksum() {
  local archive_path="$1"
  local checksum_path="$2"
  local archive_name="$3"
  python3 - "${archive_path}" "${checksum_path}" "${archive_name}" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

archive_path, checksum_path, archive_name = sys.argv[1:4]
checksum_text = Path(checksum_path).read_text(encoding="utf-8", errors="replace")
digests = re.findall(r"\b[0-9a-fA-F]{128}\b", checksum_text)
if not digests:
    raise SystemExit("kafka_setup result=fail reason=archive_checksum_digest_missing")
if len(set(digest.lower() for digest in digests)) != 1:
    raise SystemExit("kafka_setup result=fail reason=archive_checksum_digest_ambiguous")
if archive_name not in checksum_text and len(digests) != 1:
    raise SystemExit("kafka_setup result=fail reason=archive_checksum_name_missing")
expected = digests[0].lower()
actual = hashlib.sha512(Path(archive_path).read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit(f"kafka_setup result=fail reason=archive_checksum_mismatch expected={expected} actual={actual}")
print("kafka_setup step=archive_checksum result=pass")
PY
}

safe_extract_kafka_archive() {
  local archive_path="$1"
  local output_dir="$2"
  local expected_root="$3"
  python3 - "${archive_path}" "${output_dir}" "${expected_root}" "${KAFKA_ARCHIVE_MEMBER_MAX_BYTES}" "${KAFKA_ARCHIVE_TOTAL_MAX_BYTES}" <<'PY'
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

archive_path, output_dir, expected_root, max_member_raw, max_total_raw = sys.argv[1:6]
root = Path(output_dir).resolve()
max_member_bytes = int(max_member_raw)
max_total_bytes = int(max_total_raw)
seen = set()
total = 0
try:
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise SystemExit("kafka_setup result=fail reason=archive_empty")
        for member in members:
            name = str(member.name or "")
            path = PurePosixPath(name)
            normalized = path.as_posix()
            if not name or name.startswith("/") or "\\" in name or path.is_absolute():
                raise SystemExit(f"kafka_setup result=fail reason=archive_member_path_unsafe path={name or '-'}")
            if any(part in {"", ".", ".."} for part in path.parts):
                raise SystemExit(f"kafka_setup result=fail reason=archive_member_path_unsafe path={name}")
            if path.parts[0] != expected_root:
                raise SystemExit(
                    "kafka_setup result=fail "
                    f"reason=archive_unexpected_root expected={expected_root} actual={path.parts[0]}"
                )
            if normalized in seen:
                raise SystemExit(f"kafka_setup result=fail reason=archive_member_duplicate path={name}")
            if member.issym() or member.islnk():
                raise SystemExit(f"kafka_setup result=fail reason=archive_member_link path={name}")
            if not (member.isfile() or member.isdir()):
                raise SystemExit(f"kafka_setup result=fail reason=archive_member_unsupported path={name}")
            if member.size < 0:
                raise SystemExit(f"kafka_setup result=fail reason=archive_member_size_invalid path={name} size={member.size}")
            if member.size > max_member_bytes:
                raise SystemExit(
                    "kafka_setup result=fail "
                    f"reason=archive_member_too_large path={name} size={member.size} max={max_member_bytes}"
                )
            total += member.size
            if total > max_total_bytes:
                raise SystemExit(
                    "kafka_setup result=fail "
                    f"reason=archive_total_too_large size={total} max={max_total_bytes}"
                )
            target = (root / normalized).resolve()
            try:
                target.relative_to(root)
            except ValueError as exc:
                raise SystemExit(f"kafka_setup result=fail reason=archive_member_path_unsafe path={name}") from exc
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(member.mode & 0o777)
                seen.add(normalized)
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"kafka_setup result=fail reason=archive_member_read_failed path={name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)
            seen.add(normalized)
except tarfile.TarError as exc:
    raise SystemExit(f"kafka_setup result=fail reason=archive_invalid error={exc}")
print(f"kafka_setup step=archive_safety result=pass members={len(seen)}")
PY
}

run_self_test() {
  local tmpdir archive checksum expected_root
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  expected_root="kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}"
  mkdir -p "${tmpdir}/stage/${expected_root}/bin"
  printf '#!/usr/bin/env bash\n' >"${tmpdir}/stage/${expected_root}/bin/kafka-server-start.sh"
  chmod +x "${tmpdir}/stage/${expected_root}/bin/kafka-server-start.sh"
  archive="${tmpdir}/kafka.tgz"
  checksum="${archive}.sha512"
  (cd "${tmpdir}/stage" && COPYFILE_DISABLE=1 tar -czf "${archive}" "${expected_root}")
  printf '%s  %s\n' "$(sha512_file "${archive}")" "$(basename "${archive}")" >"${checksum}"
  verify_kafka_archive_checksum "${archive}" "${checksum}" "$(basename "${archive}")" >/dev/null
  safe_extract_kafka_archive "${archive}" "${tmpdir}/out" "${expected_root}" >/dev/null
  [[ -x "${tmpdir}/out/${expected_root}/bin/kafka-server-start.sh" ]] || {
    printf 'kafka_setup_self_test result=fail reason=safe_archive_not_extracted\n' >&2
    return 1
  }
  printf '%0128d  %s\n' 0 "$(basename "${archive}")" >"${tmpdir}/bad.sha512"
  if verify_kafka_archive_checksum "${archive}" "${tmpdir}/bad.sha512" "$(basename "${archive}")" >"${tmpdir}/bad-checksum.log" 2>&1; then
    printf 'kafka_setup_self_test result=fail reason=bad_checksum_accepted\n' >&2
    return 1
  fi
  grep -q 'archive_checksum_mismatch' "${tmpdir}/bad-checksum.log" || {
    printf 'kafka_setup_self_test result=fail reason=bad_checksum_reason_missing\n' >&2
    return 1
  }
  python3 - "${tmpdir}/unsafe.tgz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    data = b"unsafe\n"
    info = tarfile.TarInfo("../outside.txt")
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))
PY
  if safe_extract_kafka_archive "${tmpdir}/unsafe.tgz" "${tmpdir}/unsafe-out" "${expected_root}" >"${tmpdir}/unsafe.log" 2>&1; then
    printf 'kafka_setup_self_test result=fail reason=unsafe_archive_accepted\n' >&2
    return 1
  fi
  grep -q 'archive_member_path_unsafe' "${tmpdir}/unsafe.log" || {
    printf 'kafka_setup_self_test result=fail reason=unsafe_archive_reason_missing\n' >&2
    return 1
  }
  if KAFKA_ARCHIVE_MEMBER_MAX_BYTES=1 safe_extract_kafka_archive "${archive}" "${tmpdir}/oversized-out" "${expected_root}" >"${tmpdir}/oversized.log" 2>&1; then
    printf 'kafka_setup_self_test result=fail reason=oversized_member_accepted\n' >&2
    return 1
  fi
  grep -q 'archive_member_too_large' "${tmpdir}/oversized.log" || {
    printf 'kafka_setup_self_test result=fail reason=oversized_member_reason_missing\n' >&2
    return 1
  }
  printf 'kafka_setup_self_test result=pass\n'
}

if bool_enabled "${KAFKA_SETUP_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root

if ! command -v java >/dev/null 2>&1; then
  apt-get update
  apt-get install -y openjdk-21-jre-headless
fi

ensure_user kafka kafka "${KAFKA_HOME}"
install -d -o kafka -g kafka -m 0755 "${KAFKA_HOME}" "${KAFKA_DATA_DIR}" "${KAFKA_LOG_DIR}" /etc/kafka/kraft

archive_name="kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}.tgz"
download_url="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${archive_name}"
checksum_url="${download_url}.sha512"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

if [[ ! -x "${KAFKA_HOME}/bin/kafka-server-start.sh" ]]; then
  curl -fSL "${download_url}" -o "${tmp_dir}/${archive_name}"
  curl -fSL "${checksum_url}" -o "${tmp_dir}/${archive_name}.sha512"
  verify_kafka_archive_checksum "${tmp_dir}/${archive_name}" "${tmp_dir}/${archive_name}.sha512" "${archive_name}"
  safe_extract_kafka_archive "${tmp_dir}/${archive_name}" "${tmp_dir}" "kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}"
  rsync -a --delete "${tmp_dir}/kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}/" "${KAFKA_HOME}/"
  chown -R kafka:kafka "${KAFKA_HOME}"
fi

cluster_id_file="/etc/kafka/kraft/cluster.id"
if [[ ! -f "${cluster_id_file}" ]]; then
  "${KAFKA_HOME}/bin/kafka-storage.sh" random-uuid > "${cluster_id_file}"
fi
cluster_id="$(cat "${cluster_id_file}")"

cat > /etc/kafka/kraft/server.properties <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@127.0.0.1:9093
listeners=PLAINTEXT://127.0.0.1:9092,CONTROLLER://127.0.0.1:9093
advertised.listeners=PLAINTEXT://127.0.0.1:9092
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
inter.broker.listener.name=PLAINTEXT
log.dirs=${KAFKA_DATA_DIR}
num.network.threads=2
num.io.threads=2
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
num.partitions=6
default.replication.factor=1
min.insync.replicas=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
log.retention.hours=72
log.segment.bytes=268435456
log.retention.check.interval.ms=300000
auto.create.topics.enable=false
EOF

cat > /etc/default/kafka <<EOF
KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS}"
KAFKA_JVM_PERFORMANCE_OPTS="-server -XX:+UseG1GC -XX:MaxGCPauseMillis=50 -XX:InitiatingHeapOccupancyPercent=35"
EOF

cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka single-node KRaft broker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kafka
Group=kafka
EnvironmentFile=/etc/default/kafka
ExecStartPre=${KAFKA_HOME}/bin/kafka-storage.sh format --ignore-formatted --cluster-id ${cluster_id} --config /etc/kafka/kraft/server.properties
ExecStart=${KAFKA_HOME}/bin/kafka-server-start.sh /etc/kafka/kraft/server.properties
ExecStop=${KAFKA_HOME}/bin/kafka-server-stop.sh
Restart=always
RestartSec=5
LimitNOFILE=${KAFKA_LIMIT_NOFILE}
TasksMax=${KAFKA_TASKS_MAX}
CPUAccounting=true
MemoryAccounting=true
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${KAFKA_DATA_DIR} ${KAFKA_LOG_DIR} /etc/kafka/kraft
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now kafka
sleep 5

"${KAFKA_HOME}/bin/kafka-topics.sh" --bootstrap-server 127.0.0.1:9092 --create --if-not-exists --topic conversation-domain-events --partitions 6 --replication-factor 1
"${KAFKA_HOME}/bin/kafka-topics.sh" --bootstrap-server 127.0.0.1:9092 --create --if-not-exists --topic conversation-domain-events-dead-letter --partitions 3 --replication-factor 1

echo "Kafka is ready on 127.0.0.1:9092."
