# IMServer 100w DAU Upgrade Runbook

This runbook defines the target production posture for 1,000,000 DAU with private chats and small groups as the primary workload. This phase explicitly excludes large groups/channels and media delivery scaling.

## Capacity Targets

- DAU: `1,000,000`
- Concurrent TCP connections: `50,000~100,000`
- Initial peak write target: `3,000 msg/s`
- Stretch peak write target: `10,000 msg/s`
- Message write latency: `P95 < 150ms`, `P99 < 300ms`
- `conversations/changes` convergence: `P95 < 2s`
- Search index lag: `P95 < 3s` when OpenSearch is enabled
- Reconnect `messages/since` recovery success: `> 99.9%`
- Cross-node realtime dispatch success: `> 99.9%`
- Small group size: `<= 500` members

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
- `IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES` and `IM_CONVERSATION_SHARD_DIRECTORY_CACHE_TTL_SECONDS=1..300` when using multiple conversation shards; the TTL bounds stale local routing after a Cell migration.
- `DATABASE_CONVERSATION_<SHARD>_*`
- optional `DATABASE_CONVERSATION_<SHARD>_REPLICA_*`
- `IM_SUMMARY_SHARD_IDS`
- `DATABASE_SUMMARY_<SHARD>_*`
- `IM_EVENT_STREAM_DRIVER=kafka`
- `IM_SEARCH_DRIVER=database` for deployments without OpenSearch
- optional large-scale search: `IM_SEARCH_DRIVER=opensearch`, `IM_OPENSEARCH_ENDPOINT`, `IM_OPENSEARCH_INDEX`
- `IM_STREAM_CONSUMER_GROUPS=<single-group>`
- `IM_OUTBOX_CLAIM_TIMEOUT_MS=60000`
- `IM_METRICS_ENABLED=true`
- `IM_TCP_MAX_CONNECTIONS=<per-gateway-budget>` on every gateway. This is a
  hard admission budget for all accepted TCP channels, including pre-auth
  channels; set it from a measured safe operating point rather than treating
  file-descriptor limits as a capacity target.
- `IM_TCP_MAX_NEW_CONNECTIONS_PER_SECOND=<per-gateway-reconnect-budget>` on
  every gateway. This rate limit protects authentication, Redis presence, and
  the event loop during reconnect storms; it must be tested with the expected
  load-balancer drain and client retry profile.
- Optional `IM_GATEWAY_CONTROL_SHARED_SECRET` protects the private
  `/internal/gateway/drain` control plane; when omitted it uses
  `IM_INTERNAL_SHARED_SECRET`. A drain first rejects new TCP channels, then
  reports remaining active/authenticated connections. `disconnectExisting=true`
  is an explicit final step that sends `server_shutdown` to local clients.
- `IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT=200`
- `IM_HOT_CONVERSATION_LIMITER_MODE=redis` with `IM_HOT_CONVERSATION_LIMITER_REDIS_URL` or `REDIS_URL`
- `IM_GROUP_MEMBER_LIMIT=1000` on `command-api` and `stream-consumer` for the current large-group posture; pure small-group deployments can lower this only with matching large-group thresholds.
- `IM_SEQUENCE_ALLOCATION_MODE=block`
- `IM_MESSAGE_WRITE_BATCH_ENABLED=true`
- `IM_REDIS_MAX_CONNECTIONS=32`
- `IM_REDIS_DEPLOYMENT_TOPOLOGY=standalone` remains a valid production posture with `REDIS_URL` resolving to a stable primary endpoint. Redis Cluster is also supported through explicit `IM_REDIS_CLUSTER_NODES`; Gateway and `realtime-delivery-consumer` must set `IM_NODE_DISPATCH_MODE=http` with a shared private node endpoint map. Connection routes use `{user}`, `{session}`, and `{conversation}` keys; hot-conversation limits, auth rate limits, and auth-session revisions are independently slot-routed. Timeline/since invalidation is a bounded, hash-tagged Redis Stream, so a temporary reader disconnect resumes from the last stream ID instead of relying on ordinary Pub/Sub delivery. Redis-mode node dispatch remains incompatible with Cluster. AI stream admission is stored as a primary-database lease and enforces user/conversation limits with PostgreSQL advisory locks.
- Gateway node dispatch starts as `IM_NODE_DISPATCH_MODE=redis`. Before migrating a Cell off Redis Pub/Sub, provision private HTTPS ingress per Gateway node and configure the same `IM_GATEWAY_NODE_DISPATCH_ENDPOINTS` map on every Gateway in that Cell. Then set `IM_NODE_DISPATCH_MODE=http`, use a dedicated node-dispatch secret, and monitor the existing `im_cross_node_dispatch_*` metrics through a one-Cell canary before rolling out more Cells.
- `IM_REALTIME_CELL_ID=cell-shenzhen-a` (use the same value for every role in the cell)
- multi-Cell routing: set `IM_CELL_INGRESS_COMMAND_ENDPOINTS=cell-shenzhen-a=https://command-api-cell-shenzhen-a.internal,cell-shanghai-a=https://command-api-cell-shanghai-a.internal`, plus equivalent `IM_CELL_INGRESS_QUERY_ENDPOINTS` and `IM_CELL_INGRESS_REALTIME_ENDPOINTS` maps. Use HTTPS private endpoints and optionally set a dedicated `IM_CELL_INGRESS_SHARED_SECRET`. Every non-empty entry must be `cell_id=https://host`; malformed entries make production startup fail. `IM_REALTIME_CELL_INGRESS_ENDPOINTS` is supported only as a legacy fallback for an internal L7 router that exposes all three roles.
- To remove endpoint-map rollout coupling, set `IM_CELL_INGRESS_REGISTRY_MODE=database` on every role in a Cell and use `ops --upsert-cell-ingress` to write all three private HTTPS endpoints. Database mode deliberately does not fall back to environment endpoint maps; resolver cache TTL is controlled by `IM_CELL_INGRESS_REGISTRY_CACHE_TTL_SECONDS=1..300`.
- the realtime endpoint must reach the target Gateway's `/internal/im/realtime/dispatch`; command and query endpoint maps must reach their corresponding API roles. Redis maintains renewable global user/session-to-Cell leases while keeping node routes Cell-local; verify `im_cross_cell_dispatch_*` alongside the existing local dispatch metrics during a multi-Cell rollout.
- `MEDIA_STORAGE_PROVIDER=s3compatible`
- `MEDIA_STORAGE_S3_ENDPOINT`, `MEDIA_STORAGE_S3_BUCKET`, `MEDIA_STORAGE_S3_ACCESS_KEY_ID`, `MEDIA_STORAGE_S3_SECRET_ACCESS_KEY`
- optional repair worker: `IM_CONSISTENCY_REPAIR_ENABLED=true`, `IM_CONSISTENCY_REPAIR_INTERVAL_MS=30000`, `IM_CONSISTENCY_REPAIR_BATCH_SIZE=200`

## Observability

`GET /internal/metrics` exposes Prometheus text metrics for:

- TCP connections, admission rejections, connection-limit closes, cross-node dispatch success/failure, and `im_node_dispatch_transport` for the selected node transport.
- Redis route registrations.
- outbox processed/failed events, backlog, and oldest pending age.
- stream consumed/duplicate/failed/dead-letter-published events.
- DB operation count/failure/average/max latency.
- projection lag, search lag, and replay pending/failed counts.
- hot conversation rejection and tracked window counts.
- query-api `timeline/since` latency histogram, visibility scan limits, hot/recent
  cache hit/miss/bypass counters, target-sequence fallback/satisfied/miss/error
  counters, target-sequence singleflight joins, and target-sequence window joins.

Keep `/internal/metrics` on private networking only.

## Alert Response

The Prometheus rule file at
[`monitoring/prometheus/imserver-alerts.yml`](../../monitoring/prometheus/imserver-alerts.yml)
alerts only on low-cardinality service signals. Do not add a conversation ID,
user ID, event ID, or message content as a metric label. Use the structured
delivery logs and the read-only `ops` commands below for per-conversation
diagnosis.

| Alert | First response | Recovery boundary |
| --- | --- | --- |
| `IMServerOutboxPublicationStalled` | Check `im_outbox_backlog_events`, `im_outbox_oldest_pending_age_millis`, Kafka producer errors, and the outbox-relay role health. | Restore Kafka or the relay; do not delete pending outbox rows. Verify backlog drains before clearing the incident. |
| `IMServerOutboxPublicationStalledCritical` | Treat the relay/Kafka path as impaired. Stop increasing write load and capture consumer/producer diagnostics. | Resume the relay and use `ops --inspect-conversation-outbox --shard <id>` before any repair or replay. |
| `IMServerConversationShardMigrationCopyFailure` | Stop the migration workflow and inspect its immutable prepared record and page watermarks. | Correct the target/ingress/storage failure, then rerun the idempotent copy command. Do not cut over. |
| `IMServerConversationShardMigrationVerificationFailure` | Treat source and target state as divergent. | Run `ops --inspect-conversation-shard-migration --conversation-id <uuid> --target-shard <id>` and repeat copy/verification only after the mismatch is understood. Do not manually change the directory route. |
| `IMServerConversationShardMigrationRemoteTransferFailure` | Check Cell ingress authentication, route version, transfer-capability expiry, and target Cell health. | Renew the transfer capability only when needed, then resume paged copy. Keep the source route active until verification succeeds. |

An alert does not authorize destructive repair. Migration cutover remains a
manual, version-checked `ops` operation with the source write fence held until
the target fingerprint and search index have been verified.

## Gateway Drain

For a rolling Gateway deployment, remove the target from new TCP load-balancer
selection, then call `PUT /internal/gateway/drain` with the private control
credential and `{ "draining": true, "disconnectExisting": false }`. Poll the
same endpoint until active connections reach the deployment threshold. Only if
the timeout expires, repeat with `disconnectExisting: true`; clients receive a
`server_shutdown` packet and reconnect through the load balancer. Reset with
`{ "draining": false, "disconnectExisting": false }` only after the instance
is returned to service.

## Repair Commands

- `ops --inspect-conversation-outbox --shard <id>`
- `ops --verify-summary-shards`
- `ops --verify-search-lag --shard <id>`
- `ops --repair-search-lag --shard <id> --limit <n>`
- `ops --replay-conversation-dead-letter-events --limit <n>`
- `ops --requeue-conversation-dead-letter-events --limit <n>`
- `ops --inspect-conversation-shard-migration --conversation-id <uuid> --target-shard <id>`
  is a read-only gate before a physical shard migration. It verifies the active
  local source route, the configured target shard, source canonical-row counts,
  and that the target contains no colliding conversation state. It never copies
  data or changes `conversation_directory`; do not update a route until the
  future copy/verify/cutover workflow has completed.
  Add `--target-cell <id>` to perform the same read-only target check through
  that Cell's authenticated command ingress. This validates remote endpoint,
  credential, target shard, and target snapshot only.
- `ops --prepare-conversation-shard-migration --conversation-id <uuid> --target-shard <id>`
  persists an idempotent `prepared` control record containing the source route
  version and canonical-row snapshot. Add `--target-cell <id>` to bind the
  intent to an empty remote target and issue a short-lived transfer capability;
  it never updates the active route.
  A remote Cell may use the same local shard name as the source (for example,
  `shard-0` in both Cells); only a same-Cell move requires a different shard ID.
- `ops --copy-conversation-shard-migration --conversation-id <uuid> --page-size <n>`
  copies canonical conversation rows to the prepared target shard in durable
  pages. A repeat after an interrupted run is safe: destination rows are keyed
  by their canonical IDs and each source-row watermark advances only after its
  target transaction commits. For a remote target, each page is checksummed
  and accepted only when its source route, target shard, active migration state,
  and transfer capability match the primary control record. Pending/failed
  outbox events and active AI streams block preparation, so copy never
  transfers unfinished side effects.
- `ops --verify-conversation-shard-migration --conversation-id <uuid> --page-size <n>`
  compares the prepared source snapshot and a deterministic canonical SHA-256
  fingerprint on both shards/Cells, including resolved recipient snapshots. It
  transitions only to `ready_to_cutover`; it intentionally does **not** alter
  `conversation_directory`.
- `ops --cutover-conversation-shard-migration --conversation-id <uuid> --page-size <n>`
  is a manual source-Cell cutover. It obtains a short-lived control-record
  lease, blocks the source-shard write fence, repeats canonical verification,
  asks the destination Cell to rebuild its local target search index under the
  same lease, then performs a version-checked atomic directory update. The old
  source fence stays blocked after success; retain the source rows for audit
  and recovery instead of deleting them immediately.
- `ops --renew-conversation-shard-migration-transfer-token --conversation-id <uuid>`
  rotates the 24-hour remote-transfer capability without changing source route,
  destination binding, or copy watermarks. Run it from the source Cell before
  the current capability expires; it is unnecessary for local moves.
- `ops --inspect-conversation-shard-migration-retention --conversation-id <uuid> --retention-min-age-seconds <n>`
  is a read-only source-copy purge gate. It requires a completed cutover, the
  target directory route, a blocked source fence, stable prepared source
  counts/fingerprint, no unfinished source event, and the requested retention
  age. It does not delete any rows; global recipient sets and read-side records
  may be shared, so physical purge remains an explicit reviewed operation.

Migration preparation creates a source-shard `conversation_write_fences`
record. Canonical command paths lock this record in the same transaction as
their mutation, allowing cutover to block new writes and drain transactions
already holding the fence. A failed cutover reopens the source fence only while
the directory still points at the source route.

Do not run a route-only cutover. Automatic/background cutover remains disabled.
The local copier transfers recipient snapshots as self-contained recipient
lists and copies domain-event side-effect claims with their event page, then
verifies both auxiliary row counts before cutover. Cross-Cell transfer,
verification, and target search-index rebuild use the same primary control
record, source route version, Cell ingress secret, short-lived migration
capability, and (for finalization) cutover lease. All participating Cells must
use the same primary control database and private command ingress. Source
retention cleanup and rollback automation are still separate work.

## Go / No-Go

Go only when:

- `IM_GROUP_MEMBER_LIMIT` is explicitly enforced for create/add-member flows, present on stream consumers, and at least every enabled large-group protection threshold.
- `3,000 msg/s` write pressure holds `P95 < 150ms` and `P99 < 300ms`.
- `conversations/changes` convergence holds `P95 < 2s`.
- Outbox backlog drains after relay or consumer pause.
- Duplicate Kafka delivery does not duplicate read models or notifications.
- Redis routing failures degrade without message loss after reconnect gap sync.
- Search index failure does not break primary message writes.
- Hot conversation limiter returns `hot_conversation_rate_limited` without changing the TCP packet shape.

No-Go if:

- Any role runs outside its production boundary.
- `query-api` uses non-sharded summary reads.
- Any production stream consumer runs multiple groups without an explicit grouped-process override.
- `messages/since` cannot repair realtime gaps.
- Targeted `timeline/since` catch-up has non-zero strong misses/errors, or high
  source read amplification without corresponding target-sequence singleflight joins
  during hot large-group compact-hint validation.
- Large groups/channels or media traffic are included in the claim without separate capacity validation.

## Load Test Entrypoints

- Production topology smoke: `cd IMServer && ./scripts/production_smoke.sh run`
- Valkey Cluster smoke: `cd IMServer && ./scripts/cluster_smoke.sh run`. This starts a three-primary Cluster overlay, then runs the same outbox/Kafka/query smoke flow; run `./scripts/cluster_smoke.sh failure-drill redis-outage` before claiming Cluster outage recovery.
- Failure drills: `cd IMServer && ./scripts/failure_drill.sh pause-stream-consumer`.
  For a migrated route, also run `./scripts/multicell_smoke.sh failure-drill redis-outage`
  and `./scripts/multicell_smoke.sh failure-drill kafka-outage`; both require
  the Cell B outbox to recover before they pass.
- Staging baseline wrapper: `cd IMServer && ./scripts/staging_baseline.sh --profile staging-baseline --env-file LoadTests/staging-baseline.env`
- HTTP smoke: `cd IMServer/LoadTests/k6 && k6 run -e PROFILE=local-smoke http-small-group.js`
- HTTP staging baseline: `cd IMServer/LoadTests/k6 && k6 run -e PROFILE=staging-baseline http-small-group.js`
- TCP smoke: `cd IMServer/LoadTests/TCPDriver && swift run IMTCPLoadDriver --profile local-smoke`
- Capacity target profiles are manual-only and must run against isolated staging infrastructure.
