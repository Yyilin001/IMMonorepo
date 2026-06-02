# IMServer Aliyun Local Binary Deploy Runbook

This server is small: Aliyun ECS `120.25.106.200`, Ubuntu 24.04 x86_64, 2 vCPU, 2 GiB RAM. Do not run a full Swift release build on the server. Build a Linux x86_64 binary locally, upload it, then run migrations as a single ops process.

## Current Server Shape

- Public HTTP: `http://120.25.106.200:8080`
- TCP gateway: `120.25.106.200:9000`
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
  root@120.25.106.200:/tmp/IMServer.new
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

Smoke tests:

```bash
curl -i --max-time 10 http://120.25.106.200:8080/health

curl -sS --max-time 10 \
  -X POST http://120.25.106.200:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"demo@example.com","password":"password1234","device":{"deviceID":"codex-smoke","deviceName":"Codex","platform":"curl","appVersion":"1"}}'

nc -vz -w 5 120.25.106.200 9000
```

Known-good results from this deployment:

- `/health`: `200 {"status":"ok","role":"gateway"}`
- login for `demo@example.com / password1234`: returns access and refresh tokens
- TCP `9000`: connection succeeds

## Known Gotchas

- Remote release builds can overload the 2 GiB server and make SSH/HTTP appear dead. Build locally.
- `swift-kafka-client` musl static build fails unless Kafka SSL/SASL code paths are disabled or a proper Linux OpenSSL/librdkafka setup is provided.
- The server must have `FILE_STORAGE_DIRECTORY=/opt/imserver/files`; otherwise the binary may try to use the local compile path embedded by `#filePath`.
- Existing historical outbox events may log `DecodingError.keyNotFound: Key 'kind' not found`. That is old payload data, not a deployment failure. It may need a separate data cleanup if outbox replay is required.
- Keep `IM_AUTO_MIGRATE_ON_START=false` for normal service starts.
