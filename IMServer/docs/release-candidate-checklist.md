# IMServer Release Candidate Checklist

Use this checklist before promoting a multi-device IM release candidate.

## Required Commands

```bash
cd /Users/yyl/Desktop/Code/IMMonorepo/IMServer
./scripts/production_release_gate.sh
```

Before deploying real production env files, run the same gate with every role env
and strict secret validation:

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

xcodebuild -project IMApp/IMApp.xcodeproj \
  -scheme IMApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' \
  test \
  -only-testing:IMAppTests \
  -parallel-testing-enabled NO

./gradlew :imclientkit:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug
```

## Staging Acceptance

- `1 user x 5 devices` passes with ack and canonical success rate >= 99.9%.
- `100 users x 2 devices` passes with ack and canonical success rate >= 99.9%.
- `1 group x 500 members x 2 devices` passes in the dedicated staging environment.
- `reconnect storm` converges through `messages/since` without duplicate canonical messages; the default recovery probe runs when `IM_RECONNECT_STORM_COMMAND` is not set, and a custom command is recorded when provided.
- AI stream concurrency is exercised by the staging baseline script and records success/rejection/error counts.
- Outbox backlog drains to zero after load stops.
- Redis integration tests run against a real Redis endpoint, not the fake/local store.
- UI tests are not part of the deterministic RC gate; `IMAppTests` unit tests are the required simulator test target.

## Metrics Review

Prometheus must show these values during steady state:

- `im_cross_node_dispatch_failures_total` does not increase.
- `im_session_count_query_failures_total` does not increase.
- `im_outbox_backlog_events` returns to zero or continuously drains.
- `im_timeline_since_target_sequence_strong_misses_total` does not increase.
- `im_timeline_since_target_sequence_errors_total` does not increase.
- `im_timeline_since_target_sequence_eventual_satisfied_total` increases during active compact-hint tests when the eventual read model keeps up; `im_timeline_since_target_sequence_strong_fallbacks_total` must not grow linearly with active viewers except during measured replica/read-model lag, and the load-test gate must keep targeted strong fallback rate under `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT`.
- `im_timeline_since_target_sequence_singleflight_joined_total` increases during hot large-group compact-hint tests when many active viewers catch up from the same target sequence.
- `im_timeline_since_target_sequence_window_joined_total` is reviewed during active-viewer hot-room tests; non-zero values prove the short target-sequence window is merging pulls whose cursors differ slightly.
- `im_timeline_since_visibility_notice_bypasses_total` and `im_timeline_since_response_singleflight_notice_bypasses_total` stay near zero during pure hot-message tests; spikes indicate user-specific timeline notices forced shared catch-up requests to read independently.
- `im_timeline_since_hot_cache_target_sequence_bypasses_total` and `im_timeline_since_recent_cache_target_sequence_bypasses_total` are reviewed with the strong fallback rate; high bypasses are acceptable only when strong fallbacks are satisfied and `timeline/since` P95/P99 stay inside the load-test gate.
- `im_domain_event_message_created_summary_activity_only_total` increases for large-group `message_created` projection while recipient-resolution counters do not grow linearly with hot-group message rate; omitted-recipient large-group projection should use the snapshot `recipient_count` hint instead of decoding the full shared recipient set.
- Large-group `conversations`, `conversations/changes`, and realtime conversation summary payloads keep `member_count` accurate but omit full `memberUserIDs` when `member_count > IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT`; member details must be loaded through the paged members API.
- `im_realtime_payload_summary_member_ids_omitted_total` increases during large-group membership/settings realtime tests, while `im_realtime_payload_summary_member_ids_emitted_members_total` stays near zero for groups above `IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT`.
- Production hot-room active compact realtime uses `IM_REALTIME_ACTIVE_COMPACT_HINT_BODY=conversation-activity` with `IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS` in `1...120`; `timeline-gap` is accepted only as a rollback compatibility mode outside the release candidate posture.
- `im_realtime_active_conversation_route_cache_joined_in_flight_total` or `im_domain_relay_after_record_active_route_cache_joined_in_flight_total` increases during concurrent hot-room bursts when route-cache misses overlap; Redis route-cache misses should not grow linearly with message rate for one hot conversation.
- Large-group `pull-only` realtime delivery resolves active recipients through `conversation_domain_event_recipient_set_members`; `recipientSnapshotResolveMaxRecipients` should track active viewers, not total group size, during hot-room tests with deduplicated recipient snapshots.
- `im_ai_stream_runtime_stale_repairs_total` does not increase.
- `im_ai_stream_startup_stale_repairs_total` does not increase during steady-state restarts.
- `im_ai_stream_finalize_failures_total` does not increase.
- AI stream lease heartbeats continue while `im_ai_stream_active > 0`.

## Security Gate

- Production TCP is behind internal networking, VPN, load balancer TLS termination, or service mesh mTLS.
- Bare public TCP exposure is not allowed.
- Gateway env sets `IM_TCP_REQUIRES_TLS_TERMINATION=true` when `IM_TCP_HOST`
  is public or omitted, because the runtime default bind is `0.0.0.0`.
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
- Targeted `timeline/since` strong miss or target-sequence error is non-zero during large-group compact-hint validation.
- Redis lease limits do not enforce user limit 2 and conversation limit 5.
- iOS or Android cold start fails to show cache before converging through TCP + HTTP sync.
