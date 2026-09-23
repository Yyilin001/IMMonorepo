#!/usr/bin/env bash
set -Eeuo pipefail

# Uses two native OS processes and a task-owned PG container. Set DOCKER_CONTEXT
# explicitly; the global context and existing IMV2 stacks are untouched.
: "$DOCKER_CONTEXT"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script_dir="$repo_root/IMV2/scripts"
run_id="$(date +%s)-$$"
prefix="imv2-va-g4-$run_id"
network="$prefix-net"
pg="$prefix-pg"
host="$prefix-host"
client="$prefix-client"
evidence_dir="/tmp/$prefix-evidence"
secret_dir="$(mktemp -d "/tmp/$prefix-secrets.XXXXXX")"
mkdir -p "$evidence_dir"
read -r host_port client_port < <(python3 - <<'PY'
import socket
with socket.socket() as first, socket.socket() as second:
    first.bind(("127.0.0.1", 0))
    second.bind(("127.0.0.1", 0))
    print(first.getsockname()[1], second.getsockname()[1])
PY
)
dc() { docker --context "$DOCKER_CONTEXT" "$@"; }

cleanup() {
  local status=$?
  if [[ -n "${host_pid:-}" ]]; then
    kill -9 "$host_pid" >/dev/null 2>&1 || true
    wait "$host_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${client_pid:-}" ]]; then
    kill -9 "$client_pid" >/dev/null 2>&1 || true
    wait "$client_pid" >/dev/null 2>&1 || true
  fi
  if [[ -f "$evidence_dir/host-current.log" ]]; then
    cp "$evidence_dir/host-current.log" "$evidence_dir/host-last.log"
  fi
  dc rm -f "$pg" >/dev/null 2>&1 || true
  dc network rm "$network" >/dev/null 2>&1 || true
  rm -rf -- "$secret_dir"
  printf 'G4_EVIDENCE_DIR=%s exit=%s\n' "$evidence_dir" "$status"
}
trap cleanup EXIT

wait_file() {
  local path="$1" limit="$2" started=$SECONDS
  until [[ -f "$path" ]]; do
    if (( SECONDS - started >= limit )); then
      printf 'timed out waiting for %s\n' "$path" >&2
      return 1
    fi
    sleep 0.2
  done
}

dc network create "$network" >/dev/null
dc run -d --name "$pg" --network "$network" -p 127.0.0.1::5432 \
  -e POSTGRES_USER=probe -e POSTGRES_PASSWORD=probe -e POSTGRES_DB=probe \
  postgres:16-alpine >/dev/null
started=$SECONDS
until dc logs "$pg" 2>&1 | rg -q 'PostgreSQL init process complete; ready for start up'; do
  (( SECONDS - started < 30 )) || { echo 'isolated PostgreSQL did not start' >&2; exit 1; }
  sleep 0.2
done
until dc exec "$pg" psql -At -U probe -d probe -c 'SELECT 1' 2>/dev/null | rg -qx 1; do
  (( SECONDS - started < 30 )) || { echo 'final PostgreSQL server unavailable' >&2; exit 1; }
  sleep 0.2
done
pg_port="$(dc port "$pg" 5432/tcp | tail -n 1 | sed 's/.*://')"
database_url="postgres://probe:probe@127.0.0.1:$pg_port/probe"
dc exec -i "$pg" psql -v ON_ERROR_STOP=1 -U probe -d probe \
  < "$repo_root/IMV2/sql/schema.sql" > "$evidence_dir/schema-install.log"
dc exec -i "$pg" psql -v ON_ERROR_STOP=1 -U probe -d probe \
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
  openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$secret_dir/$role.key" -out "$secret_dir/$role.csr" \
    -subj "/CN=va-$role" >> "$evidence_dir/cert-generation.log" 2>&1
  openssl x509 -req -in "$secret_dir/$role.csr" \
    -CA "$secret_dir/ca.pem" -CAkey "$secret_dir/ca.key" -CAcreateserial \
    -days 2 -sha256 -extfile <(printf 'subjectAltName=DNS:localhost\n') \
    -out "$secret_dir/$role.pem" >> "$evidence_dir/cert-generation.log" 2>&1
  openssl genpkey -algorithm Ed25519 -out "$secret_dir/$role-signing.pem"
  openssl pkey -in "$secret_dir/$role-signing.pem" -outform DER | tail -c 32 \
    > "$secret_dir/$role-signing.key"
  openssl pkey -in "$secret_dir/$role-signing.pem" -pubout -outform DER | tail -c 32 \
    > "$secret_dir/$role-signing.pub"
done
chmod 600 "$secret_dir"/*.key
python3 - "$secret_dir" "$host_port" "$client_port" <<'PY'
import base64
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
host_port, client_port = map(int, sys.argv[2:4])
host_id = "10000000-0000-0000-0000-000000000001"
services = [
    {"id": "g4-host-service",
     "publicKeyBase64": base64.b64encode((root / "host-signing.pub").read_bytes()).decode(),
     "permissions": ["roomCoordination", "userRoomCalls"],
     "hostIDs": [host_id], "shardIDs": ["room-a"]},
    {"id": "g4-client-service",
     "publicKeyBase64": base64.b64encode((root / "client-signing.pub").read_bytes()).decode(),
     "permissions": ["roomCoordination", "userRoomCalls"],
     "hostIDs": [], "shardIDs": ["room-a"]},
]
peers = [{"hostID": host_id, "serviceID": "g4-host-service",
          "address": "localhost", "port": host_port, "shardIDs": ["room-a"],
          "maximumRooms": 10000}]
for role, port in (("host", host_port), ("client", client_port)):
    document = {
        "name": "imv2-va-g4", "address": "localhost", "port": port,
        "threadPoolSize": 2, "serviceID": f"g4-{role}-service",
        "hostID": host_id if role == "host" else None,
        "signingKeyPath": str(root / f"{role}-signing.key"),
        "certificatePath": str(root / f"{role}.pem"),
        "privateKeyPath": str(root / f"{role}.key"),
        "trustRootPath": str(root / "ca.pem"),
        "services": services, "peers": peers,
    }
    (root / f"{role}.json").write_text(json.dumps(document))
PY

python3 - "$repo_root" "$evidence_dir/native-build.log" <<'PY'
import os
import signal
import subprocess
import sys

repository, output = sys.argv[1:]
with open(output, "wb") as log:
    process = subprocess.Popen(
        ["swift", "build", "--package-path", repository + "/IMV2Server",
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

start_host() {
  rm -f "$evidence_dir/host-ready"
  env IMV2_ROOM_ACTOR_CONFIGURATION_FILE="$secret_dir/host.json" \
    VA_G4_DATABASE_URL="$database_url" VA_G4_EVIDENCE_DIR="$evidence_dir" \
    "$binary" host > "$evidence_dir/host-current.log" 2>&1 &
  host_pid=$!
  wait_file "$evidence_dir/host-ready" 30
}

start_host
env IMV2_ROOM_ACTOR_CONFIGURATION_FILE="$secret_dir/client.json" \
  VA_G4_DATABASE_URL="$database_url" VA_G4_EVIDENCE_DIR="$evidence_dir" \
  "$binary" client > "$evidence_dir/client.log" 2>&1 &
client_pid=$!
printf 'first_host_pid=%s\nclient_pid=%s\n' "$host_pid" "$client_pid" \
  > "$evidence_dir/processes.txt"
wait_file "$evidence_dir/client-stage1" 55
kill -9 "$host_pid"
wait "$host_pid" >/dev/null 2>&1 || true
printf 'first_host_sigkill=1\n' >> "$evidence_dir/processes.txt"
host_pid=""
mv "$evidence_dir/host-current.log" "$evidence_dir/host-old.log"

# The old process never releases its lease. Observe expiry by PG's clock.
started=$SECONDS
while true; do
  expired="$(dc exec "$pg" psql -At -U probe -d probe -c \
    "SELECT expires_at <= clock_timestamp() FROM im_v2.room_activation_leases WHERE room_id = '00000000-0000-0000-0000-000000000011'")"
  [[ "$expired" == t ]] && break
  (( SECONDS - started < 50 )) || { echo 'old lease did not expire' >&2; exit 1; }
  sleep 0.2
done
printf 'OLD_LEASE_EXPIRED_BY_DATABASE_CLOCK\n' > "$evidence_dir/lease-expiry.txt"
start_host
printf 'replacement_host_pid=%s\n' "$host_pid" >> "$evidence_dir/processes.txt"
touch "$evidence_dir/continue-after-restart"
wait_file "$evidence_dir/client-done" 65
started=$SECONDS
while kill -0 "$client_pid" 2>/dev/null; do
  (( SECONDS - started < 180 )) || { echo 'client did not exit' >&2; exit 1; }
  sleep 0.2
done
wait "$client_pid"
client_pid=""
rg -q 'G4_SEND_AND_LOG_OK' "$evidence_dir/client.log"
rg -q 'G4_REPLAY_AND_SQL_FENCE_OK' "$evidence_dir/client.log"
dc exec "$pg" psql -At -U probe -d probe -c \
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
printf 'G4_BUSINESS_PROBE_OK evidence=%s\n' "$evidence_dir"
