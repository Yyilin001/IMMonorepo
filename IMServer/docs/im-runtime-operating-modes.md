# IM Runtime Operating Modes

This document is the operational source of truth for choosing an IMServer runtime shape. It does not change the HTTP, TCP, Kafka, outbox, or summary read-model protocol.

## Local Development

- Use `combined` by default.
- Start with `swift run` or `./scripts/run_local.sh`.
- Allowed responsibilities in one process: HTTP auth, command routes, query routes, TCP gateway, local projection worker, local routing, and local media/file storage.
- Startup migration policy: auto-migration is enabled by default. Set `IM_AUTO_MIGRATE_ON_START=false` only when explicitly testing schema validation.
- Inline projection policy: `combined` may run inline outbox projection for local convenience; this must not be used to simulate production.
- Required validation before manual client testing:
  - `cd IMServer && swift test --no-parallel`
  - sign in with two accounts
  - verify direct chat, group chat, reconnect `messages/since`, read state, and logout kick

## Staging / Multi-Role Validation

- Use the same role split as production, but non-production infrastructure may run with reduced capacity.
- Run these roles separately:
  - `gateway`
  - `command-api`
  - `query-api`
  - `outbox-relay`
  - `stream-consumer`
  - `ops`
- Validate that role route boundaries match production:
  - `gateway` exposes auth and gateway relay, not IM query routes.
  - `command-api` exposes IM mutation routes, not auth or IM query routes.
  - `query-api` exposes IM query routes, not auth or mutation routes.
  - `outbox-relay`, `stream-consumer`, and `ops` do not expose public HTTP APIs.
- Keep staging close to production for:
  - Kafka event stream
  - sharded summary read models
  - Redis-backed routing
  - S3-compatible media storage
  - Prometheus metrics on private networking
- Use staging to validate production startup behavior:
  - serving and worker roles should start with schema validation only.
  - migrations, reset, rebuild, verify, repair, requeue, and replay should be exercised through `ops`.
  - `IM_INLINE_OUTBOX_PROJECTION=true` should never be part of staging role manifests.

## Production

Production must never run `combined` or `projection-worker`.

Required roles:

- `gateway`: TCP, auth/session bootstrap, Redis presence, command ingress proxy, realtime dispatch.
- `command-api`: IM mutations, command-side persistence, outbox production, media/file mutation APIs.
- `query-api`: conversations, changes, messages, `messages/since`, and message search.
- `outbox-relay`: shard-local outbox claim and Kafka publication.
- `stream-consumer`: Kafka consumption, domain delivery/realtime relay, summary projection, changes log, search/notification/replay updates.
- `ops`: rebuild, verify, repair, requeue, replay, and inspect commands.

Required production posture:

- `IM_NODE_ID` is explicitly configured for every process.
- Every Gateway has explicit `IM_TCP_MAX_CONNECTIONS` and `IM_TCP_MAX_NEW_CONNECTIONS_PER_SECOND` values derived from load-tested safe budgets. Both limits apply before authentication, so unauthenticated sockets cannot exhaust the process or cause a reconnect storm; use load-balancer health/drain behavior to move new connections before either limit is reached.
- `IM_REDIS_DEPLOYMENT_TOPOLOGY=standalone` remains the simplest deployment mode; `REDIS_URL` must resolve to a stable primary endpoint, such as a managed HA service endpoint or a proxy that handles failover. Redis Cluster is supported through the Valkey client when every Redis-using role sets `IM_REDIS_CLUSTER_NODES=host-a:6379,host-b:6379,...`; Gateway and `realtime-delivery-consumer` additionally require `IM_NODE_DISPATCH_MODE=valkey-stream`. Cluster state is slot-scoped: routes use `{user}`, `{session}`, or `{conversation}` keys; timeline invalidation uses a bounded, hash-tagged Redis Stream and resumes after temporary disconnects. Redis-mode node dispatch is incompatible with Cluster. The Cluster backend currently accepts `redis://` seed/auth configuration only; do not set `rediss://` until TLS configuration is added and validated.
- Gateway node dispatch defaults to `IM_NODE_DISPATCH_MODE=redis` only for standalone compatibility. Redis Pub/Sub is a best-effort realtime hint and a target Gateway restart can lose it; durable owner/timeline sync remains the recovery path. A production Gateway using it must set `IM_ALLOW_BEST_EFFORT_NODE_DISPATCH=true`; startup otherwise fails so the risk cannot be selected accidentally. A multi-Gateway production Cell should use `IM_NODE_DISPATCH_MODE=valkey-stream` with Redis Cluster: publishers append a pre-routed envelope to the target Gateway's hash-tagged stream, and the target acknowledges it only after handing it to the local connection registry. `http` remains an explicit compatibility mode with `IM_GATEWAY_NODE_DISPATCH_ENDPOINTS=node-a=https://gateway-a.internal,node-b=https://gateway-b.internal` and a dedicated `IM_NODE_DISPATCH_SHARED_SECRET` (or the Cell/internal fallback). Each Gateway must include its own `IM_NODE_ID` in the map. The target accepts only `POST /internal/im/realtime/node-dispatch`, verifies its target node, credential, and a 15-second expiry, then delivers to local TCP connections without route lookup or forwarding.
- `IM_REALTIME_CELL_ID` is explicitly configured and identical for every role in one cell. Redis node presence, Redis-mode node dispatch, and timeline cache invalidation use the `im:cell:<cell-id>:*` namespace, so a Cell never treats another Cell's Gateway node as locally dispatchable. A separate renewable global presence lease records `user/session -> online cell IDs`; the source Cell uses it only to hand an already-targeted realtime packet to the destination Cell.
- For conversation routes whose directory `cell_id` differs from the receiving role's cell, configure separate maps for each target role: `IM_CELL_INGRESS_COMMAND_ENDPOINTS`, `IM_CELL_INGRESS_QUERY_ENDPOINTS`, and `IM_CELL_INGRESS_REALTIME_ENDPOINTS`, each in `cell-a=https://host-a.internal,cell-b=https://host-b.internal` form. Public mutations use the command map; `GET`/`HEAD` conversation reads use the query map; cross-Cell realtime envelopes use the Gateway map. `IM_REALTIME_CELL_INGRESS_ENDPOINTS` remains a legacy fallback only when a trusted internal L7 router routes all three surfaces. The public command/query route resolves the authoritative route and forwards exactly once with the original bearer credential, `X-IM-Internal-Secret`, target-cell, and route-version headers. The target revalidates its cell ownership and route version before executing the request. Production endpoints must use HTTPS; prefer private DNS plus mTLS at the network boundary. `IM_CELL_INGRESS_SHARED_SECRET` may override `IM_INTERNAL_SHARED_SECRET` for this channel.
- The realtime Cell ingress endpoint must expose `POST /internal/im/realtime/dispatch` on the Gateway role. It accepts only a one-hop, short-lived internal envelope authenticated with the Cell ingress secret, verifies that it is the intended target Cell, and sends only to local TCP connections. It must not re-route the envelope. This is an at-most-once realtime hint: durable owner/timeline sync remains the recovery path after a Cell endpoint outage.
- `command-api` sets `IM_HOT_CONVERSATION_LIMITER_MODE=redis` and a shared `IM_HOT_CONVERSATION_LIMITER_REDIS_URL` or `REDIS_URL`. The quota key is cell-scoped, so replicas enforce one hot-conversation limit instead of multiplying it per process.
- `IM_AUTO_MIGRATE_ON_START` is unset or `false` for `gateway`, `command-api`, `query-api`, `outbox-relay`, and `stream-consumer`.
- `IM_AUTO_MIGRATE_ON_START=true` is allowed only for the `ops` role during an explicit schema maintenance window.
- `IM_INLINE_OUTBOX_PROJECTION` is unset or `false`; production event flow must use `outbox-relay` and `stream-consumer`.
- Gateway sets `IM_COMMAND_API_INTERNAL_BASE_URL` and `IM_INTERNAL_SHARED_SECRET` so IM command ingress is proxied to command-api over authenticated internal traffic.
- `domain-delivery-consumer` and `realtime-delivery-consumer` stream processes set `IM_GATEWAY_RELAY_MODE=http`, `IM_GATEWAY_INTERNAL_BASE_URL`, and the same `IM_INTERNAL_SHARED_SECRET` as gateway, so large-group realtime relay cannot silently fall back to local-only delivery.
- `IM_EVENT_STREAM_DRIVER=kafka` for command, relay, and stream roles.
- Large-group realtime uses fixed active compact hints plus `timeline/since` catch-up; inactive online users are not fanned out realtime hints.
- Kafka production env uses `IM_KAFKA_REQUIRED_ACKS=all`, `IM_KAFKA_SECURITY_PROTOCOL=sasl_tls`, `IM_KAFKA_SASL_MECHANISM=scram-sha-512`, and explicit SASL username/password plus `IM_KAFKA_TLS_CA_FILE`.
- `IM_SUMMARY_PROJECTION_WRITE_MODE=sharded` outside explicit `ops` schema maintenance windows.
- `IM_SUMMARY_QUERY_READ_SOURCE=sharded`.
- `IM_CONVERSATION_SHARD_IDS` and every matching `DATABASE_CONVERSATION_<SHARD>_{HOST,PORT,USERNAME,PASSWORD,NAME}` value are present.
- `IM_SUMMARY_SHARD_IDS` and every matching `DATABASE_SUMMARY_<SHARD>_{HOST,PORT,USERNAME,PASSWORD,NAME}` value are present.
- `MEDIA_STORAGE_PROVIDER=s3compatible` for `command-api`, with explicit S3 endpoint, bucket, access key, secret key, region, and path-style setting.
- `IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT`, `IM_SEQUENCE_ALLOCATION_MODE=block`, matching `IM_COMMAND_NODE_ID` / `IM_COMMAND_NODE_URLS`, `IM_COMMAND_INTERNAL_SHARED_SECRET` or `IM_INTERNAL_SHARED_SECRET`, `IM_MESSAGE_WRITE_BATCH_ENABLED=true`, and an explicit `IM_GROUP_MEMBER_LIMIT` for production capacity. The current large-group template uses `1000`; keep the same value on `command-api` and `stream-consumer`, and keep it at or above `IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD`.
- Admin management is a `command-api` responsibility only. Keep `IM_ADMIN_API_ENABLED=false` by default; when enabling it, set a separate strong `IM_ADMIN_SHARED_SECRET` and expose `/admin` only behind private networking or an authenticated reverse proxy.
- `/internal/metrics` is enabled only on private networking.

## Production Startup Guards

| Condition | Expected failure text |
| --- | --- |
| `combined` in production | `combined runtime role is not supported in production` |
| `projection-worker` in production | `projection-worker is a development/testing fallback only` |
| non-`ops` with `IM_AUTO_MIGRATE_ON_START=true` | `must not run auto-migration on startup` |
| production with `IM_INLINE_OUTBOX_PROJECTION=true` | `Production must not enable IM_INLINE_OUTBOX_PROJECTION` |
| `gateway` without `IM_COMMAND_API_INTERNAL_BASE_URL` | `Production gateway requires IM_COMMAND_API_INTERNAL_BASE_URL` |
| `command-api` without Kafka producer mode | `command-api requires IM_EVENT_STREAM_DRIVER=kafka` |
| `command-api` without S3-compatible media storage | `Production command-api requires MEDIA_STORAGE_PROVIDER=s3compatible` |
| `command-api` without hot conversation limit | `Production command-api requires IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT` |
| `command-api` without block sequence allocation | `Production command-api requires IM_SEQUENCE_ALLOCATION_MODE=block` |
| `command-api` without message write batching | `Production command-api requires IM_MESSAGE_WRITE_BATCH_ENABLED=true` |
| `command-api` with admin enabled and no admin secret | `Production requires IM_ADMIN_SHARED_SECRET` |
| `query-api` without sharded summary reads | `Production summary query reads must use IM_SUMMARY_QUERY_READ_SOURCE=sharded` |
| `stream-consumer` without Kafka | `stream-consumer requires IM_EVENT_STREAM_DRIVER=kafka` |
| `stream-consumer` with multiple groups and no override | `Production stream-consumer deployments must run exactly one IM_STREAM_CONSUMER_GROUPS entry per process` |

## Production Acceptance Commands

The command-level release gate is documented in
[im-production-release-gate.md](im-production-release-gate.md). Use that runbook
as the source of truth for local smoke gates, full release gates, real env
preflight, CI artifacts, and failure handling.

- `cd IMServer && scripts/production_release_gate.sh --command-api /etc/im/command-api.env --gateway /etc/im/gateway.env --query-api /etc/im/query-api.env --outbox-relay /etc/im/outbox-relay.env --ops /etc/im/ops.env --stream-consumer /etc/im/stream-summary.env --stream-consumer /etc/im/stream-domain.env --stream-consumer /etc/im/stream-realtime.env --stream-consumer /etc/im/stream-notification.env --strict-secrets --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,notification-consumer`
- `cd IMServer && scripts/production_env_preflight.sh`
- `cd IMServer && scripts/production_env_preflight_test.sh`
- `cd IMServer && LoadTests/tcp_capacity_ladder_test.sh`
- `cd IMServer && scripts/production_env_preflight.sh --command-api /etc/im/command-api.env --gateway /etc/im/gateway.env --query-api /etc/im/query-api.env --outbox-relay /etc/im/outbox-relay.env --ops /etc/im/ops.env --stream-consumer /etc/im/stream-summary.env --stream-consumer /etc/im/stream-domain.env --stream-consumer /etc/im/stream-realtime.env --stream-consumer /etc/im/stream-notification.env --strict-secrets --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,notification-consumer`
- `cd IMServer && swift test --no-parallel`
- `cd IMServer && IM_POSTGRES_SMOKE_DATABASE_URL=postgres://user:password@127.0.0.1:5432/imserver_smoke swift test --no-parallel` (creates and removes an isolated schema; includes multi-worker governance-command claim verification)
- `IM_ENV=production IM_RUNTIME_ROLE=combined swift run IMServer serve` must fail.
- `IM_ENV=production IM_RUNTIME_ROLE=projection-worker swift run IMServer serve` must fail.
- `IM_ENV=production IM_RUNTIME_ROLE=gateway IM_AUTO_MIGRATE_ON_START=true swift run IMServer serve` must fail.
- `IM_ENV=production IM_RUNTIME_ROLE=command-api IM_INLINE_OUTBOX_PROJECTION=true swift run IMServer serve` must fail.
- Start each production role with its required env and confirm only role-owned routes are reachable.

`production_release_gate.sh` writes a timestamped markdown report plus per-step
`.log` files under `reports/`; CI uploads them as the
`imserver-production-release-gate-reports` artifact. The release gate runs
`swift test -c release --no-parallel` by default; use `--skip-swift-tests` only
for a local fast smoke gate that is not release acceptance evidence.

## Production Go / No-Go Checklist

Go only when all checks pass:

- Role startup guard rejects invalid production roles and missing required env.
- Route separation tests pass for `gateway`, `command-api`, `query-api`, `outbox-relay`, `stream-consumer`, and `ops`.
- Kafka producer and consumer configuration validates with production credentials.
- Summary projection writes and query reads are sharded.
- Outbox backlog drains after pausing and resuming relay/consumer workers.
- Duplicate stream delivery does not duplicate summaries, notifications, or search rows.
- Redis routing failure does not lose messages; reconnect `messages/since` recovers gaps.
- OpenSearch failure, when enabled, does not break primary message writes.
- Hot conversation limiter rejects overload without changing the TCP packet shape.

No-Go if any production process runs `combined`, runs `projection-worker`, auto-migrates outside `ops`, enables inline outbox projection, uses non-sharded summary reads or writes, exposes public metrics, bypasses conversation shard routing, or serves active-conversation fanout without route splitting.
