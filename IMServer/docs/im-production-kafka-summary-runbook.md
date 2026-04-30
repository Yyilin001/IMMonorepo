# IMServer Kafka + Summary Shards Production Runbook

This runbook describes the production rollout path for the current IMServer distributed data plane:

- `gateway`
- `command-api`
- `query-api`
- `outbox-relay`
- `stream-consumer`
- `ops`

The rollout keeps the client protocol unchanged and uses:

- Kafka with `SASL/TLS + SCRAM-SHA-512`
- summary read models sharded by `ownerUserID`
- `backfill + sharded query cutover`

## 1. Role Responsibilities

### `gateway`

- owns TCP / session bootstrap / Redis presence / dispatch
- proxies authenticated IM mutate ingress to `command-api` over the internal command bridge
- does not serve IM query or mutate HTTP routes

### `command-api`

- serves IM mutate routes only
- persists command-side facts
- relays realtime back through gateway HTTP relay
- does not own connection registry

### `query-api`

- serves `conversations`, `conversations/changes`, `messages`, `messages/since`, `search`
- reads summary / changes from sharded summary stores
- reads search from OpenSearch and returns shard-backed message aggregates

### `outbox-relay`

- scans shard-local DB outbox
- publishes Kafka stream envelopes
- marks `streamPublishedAt`

### `stream-consumer`

- consumes Kafka topics
- updates summary, changes, search, notification, replay stores
- should be deployed as one consumer group per process in production

### `ops`

- runs rebuild / verify / repair / requeue / replay commands

## 2. Kafka Prerequisites

Provision these topics before enabling production traffic:

- `conversation-domain-events`
- `conversation-domain-events-dead-letter`

Provision credentials and trust material for:

- `IM_KAFKA_SASL_USERNAME`
- `IM_KAFKA_SASL_PASSWORD`
- `IM_KAFKA_TLS_CA_FILE`
- optional client cert/key if the broker requires mutual TLS

The current server code expects:

- `IM_KAFKA_SECURITY_PROTOCOL=sasl_tls`
- `IM_KAFKA_SASL_MECHANISM=scram-sha-512`
- `IM_KAFKA_REQUIRED_ACKS=all`
- `IM_KAFKA_AUTO_CREATE_TOPICS=false`

## 2.1 Conversation Shard Prerequisites

Conversation command/query routing must always go through `ConversationShardRouter`, even when production still runs a single command shard.

Example:

- `IM_CONVERSATION_SHARD_IDS=shard-0`
- `DATABASE_CONVERSATION_SHARD_0_*`
- optional `DATABASE_CONVERSATION_SHARD_0_REPLICA_*`

Important:

- shard environment names use the normalized shard ID
- `shard-0` becomes `SHARD_0`
- every shard listed in `IM_CONVERSATION_SHARD_IDS` must have a full `DATABASE_CONVERSATION_<SHARD>_*` block in production
- `query-api`, `command-api`, `outbox-relay`, `stream-consumer`, and `ops` must all see the same conversation shard topology

## 3. Summary Shard Prerequisites

Summary read models are routed by `ownerUserID` and require one PostgreSQL database per shard.

Example:

- `IM_SUMMARY_SHARD_IDS=summary-a,summary-b`
- `DATABASE_SUMMARY_SUMMARY_A_*`
- `DATABASE_SUMMARY_SUMMARY_B_*`

Important:

- shard environment names use the normalized shard ID
- `summary-a` becomes `SUMMARY_A`
- every shard listed in `IM_SUMMARY_SHARD_IDS` must have a full `DATABASE_SUMMARY_<SHARD>_*` block in production

Each shard must contain:

- `im_conversation_user_summaries`
- `conversation_changes_log`
- `conversation_read_model_tokens`
- `conversation_notification_events`

## 4. Deployment Order

Roll out in this exact order.

### Stage A: Base HTTP/Gateway Roles

Deploy:

- `gateway`
- `command-api`
- `query-api`

Required internal ingress wiring:

- `gateway` must set `IM_COMMAND_API_INTERNAL_BASE_URL`
- `command-api` must set `IM_GATEWAY_INTERNAL_BASE_URL`
- both sides must share the same `IM_INTERNAL_SHARED_SECRET`

Keep:

- `IM_SUMMARY_PROJECTION_WRITE_MODE=sharded`
- `IM_SUMMARY_QUERY_READ_SOURCE=sharded`
- `IM_SEARCH_DRIVER=opensearch`

### Stage B: Kafka Event Path

Deploy:

- `outbox-relay`
- `stream-consumer` with one group per deployment:
  - `summary-projection-consumer`
  - `changes-log-consumer`
  - `search-index-consumer`
  - `notification-consumer`
  - `repair-replay-consumer`

Verify:

- outbox rows receive `streamPublishedAt`
- Kafka consumers advance independently
- dead-letter records land in replay store

### Stage C: Summary Shards Migration

1. create summary shard databases
2. run migrations against every shard
3. keep `IM_SUMMARY_PROJECTION_WRITE_MODE=sharded`
4. keep `IM_SUMMARY_QUERY_READ_SOURCE=sharded`
5. run:

```bash
IMServer serve --role ops --rebuild-conversation-summaries
IMServer serve --role ops --verify-conversation-summaries
```

6. only if you are finishing a pre-existing migration window, temporarily enable:

```env
IM_ALLOW_TRANSITIONAL_READ_MODELS=true
IM_SUMMARY_PROJECTION_WRITE_MODE=dual-write
IM_SUMMARY_QUERY_READ_SOURCE=legacy
```

7. once verification passes, remove the transitional override and return to sharded-only mode

### Stage D: Search Cutover

1. provision OpenSearch
2. set `IM_SEARCH_DRIVER=opensearch`
3. set `IM_OPENSEARCH_ENDPOINT`
4. set `IM_OPENSEARCH_INDEX`
5. let `search-index-consumer` build the new index
6. do not keep database search fallback enabled in production

### Stage E: Conversation Shards

Do this last.

1. define `IM_CONVERSATION_SHARD_IDS`
2. provision `DATABASE_CONVERSATION_<SHARD>_*` for every listed shard
3. optionally provision `DATABASE_CONVERSATION_<SHARD>_REPLICA_*`
4. keep router-enabled single-shard mode first
5. expand to multiple conversation shards only after Kafka + summary shards + OpenSearch are stable

## 5. Cutover Safety Rules

- never hard-cut summary reads without backfill and verify
- never enable production `combined`
- do not run `projection-worker` in production; it is a development/testing fallback only
- do not let `command-api` use local gateway relay in production
- do not let `gateway` proxy IM mutate traffic without `IM_COMMAND_API_INTERNAL_BASE_URL`
- do not let production `query-api` use `legacy` summary reads
- do not let production `stream-consumer` use `legacy` or `dual-write` summary projection modes unless `ops` is explicitly running a temporary migration override
- do not let production `query-api` use database search fallback
- do not let production `stream-consumer` run multiple consumer groups in one process unless `IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP=true` is set for a temporary transition
- do not let any production role bypass `IM_CONVERSATION_SHARD_IDS` once conversation router topology is enabled

## 6. Production Verification Checklist

Before enabling production traffic, confirm:

- `gateway` does not expose IM query/mutate routes
- `command-api` does not initialize local routing
- `query-api` does not expose mutate routes
- `outbox-relay` does not start HTTP/TCP
- `stream-consumer` does not start HTTP/TCP
- Kafka producer connects with `SASL/TLS`
- dead-letter events can be replayed through `ops --replay-conversation-dead-letter-events`
- `conversations` and `conversations/changes` come from sharded summary stores
- `search` resolves through OpenSearch and still returns shard-backed message aggregates
- `visibleFromSequence` does not regress during projection lag or reconnect

## 7. Role Templates

Use the production env templates under:

- `/Users/yy/Desktop/vaporTest/IMServer/config/env/gateway.production.env.example`
- `/Users/yy/Desktop/vaporTest/IMServer/config/env/command-api.production.env.example`
- `/Users/yy/Desktop/vaporTest/IMServer/config/env/query-api.production.env.example`
- `/Users/yy/Desktop/vaporTest/IMServer/config/env/outbox-relay.production.env.example`
- `/Users/yy/Desktop/vaporTest/IMServer/config/env/stream-consumer.production.env.example`
- `/Users/yy/Desktop/vaporTest/IMServer/config/env/ops.production.env.example`
