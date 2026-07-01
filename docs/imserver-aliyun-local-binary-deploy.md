# IMServer Aliyun Local Binary Deploy Runbook

This is a legacy/bootstrap runbook for a small Aliyun ECS host. Do not use it as
the long-term production deployment path. For production, use the
`deploy/ubuntu/90_deploy_single_node.sh` flow with a real DNS name, HTTPS on
default port `443`, public TCP `9000`, and cloud security group evidence that
keeps `8080` and internal ports closed to the Internet.

The original bootstrap server shape was Aliyun ECS `<server-public-ip>`, Ubuntu
24.04 x86_64, 2 vCPU, 2 GiB RAM. Do not run a full Swift release build on that
class of server. Build a Linux x86_64 binary locally, upload it, then run
migrations as a single ops process.

## Current Server Shape

- Temporary bootstrap HTTP: `http://<server-public-ip>`
- Long-term production HTTP: `https://chat.yourdomain.com`
- TCP gateway: `<server-public-ip>:9000`
- Runtime services:
  - `postgresql`
  - `redis-server`
  - `kafka`
  - `nginx`
  - `imserver-gateway`
  - `imserver-command-api`
  - `imserver-query-api`
  - `imserver-outbox-relay`
  - `imserver-stream-consumer`
  - `imserver-domain-delivery-consumer`
- Keep swap enabled. This deployment added a 6 GiB `/swapfile`.
- `/etc/imserver/common.env` must include:

```bash
IM_AUTO_MIGRATE_ON_START=false
MEDIA_STORAGE_DIRECTORY=/opt/imserver/media
FILE_STORAGE_DIRECTORY=/opt/imserver/files
```

Do not use `--env testing` for this server. It switches the app to the test database path and can create SQLite files. Do not use production mode unless full production settings are ready, including S3 media storage and production TCP/TLS requirements.

## Local Build Prerequisites

This machine was set up with Swiftly and the Swift 6.3.2 Static Linux SDK:

```bash
. "$HOME/.swiftly/env.sh"
swift --version
swift sdk list
```

Expected SDK:

```text
swift-6.3.2-RELEASE_static-linux-0.1.0
```

The static SDK OpenSSL is not enough for this repository's `swift-kafka-client` checkout when librdkafka SSL/SASL is enabled. Because the single-node deployment uses plaintext Kafka, the local checkout was patched for Linux-musl builds:

- `IMServer/.build/checkouts/swift-kafka-client/Package.swift`
  - exclude `rdkafka_sasl_cyrus.c`
  - exclude `rdkafka_sasl_scram.c`
  - exclude `rdkafka_ssl.c`
  - remove the `COpenSSL` dependency from the `Crdkafka` target
- `IMServer/.build/checkouts/swift-kafka-client/Sources/Crdkafka/custom/config/config.h`
  - `WITH_SSL 0`
  - `WITH_SASL_CYRUS 0`
  - `WITH_SASL_SCRAM 0`

If `swift package reset`, dependency resolution, or deleting `.build` removes that checkout patch, reapply it before cross-building.

## Build Locally

Run from repo root:

```bash
. "$HOME/.swiftly/env.sh"

SDKROOT="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_static-linux-0.1.0.artifactbundle/swift-6.3.2-RELEASE_static-linux-0.1.0/swift-linux-musl/musl-1.2.5.sdk/x86_64"
export PKG_CONFIG_PATH=/tmp/imserver-linux-pkgconfig
export PKG_CONFIG_LIBDIR=/tmp/imserver-linux-pkgconfig:$SDKROOT/usr/lib/pkgconfig

swift build \
  -c release \
  --package-path IMServer \
  --product IMServer \
  --swift-sdk x86_64-swift-linux-musl \
  --jobs 4
```

Verify the result:

```bash
file IMServer/.build/x86_64-swift-linux-musl/release/IMServer
```

Expected:

```text
ELF 64-bit LSB executable, x86-64, statically linked
```

## Upload And Install

```bash
rsync -avP --compress \
  IMServer/.build/x86_64-swift-linux-musl/release/IMServer \
  root@<server-public-ip>:/tmp/IMServer.new
```

On the server:

```bash
systemctl stop \
  imserver-command-api \
  imserver-gateway \
  imserver-query-api \
  imserver-outbox-relay \
  imserver-stream-consumer \
  imserver-domain-delivery-consumer

file /tmp/IMServer.new

cp /tmp/IMServer.new /tmp/IMServer.new.stripped
strip /tmp/IMServer.new.stripped
mv /tmp/IMServer.new.stripped /tmp/IMServer.new
chmod 0755 /tmp/IMServer.new

install -o imserver -g imserver -m 0755 \
  /tmp/IMServer.new \
  /opt/imserver/bin/IMServer
```

## Run Migrations Safely

Never let all systemd services auto-migrate concurrently. Keep startup migration disabled:

```bash
sed -i 's/^IM_AUTO_MIGRATE_ON_START=.*/IM_AUTO_MIGRATE_ON_START=false/' /etc/imserver/common.env
```

Run migration once through the ops role:

```bash
set -a
. /etc/imserver/common.env
set +a
export IM_AUTO_MIGRATE_ON_START=true

cd /opt/imserver
runuser -u imserver -- /opt/imserver/bin/IMServer ops
```

When the log says `IM ops role initialized`, migrations have completed. If the process stays attached because lifecycle workers started, stop it:

```bash
pkill -u imserver -f "IMServer ops" || true
```

Then make sure auto-migration is disabled again:

```bash
sed -i 's/^IM_AUTO_MIGRATE_ON_START=.*/IM_AUTO_MIGRATE_ON_START=false/' /etc/imserver/common.env
```

## Start And Verify

```bash
systemctl start \
  imserver-command-api \
  imserver-gateway \
  imserver-query-api \
  imserver-outbox-relay \
  imserver-stream-consumer \
  imserver-domain-delivery-consumer

systemctl is-active \
  postgresql redis-server kafka nginx \
  imserver-command-api imserver-gateway imserver-query-api \
  imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer
```

Bootstrap smoke tests before DNS/HTTPS:

```bash
curl -i --max-time 10 http://<server-public-ip>/health

curl -sS --max-time 10 \
  -X POST http://<server-public-ip>/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"demo@example.com","password":"password1234","device":{"deviceID":"codex-smoke","deviceName":"Codex","platform":"curl","appVersion":"1"}}'

nc -vz -w 5 <server-public-ip> 9000
```

During this bootstrap phase, Aliyun security group `8080/tcp` may be open only
if the temporary public entrypoint still depends on it. Before treating the
server as production, change the inbound rules to the long-term posture:

| Port | Source | Production posture |
| --- | --- | --- |
| `80/tcp` | `0.0.0.0/0` | Allowed for ACME HTTP challenge or redirect only. |
| `443/tcp` | `0.0.0.0/0` | Allowed for public HTTPS API traffic. |
| `9000/tcp` | `0.0.0.0/0` | Allowed for direct IM TCP gateway clients. |
| `22/tcp` | `<your-admin-public-ip>/32` | Allowed only from the operator IP or VPN egress. |
| `3389/tcp` | any | Deleted; Ubuntu does not use RDP. |
| `8080/tcp` | any public CIDR | Deleted after HTTPS is installed. |
| `5432`, `6379`, `9092`, `8081`, `8082`, `18080` | any public CIDR | Deleted; internal services are local/private only. |

Use `deploy/ubuntu/29_fetch_aliyun_security_group_snapshot.sh` plus
`deploy/ubuntu/26_audit_cloud_security_group.sh`, or the all-in-one deploy's
Aliyun security group repair path, to produce machine-readable evidence. A
console screenshot alone is not enough for the production gate.

Long-term production smoke tests:

```bash
curl -i --max-time 10 https://chat.yourdomain.com/health

curl -sS --max-time 10 \
  -X POST https://chat.yourdomain.com/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"demo@example.com","password":"password1234","device":{"deviceID":"codex-smoke","deviceName":"Codex","platform":"curl","appVersion":"1"}}'

nc -vz -w 5 chat.yourdomain.com 9000
```

Known-good results from this deployment:

- `/health`: `200 {"status":"ok","role":"gateway"}`
- login for `demo@example.com / password1234`: returns access and refresh tokens
- TCP `9000`: connection succeeds

## Known Gotchas

- Remote release builds can overload the 2 GiB server and make SSH/HTTP appear dead. Build locally.
- `swift-kafka-client` musl static build fails unless Kafka SSL/SASL code paths are disabled or a proper Linux OpenSSL/librdkafka setup is provided.
- The server must have `FILE_STORAGE_DIRECTORY=/opt/imserver/files`; otherwise the binary may try to use the local compile path embedded by `#filePath`.
- Keep `IM_AUTO_MIGRATE_ON_START=false` for normal service starts.
