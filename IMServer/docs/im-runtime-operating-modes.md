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
  - migrations, reset, backfill, verify, repair, requeue, and replay should be exercised through `ops`.
  - `IM_INLINE_OUTBOX_PROJECTION=true` should never be part of staging role manifests.

## Production

Production must never run `combined` or `projection-worker`.

Required roles:

- `gateway`: TCP, auth/session bootstrap, Redis presence, command ingress proxy, realtime dispatch.
- `command-api`: IM mutations, command-side persistence, outbox production, media/file mutation APIs.
- `query-api`: conversations, changes, messages, `messages/since`, and message search.
- `outbox-relay`: shard-local outbox claim and Kafka publication.
- `stream-consumer`: Kafka consumption, summary projection, changes log, search/notification/replay updates.
- `ops`: rebuild, verify, repair, requeue, replay, and inspect commands.

Required production posture:

- `IM_NODE_ID` is explicitly configured for every process.
- `IM_AUTO_MIGRATE_ON_START` is unset or `false` for `gateway`, `command-api`, `query-api`, `outbox-relay`, and `stream-consumer`.
- `IM_AUTO_MIGRATE_ON_START=true` is allowed only for the `ops` role during an explicit migration window.
- `IM_INLINE_OUTBOX_PROJECTION` is unset or `false`; production event flow must use `outbox-relay` and `stream-consumer`.
- `IM_EVENT_STREAM_DRIVER=kafka` for command, relay, and stream roles.
- `IM_SUMMARY_PROJECTION_WRITE_MODE=sharded` outside temporary `ops` migration windows.
- `IM_SUMMARY_QUERY_READ_SOURCE=sharded` outside temporary `ops` migration windows.
- `IM_CONVERSATION_SHARD_IDS` and all matching `DATABASE_CONVERSATION_<SHARD>_*` values are present.
- `IM_SUMMARY_SHARD_IDS` and all matching `DATABASE_SUMMARY_<SHARD>_*` values are present.
- `MEDIA_STORAGE_PROVIDER=s3compatible` for `command-api`.
- `IM_SEQUENCE_ALLOCATION_MODE=block`, `IM_MESSAGE_WRITE_BATCH_ENABLED=true`, and `IM_GROUP_MEMBER_LIMIT=500` for production small-group capacity.
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
| `query-api` without sharded summary reads | `Production summary query reads must use IM_SUMMARY_QUERY_READ_SOURCE=sharded` |
| `stream-consumer` without Kafka | `stream-consumer requires IM_EVENT_STREAM_DRIVER=kafka` |
| `stream-consumer` with multiple groups and no override | `Production stream-consumer deployments must run exactly one IM_STREAM_CONSUMER_GROUPS entry per process` |

## Production Acceptance Commands

- `cd IMServer && swift test --no-parallel`
- `cd IMServer && IM_POSTGRES_SMOKE_DATABASE_URL=postgres://user:password@127.0.0.1:5432/imserver_smoke swift test --no-parallel`
- `IM_ENV=production IM_RUNTIME_ROLE=combined swift run IMServer serve` must fail.
- `IM_ENV=production IM_RUNTIME_ROLE=projection-worker swift run IMServer serve` must fail.
- `IM_ENV=production IM_RUNTIME_ROLE=gateway IM_AUTO_MIGRATE_ON_START=true swift run IMServer serve` must fail.
- `IM_ENV=production IM_RUNTIME_ROLE=command-api IM_INLINE_OUTBOX_PROJECTION=true swift run IMServer serve` must fail.
- Start each production role with its required env and confirm only role-owned routes are reachable.

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

No-Go if any production process runs `combined`, runs `projection-worker`, auto-migrates outside `ops`, enables inline outbox projection, reads legacy summaries, writes legacy summaries outside an explicit `ops` transition, exposes public metrics, or bypasses conversation shard routing.
