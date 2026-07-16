# Conversation Shard User Directory Boundary

## Boundary

Conversation shards own conversation, membership, message, outbox and shard-local projection facts. A
user_id stored in conversation_members or sender_user_id stored in im_messages is a logical reference to
the primary user directory; it is not a database foreign key.

The primary database remains the authority for:

- user existence and account status;
- email, display name and avatar profile;
- credentials, sessions, contacts and user-level moderation state.

Conversation shard code must not store a replicated users row, especially not credentials. User-facing
member lists, direct-peer summaries, administrative inspection, APNs sender labels and summary projections
resolve profile data from the primary directory through an explicit userDirectoryDB dependency.

## Schema Change

For new databases, CreateConversationMember and CreateConversationMessage create user_id and
sender_user_id as logical IDs without users foreign keys. Existing PostgreSQL conversation databases use
RemoveConversationUserForeignKeys, which discovers and drops only these two constraints.

The migration is intentionally non-reversible: recreating a cross-database foreign key would restore the
deployment coupling this boundary removes.

## Production Migration Sequence

This repository has not executed this sequence against a production server.

1. Back up every conversation shard and record its current migration state.
2. Deploy application code that reads user directory data from the primary database.
3. Run RemoveConversationUserForeignKeys through the ops role against every conversation shard.
4. Verify each shard has no foreign key from conversation_members.user_id or im_messages.sender_user_id
   to users.
5. Run member-list, direct-summary, message send and offline-push smoke tests with a shard that has no
   users table.
6. Only then enable routing to a separately provisioned conversation shard.

`IMMigrationRegistry` now registers the conversation-only migration set for every independent configured
`DATABASE_CONVERSATION_<SHARD>` database. The implicit default `shard-0` that reuses the primary database
does not receive a second migration registration. The shard set intentionally excludes `users`, auth,
contacts, owner-delivery and summary tables. `IMSchemaValidator` validates the primary directory, explicit
summary databases, and every configured conversation shard separately at startup. Migrations remain a
release operation: run them through the `ops` role and do not introduce a shard by pointing production
traffic at an unverified database.

## Directory Route Cache

Each application process keeps a bounded LRU cache for `conversationID -> shardID` lookups. Set the limit
explicitly on every multi-shard production role:

```text
IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES=50000
```

The exact value depends on the active conversation working set per process. Start at `50,000` for a cell
that serves tens of thousands of concurrent users, then tune from the following low-cardinality metrics:

- `im_conversation_shard_directory_cache_hits_total`
- `im_conversation_shard_directory_cache_misses_total`
- `im_conversation_shard_directory_cache_evictions_total`
- `im_conversation_shard_directory_lookup_latency_avg_millis`
- `im_conversation_shard_directory_cache_entries`

Cache misses fall back to the primary conversation directory. A route/cache failure must fail the request
or rely on durable client reconciliation; it must never trigger a cross-shard table scan.

## Cell Route Foundation

`conversation_directory` stores `cell_id`, `shard_id`, `route_state`, and `route_version`. New conversations
first reserve a `pending` primary-directory route, then commit the canonical conversation and its outbox
event on the selected shard. The command process activates the route immediately when possible; replay of
the durable `membership_added` event activates a still-pending route after a process crash or transient
primary-directory failure. Pending routes fail closed with `503`, so they can never fall through to a local
shard by accident. Legacy rows migrate as `active` with `route_version=1`.

The primary database owns this directory: a conversation-shard write no longer creates a second shard-local
route record. Route changes must be a separate, versioned migration operation; normal conversation creation
may not overwrite an existing route.
`ConversationDirectory.route(for:)` returns both values so gateway, command,
and strong-query routes can forward a remote-Cell conversation request before
they attempt a local shard lookup. The target Cell verifies the directory route
version and internal credential before executing the request.

后台跨分片治理命令会在受理时记录完整的 `cell_id`、`shard_id` 和 `route_version`，worker 在
写入前重新比对当前目录。版本不一致会以 `route_changed` 失败；目标不属于当前 cell 会以
`remote_cell` 失败。当前版本没有 remote-cell 命令转发，因此远端治理必须由目标 cell 的受控
命令入口接管，不能降级为本地 shard 查询。

Before moving an existing deployment to a non-default cell, back up the primary database and explicitly
attribute legacy rows. For a deployment where every legacy conversation belongs to `cell-a`:

```sql
UPDATE conversation_directory
SET cell_id = 'cell-a'
WHERE cell_id = 'default';
```

Do not run that bulk update for mixed legacy data; attribute those rows per conversation before cutover.
Public conversation-scoped requests now proxy to the configured target Cell and
fail closed with `503` if its required role-specific ingress endpoint is
missing. They never fall through to a local shard. Physical shard migration and
Cell failover remain separate controlled operations.

## Local Evidence

The following tests use an independent SQLite conversation database with no users table:

- adminConversationInspectionUsesPrimaryUserDirectoryAcrossShards
- userMemberListingUsesPrimaryUserDirectoryAcrossShards
- userConversationSummaryUsesPrimaryUserDirectoryAcrossShards
- migrationRegistryProvisionsConversationShardSchema
- directoryBackedShardRouterUsesBoundedLRUCache

They prove the code boundary locally. They do not prove PostgreSQL migration execution, production topology,
or live traffic behavior.
