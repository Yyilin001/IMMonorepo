# IMServer Release Candidate Checklist

Use this checklist before promoting a multi-device IM release candidate.

## Required Commands

```bash
cd /Users/yyl/Desktop/Code/IMMonorepo/IMServer
swift test --no-parallel

IM_REDIS_INTEGRATION_URL=redis://127.0.0.1:6379 \
swift test --filter RedisPresenceIntegrationTests

./scripts/multidevice_release_gate.sh \
  --require-redis \
  --require-staging-baseline \
  --env-file LoadTests/staging-baseline.env \
  --profile staging-baseline
```

```bash
cd /Users/yyl/Desktop/Code/IMMonorepo/IMClientKit
swift test
```

```bash
cd /Users/yyl/Desktop/Code/IMMonorepo
xcodebuild -project IMApp/IMApp.xcodeproj \
  -scheme IMApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' \
  build

./gradlew :imclientkit:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug
```

## Staging Acceptance

- `1 user x 5 devices` passes with ack and canonical success rate >= 99.9%.
- `100 users x 2 devices` passes with ack and canonical success rate >= 99.9%.
- `1 group x 500 members x 2 devices` passes in the dedicated staging environment.
- `reconnect storm` converges through `messages/since` without duplicate canonical messages; `IM_RECONNECT_STORM_COMMAND` is recorded in the staging report.
- AI stream concurrency is exercised by the staging baseline script and records success/rejection/error counts.
- Outbox backlog drains to zero after load stops.
- Redis integration tests run against a real Redis endpoint, not the fake/local store.

## Metrics Review

Prometheus must show these values during steady state:

- `im_cross_node_dispatch_failures_total` does not increase.
- `im_session_count_query_failures_total` does not increase.
- `im_outbox_backlog_events` returns to zero or continuously drains.
- `im_ai_stream_runtime_stale_repairs_total` does not increase.
- `im_ai_stream_startup_stale_repairs_total` does not increase during steady-state restarts.
- `im_ai_stream_finalize_failures_total` does not increase.
- AI stream lease heartbeats continue while `im_ai_stream_active > 0`.

## Security Gate

- Production TCP is behind internal networking, VPN, load balancer TLS termination, or service mesh mTLS.
- Bare public TCP exposure is not allowed.
- `IM_INTERNAL_SHARED_SECRET` is configured for production gateway relay.
- `IM_METRICS_INTERNAL_SECRET` or `IM_INTERNAL_SHARED_SECRET` protects `/internal/metrics`.
- Android release configuration uses HTTPS API base URL and TLS-terminated TCP host.

## Go / No-Go

Block the release when any of these occur:

- Duplicate canonical message appears for the same `clientMessageID`.
- A session kick targets the wrong device/session.
- Cross-node dispatch failure or session-count relay failure is non-zero.
- AI stream remains permanently `streaming`.
- AI stream stale repair or finalize failure is non-zero.
- Redis lease limits do not enforce user limit 2 and conversation limit 5.
- iOS or Android cold start fails to show cache before converging through TCP + HTTP sync.
