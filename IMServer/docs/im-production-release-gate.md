# IMServer Production Release Gate

This runbook is the required gate before promoting IMServer production changes.
It is deliberately separate from capacity tests: capacity results prove how much
traffic the deployment can handle, while this gate proves the build, generated
protocol files, production env shape, and role guardrails are deployable.

## What The Gate Checks

`scripts/production_release_gate.sh` runs these steps in order:

- shell syntax checks for production, staging, failure-drill, load-test,
  login-cache/account helper, and protobuf helper scripts
- `scripts/production_env_preflight_test.sh`
- `LoadTests/tcp_capacity_ladder_test.sh`
- `scripts/production_env_preflight.sh` against the checked-in production env templates
- `scripts/check_protobuf_generated.sh`
- optional real production env preflight when real env files are passed
- `swift build -c release --package-path IMServer/LoadTests/TCPDriver`
- `swift build -c release --package-path IMServer`
- `swift test -c release --no-parallel --package-path IMServer` by default

The protobuf drift check regenerates expected Swift protobuf outputs in a temp
directory and compares them with the committed generated files. If it fails, run
`scripts/generate_protobuf.sh`, review the generated diff, and commit the
updated generated files with the proto change.

## Local Smoke Gate

Use this only while iterating locally. It is useful before committing because it
still runs the shell checks, preflight self-tests, load-test gate self-test,
protobuf drift check, and release builds. It is not release acceptance evidence
because it skips the full Swift test suite.

```bash
cd /Users/yyl/Desktop/Code/IMMonorepo/IMServer
./scripts/production_release_gate.sh --skip-swift-tests
```

The command writes a markdown report and one log file per step under
`IMServer/reports/`.

## Required Release Gate

Run the full gate before deployment or before treating a branch as production
ready.

```bash
cd /Users/yyl/Desktop/Code/IMMonorepo/IMServer
./scripts/production_release_gate.sh
```

This checks the repo and the default production env templates. It does not prove
that a real `/etc/im/*.env` deployment is valid.

## Real Env Preflight

Before deploying real role env files, run the gate with every production role env
and strict secret validation enabled.

```bash
cd /Users/yyl/Desktop/Code/IMMonorepo/IMServer
./scripts/production_release_gate.sh \
  --command-api /etc/im/command-api.env \
  --gateway /etc/im/gateway.env \
  --query-api /etc/im/query-api.env \
  --outbox-relay /etc/im/outbox-relay.env \
  --ops /etc/im/ops.env \
  --stream-consumer /etc/im/stream-summary.env \
  --stream-consumer /etc/im/stream-domain.env \
  --stream-consumer /etc/im/stream-realtime.env \
  --stream-consumer /etc/im/stream-notification.env \
  --strict-secrets \
  --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,notification-consumer
```

The real env preflight is fail-closed. If any real env arg is provided, the gate
requires all core role env files, at least one `--stream-consumer`, and
`--strict-secrets`.

## Required Production Invariants

The preflight enforces these production invariants:

- production roles are split into `gateway`, `command-api`, `query-api`,
  `outbox-relay`, `stream-consumer`, and `ops`
- non-`ops` production roles do not auto-migrate on startup
- inline outbox projection is disabled in production
- Kafka is used with `acks=all`, SASL/TLS, SCRAM-SHA-512, credentials, and CA file
- gateway command ingress and gateway relay use authenticated internal HTTP
- gateway TCP on a public bind requires `IM_TCP_REQUIRES_TLS_TERMINATION=true`;
  use a private/loopback bind only when TCP is reachable through internal
  networking, VPN, load balancer TLS termination, or service-mesh mTLS
- domain and realtime stream consumers relay through gateway and do not fall back
  to local-only delivery
- summary write/read paths use sharded read models outside explicit ops windows
- conversation and summary shard env values are complete for every configured
  shard id
- command-api uses S3-compatible media storage
- hot conversation throttling, block sequence allocation, and message write
  batching are enabled
- full-fanout and relay body-size knobs stay within bounded production limits

If a deployment intentionally needs to violate one of these rules, change the
preflight and its self-test in the same commit. Do not bypass the gate by editing
real env files only.

## CI

`.github/workflows/imserver-production-release-gate.yml` runs the release gate
for PRs and pushes that touch IMServer, realtime protocol files, or protobuf
helper scripts. CI uploads `IMServer/reports/` as the
`imserver-production-release-gate-reports` artifact.

For manual CI runs, use `workflow_dispatch`. Keep `run_swift_tests=true` for
release evidence. Use `false` only to debug non-test gate failures quickly.

## Failure Handling

When the gate fails:

1. Open the generated markdown report under `IMServer/reports/`.
2. Open the failed step log referenced by the report.
3. Fix the source, env template, generated protobuf files, or production script
   that caused the failure.
4. Rerun the same command that failed.

Do not treat a capacity run, a successful deploy restart, or a manual smoke test
as a substitute for this gate. They answer different questions.
