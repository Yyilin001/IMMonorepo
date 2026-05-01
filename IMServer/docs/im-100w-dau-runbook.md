# IMServer 100w DAU Upgrade Runbook

This runbook defines the target production posture for 1,000,000 DAU with private chats and small groups as the primary workload.

## Capacity Targets

- DAU: `1,000,000`
- Concurrent TCP connections: `50,000~100,000`
- Initial peak write target: `3,000 msg/s`
- Stretch peak write target: `10,000 msg/s`
- Message write latency: `P95 < 150ms`, `P99 < 300ms`
- `conversations/changes` convergence: `P95 < 2s`
- Search index lag: `P95 < 3s`
- Reconnect `messages/since` recovery success: `> 99.9%`
- Cross-node realtime dispatch success: `> 99.9%`

## Required Production Shape

- `gateway`: TCP, session bootstrap, Redis presence, realtime dispatch only.
- `command-api`: IM mutation ingress and command-side facts only.
- `query-api`: conversations, changes, messages, messages/since, and search only.
- `outbox-relay`: shard-local outbox claim and Kafka publish only.
- `stream-consumer`: one consumer group per process.
- `ops`: repair, replay, verify, and inspect commands only.

Production must not run `combined` or `projection-worker`.

## Required Config

- `IM_CONVERSATION_SHARD_IDS`
- `DATABASE_CONVERSATION_<SHARD>_*`
- optional `DATABASE_CONVERSATION_<SHARD>_REPLICA_*`
- `IM_SUMMARY_SHARD_IDS`
- `DATABASE_SUMMARY_<SHARD>_*`
- `IM_EVENT_STREAM_DRIVER=kafka`
- `IM_SEARCH_DRIVER=opensearch`
- `IM_STREAM_CONSUMER_GROUPS=<single-group>`
- `IM_OUTBOX_CLAIM_TIMEOUT_MS=60000`
- `IM_METRICS_ENABLED=true`
- `IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT=200`
- `IM_REDIS_MAX_CONNECTIONS=32`
- `MEDIA_STORAGE_PROVIDER=s3compatible`
- `MEDIA_STORAGE_S3_ENDPOINT`, `MEDIA_STORAGE_S3_BUCKET`, `MEDIA_STORAGE_S3_ACCESS_KEY_ID`, `MEDIA_STORAGE_S3_SECRET_ACCESS_KEY`
- optional repair worker: `IM_CONSISTENCY_REPAIR_ENABLED=true`, `IM_CONSISTENCY_REPAIR_INTERVAL_MS=30000`, `IM_CONSISTENCY_REPAIR_BATCH_SIZE=200`

## Observability

`GET /internal/metrics` exposes Prometheus text metrics for:

- TCP connections and cross-node dispatch success/failure.
- Redis route registrations.
- outbox processed/failed events, backlog, and oldest pending age.
- stream consumed/duplicate/failed/dead-letter-published events.
- DB operation count/failure/average/max latency.
- projection lag, search lag, and replay pending/failed counts.
- hot conversation rejection and tracked window counts.

Keep `/internal/metrics` on private networking only.

## Repair Commands

- `ops --inspect-conversation-outbox --shard <id>`
- `ops --verify-summary-shards`
- `ops --verify-search-lag --shard <id>`
- `ops --repair-search-lag --shard <id> --limit <n>`
- `ops --replay-conversation-dead-letter-events --limit <n>`
- `ops --requeue-conversation-dead-letter-events --limit <n>`

## Go / No-Go

Go only when:

- Outbox backlog drains after relay or consumer pause.
- Duplicate Kafka delivery does not duplicate read models or notifications.
- Redis routing failures degrade without message loss after reconnect gap sync.
- OpenSearch failure does not break primary message writes.
- Hot conversation limiter returns `hot_conversation_rate_limited` without changing the TCP packet shape.

No-Go if:

- Any role runs outside its production boundary.
- `query-api` uses legacy summary reads or database search fallback.
- Any production stream consumer runs multiple groups without a temporary explicit override.
- `messages/since` cannot repair realtime gaps.
