# Multi-device Realtime Release Gate

This runbook is the release gate for same-account multi-device realtime sync. It assumes protocol semantics are already locked:

- same `userID + deviceID` is single-active-session
- different `deviceID` values can stay online concurrently
- read state is user-level
- TCP `ack` means the server accepted and persisted the message
- canonical `message` is the source clients merge by `clientMessageID`

## Required Staging Shape

Minimum staging must mirror the production routing shape:

- 2+ `gateway` nodes with TCP enabled
- 1+ `command-api` node
- 1+ `query-api` node
- Redis routing enabled with `IM_ROUTING_MODE=redis`
- gateway relay enabled from non-gateway roles with `IM_GATEWAY_RELAY_MODE=http`
- private Prometheus scraping `/internal/metrics`

Do not use `combined` runtime for this gate except for local smoke.

## One-command Local Gate

```bash
cd IMServer
./scripts/multidevice_release_gate.sh
```

This runs:

- `swift test --no-parallel` for IMServer
- `swift test` for `IMClientKit`
- Android `:imclientkit:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug`
- TCPDriver build
- Redis integration test when `IM_REDIS_INTEGRATION_URL` is set

Require Redis explicitly:

```bash
cd IMServer
IM_REDIS_INTEGRATION_URL=redis://127.0.0.1:6379 ./scripts/multidevice_release_gate.sh --require-redis
```

## Staging Gate

Create a private env file from `LoadTests/staging-baseline.env.example`, then run:

```bash
cd IMServer
./scripts/multidevice_release_gate.sh \
  --env-file LoadTests/staging-baseline.env \
  --profile staging-baseline \
  --staging-baseline \
  --require-redis
```

For a focused same-account smoke:

```bash
cd IMServer
./scripts/staging_baseline.sh \
  --profile local-smoke \
  --env-file LoadTests/staging-baseline.env \
  --skip-http \
  --tcp-connections 5 \
  --tcp-devices-per-user 5 \
  --tcp-messages 1
```

## Manual Client Matrix

Run this matrix with at least one iOS device/simulator and one Android device/emulator:

| Scenario | Expected result |
| --- | --- |
| iOS and Android login with same account and different device IDs | both sessions remain active |
| same device ID logs in again | old session receives `kick`, new session remains active |
| device A sends text | A receives `ack`; A and B receive canonical `message` |
| canonical message arrives before ack | pending local message merges by `clientMessageID`; no duplicate UI row |
| device A opens conversation and marks read | device B unread count converges to zero by realtime event or HTTP changes |
| device B cold starts | cache renders immediately, then TCP + `changes/messages/since` converges |
| logout current/session/all | only the expected session set is kicked |

## Metrics To Watch

Prometheus/Grafana must be watched throughout the gate:

- `im_tcp_connections`
- `im_user_fanout_total`
- `im_session_kick_total`
- `im_cross_node_dispatch_total`
- `im_cross_node_dispatch_failures_total`
- `im_session_count_query_failures_total`
- `im_redis_presence_route_cache_hits_total`
- `im_redis_presence_route_cache_misses_total`
- `im_redis_presence_stale_cleanup_total`
- `im_db_operation_latency_max_millis`
- `im_conversation_write_queue_depth`
- `im_outbox_backlog_events`

TCPDriver report fields are the source for ack/canonical p50/p95/p99 until those client-side latency measurements are exported centrally.

## Go / No-Go

Go only when all are true:

- no duplicate messages in iOS or Android for canonical echo
- no incorrect session kick in same-account multi-device tests
- `ackSuccessRate >= 0.999`
- `canonicalSuccessRate >= 0.999`
- cross-node dispatch failures stay at zero
- session-count query failures stay at zero
- Redis stale cleanup is not continuously increasing after load stops
- outbox backlog drains after load stops
- `conversations/changes` and `messages/since` close all observed gaps after reconnect

No-go on any protocol ambiguity, duplicate UI row, wrong-session kick, sustained Redis route failures, or unbounded write/outbox backlog.
