#!/usr/bin/env bash
set -Eeuo pipefail

# Uses two native OS processes (default) or two Linux containers, plus a
# task-owned PG container. The global Docker context and existing stacks stay untouched.
mode="${VA_G4_MODE:-native}"
[[ "$mode" == native || "$mode" == linux ]] || { echo 'VA_G4_MODE must be native or linux' >&2; exit 2; }
local_postgres="${VA_G4_LOCAL_POSTGRES:-0}"
[[ "$local_postgres" == 0 || "$local_postgres" == 1 ]] || { echo 'VA_G4_LOCAL_POSTGRES must be 0 or 1' >&2; exit 2; }
if [[ "$local_postgres" == 1 ]]; then
  [[ "$mode" == native ]] || { echo 'Local PostgreSQL requires native mode' >&2; exit 2; }
  local_pg_user="${USER:?}"
  [[ "$local_pg_user" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo 'Unsupported local PostgreSQL username' >&2; exit 2; }
else
  : "$DOCKER_CONTEXT"
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script_dir="$repo_root/IMV2/scripts"
run_id="$(date +%s)-$$"
local_pg_database="imv2_va_g4_${run_id//-/_}"
local_pg_created=0
prefix="imv2-va-g4-$run_id"
network="$prefix-net"
pg="$prefix-pg"
host="$prefix-host"
client="$prefix-client"
if [[ "$mode" == linux ]]; then
  client_first="${VA_G4_LINUX_CLIENT_FIRST:-0}"
  [[ "$client_first" == 0 || "$client_first" == 1 ]] || {
    echo 'VA_G4_LINUX_CLIENT_FIRST must be 0 or 1' >&2; exit 2;
  }
  run_root="${VA_G4_LINUX_RUN_ROOT:-$HOME/.codex/virtual-actor-builds/g5-runs}"
  [[ "$run_root" = /* ]] || { echo 'VA_G4_LINUX_RUN_ROOT must be absolute' >&2; exit 2; }
  mkdir -p "$run_root"
  evidence_dir="$run_root/$prefix-evidence"
  secret_dir="$run_root/$prefix-secrets"
  : "${VA_G4_LINUX_SCRATCH_DIR:?set an existing Linux SwiftPM scratch directory}"
  [[ "$VA_G4_LINUX_SCRATCH_DIR" = /* && -d "$VA_G4_LINUX_SCRATCH_DIR" ]] || {
    echo 'VA_G4_LINUX_SCRATCH_DIR must be an existing absolute directory' >&2; exit 2;
  }
  python3 - "$repo_root" "$VA_G4_LINUX_SCRATCH_DIR" "$run_root" <<'PY'
from pathlib import Path
import sys
source, scratch, artifacts = (Path(value).resolve() for value in sys.argv[1:])
for candidate in (scratch, artifacts):
    if candidate == source or candidate in source.parents or source in candidate.parents:
        raise SystemExit("Linux scratch/artifacts must not contain or be inside the source tree")
if scratch == artifacts or scratch in artifacts.parents or artifacts in scratch.parents:
    raise SystemExit("Linux scratch and artifacts must be separate directories")
PY
  mkdir -m 700 "$secret_dir"
  swift_image="${VA_G4_SWIFT_IMAGE:-swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6}"
else
  evidence_dir="/tmp/$prefix-evidence"
  secret_dir="$(mktemp -d "/tmp/$prefix-secrets.XXXXXX")"
fi
mkdir -p "$evidence_dir"
if [[ "$mode" == native ]]; then
  read -r host_port client_port < <(python3 - <<'PY'
import socket
with socket.socket() as first, socket.socket() as second:
    first.bind(("127.0.0.1", 0))
    second.bind(("127.0.0.1", 0))
    print(first.getsockname()[1], second.getsockname()[1])
PY
  )
  host_address=localhost
  client_address=localhost
else
  host_port=19081
  client_port=19082
  host_address=va-host
  client_address=va-client
fi
dc() { docker --context "$DOCKER_CONTEXT" "$@"; }
pgsql() {
  if [[ "$local_postgres" == 1 ]]; then
    psql -h 127.0.0.1 -U "$local_pg_user" -d "$local_pg_database" "$@"
  else
    dc exec -i "$pg" psql -U probe -d probe "$@"
  fi
}

cleanup() {
  local status="$1"
  if [[ "$mode" == native && -n "${host_pid:-}" ]]; then
    kill -9 "$host_pid" >/dev/null 2>&1 || true
    wait "$host_pid" >/dev/null 2>&1 || true
  fi
  if [[ "$mode" == native && -n "${client_pid:-}" ]]; then
    kill -9 "$client_pid" >/dev/null 2>&1 || true
    wait "$client_pid" >/dev/null 2>&1 || true
  fi
  if [[ -f "$evidence_dir/host-current.log" ]]; then
    cp "$evidence_dir/host-current.log" "$evidence_dir/host-last.log"
  fi
  if [[ "$mode" == linux ]]; then
    dc logs "$host" > "$evidence_dir/host-last.log" 2>&1 || true
    dc logs "$client" > "$evidence_dir/client.log" 2>&1 || true
    dc rm -f "$host" "$client" >/dev/null 2>&1 || true
  fi
  if [[ "$local_postgres" == 1 ]]; then
    if [[ "$local_pg_created" == 1 ]]; then
      dropdb -h 127.0.0.1 -U "$local_pg_user" "$local_pg_database" || status=1
    fi
  else
    dc rm -f "$pg" >/dev/null 2>&1 || true
    dc network rm "$network" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$secret_dir"
  printf 'G4_EVIDENCE_DIR=%s mode=%s exit=%s\n' "$evidence_dir" "$mode" "$status"
  trap - EXIT
  exit "$status"
}
trap 'cleanup "$?"' EXIT

wait_file() {
  local path="$1" limit="$2" watched="${3:-}" started=$SECONDS
  until [[ -f "$path" ]]; do
    if [[ "$mode" == native && -n "$watched" ]]; then
      local watched_pid=""
      [[ "$watched" != "$host" ]] || watched_pid="${host_pid:-}"
      [[ "$watched" != "$client" ]] || watched_pid="${client_pid:-}"
      if [[ -n "$watched_pid" ]] && ! kill -0 "$watched_pid" 2>/dev/null; then
        printf '%s exited before creating %s\n' "$watched" "$path" >&2
        return 1
      fi
    fi
    if [[ "$mode" == linux && -n "$watched" &&
          "$(dc inspect --format '{{.State.Running}}' "$watched" 2>/dev/null || true)" != true ]]; then
      dc logs "$watched" >&2 || true
      printf '%s exited before creating %s\n' "$watched" "$path" >&2
      return 1
    fi
    if (( SECONDS - started >= limit )); then
      printf 'timed out waiting for %s\n' "$path" >&2
      return 1
    fi
    sleep 0.2
  done
}

if [[ "$local_postgres" == 1 ]]; then
  createdb -h 127.0.0.1 -U "$local_pg_user" "$local_pg_database"
  local_pg_created=1
  database_url="postgres://$local_pg_user@127.0.0.1:5432/$local_pg_database"
else
dc network create "$network" >/dev/null
if [[ "$mode" == linux ]]; then
  dc run -d --name "$pg" --network "$network" --network-alias va-pg \
    -e POSTGRES_USER=probe -e POSTGRES_PASSWORD=probe -e POSTGRES_DB=probe \
    postgres:16-alpine >/dev/null
else
  dc run -d --name "$pg" --network "$network" --network-alias va-pg \
    -p 127.0.0.1::5432 \
    -e POSTGRES_USER=probe -e POSTGRES_PASSWORD=probe -e POSTGRES_DB=probe \
    postgres:16-alpine >/dev/null
fi
started=$SECONDS
until dc logs "$pg" 2>&1 | rg -q 'PostgreSQL init process complete; ready for start up'; do
  (( SECONDS - started < 30 )) || { echo 'isolated PostgreSQL did not start' >&2; exit 1; }
  sleep 0.2
done
until dc exec "$pg" psql -At -U probe -d probe -c 'SELECT 1' 2>/dev/null | rg -qx 1; do
  (( SECONDS - started < 30 )) || { echo 'final PostgreSQL server unavailable' >&2; exit 1; }
  sleep 0.2
done
if [[ "$mode" == linux ]]; then
  database_url='postgres://probe:probe@va-pg:5432/probe'
else
  pg_port="$(dc port "$pg" 5432/tcp | tail -n 1 | sed 's/.*://')"
  database_url="postgres://probe:probe@127.0.0.1:$pg_port/probe"
fi
fi
pgsql -v ON_ERROR_STOP=1 \
  < "$repo_root/IMV2/sql/schema.sql" > "$evidence_dir/schema-install.log"
pgsql -v ON_ERROR_STOP=1 \
  > "$evidence_dir/fixture-install.log" <<'SQL'
INSERT INTO im_v2.public_user_profiles
  (user_id, public_handle, display_name, revision, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000012', 'g4_sender', 'G4 Sender',
        1, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.rooms
  (room_id, room_shard_id, capacity_profile_id, capacity_class, membership_revision)
VALUES ('00000000-0000-0000-0000-000000000011', 'room-a', 'standard', 'standard', 1);
INSERT INTO im_v2.room_owner_routes
  (room_id, room_shard_id, route_epoch, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000011', 'room-a', 0,
        clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
VALUES ('00000000-0000-0000-0000-000000000011',
        '00000000-0000-0000-0000-000000000012', 'G4 room', clock_timestamp());
INSERT INTO im_v2.shard_admission_pools
  (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
VALUES ('room-a', 'standard', '00000000-0000-0000-0000-000000000014',
        1, clock_timestamp() + interval '10 minutes', 10);
INSERT INTO im_v2.room_admission
  (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
VALUES ('00000000-0000-0000-0000-000000000011', 1, 10,
        '00000000-0000-0000-0000-000000000014', 1);
INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
VALUES ('00000000-0000-0000-0000-000000000011',
        '00000000-0000-0000-0000-000000000012', 'owner', 1);
INSERT INTO im_v2.user_shard_router_configuration
  (configuration_key, router_epoch, default_write_bucket, updated_at)
VALUES (TRUE, 1, 'g4-users', clock_timestamp());
SQL

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -keyout "$secret_dir/ca.key" -out "$secret_dir/ca.pem" \
  -subj /CN=imv2-va-g4-ca -addext 'basicConstraints=critical,CA:TRUE' \
  > "$evidence_dir/cert-generation.log" 2>&1
for role in host client; do
  if [[ "$role" == host ]]; then cert_address="$host_address"; else cert_address="$client_address"; fi
  openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$secret_dir/$role.key" -out "$secret_dir/$role.csr" \
    -subj "/CN=va-$role" >> "$evidence_dir/cert-generation.log" 2>&1
  openssl x509 -req -in "$secret_dir/$role.csr" \
    -CA "$secret_dir/ca.pem" -CAkey "$secret_dir/ca.key" -CAcreateserial \
    -days 2 -sha256 -extfile <(printf 'subjectAltName=DNS:%s\n' "$cert_address") \
    -out "$secret_dir/$role.pem" >> "$evidence_dir/cert-generation.log" 2>&1
  openssl genpkey -algorithm Ed25519 -out "$secret_dir/$role-signing.pem"
  openssl pkey -in "$secret_dir/$role-signing.pem" -outform DER | tail -c 32 \
    > "$secret_dir/$role-signing.key"
  openssl pkey -in "$secret_dir/$role-signing.pem" -pubout -outform DER | tail -c 32 \
    > "$secret_dir/$role-signing.pub"
done
chmod 600 "$secret_dir"/*.key
python3 - "$secret_dir" "$host_port" "$client_port" "$host_address" "$client_address" "$mode" <<'PY'
import base64
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
host_port, client_port = map(int, sys.argv[2:4])
host_address, client_address, mode = sys.argv[4:7]
host_id = "10000000-0000-0000-0000-000000000001"
services = [
    {"id": "g4-host-service",
     "publicKeyBase64": base64.b64encode((root / "host-signing.pub").read_bytes()).decode(),
     "permissions": ["roomCoordination", "userRoomCalls", "realtimePublish", "realtimeReceive"],
     "gatewayNodeIDs": ["g4-host"],
     "hostIDs": [host_id], "shardIDs": ["room-a"]},
    {"id": "g4-client-service",
     "publicKeyBase64": base64.b64encode((root / "client-signing.pub").read_bytes()).decode(),
     "permissions": ["roomCoordination", "userRoomCalls", "realtimePublish", "realtimeReceive"],
     "gatewayNodeIDs": ["g4-client"],
     "hostIDs": [], "shardIDs": ["room-a"]},
]
peers = [{"hostID": host_id, "serviceID": "g4-host-service",
          "address": host_address, "port": host_port, "shardIDs": ["room-a"],
          "maximumRooms": 10000}]
for role, port in (("host", host_port), ("client", client_port)):
    address = host_address if role == "host" else client_address
    paths = (lambda filename: "/secrets/" + filename) if mode == "linux" else (lambda filename: str(root / filename))
    document = {
        "name": "imv2-va-g4", "address": address, "port": port,
        "threadPoolSize": 2, "serviceID": f"g4-{role}-service",
        "hostID": host_id if role == "host" else None,
        "signingKeyPath": paths(f"{role}-signing.key"),
        "certificatePath": paths(f"{role}.pem"),
        "privateKeyPath": paths(f"{role}.key"),
        "trustRootPath": paths("ca.pem"),
        "services": services, "peers": peers,
        "realtimePeers": [
            {"nodeID": "g4-host", "serviceID": "g4-host-service", "address": host_address, "port": host_port},
            {"nodeID": "g4-client", "serviceID": "g4-client-service", "address": client_address, "port": client_port},
        ],
    }
    (root / f"{role}.json").write_text(json.dumps(document))
PY

git -C "$repo_root" rev-parse HEAD > "$evidence_dir/source-sha.txt"
printf 'mode=%s\ndocker_context=%s\nswift_image=%s\nclient_first=%s\n' \
  "$mode" "${DOCKER_CONTEXT:-local-postgres}" "${swift_image:-native}" "${client_first:-0}" \
  > "$evidence_dir/environment.txt"
if [[ "$mode" == linux ]]; then
  dc run --rm --name "$prefix-build" \
    -v "$repo_root:/repo:ro" -v "$VA_G4_LINUX_SCRATCH_DIR:/build" \
    -w /repo/IMV2Server "$swift_image" \
    timeout 2400 swift build --disable-automatic-resolution --scratch-path /build -c debug \
      --product VirtualActorBusinessProbe -j 2 \
    > "$evidence_dir/linux-debug-build.log" 2>&1
  binary=/build/debug/VirtualActorBusinessProbe
  [[ -x "$VA_G4_LINUX_SCRATCH_DIR/debug/VirtualActorBusinessProbe" ]] || {
    echo 'Linux business probe binary missing' >&2; exit 1;
  }
else
python3 - "$repo_root" "$evidence_dir/native-build.log" <<'PY'
import os
import signal
import subprocess
import sys

repository, output = sys.argv[1:]
with open(output, "wb") as log:
    process = subprocess.Popen(
        ["swift", "build", "--disable-automatic-resolution", "--package-path", repository + "/IMV2Server",
         "--jobs", "2", "--product", "VirtualActorBusinessProbe"],
        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = process.wait(timeout=900)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        code = 124
sys.exit(code)
PY
binary="$repo_root/IMV2Server/.build/debug/VirtualActorBusinessProbe"
[[ -x "$binary" ]] || { echo 'native business probe binary missing' >&2; exit 1; }
fi

start_host() {
  rm -f "$evidence_dir/host-ready"
  if [[ "$mode" == linux ]]; then
    dc run -d --name "$host" --network "$network" --network-alias va-host \
      -v "$VA_G4_LINUX_SCRATCH_DIR:/build:ro" \
      -v "$secret_dir:/secrets:ro" -v "$evidence_dir:/evidence" \
      -e IMV2_ROOM_ACTOR_CONFIGURATION_FILE=/secrets/host.json \
      -e VA_G4_DATABASE_URL="$database_url" -e VA_G4_EVIDENCE_DIR=/evidence \
      "$swift_image" "$binary" host > "$evidence_dir/host-container-id.txt"
  else
    env IMV2_ROOM_ACTOR_CONFIGURATION_FILE="$secret_dir/host.json" \
      VA_G4_DATABASE_URL="$database_url" VA_G4_EVIDENCE_DIR="$evidence_dir" \
      "$binary" host > "$evidence_dir/host-current.log" 2>&1 &
    host_pid=$!
  fi
  wait_file "$evidence_dir/host-ready" 30 "$host"
}

start_client() {
  if [[ "$mode" == linux ]]; then
    dc run -d --name "$client" --network "$network" --network-alias va-client \
      -v "$VA_G4_LINUX_SCRATCH_DIR:/build:ro" \
      -v "$secret_dir:/secrets:ro" -v "$evidence_dir:/evidence" \
      -e IMV2_ROOM_ACTOR_CONFIGURATION_FILE=/secrets/client.json \
      -e VA_G4_DATABASE_URL="$database_url" -e VA_G4_EVIDENCE_DIR=/evidence \
      "$swift_image" "$binary" client > "$evidence_dir/client-container-id.txt"
  else
    env IMV2_ROOM_ACTOR_CONFIGURATION_FILE="$secret_dir/client.json" \
      VA_G4_DATABASE_URL="$database_url" VA_G4_EVIDENCE_DIR="$evidence_dir" \
      "$binary" client > "$evidence_dir/client.log" 2>&1 &
    client_pid=$!
  fi
}

if [[ "$mode" == linux && "$client_first" == 1 ]]; then
  start_client
  wait_file "$evidence_dir/client-started" 20 "$client"
  dc run --rm --network "$network" "$swift_image" getent hosts va-host \
    > "$evidence_dir/initial-host-dns.txt" 2>&1 || true
  network_subnet="$(dc network inspect --format '{{(index .IPAM.Config 0).Subnet}}' "$network")"
  python3 - "$network_subnet" "$evidence_dir/initial-host-dns.txt" <<'PY'
import ipaddress
from pathlib import Path
import sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
for line in Path(sys.argv[2]).read_text().splitlines():
    try:
        address = ipaddress.ip_address(line.split()[0])
    except (IndexError, ValueError):
        continue
    if address in network:
        raise SystemExit("va-host unexpectedly resolved inside the private network before startup")
PY
  printf 'HOST_ABSENT_FROM_PRIVATE_NETWORK_DNS\n' > "$evidence_dir/initial-host-dns-check.txt"
  sleep 2
  start_host
else
  start_host
  start_client
fi
if [[ "$mode" == linux ]]; then
  printf 'first_host_container=%s\nclient_container=%s\n' \
    "$(cat "$evidence_dir/host-container-id.txt")" \
    "$(cat "$evidence_dir/client-container-id.txt")" > "$evidence_dir/processes.txt"
else
  printf 'first_host_pid=%s\nclient_pid=%s\n' "$host_pid" "$client_pid" \
    > "$evidence_dir/processes.txt"
fi
wait_file "$evidence_dir/client-stage1" 55 "$client"
if [[ "$mode" == linux ]]; then
  dc kill "$host" >/dev/null
  dc logs "$host" > "$evidence_dir/host-old.log" 2>&1
  dc rm "$host" >/dev/null
else
  kill -9 "$host_pid"
  wait "$host_pid" >/dev/null 2>&1 || true
  host_pid=""
  mv "$evidence_dir/host-current.log" "$evidence_dir/host-old.log"
fi
printf 'first_host_sigkill=1\n' >> "$evidence_dir/processes.txt"

# The old process never releases its lease. Observe expiry by PG's clock.
started=$SECONDS
while true; do
  expired="$(pgsql -At -c \
    "SELECT expires_at <= clock_timestamp() FROM im_v2.room_activation_leases WHERE room_id = '00000000-0000-0000-0000-000000000011'")"
  [[ "$expired" == t ]] && break
  (( SECONDS - started < 50 )) || { echo 'old lease did not expire' >&2; exit 1; }
  sleep 0.2
done
printf 'OLD_LEASE_EXPIRED_BY_DATABASE_CLOCK\n' > "$evidence_dir/lease-expiry.txt"
start_host
if [[ "$mode" == linux ]]; then
  printf 'replacement_host_container=%s\n' "$(cat "$evidence_dir/host-container-id.txt")" \
    >> "$evidence_dir/processes.txt"
else
  printf 'replacement_host_pid=%s\n' "$host_pid" >> "$evidence_dir/processes.txt"
fi
touch "$evidence_dir/continue-after-restart"
wait_file "$evidence_dir/client-done" 65 "$client"
if [[ "$mode" == linux ]]; then
  started=$SECONDS
  while [[ "$(dc inspect --format '{{.State.Running}}' "$client")" == true ]]; do
    (( SECONDS - started < 180 )) || { echo 'Linux client did not exit' >&2; exit 1; }
    sleep 0.2
  done
  client_exit="$(dc wait "$client")"
  dc logs "$client" > "$evidence_dir/client.log" 2>&1
  [[ "$client_exit" == 0 ]] || { echo "Linux client exited $client_exit" >&2; exit 1; }
else
  started=$SECONDS
  while kill -0 "$client_pid" 2>/dev/null; do
    (( SECONDS - started < 180 )) || { echo 'client did not exit' >&2; exit 1; }
    sleep 0.2
  done
  wait "$client_pid"
  client_pid=""
fi
rg -q 'G4_SEND_AND_LOG_OK' "$evidence_dir/client.log"
rg -q 'G4_REPLAY_AND_SQL_FENCE_OK' "$evidence_dir/client.log"
pgsql -At -c \
  "SELECT activation_epoch, host_incarnation_id FROM im_v2.room_activation_leases WHERE room_id = '00000000-0000-0000-0000-000000000011'; SELECT count(*) FROM im_v2.messages;" \
  > "$evidence_dir/final-sql.txt"
rg -q '^2\|' "$evidence_dir/final-sql.txt"
[[ "$(tail -n 1 "$evidence_dir/final-sql.txt")" == 1 ]]
python3 - "$evidence_dir" <<'PY'
import json
from pathlib import Path
import sys

evidence = Path(sys.argv[1])
result = json.loads((evidence / "result.json").read_text())
old = json.loads((evidence / "old-token.json").read_text())
lease, rows = (evidence / "final-sql.txt").read_text().splitlines()
epoch, incarnation = lease.split("|")
assert result["roomID"] == "00000000-0000-0000-0000-000000000011"
assert result["clientMessageID"] == "00000000-0000-0000-0000-000000000013"
assert result["firstActivationEpoch"] == old["activationEpoch"] == 1
assert result["replacementActivationEpoch"] == int(epoch) == 2
assert result["firstHostIncarnation"].lower() == old["host"]["incarnationID"].lower()
assert result["replacementHostIncarnation"].lower() == incarnation.lower()
assert result["firstHostIncarnation"] != result["replacementHostIncarnation"]
assert result["subscriptionMembershipRevision"] == 1
assert result["subscriptionHighWatermark"] >= 1
assert result["messageRows"] == int(rows) == 1
assert result["staleBusinessWriteRejected"] is True
PY
printf 'G4_BUSINESS_PROBE_OK mode=%s evidence=%s\n' "$mode" "$evidence_dir"
