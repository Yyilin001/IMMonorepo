#!/usr/bin/env bash
set -euo pipefail

probe_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VA_WORKTREE="$(cd "$probe_dir/../../.." && pwd)"
export VA_EVIDENCE_DIR="${VA_EVIDENCE_DIR:-/Users/yyl/.codex/virtual-actor-builds/p0/evidence}"
export VA_BUILD_DIR="${VA_BUILD_DIR:-/Users/yyl/.codex/virtual-actor-builds/p0}"
export VA_SWIFT_IMAGE="swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6"
export DOCKER_CONTEXT=colima-imv2-vapor5
compose=(docker compose -p imv2-va-p0 -f "$probe_dir/compose.yml")

mkdir -p "$VA_EVIDENCE_DIR" "$VA_BUILD_DIR"
rm -f "$VA_EVIDENCE_DIR"/{actor-old.json,actor-new.json,host-old-incarnation.txt,host-new-incarnation.txt,stage1,continue1}

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -keyout "$VA_EVIDENCE_DIR/ca.key" -out "$VA_EVIDENCE_DIR/ca.pem" \
  -subj /CN=imv2-va-p0-ca -addext 'basicConstraints=critical,CA:TRUE' \
  > "$VA_EVIDENCE_DIR/cert-generation.log" 2>&1
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -keyout "$VA_EVIDENCE_DIR/rogue-ca.key" -out "$VA_EVIDENCE_DIR/rogue-ca.pem" \
  -subj /CN=imv2-va-p0-rogue-ca -addext 'basicConstraints=critical,CA:TRUE' \
  >> "$VA_EVIDENCE_DIR/cert-generation.log" 2>&1
for role in host client; do
  name="imv2-va-p0-$role"
  openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$VA_EVIDENCE_DIR/$role.key" -out "$VA_EVIDENCE_DIR/$role.csr" \
    -subj "/CN=$name" >> "$VA_EVIDENCE_DIR/cert-generation.log" 2>&1
  openssl x509 -req -in "$VA_EVIDENCE_DIR/$role.csr" \
    -CA "$VA_EVIDENCE_DIR/ca.pem" -CAkey "$VA_EVIDENCE_DIR/ca.key" -CAcreateserial \
    -days 2 -sha256 -extfile <(printf 'subjectAltName=DNS:%s\n' "$name") \
    -out "$VA_EVIDENCE_DIR/$role.pem" >> "$VA_EVIDENCE_DIR/cert-generation.log" 2>&1
  openssl genpkey -algorithm Ed25519 -out "$VA_EVIDENCE_DIR/$role-signing.pem"
  openssl pkey -in "$VA_EVIDENCE_DIR/$role-signing.pem" -outform DER | tail -c 32 \
    > "$VA_EVIDENCE_DIR/$role-signing.key"
  openssl pkey -in "$VA_EVIDENCE_DIR/$role-signing.pem" -pubout -outform DER | tail -c 32 \
    > "$VA_EVIDENCE_DIR/$role-signing.pub"
done
chmod 600 "$VA_EVIDENCE_DIR"/*.key

docker run --rm --name imv2-va-p0-build \
  -v "$VA_WORKTREE:/repo:ro" -v "$VA_BUILD_DIR:/build" \
  -w /repo/IMV2Server "$VA_SWIFT_IMAGE" \
  swift build --scratch-path /build -c release --product VirtualActorCompatibilityProbe -j 2 \
  > "$VA_EVIDENCE_DIR/release-build.log" 2>&1

wait_file() {
  local path="$1"
  for _ in {1..120}; do
    if [[ -f "$path" ]]; then return 0; fi
    sleep 0.25
  done
  echo "Timed out waiting for $path" >&2
  return 1
}

collect_logs() {
  docker logs imv2-va-p0-host > "$VA_EVIDENCE_DIR/host-final.log" 2>&1 || true
  docker logs imv2-va-p0-client > "$VA_EVIDENCE_DIR/client.log" 2>&1 || true
  "${compose[@]}" ps -a > "$VA_EVIDENCE_DIR/compose-ps.txt" 2>&1 || true
}
trap collect_logs EXIT

"${compose[@]}" down -v --remove-orphans
"${compose[@]}" up -d --wait postgres
export VA_ACTOR_ID_FILE=actor-old.json
"${compose[@]}" up -d host
wait_file "$VA_EVIDENCE_DIR/actor-old.json"
docker exec imv2-va-p0-host python3 -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:19080/health", timeout=5).read().decode())'
docker run --rm --name imv2-va-p0-oversized-header --network imv2-va-p0_default \
  -v "$VA_WORKTREE:/repo:ro" -v "$VA_EVIDENCE_DIR:/evidence:ro" \
  "$VA_SWIFT_IMAGE" python3 /repo/IMV2Server/Tests/VirtualActorCompatibilityProbe/oversized-tls-header.py \
  --host imv2-va-p0-host --port 19081 --evidence /evidence --maximum-frame-bytes 1048576 \
  > "$VA_EVIDENCE_DIR/oversized-tls-header.log" 2>&1
rg -q 'TLS_ESTABLISHED' "$VA_EVIDENCE_DIR/oversized-tls-header.log"
rg -q 'OVERSIZED_HEADER_CLOSED' "$VA_EVIDENCE_DIR/oversized-tls-header.log"
docker run --rm --name imv2-va-p0-badclient --network imv2-va-p0_default \
  -v "$VA_BUILD_DIR:/build:ro" -v "$VA_EVIDENCE_DIR:/evidence:ro" \
  -e VA_CERT_NAME=client -e VA_CA_FILE=rogue-ca.pem -e VA_EVIDENCE_DIR=/evidence \
  "$VA_SWIFT_IMAGE" /build/release/VirtualActorCompatibilityProbe negative-tls \
  > "$VA_EVIDENCE_DIR/negative-tls.log" 2>&1
rg -q 'UNTRUSTED_TLS_REJECTED' "$VA_EVIDENCE_DIR/negative-tls.log"
"${compose[@]}" up -d client
wait_file "$VA_EVIDENCE_DIR/stage1"

"${compose[@]}" stop -t 20 host
docker logs imv2-va-p0-host > "$VA_EVIDENCE_DIR/host-old.log" 2>&1
rg -q 'ALL_STOPPED' "$VA_EVIDENCE_DIR/host-old.log"

export VA_ACTOR_ID_FILE=actor-new.json
export VA_HOST_INCARNATION_FILE=host-new-incarnation.txt
"${compose[@]}" up -d --force-recreate host
wait_file "$VA_EVIDENCE_DIR/actor-new.json"
wait_file "$VA_EVIDENCE_DIR/host-new-incarnation.txt"
docker exec imv2-va-p0-host python3 -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:19080/health", timeout=5).read().decode())'
touch "$VA_EVIDENCE_DIR/continue1"

client_exit="$(docker wait imv2-va-p0-client)"
docker logs imv2-va-p0-client > "$VA_EVIDENCE_DIR/client.log" 2>&1
if [[ "$client_exit" != 0 ]]; then
  cat "$VA_EVIDENCE_DIR/client.log" >&2
  exit "$client_exit"
fi
rg -q 'NEW_REF_OK' "$VA_EVIDENCE_DIR/client.log"
rg -q 'STALE_REF_FAILED' "$VA_EVIDENCE_DIR/client.log"

"${compose[@]}" stop -t 20 host
docker logs imv2-va-p0-host > "$VA_EVIDENCE_DIR/host-new.log" 2>&1
rg -q 'ALL_STOPPED' "$VA_EVIDENCE_DIR/host-new.log"

# A bad database endpoint must fail after creating ClusterSystem and must close
# its own resources. This uses only the isolated probe Compose project.
export VA_DATABASE_URL=postgres://probe:probe@does-not-exist:5432/probe
"${compose[@]}" up -d --force-recreate host
startup_exit="$(docker wait imv2-va-p0-host)"
docker logs imv2-va-p0-host > "$VA_EVIDENCE_DIR/host-startup-failure.log" 2>&1
if [[ "$startup_exit" == 0 ]]; then
  echo 'Expected failed database startup to exit nonzero' >&2
  exit 1
fi
rg -q 'PROBE_FAILURE' "$VA_EVIDENCE_DIR/host-startup-failure.log"

echo "P0_PROBE_OK evidence=$VA_EVIDENCE_DIR"
collect_logs
trap - EXIT
"${compose[@]}" down -v
